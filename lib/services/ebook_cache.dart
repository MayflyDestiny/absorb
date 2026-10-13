import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';
import 'ebook_preferences.dart';
import 'ebook_stream_cache.dart';

/// File extension (with leading dot) for an ABS ebookFile, or '' if unknown.
/// Prefers the explicit `ebookFormat` field over the filename extension so a
/// mis-named file can't be treated as the wrong format downstream (foliate-js
/// tells CBZ and EPUB apart purely by the served filename).
String ebookExtFromFile(Map<String, dynamic> ebookFile) {
  final fmt = (ebookFile['ebookFormat'] as String?)?.toLowerCase();
  if (fmt != null && fmt.isNotEmpty) return '.$fmt';
  final name = (ebookFile['metadata'] as Map<String, dynamic>?)?['filename'] as String?
      ?? ebookFile['name'] as String?
      ?? '';
  return name.contains('.') ? name.substring(name.lastIndexOf('.')).toLowerCase() : '';
}

/// Distinguishes the versions of one item's ebook: the server file's `ino`
/// (or '' when absent, i.e. versions can't be told apart). Used to keep each
/// version's cached bytes and reading position separate.
String ebookVersionKey(Map<String, dynamic> ebookFile) =>
    ebookFile['ino']?.toString() ?? '';

/// Strips path separators, traversal (`..`) and anything else unsafe from a
/// server-supplied path segment (an item id or a version `ino`), so a crafted
/// id can't escape the cache directory. Normal ids (UUIDs, integers) pass
/// through unchanged, so existing cache filenames stay valid.
String safeEbookPathSegment(String s) =>
    s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

/// File extension (with a leading dot) safe to append to a cache filename.
String _safeExt(String ext) {
  if (ext.isEmpty) return '';
  final body = ext.startsWith('.') ? ext.substring(1) : ext;
  return '.${safeEbookPathSegment(body).toLowerCase()}';
}

/// Formats the in-app readers can open. EPUB uses the full reader, PDF the
/// dedicated viewer, foliate-js covers MOBI/AZW3, and comics get the comic
/// reader. A CBZ opens on the phone; CBR (RAR) and CB7 (7-Zip) need a server
/// that hands out the pages (BookOrbit), so on their own they stay
/// download-only.
const foliateEbookFormats = {'mobi', 'azw3'};
const comicEbookFormats = {'cbz', 'cbr', 'cb7'};
const readableEbookFormats = {'epub', 'pdf', 'cbz', ...foliateEbookFormats};
const allEbookFormats = {...readableEbookFormats, 'cbr', 'cb7'};

/// The ebook to use for a library item: the server's primary (media.ebookFile)
/// when set, otherwise the best supplementary ebook from libraryFiles - epub
/// first (mirroring the server's own primary pick), then the first readable
/// format, then any ebook file (a CBR can still be saved to device).
/// Audiobooks-only libraries mark every ebook supplementary and never set a
/// primary, so without this fallback those books always showed "no ebook".
Map<String, dynamic>? resolveEbookFile(Map<String, dynamic>? item) {
  if (item == null) return null;
  final media = item['media'] as Map<String, dynamic>?;
  final primary = media?['ebookFile'] as Map<String, dynamic>?;
  // A locally chosen default version wins over the server's primary, so every
  // path that opens/downloads without prompting (the card's Read, offline
  // download) uses the version the user picked in the version sheet.
  final preferred = EbookPreferences.defaultIno(item['id'] as String? ?? '');
  if (preferred != null) {
    final match = _ebookFileByIno(item, primary, preferred);
    if (match != null) return match;
  }
  if (primary != null) return primary;
  Map<String, dynamic>? firstReadable;
  Map<String, dynamic>? firstEbook;
  for (final f in (item['libraryFiles'] as List<dynamic>? ?? const [])) {
    if (f is! Map<String, dynamic>) continue;
    final ext = ebookExtFromFile(f);
    final fmt = ext.startsWith('.') ? ext.substring(1) : ext;
    if (!allEbookFormats.contains(fmt)) continue;
    if (fmt == 'epub') return f;
    if (readableEbookFormats.contains(fmt)) firstReadable ??= f;
    firstEbook ??= f;
  }
  return firstReadable ?? firstEbook;
}

