import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'user_account_service.dart';

/// Scoped-per-account JSON payload cache.
///
/// Server payloads that can be megabytes (personalized shelves, library item
/// pages, progress snapshots) would bloat SharedPreferences - a single write
/// rewrites the whole preferences file. They land here instead, one JSON file
/// per key, spread over two physical tiers:
///
///   support tier (preferred): <app-support>/json_cache/<sanitized scope>/<key>.json
///   evictable tier (large):    <tmp>/json_cache/<sanitized scope>/<key>.json
///
/// Payloads at/above [._tierByteThreshold] bytes live in the OS-evictable tier
/// (the platform's cache directory, which the OS may reclaim when storage runs
/// low). Everything else - progress snapshots, small shelves - stays in the
/// app-support tier, which the app owns. Reads prefer the support tier and
/// fall back to the evictable one, so a payload that crossed the size line is
/// still found.
///
/// Each file stores an envelope `{ v, storedAt, data }` so a caller can tell a
/// "stale but renderable" copy apart from a missing one and decide whether to
/// also refresh in the background (stale-while-revalidate). Payloads over
/// [._gzipThreshold] bytes are gzip-compressed as a whole - self-declaring via
/// the gzip magic header, so pre-existing plain files keep decoding - and
/// every write is atomic (tmp + rename) so a crash can never leave a torn file
/// behind.
///
/// Space is bounded per account by [._budgetBytes]/[._maxFiles] across BOTH
/// tiers, with a throttled oldest-first eviction piggybacking on writes plus an
/// explicit [clearOlderThan] prune callers can schedule. When the budget is
/// exceeded the evictable tier is dropped wholesale first (it is disposable by
/// definition), then the support tier is trimmed oldest-first. Writes of
/// byte-identical payloads are skipped entirely, so event storms that re-fetch
/// unchanged shelves cost ~no disk I/O. Large payloads encode/decode off the
/// UI isolate and concurrent reads of one key coalesce into a single file
/// read.
///
/// Scoping by account (same semantics as [ScopedPrefs], keyed on the active
/// account's scopeKey) keeps one user's shelves/progress from bleeding into
/// another's when they switch accounts on the same device.
class JsonFileCache {
  JsonFileCache._();

  /// Bump to invalidate old-format payload files (all scopes).
  static const _version = 'v1';

  /// Envelope schema version written by this build. Readers drop payloads
  /// whose `v` exceeds the [maxVersion] they declare, so a caller can evolve
  /// one key's shape without nuking the whole cache.
  static const _schemaVersion = 1;

  /// Payloads under this serialized size stay plain JSON; gzip only pays off
  /// on the multi-MB shelves, grids and progress snapshots.
  static const _gzipThreshold = 4096;

  /// Stored files at/above this size are routed to the OS-evictable tier.
  /// Small payloads (progress, compact shelves) never cross it and stay in the
  /// app-support tier, so a high threshold would make the evictable tier a
  /// no-op: the gzip'd shelves/grids that dominate storage usually land in the
  /// low-hundreds of KB.
  static const _tierByteThreshold = 128 * 1024;

  /// Per-account caps, enforced oldest-first by file mtime across both tiers.
  static const _budgetBytes = 48 * 1024 * 1024;
  static const _maxFiles = 600;
  static const _evictMinInterval = Duration(seconds: 60);

  /// When each scope's budget was last checked, so a write storm doesn't pay a
  /// full directory scan on every single write.
  static final _lastEvictCheck = <String, DateTime>{};

  /// Data fingerprints per key (scope-qualified) so rewriting the same payload
  /// is a no-op. Volatile: a cold start pays exactly one redundant write, and
  /// every skip is re-validated against the file's existence so a deletion in
  /// between is never silently re-skipped.
  static final _lastDataHash = <String, int>{};

  /// In-flight reads keyed by `rel|maxAgeMs|maxVersion`, so concurrent readers
  /// of the same key share one file read + decode instead of each paying for
  /// it (the grid restore path can hit the same shelf from several callers at
  /// once).
  static final _inflight = <String, Future<Object?>>{};

  static String _scope() => UserAccountService().activeScopeKey;

  static String sanitize(String s) =>
      s.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');

