import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'stream_cache_eviction.dart';

// pdfrx's streamed-PDF block cache lives under
// `<Pdfrx.cacheDirectoryPath>/pdfrx.cache/<xx>/<yy>/<hash>.pdf`. pdfrx fetches
// only the byte blocks pdfium asks for and persists them there, never evicting
// on its own; and because every URL (including the rotating `?token=`) hashes to
// a *new* file, the same book can be cached many times over. These helpers bound
// it with the shared flat 流式缓存 budget (see [streamCacheTotalMaxBytes]),
// trimming whole files LRU-style by last-modified time and never touching one an
// open viewer is reading. pdfrx caches a whole document as one sparse file per
// URL hash with no block-level eviction, so trimming is at file granularity.
// When that setting is 0 the cache is not persisted at all: enforcement drops
// every idle file, so blocks survive only for the current session.

/// Ensure `Pdfrx.cacheDirectoryPath` is known. pdfrx normally sets it lazily to
/// the temporary directory on first document load; we mirror that default so the
/// cache root can be resolved even before any viewer has opened.
Future<String> ensurePdfStreamCacheConfigured() async {
  final existing = Pdfrx.cacheDirectoryPath;
  if (existing != null) return existing;
  Pdfrx.cacheDirectoryPath ??= (await getTemporaryDirectory()).path;
  return Pdfrx.cacheDirectoryPath!;
}

Future<Directory?> _pdfStreamCacheRoot() async {
  final base = Pdfrx.cacheDirectoryPath ?? await ensurePdfStreamCacheConfigured();
  final dir = Directory('$base/pdfrx.cache');
  return dir.existsSync() ? dir : null;
}

// pdfrx cache-file header layout (native/pdf_file_cache.dart): a 16-byte
// header of four little-endian int32s (magic, fileSize, blockSize,
// dataStrSize), then a fixed 128-byte cache-control slot, then the occupancy
// bitmap from `_pdfCacheStateOffset`. Data blocks follow the bitmap.
const int _pdfCacheHeaderSize = 16;
const int _pdfCacheMagic = 34567;
const int _pdfCacheDataStrMax = 128;
const int _pdfCacheStateOffset = _pdfCacheHeaderSize + _pdfCacheDataStrMax;

/// Bytes actually downloaded for one pdfrx cache file.
///
/// pdfrx writes each 1MB block at its byte offset into a sparse file with no
/// preallocation, so the file's *length* jumps to `highestBlock * blockSize`
/// even when only a couple of blocks were fetched. Counting `File.length()`
/// would report a nearly-complete download after a page or two. Instead we read
/// the header's occupancy bitmap and count resident blocks. Falls back to
/// [fallback] (the file length) on anything unexpected, so a corrupt or
/// foreign file is never silently treated as empty.
int _pdfCacheResidentBytes(File file, int fallback) {
  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    final header = Uint8List(_pdfCacheHeaderSize);
    if (raf.readIntoSync(header, 0, _pdfCacheHeaderSize) != _pdfCacheHeaderSize) {
      return fallback;
    }
    final bd = ByteData.sublistView(header);
    if (bd.getInt32(0, Endian.little) != _pdfCacheMagic) return fallback;
    final fileSize = bd.getInt32(4, Endian.little);
    final blockSize = bd.getInt32(8, Endian.little);
    if (fileSize <= 0 || blockSize <= 0) return fallback;
    final blockCount = (fileSize + blockSize - 1) ~/ blockSize;
    final bitmapLen = (blockCount + 7) >> 3;
    raf.setPositionSync(_pdfCacheStateOffset);
    final bitmap = Uint8List(bitmapLen);
    if (raf.readIntoSync(bitmap, 0, bitmapLen) != bitmapLen) return fallback;
    var residentBlocks = 0;
    for (var i = 0; i < blockCount; i++) {
      if (bitmap[i >> 3] & (1 << (i & 7)) != 0) residentBlocks++;
    }
    final bytes = residentBlocks * blockSize;
    return bytes < fileSize ? bytes : fileSize;
  } catch (_) {
    return fallback;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
}

/// Total bytes of the streamed-PDF cache currently on disk, counting only the
/// blocks pdfrx has actually downloaded rather than sparse file lengths.
Future<int> pdfStreamCacheUsageBytes() async {
  return streamCacheUsageBytes(await _pdfStreamCacheRoot(),
      measure: _residentPdfBytes);
}

int _residentPdfBytes(File file) => _pdfCacheResidentBytes(file, file.lengthSync());

/// Enforce the flat total cap shared with the audio/ebook streaming caches. Only
/// whole cache files are deleted, oldest-first (by last modification) until the
/// resident total fits the 流式缓存 MB setting; files modified within
/// [streamCacheInUseWindow] are skipped, so a viewer reading a PDF never has its
/// cache pulled out from under it. When the setting is 0 nothing is persisted and
/// every idle file is dropped. A no-op while the cache doesn't exist yet.
Future<void> enforcePdfStreamCacheLimits() async {
  await enforceStreamCacheLimit(await _pdfStreamCacheRoot(),
      measure: _residentPdfBytes);
}

/// Delete the whole streamed-PDF cache. Every entry is regenerable on demand, so
/// this is always safe outside of an open streamed-PDF viewer.
Future<void> clearPdfStreamCache() async {
  await clearStreamCacheDir(await _pdfStreamCacheRoot());
}