/// The item's ebook file whose `ino` is [ino] - the server primary or a
/// supplementary ebook in libraryFiles - or null when no such version exists.
Map<String, dynamic>? _ebookFileByIno(
    Map<String, dynamic> item, Map<String, dynamic>? primary, String ino) {
  if (primary != null && primary['ino']?.toString() == ino) return primary;
  for (final f in (item['libraryFiles'] as List<dynamic>? ?? const [])) {
    if (f is! Map<String, dynamic>) continue;
    if (f['ino']?.toString() == ino) return f;
  }
  return null;
}

/// Size in bytes of an ebook file, from its metadata when the server provides
/// it (libraryFiles entries carry `metadata.size`), else null.
int? ebookFileSize(Map<String, dynamic>? ebookFile) {
  if (ebookFile == null) return null;
  final meta = ebookFile['metadata'] as Map<String, dynamic>?;
  final size = meta?['size'] ?? ebookFile['size'];
  return size is num ? size.toInt() : null;
}

/// Every downloadable ebook version of an item, for version pickers: the
/// server's primary (media.ebookFile) first, then any supplementary ebooks in
/// libraryFiles. Deduped by ino so a supplementary that happens to BE the
/// primary (ABS marks some libs' primaries as supplementary) doesn't repeat.
/// A server like 极品家丁 carries several: the image-heavy "精校多图" EPUB next
/// to a plain EPUB / MOBI / PDF, so the picker can offer size per version.
List<Map<String, dynamic>> ebookFileChoices(Map<String, dynamic>? item) {
  if (item == null) return const [];
  final media = item['media'] as Map<String, dynamic>?;
  final primary = media?['ebookFile'] as Map<String, dynamic>?;
  final seen = <Object?>{};
  final out = <Map<String, dynamic>>[];
  void collect(Map<String, dynamic>? f) {
    if (f == null) return;
    final ino = f['ino'];
    if (ino == null || seen.add(ino)) out.add(f);
  }
  collect(primary);
  for (final f in (item['libraryFiles'] as List<dynamic>? ?? const [])) {
    if (f is! Map<String, dynamic>) continue;
    if ((f['fileType'] as String?) != 'ebook') continue;
    collect(f);
  }
  return out;
}

/// Whether a library item comes with an ebook, from the full item or from
/// the minified list form, which only carries the format.
bool hasEbookFile(Map<String, dynamic>? item) {
  if (item == null) return false;
  if (resolveEbookFile(item) != null) return true;
  final media = item['media'] as Map<String, dynamic>?;
  final fmt = media?['ebookFormat'];
  return fmt is String && fmt.isNotEmpty;
}

Directory? _ebookCacheDirHandle;

Future<Directory> _ebookCacheDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/ebook_cache');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  _ebookCacheDirHandle = dir;
  return dir;
}

/// Warms the synchronous directory handle so [cachedEbookBytesSync] can see
/// cached ebooks from sync code (e.g. download size accounting).
Future<void> hydrateEbookCacheDir() => _ebookCacheDir();

/// Size in bytes of the cached ebook for [itemId], or 0 when there is none or
/// the directory handle hasn't been warmed yet. Only real ebook files count:
/// the `<id>.<ext>.locations.json` sidecar and a leftover `<id>.<ext>.part`
/// share the name prefix but are not the book.
int cachedEbookBytesSync(String itemId) =>
    cachedEbookVersionsSync(itemId).fold(0, (a, e) => a + e.bytes);

/// Byte sizes of the cached ebook files for [itemId], keyed by version: the
/// file's `ino` for a versioned cache name (`<id>.<ino>.<ext>`) or '' for a
/// legacy unkeyed one (`<id>.<ext>`). Lets a caller total the distinct versions
/// on disk and skip the one an exported copy already accounts for, so the same
/// version isn't counted twice.
Map<String, int> cachedEbookVersionBytesSync(String itemId) {
  final out = <String, int>{};
  for (final e in cachedEbookVersionsSync(itemId)) {
    out[e.version] = (out[e.version] ?? 0) + e.bytes;
  }
  return out;
}