  /// Relative path (under the cache root) for an account-scoped key.
  static String relPath(String scope, String key) {
    final filePart = '${_version}_${sanitize(key)}.json';
    return scope.isEmpty ? filePart : '${sanitize(scope)}/$filePart';
  }

  /// App-support tier root: files here are owned by the app and only evicted
  /// by our budget logic.
  /// Cached root directories to avoid repeated platform channel calls.
  static Directory? _supportRootCache;
  static Directory? _evictableRootCache;

  /// App-support tier root: files here are owned by the app and only evicted
  /// by our budget logic.
  static Future<Directory> _supportRoot() async {
    return _supportRootCache ??= Directory(
        '${(await getApplicationSupportDirectory()).path}/json_cache');
  }

  /// OS-evictable tier root: the platform's cache directory, which the OS may
  /// reclaim when storage runs low.
  static Future<Directory> _evictableRoot() async {
    return _evictableRootCache ??= Directory(
        '${(await getTemporaryDirectory()).path}/json_cache');
  }

  /// A file for [rel] in a specific tier.
  static Future<File> _file(String rel, {required bool cacheTier}) async {
    final root = await (cacheTier ? _evictableRoot() : _supportRoot());
    return File('${root.path}/$rel');
  }

  /// A scope directory in a specific tier.
  static Future<Directory> _scopeDir(
    String scope, {
    required bool cacheTier,
  }) async {
    final root = await (cacheTier ? _evictableRoot() : _supportRoot());
    return Directory('${root.path}/${sanitize(scope)}');
  }

  /// First existing copy of [rel] across both tiers, support tier first (so a
  /// key is never shadowed by a stale/disposable copy after an invalidate).
  static Future<File?> _existingFile(String rel) async {
    for (final cacheTier in const [false, true]) {
      final f = await _file(rel, cacheTier: cacheTier);
      if (f.existsSync()) return f;
    }
    return null;
  }

  /// Whether [storedMs] falls inside [maxAge]; null means "no age bound".
  static bool _fresh(int storedMs, Duration? maxAge) =>
      maxAge == null ||
      DateTime.now().millisecondsSinceEpoch - storedMs <= maxAge.inMilliseconds;

