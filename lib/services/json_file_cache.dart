import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'user_account_service.dart';

/// Scoped-per-account JSON payload cache.
///
/// Server payloads that can be megabytes (personalized shelves, library item
/// pages, progress snapshots) would bloat SharedPreferences — a single write
/// rewrites the whole preferences file. They land here instead, one JSON file
/// per key under:
///
///   <application-support>/json_cache/<sanitized scope>/<key>.json
///
/// Each file stores an envelope `{ storedAt: <ms>, data: ... }` so a caller
/// can tell a "stale but renderable" copy apart from a missing one and decide
/// whether to also refresh in the background (stale-while-revalidate).
///
/// Scoping by account (same semantics as [ScopedPrefs], keyed on the active
/// account's scopeKey) keeps one user's shelves/progress from bleeding into
/// another's when they switch accounts on the same device.
class JsonFileCache {
  JsonFileCache._();

  /// Bump to invalidate old-format payload files (all scopes).
  static const _version = 'v1';

  static String _scope() => UserAccountService().activeScopeKey;

  static String sanitize(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');

  /// Relative path (under the cache root) for an account-scoped key.
  static String relPath(String scope, String key) {
    final filePart = '${_version}_${sanitize(key)}.json';
    return scope.isEmpty ? filePart : '${sanitize(scope)}/$filePart';
  }

  /// Whether [storedAt] falls inside [maxAge]; null means "no age bound".
  static bool _fresh(int storedMs, Duration? maxAge) =>
      maxAge == null ||
      DateTime.now().millisecondsSinceEpoch - storedMs <= maxAge.inMilliseconds;

  static Future<Object?> _decodeRaw(File file, Duration? maxAge) async {
    try {
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final storedAt = decoded['storedAt'];
      if (storedAt is! num) return null;
      if (!_fresh(storedAt.toInt(), maxAge)) return null;
      return decoded['data'];
    } catch (_) {
      return null;
    }
  }

  /// Read a cached Map payload, or null when absent/older than [maxAge].
  static Future<Map<String, dynamic>?> readMap(
    String key, {
    Duration? maxAge,
    String? scope,
  }) async {
    try {
      final data = await _readRaw(key, scope, maxAge);
      return data is Map<String, dynamic> ? data : null;
    } catch (e) {
      debugPrint('[JsonFileCache] read $key failed: $e');
      return null;
    }
  }

  /// Read a cached List payload, or null when absent/older than [maxAge].
  static Future<List<dynamic>?> readList(
    String key, {
    Duration? maxAge,
    String? scope,
  }) async {
    try {
      final data = await _readRaw(key, scope, maxAge);
      return data is List<dynamic> ? data : null;
    } catch (e) {
      debugPrint('[JsonFileCache] read $key failed: $e');
      return null;
    }
  }

  static Future<Object?> _readRaw(String key, String? scope, Duration? maxAge) async {
    final active = scope ?? _scope();
    if (!UserAccountService().hasScope && active.isEmpty) return null;
    final file = await _file(relPath(active, key));
    return _decodeRaw(file, maxAge);
  }

  /// When the cached payload was written, or null when missing/corrupt.
  static Future<DateTime?> storedAt(String key, {String? scope}) async {
    try {
      final file = await _file(relPath(scope ?? _scope(), key));
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final ms = decoded['storedAt'];
      if (ms is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms.toInt());
    } catch (e) {
      return null;
    }
  }

  /// Persist a payload under [key] for the active (or given) account scope.
  static Future<void> write(String key, Object? data, {String? scope}) async {
    try {
      final active = scope ?? _scope();
      if (!UserAccountService().hasScope && active.isEmpty) return;
      final file = await _file(relPath(active, key));
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'storedAt': DateTime.now().millisecondsSinceEpoch,
          'data': data,
        }),
        flush: true,
      );
    } catch (e) {
      debugPrint('[JsonFileCache] write $key failed: $e');
    }
  }

  /// Delete one cached payload.
  static Future<void> invalidate(String key, {String? scope}) async {
    try {
      final file = await _file(relPath(scope ?? _scope(), key));
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      debugPrint('[JsonFileCache] invalidate $key failed: $e');
    }
  }

  /// Delete every cached payload for a scope (e.g. on logout).
  static Future<void> invalidateScope({String? scope}) async {
    try {
      final active = scope ?? _scope();
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/json_cache/${sanitize(active)}');
      if (active.isNotEmpty && dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (e) {
      debugPrint('[JsonFileCache] invalidateScope failed: $e');
    }
  }

  /// Delete cached files older than [maxAge] in the active scope — a cheap
  /// LRU-ish prune so stale shelves never accumulate past album-size JSON.
  static Future<void> clearOlderThan(Duration maxAge, {String? scope}) async {
    try {
      final active = scope ?? _scope();
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/json_cache/${sanitize(active)}');
      if (!dir.existsSync()) return;
      final cutoff = DateTime.now().subtract(maxAge);
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        try {
          if (f.statSync().modified.isBefore(cutoff)) f.deleteSync();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[JsonFileCache] clearOlderThan failed: $e');
    }
  }

  static Future<File> _file(String rel) async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}/json_cache/$rel');
  }
}