/// The cached ebook files for [itemId], one per version: the version key (the
/// file's `ino`, or '' for a legacy unkeyed name), the format extension (with
/// leading dot), the byte size and the on-disk file name. Only real ebook files
/// count: the `<id>.<ext>.locations.json` sidecar and a `<id>.<ext>.part` share
/// the name prefix but are not the book. Empty until the directory handle is
/// warmed ([hydrateEbookCacheDir]).
List<({String version, String ext, int bytes, String fileName})>
    cachedEbookVersionsSync(String itemId) {
  final dir = _ebookCacheDirHandle;
  if (dir == null || !dir.existsSync()) return const [];
  final out = <({String version, String ext, int bytes, String fileName})>[];
  try {
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (!name.startsWith('$itemId.')) continue;
      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      final ext = name.substring(dot + 1).toLowerCase();
      if (!allEbookFormats.contains(ext)) continue;
      final stem = name.substring(0, dot);
      var version = '';
      final prefix = '$itemId.';
      if (stem.startsWith(prefix)) {
        final rest = stem.substring(prefix.length);
        if (rest.isNotEmpty &&
            !rest.contains('.') &&
            num.tryParse(rest) != null) {
          version = rest;
        }
      }
      int bytes;
      try {
        bytes = f.lengthSync();
      } catch (_) {
        bytes = 0;
      }
      out.add((
        version: version,
        ext: '.$ext',
        bytes: bytes,
        fileName: name,
      ));
    }
  } catch (_) {}
  return out;
}

/// The on-disk [File] for a cached ebook by its [fileName] (from
/// [cachedEbookVersionsSync], e.g. `<id>.<ino>.<ext>`), so a caller can read or
/// export one specific cached version.
Future<File> cachedEbookFileByName(String fileName) async {
  final dir = await _ebookCacheDir();
  return File('${dir.path}/$fileName');
}

/// Delete one cached ebook file by its on-disk [fileName] (from
/// [cachedEbookVersionsSync]). Leaves the epub.js locations sidecar, which is
/// simply rebuilt on the next open.
Future<void> deleteCachedEbookFile(String fileName) async {
  try {
    final dir = await _ebookCacheDir();
    final f = File('${dir.path}/$fileName');
    if (f.existsSync()) await f.delete();
  } catch (_) {}
}