  static bool _isGzip(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B;

  /// Decode a stored payload. Plain and gzip'd files both decode; anything
  /// malformed, older than [maxAge] or written by a schema newer than
  /// [maxVersion] is treated as absent.
  static Object? _decodeBytes(Uint8List bytes, Duration? maxAge, int maxVersion) {
    try {
      final json = _isGzip(bytes)
          ? utf8.decode(gzip.decode(bytes))
          : utf8.decode(bytes);
      final envelope = jsonDecode(json);
      if (envelope is! Map<String, dynamic>) return null;
      final storedAt = envelope['storedAt'];
      if (storedAt is! num) return null;
      if (!_fresh(storedAt.toInt(), maxAge)) return null;
      final v = (envelope['v'] as num?)?.toInt() ?? 1;
      if (v > maxVersion) return null;
      return envelope['data'];
    } catch (_) {
      return null;
    }
  }

  static Future<Object?> _readRaw(
    String key,
    String? scope,
    Duration? maxAge,
    int maxVersion,
  ) async {
    final active = scope ?? _scope();
    if (!UserAccountService().hasScope && active.isEmpty) return null;
    final rel = relPath(active, key);
    final flightKey = '$rel|${maxAge?.inMilliseconds ?? -1}|$maxVersion';
    final existing = _inflight[flightKey];
    if (existing != null) return existing;
    final future = _readFile(rel, maxAge, maxVersion);
    _inflight[flightKey] = future;
    unawaited(future.whenComplete(() {
      if (identical(_inflight[flightKey], future)) _inflight.remove(flightKey);
    }));
    return future;
  }

  static Future<Object?> _readFile(
    String rel,
    Duration? maxAge,
    int maxVersion,
  ) async {
    try {
      final file = await _existingFile(rel);
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      // Large envelopes decode off the UI isolate (compute); the frequent
      // small files stay inline so a tiny read never pays for an isolate.
      if (bytes.length >= _gzipThreshold) {
        return await compute(
            _decodeRemote, [bytes, maxAge?.inMilliseconds ?? -1, maxVersion]);
      }
      return _decodeBytes(bytes, maxAge, maxVersion);
    } catch (e) {
      debugPrint('[JsonFileCache] read $rel failed: $e');
      return null;
    }
  }

  /// [compute] callback for decoding large payloads off the UI isolate.
  /// [args] is `[bytes, maxAgeMs, maxVersion]` (maxAgeMs -1 = unbounded) - a
  /// sendable list, since records and Durations are not port-message types.
  static Object? _decodeRemote(List<Object?> args) {
    final bytes = args[0] as Uint8List;
    final maxAgeMs = args[1] as int;
    final maxVersion = args[2] as int;
    return _decodeBytes(
      bytes,
      maxAgeMs == -1 ? null : Duration(milliseconds: maxAgeMs),
      maxVersion,
    );
  }

  /// Read a cached Map payload, or null when absent/older than [maxAge]/from a
  /// schema newer than [maxVersion].
  static Future<Map<String, dynamic>?> readMap(
    String key, {
    Duration? maxAge,
    int maxVersion = _schemaVersion,
    String? scope,
  }) async {
    final data = await _readRaw(key, scope, maxAge, maxVersion);
    return data is Map<String, dynamic> ? data : null;
  }

  /// Read a cached List payload, or null when absent/older/too-new as above.
  static Future<List<dynamic>?> readList(
    String key, {
    Duration? maxAge,
    int maxVersion = _schemaVersion,
    String? scope,
  }) async {
    final data = await _readRaw(key, scope, maxAge, maxVersion);
    return data is List<dynamic> ? data : null;
  }

  /// When the cached payload was written, or null when missing/corrupt.
  static Future<DateTime?> storedAt(String key, {String? scope}) async {
    try {
      final file = await _existingFile(relPath(scope ?? _scope(), key));
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      final json = _isGzip(bytes)
          ? utf8.decode(gzip.decode(bytes))
          : utf8.decode(bytes);
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;
      final ms = decoded['storedAt'];
      if (ms is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    } catch (e) {
      return null;
    }
  }

  /// Serialize a payload into the disk envelope. Returns `[bytes, dataHash]` -
  /// a sendable list so the same function doubles as the [compute] callback
  /// for large payloads. The data is encoded exactly once and reused inside
  /// the envelope, so fingerprinting and writing share the encode instead of
  /// paying for it twice.
  static List<Object?> _encodePayloadSync(Object? data) {
    final dataJson = jsonEncode(data);
    final plain = utf8.encode(
      '{"storedAt":${DateTime.now().millisecondsSinceEpoch},'
      '"v":$_schemaVersion,"data":$dataJson}',
    );
    return [
      plain.length >= _gzipThreshold
          ? Uint8List.fromList(gzip.encode(plain))
          : plain,
      _fnv1a(utf8.encode(dataJson)),
    ];
  }

  /// FNV-1a, cheap and deterministic; good enough to spot re-written identity.
  static int _fnv1a(List<int> bytes) {
    var hash = 0x811C9DC5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// Persist a payload under [key] for the active (or given) account scope.
  ///
  /// Routes large payloads to the OS-evictable tier, deletes a stale copy that
  /// may linger in the OTHER tier (the key can cross the size line between
  /// writes), writes atomically (tmp + rename), skips the write entirely when
  /// the data fingerprint matches the last one stored for this key, and fires
  /// the throttled budget eviction for the scope.
  static Future<void> write(String key, Object? data, {String? scope}) async {
    try {
      final active = scope ?? _scope();
      if (!UserAccountService().hasScope && active.isEmpty) return;
      final rel = relPath(active, key);

      List<Object?> encoded;
      try {
        encoded = await compute(_encodePayloadSync, data);
      } catch (e) {
        // Non-sendable payload (e.g. a DateTime inside a map): fall back to
        // the inline encode rather than silently dropping a cache write.
        encoded = _encodePayloadSync(data);
      }
      final bytes = encoded[0] as Uint8List;
      final dataHash = encoded[1] as int;
      final cacheTier = bytes.length >= _tierByteThreshold;
      final file = await _file(rel, cacheTier: cacheTier);

      // The key may have moved tiers since the last write: drop the other
      // tier's copy so reads can never resurrect a big leftover after a small
      // rewrite (or vice versa). ~free next to the encode already paid for.
      final peer = await _file(rel, cacheTier: !cacheTier);
      try {
        if (peer.existsSync()) peer.deleteSync();
      } catch (_) {}

      // Skip only when the fingerprint matches AND the file is still there: a
      // hash is just a hint, and an invalidate/evict in between would else
      // leave an identical refetch silently unwritten (next cold start then
      // misses a cache we could have had). The existence stat is ~free next
      // to the encode already paid for.
      if (_lastDataHash[rel] == dataHash && file.existsSync()) return;

      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: false);
      await tmp.rename(file.path);
      _lastDataHash[rel] = dataHash;
      unawaited(_evictIfNeeded(active));
    } catch (e) {
      debugPrint('[JsonFileCache] write $key failed: $e');
    }
  }

  /// Delete one cached payload (both tiers).
  static Future<void> invalidate(String key, {String? scope}) async {
    try {
      final rel = relPath(scope ?? _scope(), key);
      for (final cacheTier in const [false, true]) {
        final f = await _file(rel, cacheTier: cacheTier);
        if (f.existsSync()) f.deleteSync();
      }
    } catch (e) {
      debugPrint('[JsonFileCache] invalidate $key failed: $e');
    }
  }

  /// Delete every cached payload whose key starts with any of [prefixes] in a
  /// single directory sweep (both tiers). Used when a caller keys configurable
  /// variants under a common namespace (e.g. the library grid's per-sort/
  /// filter views) and a remote change makes ALL of them stale, not just one
  /// exact key.
  static Future<void> invalidatePrefixes(
    List<String> prefixes, {
    String? scope,
  }) async {
    if (prefixes.isEmpty) return;
    try {
      final active = scope ?? _scope();
      final filePrefixes =
          prefixes.map((p) => '${_version}_${sanitize(p)}').toList();
      for (final cacheTier in const [false, true]) {
        final dir = await _scopeDir(active, cacheTier: cacheTier);
        if (!dir.existsSync()) continue;
        _sweepPrefixes(dir, filePrefixes);
      }
    } catch (e) {
      debugPrint('[JsonFileCache] invalidatePrefixes $prefixes failed: $e');
    }
  }

  static void _sweepPrefixes(Directory dir, List<String> filePrefixes) {
    // Snapshot the file names first (reads can run concurrently once I/O
    // moves off the main isolate); deletes target the captured paths only.
    final names = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();
    for (final name in names) {
      try {
        // Total match (exact keys) or a key-namespace boundary ('_') so e.g.
        // 'library_items|1' can't sweep the files of 'library_items|10'.
        final base = name.endsWith('.json') && name.length > 5
            ? name.substring(0, name.length - 5)
            : name;
        for (final prefix in filePrefixes) {
          if (base == prefix || base.startsWith('${prefix}_')) {
            File('${dir.path}/$name').deleteSync();
            break;
          }
        }
      } catch (_) {}
    }
  }

  /// Delete every cached payload for a scope - both tiers (e.g. on logout).
  static Future<void> invalidateScope({String? scope}) async {
    try {
      final active = scope ?? _scope();
      if (active.isEmpty) return;
      for (final cacheTier in const [false, true]) {
        final dir = await _scopeDir(active, cacheTier: cacheTier);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      }
    } catch (e) {
      debugPrint('[JsonFileCache] invalidateScope failed: $e');
    }
  }

  /// Delete cached files older than [maxAge] in the active scope - both
  /// tiers - a cheap LRU-ish prune so stale shelves never accumulate past
  /// album-size JSON.
  static Future<void> clearOlderThan(Duration maxAge, {String? scope}) async {
    try {
      final active = scope ?? _scope();
      final cutoff = DateTime.now().subtract(maxAge);
      for (final cacheTier in const [false, true]) {
        final dir = await _scopeDir(active, cacheTier: cacheTier);
        if (!dir.existsSync()) continue;
        for (final f in dir.listSync().whereType<File>()) {
          try {
            if (f.statSync().modified.isBefore(cutoff)) f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[JsonFileCache] clearOlderThan failed: $e');
    }
  }

  /// Bytes on disk right now across every scope and both tiers (excluding
  /// `.tmp` leftovers from interrupted writes). Used by the Settings ▶
  /// Downloads & Storage clear-cache entry to show what would be freed.
  static Future<int> usageBytes() async {
    var total = 0;
    for (final cacheTier in const [false, true]) {
      final root = await (cacheTier ? _evictableRoot() : _supportRoot());
      if (!root.existsSync()) continue;
      for (final dir in root.listSync().whereType<Directory>()) {
        for (final f in dir.listSync().whereType<File>()) {
          if (f.path.endsWith('.tmp')) continue;
          try {
            total += f.statSync().size;
          } catch (_) {}
        }
      }
    }
    return total;
  }

  /// Delete EVERY cached payload - all scopes, both tiers - and report the
  /// bytes freed. Backs the Settings "clear cache" button; the fingerprint map
  /// is reset so a future identical write is not skipped against a cleared
  /// disk.
  static Future<int> clearAll() async {
    var freed = 0;
    for (final cacheTier in const [false, true]) {
      final root = await (cacheTier ? _evictableRoot() : _supportRoot());
      if (!root.existsSync()) continue;
      for (final dir in root.listSync().whereType<Directory>().toList()) {
        try {
          freed += _dirBytes(dir);
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    _lastDataHash.clear();
    return freed;
  }

  static int _dirBytes(Directory dir) {
    var total = 0;
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      try {
        total += f.statSync().size;
      } catch (_) {}
    }
    return total;
  }

  /// Throttled budget eviction for one scope, over both tiers. The evictable
  /// tier is disposable by definition, so when the budget is exceeded it is
  /// dropped wholesale; the support tier is then trimmed oldest-first if the
  /// combined budget is still over. Also sweeps `.tmp` leftovers (both tiers)
  /// that a crash may have left in place of a completed rename.
  static Future<void> _evictIfNeeded(String scope) async {
    final now = DateTime.now();
    final last = _lastEvictCheck[scope];
    if (last != null && now.difference(last) < _evictMinInterval) return;
    _lastEvictCheck[scope] = now;
    try {
      var (supportFiles, supportBytes) =
          _scanScope(await _scopeDir(scope, cacheTier: false), now);
      var (cacheFiles, cacheBytes) =
          _scanScope(await _scopeDir(scope, cacheTier: true), now);
      if (supportFiles.length + cacheFiles.length <= _maxFiles &&
          supportBytes + cacheBytes <= _budgetBytes) {
        return;
      }

      // The evictable tier goes first - these are the big, disposable shelves.
      for (final (path, _, _) in cacheFiles) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
      if (supportFiles.length <= _maxFiles && supportBytes <= _budgetBytes) {
        return;
      }

      supportFiles.sort(
        (a, b) => a.$2.compareTo(b.$2), // oldest first
      );
      for (var i = 0; i < supportFiles.length; i++) {
        if (supportFiles.length <= _maxFiles && supportBytes <= _budgetBytes) {
          break;
        }
        final (path, _, size) = supportFiles[i];
        try {
          File(path).deleteSync();
          supportBytes -= size;
          supportFiles.removeAt(i);
          i--;
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[JsonFileCache] evict failed: $e');
    }
  }

  /// Snapshot a scope directory: `.json` files (path/mtime/size) plus the
  /// combined byte count, also deleting `.tmp` leftovers older than 10 min.
  static (List<(String, DateTime, int)>, int) _scanScope(
    Directory dir,
    DateTime now,
  ) {
    final files = <(String, DateTime, int)>[];
    var total = 0;
    if (!dir.existsSync()) return (files, total);
    for (final f in dir.listSync().whereType<File>()) {
      try {
        final name = f.uri.pathSegments.last;
        final st = f.statSync();
        if (name.endsWith('.tmp')) {
          if (now.difference(st.modified) > const Duration(minutes: 10)) {
            f.deleteSync();
          }
          continue;
        }
        files.add((f.path, st.modified, st.size));
        total += st.size;
      } catch (_) {}
    }
    return (files, total);
  }
}