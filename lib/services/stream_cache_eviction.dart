import 'dart:io';

import 'player_settings.dart';

/// A cache file touched within this window is treated as held by an open viewer
/// and is left alone, so eviction can't pull data out from under a reader.
const Duration streamCacheInUseWindow = Duration(seconds: 90);

/// Flat total cap (bytes) for a streamed-document cache, shared with the audio
/// streaming cache through the 流式缓存 (streaming cache) MB setting. 0 means the
/// cache must not be persisted at all.
Future<int> streamCacheTotalMaxBytes() async {
  final mb = await PlayerSettings.getStreamingCacheSizeMb();
  if (mb <= 0) return 0;
  return mb * 1024 * 1024;
}

/// Total bytes a streamed-document cache occupies on disk.
///
/// [include] selects which files in [root] belong to the cache (all files by
/// default). [measure] reports the resident size of one file, defaulting to its
/// on-disk length - pass a custom one for sparse files. A missing [root] counts
/// as empty.
Future<int> streamCacheUsageBytes(
  Directory? root, {
  bool Function(File file)? include,
  int Function(File file)? measure,
}) async {
  if (root == null) return 0;
  final sizeOf = measure ?? _fileLength;
  try {
    var total = 0;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (include != null && !include(e)) continue;
      try {
        total += sizeOf(e);
      } catch (_) {}
    }
    return total;
  } catch (_) {
    return 0;
  }
}

/// Evict least-recently-written files from a streamed-document cache until its
/// resident total fits the shared 流式缓存 cap. Files modified within
/// [streamCacheInUseWindow] are skipped so an open viewer keeps its data; when
/// the cap is 0 every idle file is dropped. Best-effort: a missing [root] is a
/// no-op and one failed delete never aborts the rest.
Future<void> enforceStreamCacheLimit(
  Directory? root, {
  bool Function(File file)? include,
  int Function(File file)? measure,
}) async {
  if (root == null) return;
  final sizeOf = measure ?? _fileLength;
  try {
    final totalMax = await streamCacheTotalMaxBytes();
    final now = DateTime.now();
    final entries = <_StreamCacheEntry>[];
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (include != null && !include(e)) continue;
      FileStat st;
      try {
        st = e.statSync();
      } catch (_) {
        continue;
      }
      if (now.difference(st.modified) < streamCacheInUseWindow) continue;
      entries.add(_StreamCacheEntry(e, sizeOf(e), st.modified));
    }
    var total = entries.fold<int>(0, (s, en) => s + en.bytes);
    if (totalMax > 0 && total <= totalMax) return;
    entries.sort((a, b) => a.mtime.compareTo(b.mtime));
    for (final en in entries) {
      if (totalMax > 0 && total <= totalMax) break;
      try {
        en.file.deleteSync();
        total -= en.bytes;
      } catch (_) {}
    }
  } catch (_) {}
}

/// Delete every file in a streamed-document cache. Entries are regenerable on
/// demand, so this is always safe outside of an open viewer.
Future<void> clearStreamCacheDir(Directory? root) async {
  if (root == null) return;
  try {
    if (root.existsSync()) await root.delete(recursive: true);
  } catch (_) {}
}

int _fileLength(File file) => file.lengthSync();

class _StreamCacheEntry {
  _StreamCacheEntry(this.file, this.bytes, this.mtime);
  final File file;
  final int bytes;
  final DateTime mtime;
}