/// Delete the reader-cached copy of one item version (the same file
/// [ebookCacheFileFor] points at, plus any half-written `.part`). Called after
/// that version is exported so the book isn't stored twice; the reader then
/// reads the exported copy in place. A no-op when nothing is cached. The
/// location index is left alone - it still matches the same version's bytes.
Future<void> deleteCachedEbookVersion(
    String itemId, Map<String, dynamic> ebookFile) async {
  try {
    final f = await ebookCacheFileFor(itemId, ebookFile);
    if (f.existsSync()) await f.delete();
    // Sweep every half-written temp for this version, not just the legacy
    // `<file>.part`: current temp names are `<file>.<nonce>.part`.
    final dir = f.parent;
    final base = f.uri.pathSegments.last;
    if (dir.existsSync()) {
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (name.startsWith('$base.') && name.endsWith('.part')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
  } catch (_) {}
  // The version now reads from its export (or is gone), so drop any temp stream
  // blocks for it too rather than leave a second copy behind.
  await clearEbookStreamCacheVersion(itemId, ebookFile);
}

/// Item ids with a cached ebook file, read through the warmed directory handle.
/// The synchronous twin of [cachedEbookItemIds], for widget builds: an ebook
/// fetched beside a download (or opened from a streamed book) is only in the
/// cache, with no record that lists it.
Set<String> cachedEbookItemIdsSync() {
  final dir = _ebookCacheDirHandle;
  if (dir == null || !dir.existsSync()) return const <String>{};
  final ids = <String>{};
  try {
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      final ext = name.substring(dot + 1).toLowerCase();
      if (!allEbookFormats.contains(ext)) continue;
      ids.add(_itemIdFromCachedName(name));
    }
  } catch (_) {}
  return ids;
}

/// Item id out of a cached ebook filename, whatever the naming scheme: legacy
/// `<id>.<ext>` or versioned `<id>.<ino>.<ext>`. The ino tail is stripped only
/// when it is clearly numeric, so it can't eat an id that ends in digits.
String _itemIdFromCachedName(String name) {
  var stem = name.substring(0, name.lastIndexOf('.'));
  final dot = stem.lastIndexOf('.');
  if (dot > 0 && num.tryParse(stem.substring(dot + 1)) != null) {
    stem = stem.substring(0, dot);
  }
  return stem;
}

/// Total bytes of all cached ebook files. Regenerable from the server, so this
/// can be surfaced in the settings clear-cache sheet.
Future<int> ebookCacheUsageBytes() async {
  try {
    final dir = await _ebookCacheDir();
    var total = 0;
    await for (final f in dir.list(recursive: false, followLinks: false)) {
      if (f is File) {
        try {
          total += f.lengthSync();
        } catch (_) {}
      }
    }
    return total;
  } catch (_) {
    return 0;
  }
}

/// Delete every cached ebook file. Cached ebooks are re-downloaded on demand
/// the next time the reader wants one, so this is a safe cache clear. The
/// epub.js location indexes (regenerated on open) are swept too.
Future<void> clearEbookCache() async {
  try {
    final dir = await _ebookCacheDir();
    for (final f in dir.listSync()) {
      if (f is File) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  } catch (_) {}
  try {
    final base = await getApplicationSupportDirectory();
    final loc = Directory('${base.path}/ebook_locations');
    if (loc.existsSync()) loc.deleteSync(recursive: true);
  } catch (_) {}
  try {
    final tmp = await getTemporaryDirectory();
    final reader = Directory('${tmp.path}/absorb_reader');
    if (reader.existsSync()) reader.deleteSync(recursive: true);
  } catch (_) {}
}

/// Synthesizes an ebookFile map from a cached file on disk, so a downloaded
/// book can open its ebook offline even when no ebook metadata survived (old
/// downloads persisted before the trimmed libraryItem was kept). The format
/// comes from the cached file's extension, which [ebookCacheFileFor] derived
/// from the real ebookFile at download time, so the reader routing (EPUB vs
/// PDF vs foliate) stays correct. When several formats are cached for one item
/// the EPUB wins, mirroring [resolveEbookFile]'s pick (and transcript
/// correction can only read EPUBs). Returns null when nothing is cached.
Future<Map<String, dynamic>?> cachedEbookFileFor(String itemId) async {
  try {
    final dir = await _ebookCacheDir();
    Map<String, dynamic>? first;
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (!name.startsWith('$itemId.')) continue;
      if (await f.length() <= 0) continue;
      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      final ext = name.substring(dot + 1).toLowerCase();
      if (!allEbookFormats.contains(ext)) continue;
      // Versioned cache names are `<id>.<ino>.<ext>`; keep the ino so a later
      // ebookCacheFileFor pinpoints the exact downloaded version instead of
      // bouncing to a different (legacy single-format) file.
      final stem = name.substring(0, dot);
      String? ino;
      final prefix = '$itemId.';
      if (stem.length > prefix.length && stem.startsWith(prefix)) {
        final rest = stem.substring(prefix.length);
        if (rest.isNotEmpty && !rest.contains('.') && num.tryParse(rest) != null) {
          ino = rest;
        }
      }
      final entry = {
        'ebookFormat': ext,
        if (ino != null) 'ino': ino,
        'metadata': {'filename': name},
      };
      if (ext == 'epub') return entry;
      first ??= entry;
    }
    return first;
  } catch (_) {}
  return null;
}

/// Item ids that have an ebook file in the cache.
Future<List<String>> cachedEbookItemIds() async {
  final ids = <String>{};
  try {
    final dir = await _ebookCacheDir();
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      final ext = name.substring(dot + 1).toLowerCase();
      if (!allEbookFormats.contains(ext)) continue;
      ids.add(_itemIdFromCachedName(name));
    }
  } catch (_) {}
  return ids.toList();
}

/// Cover kept beside a cached ebook for the offline lists. Named so neither
/// cachedEbookFileFor nor cachedEbookBytesSync can take it for the book.
Future<File> ebookCoverCacheFile(String itemId) async {
  final dir = await _ebookCacheDir();
  return File('${dir.path}/cover_$itemId.jpg');
}

