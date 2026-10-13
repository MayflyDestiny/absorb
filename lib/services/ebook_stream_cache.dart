import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:path_provider/path_provider.dart';

import 'http_range_book_source.dart' show fmtBytes;
import 'stream_cache_eviction.dart';

/// Whether to print per-book cache reuse summaries (`[EbookStreamCache] open`
/// / `closed`). Flip off to quiet the log once streaming reuse is verified.
bool ebookStreamCacheDebugLog = true;

/// Whether to also print every individual block read (`HIT`/`MISS`/`store`).
/// Off by default: a single 161 MB open emits thousands of these lines, which
/// drowns out everything else. Turn on only to trace block-level behaviour.
bool ebookStreamCacheTraceLog = false;

/// Block size for the streamed-ebook disk cache. epub.js reads the zip central
/// directory and then each section on demand, and most of those sections are
/// small, so 256KB keeps the over-fetch from rounding a tiny range up to a huge
/// block modest while still cutting the number of requests. Bigger blocks waste
/// more on scattered reads; smaller blocks mean more separate requests/files.
const int ebookStreamCacheBlockSize = 1 << 18;

Future<Directory> _ebookStreamCacheRoot() async {
  final tmp = await getTemporaryDirectory();
  final dir = Directory('${tmp.path}${Platform.pathSeparator}ebook_stream_cache');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// Disk block cache for one streamed ebook version.
///
/// Keyed by item id plus the file's version (ino) rather than the request URL,
/// so the rotating `?token=` the server hands out can't spawn a fresh cache on
/// every open. Each fetched block is a separate `<index>.blk` file, so an
/// interrupted read leaves at most one torn block (written via temp+rename) and
/// eviction can drop the coldest blocks without discarding a whole book.
class EbookStreamCache {
  EbookStreamCache._(this._dir, this._key);

  final Directory _dir;
  final String _key;
  final Map<int, Future<Uint8List?>> _inflight = {};
  int _hits = 0;
  int _misses = 0;

  /// Cache key (item id + version) this instance reads and writes under.
  String get key => _key;

  /// Block reads served from disk (no network) / fetched from the network.
  int get cacheHits => _hits;
  int get cacheMisses => _misses;

  /// Opens the block cache for [ebookFile] of [itemId], or null when the
  /// streaming-cache setting is 0 - the caller then reads straight from the
  /// network and nothing is persisted.
  static Future<EbookStreamCache?> open(
      String itemId, Map<String, dynamic> ebookFile) async {
    if (await streamCacheTotalMaxBytes() <= 0) return null;
    final ino = ebookFile['ino']?.toString() ?? '';
    final key = ino.isEmpty ? itemId : '$itemId.$ino';
    final root = await _ebookStreamCacheRoot();
    final dir = Directory('${root.path}${Platform.pathSeparator}$key');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final cache = EbookStreamCache._(dir, key);
    if (ebookStreamCacheDebugLog) {
      final existing = await cache._countBlocks();
      debugPrint('[EbookStreamCache] open $key: ${existing.$1} blocks / '
          '${fmtBytes(existing.$2)} already on disk (block=${fmtBytes(ebookStreamCacheBlockSize)})');
    }
    return cache;
  }

  /// (block count, total bytes) currently persisted for this key.
  Future<(int, int)> _countBlocks() async {
    var count = 0;
    var bytes = 0;
    try {
      if (_dir.existsSync()) {
        await for (final e in _dir.list(followLinks: false)) {
          if (e is! File || !e.path.endsWith('.blk')) continue;
          count++;
          try {
            bytes += e.lengthSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return (count, bytes);
  }

  File _blockFile(int index) =>
      File('${_dir.path}${Platform.pathSeparator}$index.blk');

  /// The cached bytes of block [index], or null on a miss.
  Future<Uint8List?> readBlock(int index) async {
    try {
      final f = _blockFile(index);
      if (!f.existsSync()) return null;
      final data = await f.readAsBytes();
      return data.isEmpty ? null : data;
    } catch (_) {
      return null;
    }
  }

  /// Persists block [index] atomically (temp file then rename) so a crash or a
  /// concurrent eviction never leaves a torn block that reads back as the book.
  Future<void> writeBlock(int index, Uint8List data) async {
    try {
      final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final tmp = File(
          '${_dir.path}${Platform.pathSeparator}$index.$nonce.blk.part');
      await tmp.writeAsBytes(data, flush: false);
      final f = _blockFile(index);
      if (f.existsSync()) await f.delete();
      await tmp.rename(f.path);
      if (ebookStreamCacheTraceLog) {
        debugPrint('[EbookStreamCache] $_key store block $index ${fmtBytes(data.length)}');
      }
    } catch (_) {
      // Best-effort: a failed write just means the block is fetched again.
    }
  }

  /// Bytes of block [index], serving a cached copy when present and otherwise
  /// fetching through [fetch] and persisting a full block. Concurrent reads of
  /// the same missing block share one fetch.
  Future<Uint8List?> block(
    int index,
    int blockStart,
    int blockLen,
    Future<Uint8List> Function(int offset, int count) fetch,
  ) async {
    final cached = await readBlock(index);
    if (cached != null) {
      _hits++;
      if (ebookStreamCacheTraceLog) {
        debugPrint('[EbookStreamCache] $_key block $index HIT ${fmtBytes(cached.length)}');
      }
      return cached;
    }
    final pending = _inflight[index];
    if (pending != null) {
      _hits++;
      return pending;
    }
    _misses++;
    if (ebookStreamCacheTraceLog) {
      debugPrint('[EbookStreamCache] $_key MISS block $index (offset $blockStart)');
    }
    final future = _fetchAndStore(index, blockStart, blockLen, fetch);
    _inflight[index] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(index);
    }
  }

  Future<Uint8List?> _fetchAndStore(
    int index,
    int blockStart,
    int blockLen,
    Future<Uint8List> Function(int offset, int count) fetch,
  ) async {
    try {
      final data = await fetch(blockStart, blockLen);
      // Only cache a whole block; a short read (server hiccup) is served now but
      // left unpersisted so the next read retries the full block.
      if (data.length == blockLen) await writeBlock(index, data);
      return data;
    } catch (_) {
      return null;
    }
  }
}

/// A [BookSource] that reads an ebook through [cache]: every requested span is
/// served from cached blocks, fetching only the missing ones from [_inner].
class CachingBookSource implements BookSource {
  CachingBookSource(this._inner, this._cache, this._length);

  final BookSource _inner;
  final EbookStreamCache _cache;
  final int _length;

  @override
  Future<int> length() async => _length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (count <= 0 || offset < 0 || offset >= _length) return Uint8List(0);
    final end = offset + count < _length ? offset + count : _length;
    final firstBlock = offset ~/ ebookStreamCacheBlockSize;
    final lastBlock = (end - 1) ~/ ebookStreamCacheBlockSize;
    final out = Uint8List(end - offset);

    for (var b = firstBlock; b <= lastBlock; b++) {
      final blockStart = b * ebookStreamCacheBlockSize;
      final blockLen = blockStart + ebookStreamCacheBlockSize <= _length
          ? ebookStreamCacheBlockSize
          : _length - blockStart;
      final data = await _cache.block(
          b, blockStart, blockLen, (o, n) => _inner.read(o, n));
      // A missing or truncated block means the underlying source couldn't serve
      // the whole span; fail the read the way the raw HTTP source does rather
      // than return a zero-filled tail the reader would parse as real bytes.
      if (data == null || data.length < blockLen) return Uint8List(0);
      final srcFrom = offset > blockStart ? offset - blockStart : 0;
      final srcTo = end - blockStart < data.length ? end - blockStart : data.length;
      if (srcTo <= srcFrom) continue;
      final dst = blockStart + srcFrom - offset;
      out.setRange(dst, dst + (srcTo - srcFrom), data, srcFrom);
    }
    return out;
  }

  @override
  Future<void> close() async {
    if (ebookStreamCacheDebugLog) {
      final total = _cache.cacheHits + _cache.cacheMisses;
      debugPrint('[EbookStreamCache] ${_cache.key} closed: '
          '${_cache.cacheHits} hits / ${_cache.cacheMisses} misses of $total block reads');
    }
    await _inner.close();
  }
}

bool _isBlock(File file) => file.path.endsWith('.blk');

/// Total bytes of the streamed-ebook block cache currently on disk (whole
/// blocks only; half-written `.part` temps are ignored).
Future<int> ebookStreamCacheUsageBytes() async {
  return streamCacheUsageBytes(await _ebookStreamCacheRoot(), include: _isBlock);
}

/// Enforce the flat total cap shared with the audio/PDF streaming caches. Only
/// whole blocks are deleted, oldest-first (by last modification) until the total
/// fits the 流式缓存 MB setting. When that setting is 0 the cache is not persisted
/// at all - every idle block is dropped. Blocks modified within
/// [streamCacheInUseWindow] are skipped so an open reader never has its book
/// pulled out from under it.
Future<void> enforceEbookStreamCacheLimits() async {
  await enforceStreamCacheLimit(await _ebookStreamCacheRoot(),
      include: _isBlock);
}

/// Delete the whole streamed-ebook block cache. Every block is regenerable on
/// demand, so this is always safe outside of an open streamed-ebook viewer.
Future<void> clearEbookStreamCache() async {
  await clearStreamCacheDir(await _ebookStreamCacheRoot());
}

/// Delete the persisted stream blocks for one version of [itemId] (its
/// `<itemId>` / `<itemId>.<ino>` directory). Called once the version is fully
/// cached or exported, so a book that now has a complete local copy isn't left
/// holding a second set of temp blocks. No-op when nothing was streamed.
Future<void> clearEbookStreamCacheVersion(
    String itemId, Map<String, dynamic> ebookFile) async {
  try {
    final ino = ebookFile['ino']?.toString() ?? '';
    final key = ino.isEmpty ? itemId : '$itemId.$ino';
    final root = await _ebookStreamCacheRoot();
    final dir = Directory('${root.path}${Platform.pathSeparator}$key');
    if (dir.existsSync()) await dir.delete(recursive: true);
  } catch (_) {}
}

/// Delete the persisted stream blocks for every version of [itemId] (all
/// `<itemId>` / `<itemId>.<ino>` dirs). Used when the item's ebook is removed.
Future<void> clearEbookStreamCacheItem(String itemId) async {
  try {
    final root = await _ebookStreamCacheRoot();
    if (!root.existsSync()) return;
    for (final e in root.listSync()) {
      final name = e.path.split(Platform.pathSeparator).last;
      if (name == itemId || name.startsWith('$itemId.')) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    }
  } catch (_) {}
}