Future<void> deleteCachedEbookCover(String itemId) async {
  try {
    final f = await ebookCoverCacheFile(itemId);
    if (f.existsSync()) await f.delete();
  } catch (_) {}
}

/// Persistent cache path for an item's ebook, keyed by itemId plus the file's
/// version (ino) so two ebook versions of the same item - e.g. 极品家丁's
/// 161MB image-rich EPUB next to a 6MB plain one - never overwrite each other.
/// Lives in app support (not temp, not iCloud-backed docs) so once an ebook is
/// here it stays available offline.
///
/// Deliberately strict: a version is only "cached" when its own keyed file
/// exists. An ebook cached before versions were tracked (`<id>.<ext>`, from the
/// server's primary) is not matched to a specific version, so such books
/// re-download once after the update rather than risk handing one version the
/// other's bytes. Offline lists still surface it via [cachedEbookFileFor],
/// which reads the file from disk by format.
Future<File> ebookCacheFileFor(String itemId, Map<String, dynamic> ebookFile) async {
  final dir = await _ebookCacheDir();
  final id = safeEbookPathSegment(itemId);
  final ext = _safeExt(ebookExtFromFile(ebookFile));
  final ino = ebookVersionKey(ebookFile);
  if (ino.isEmpty) return File('${dir.path}/$id$ext');
  return File('${dir.path}/$id.${safeEbookPathSegment(ino)}$ext');
}

/// Key for an item's epub.js location index: itemId plus the file's version
/// (ino) when known. Stored in its own folder rather than beside the ebook so
/// an ebook opened straight from its exported copy - where the path is a
/// throwaway `/proc/self/fd/<n>` - still reuses the index instead of rebuilding
/// it on every open.
String ebookLocationsKey(String itemId, Map<String, dynamic> ebookFile) {
  final ino = ebookVersionKey(ebookFile);
  final id = safeEbookPathSegment(itemId);
  return ino.isEmpty ? id : '$id.${safeEbookPathSegment(ino)}';
}

Future<File> _locationsFileForKey(String key) async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/ebook_locations');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return File('${dir.path}/$key.json');
}

/// The location index epub.js builds by walking the whole book, so the walk
/// happens once per file instead of on every open. Tagged with the ebook's byte
/// size ([size]) so a re-downloaded file rebuilds it.
Future<String?> loadCachedLocations(String key, int size) async {
  try {
    final f = await _locationsFileForKey(key);
    if (!f.existsSync()) return null;
    final decoded = jsonDecode(await f.readAsString());
    if (decoded is! Map) return null;
    if (decoded['size'] != size) return null;
    final locations = decoded['locations'];
    return locations is String && locations.isNotEmpty ? locations : null;
  } catch (_) {
    return null;
  }
}

Future<void> saveCachedLocations(String key, int size, String locations) async {
  try {
    final f = await _locationsFileForKey(key);
    await f.writeAsString(jsonEncode({'size': size, 'locations': locations}));
  } catch (_) {}
}

/// True if the item's ebook is already cached on disk (readable offline).
Future<bool> isEbookCached(String itemId, Map<String, dynamic> ebookFile) async {
  final f = await ebookCacheFileFor(itemId, ebookFile);
  return f.existsSync() && await f.length() > 0;
}

/// Returns the cached ebook, downloading it if not already present. The download
/// is atomic (written to a .part file then renamed) so an interrupted transfer
/// never leaves a half-written file that looks complete. Once fetched the ebook
/// stays available offline.
Future<File> fetchEbookToCache(
  ApiService api,
  String itemId,
  Map<String, dynamic> ebookFile,
  String title,
) async {
  final cachedFile = await ebookCacheFileFor(itemId, ebookFile);
  if (cachedFile.existsSync() && await cachedFile.length() > 0) {
    debugPrint('[EbookCache] cache hit item=$itemId bytes=${await cachedFile.length()}');
    return cachedFile;
  }

  // Two callers racing to cache the same version (e.g. catch-up fired from both
  // the library provider and the socket path) share one transfer instead of
  // pulling the whole file down twice.
  final key = cachedFile.path;
  final pending = _ebookFetchInflight[key];
  if (pending != null) {
    debugPrint('[EbookCache] joining in-flight download item=$itemId');
    return pending;
  }
  final future = _fetchEbookToCacheOnce(api, itemId, ebookFile, cachedFile);
  _ebookFetchInflight[key] = future;
  try {
    return await future;
  } finally {
    _ebookFetchInflight.remove(key);
  }
}

/// In-flight ebook downloads keyed by destination path (see [fetchEbookToCache]).
final Map<String, Future<File>> _ebookFetchInflight = {};

Future<File> _fetchEbookToCacheOnce(
  ApiService api,
  String itemId,
  Map<String, dynamic> ebookFile,
  File cachedFile,
) async {
  final ino = ebookFile['ino']?.toString();
  if (ino == null || ino.isEmpty) throw Exception('No ebook file found');

  final cleanBase = api.baseUrl.endsWith('/')
      ? api.baseUrl.substring(0, api.baseUrl.length - 1)
      : api.baseUrl;
  // Auth travels both ways: the Authorization header (re-attached across the
  // manual redirect hops below) plus `?token=` in the URL, because some
  // reverse proxies strip the header - the same reason audio file downloads
  // use the token form (see ApiService.buildFileUrl).
  final url = api.isBookOrbit
      ? api.buildEbookUrl(itemId, ino)
      : '$cleanBase/api/items/$itemId/file/$ino?token=${api.token}';

  debugPrint('[EbookCache] downloading item=$itemId path=/api/items/$itemId/file/$ino');
  final startedAt = DateTime.now();
  // Unique temp name: two opens of the same version (a re-open while the first
  // download is still running) must not share one `.part`, and a concurrent
  // cleanup could delete a shared one mid-transfer.
  final nonce = Random().nextInt(1 << 32).toRadixString(36);
  final partFile = File(
      '${cachedFile.path}.${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}.$nonce.part');
  final request = http.Request('GET', Uri.parse(url));
  request.followRedirects = false;
  api.mediaHeaders.forEach((k, v) => request.headers[k] = v);
  final client = http.Client();
  try {
    var response = await client.send(request);
    var redirects = 0;
    while ([301, 302, 303, 307, 308].contains(response.statusCode) && redirects < 5) {
      final location = response.headers['location'];
      if (location == null) break;
      final redirectUrl = Uri.parse(url).resolve(location);
      final rReq = http.Request('GET', redirectUrl);
      api.mediaHeaders.forEach((k, v) => rReq.headers[k] = v);
      rReq.followRedirects = false;
      response = await client.send(rReq);
      redirects++;
    }
    if (response.statusCode != 200) {
      throw Exception('Failed to download ebook (${response.statusCode})');
    }
    final ct = response.headers['content-type'] ?? '';
    if (ct.contains('text/html')) throw Exception('Server returned an error page');
    final sink = partFile.openWrite();
    try {
      await response.stream.pipe(sink);
    } finally {
      await sink.close();
    }
    try {
      if (cachedFile.existsSync()) await cachedFile.delete();
      await partFile.rename(cachedFile.path);
    } on FileSystemException {
      // A concurrent fetch finished first and its rename won; ours is
      // redundant. Anything else (no complete file present) is a real error.
      if (!(cachedFile.existsSync() && await cachedFile.length() > 0)) rethrow;
    }
    final secs = DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
    debugPrint('[EbookCache] downloaded item=$itemId bytes=${await cachedFile.length()} in ${secs}s');
    // The version is now fully cached, so any temp stream blocks for it are
    // stale - drop them and keep a single on-disk copy.
    await clearEbookStreamCacheVersion(itemId, ebookFile);
  } finally {
    client.close();
    if (partFile.existsSync()) {
      try { await partFile.delete(); } catch (_) {}
    }
  }
  return cachedFile;
}

/// Removes any cached ebook for [itemId] (used when a download is removed).
Future<void> deleteCachedEbook(String itemId) async {
  try {
    final dir = await _ebookCacheDir();
    if (!dir.existsSync()) return;
    for (final f in dir.listSync()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      if (name == itemId ||
          name.startsWith('$itemId.') ||
          name == 'cover_$itemId.jpg') {
        try { await f.delete(); } catch (_) {}
      }
    }
  } catch (_) {}
  // Also drop the item's temp stream blocks (all versions).
  await clearEbookStreamCacheItem(itemId);
}
