import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_account_service.dart';

/// A tiny per-book "start manifest": only what is needed to build a playable
/// source - each file's `ino` and duration, and the book's total length.
///
/// Why it exists: the full library item is multi-MB on books with a thousand
/// files (one real capture: 2.87 MB, 1.5s for the response headers alone), and
/// a start that has neither a shelf snapshot, a disk item, nor a session cache
/// has to wait for it before any audio. The manifest is tens of KB and comes
/// straight out of SharedPreferences, so that wait disappears.
///
/// Chapters are deliberately NOT stored here: `ChapterCache` already holds them
/// per item, and duplicating a thousand chapter titles cost more than the file
/// list itself.
///
/// The file ids are stored, not URLs: the URL is built at play time
/// (`/api/items/<id>/file/<ino>?token=…`), so a rotated token can never be
/// baked into the cache.
///
/// Books only for now: a podcast's files live on its episodes, so the show's
/// manifest would have to carry one entry per episode. Those starts keep their
/// existing paths.
class PlaybackManifest {
  PlaybackManifest._();

  /// Matches the item cache's retention: the file ids stay valid as long as the
  /// item does, and a server-side re-upload refreshes the manifest on the next
  /// fetch anyway.
  static const _maxAge = Duration(days: 7);

  /// Per-book budget for the encoded JSON. A 1000-file book needs roughly 40
  /// KB, so this only rejects pathological items (tens of thousands of files),
  /// and it is measured in bytes so that the thing being limited is the thing
  /// that costs - preferences load every string into memory at startup.
  static const _maxBytes = 256 * 1024;

  /// Hard sanity cap on the file count, independent of the byte budget.
  static const _maxFiles = 10000;

  static String _key(String itemId) {
    final scope = UserAccountService().activeScopeKey;
    final prefix = scope.isEmpty ? '' : '$scope:';
    return '${prefix}playback_manifest_$itemId';
  }

  /// Derive and store the manifest from a full library-item payload. Called
  /// wherever the item itself is cached, so every path that learns the file
  /// list leaves this behind for the next start.
  static Future<void> saveFromItem(
    String itemId,
    Map<String, dynamic> item,
  ) async {
    try {
      final media = item['media'] as Map<String, dynamic>?;
      if (media == null) return;
      // Movies/podcasts have no audioFiles at this level; the episode shape is
      // not carried here (see the class comment).
      final raw = (media['audioFiles'] as List<dynamic>?) ?? const [];
      final audioFiles = raw.whereType<Map<String, dynamic>>().toList()
        ..sort(
          (a, b) =>
              ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0),
        );
      if (audioFiles.isEmpty || audioFiles.length > _maxFiles) return;

      final files = <Map<String, dynamic>>[];
      var sum = 0.0;
      for (final af in audioFiles) {
        final ino = af['ino']?.toString();
        if (ino == null || ino.isEmpty) return;
        final dur = (af['duration'] as num?)?.toDouble() ?? 0;
        sum += dur;
        files.add({'ino': ino, 'duration': dur});
      }
      if (files.isEmpty) return;

      final mediaDuration = (media['duration'] as num?)?.toDouble() ?? 0;
      final data = <String, dynamic>{
        'files': files,
        // File durations can be missing; the item's own duration is the better
        // guess for the whole-book progress bar.
        'totalDuration': mediaDuration > 0 ? mediaDuration : sum,
        'itemUpdatedAt': (item['updatedAt'] as num?)?.toInt(),
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      };

      final encoded = jsonEncode(data);
      final bytes = utf8.encode(encoded).length;
      if (bytes > _maxBytes) {
        debugPrint(
          '[Manifest] Skipping $itemId: ${files.length} files encode to '
          '${bytes ~/ 1024} KB (budget ${_maxBytes ~/ 1024} KB)',
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_key(itemId));
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(itemId), encoded);
      debugPrint(
        '[Manifest] Saved $itemId: ${files.length} file(s), '
        '${bytes ~/ 1024} KB',
      );
    } catch (e) {
      debugPrint('[Manifest] Failed to save $itemId: $e');
    }
  }

  /// Load a manifest, or null when there is none, it is older than [_maxAge],
  /// or it predates [newerThanUpdatedAt] (the shelf payload says the item
  /// changed since - its file list may point at files that no longer exist).
  ///
  /// The returned blob deliberately carries no `savedAt`/`itemUpdatedAt`: the
  /// caller's session-cache staleness rule (45 min) is about session URLs and
  /// must not expire a manifest, whose URLs are re-signed on every start.
  static Future<Map<String, dynamic>?> load(
    String itemId, {
    int? newerThanUpdatedAt,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(itemId));
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;

      final savedAt = (data['savedAt'] as num?)?.toInt();
      if (savedAt == null) return null;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      if (age < 0 || age > _maxAge.inMilliseconds) return null;

      final updatedAt = (data['itemUpdatedAt'] as num?)?.toInt();
      if (newerThanUpdatedAt != null &&
          updatedAt != null &&
          updatedAt < newerThanUpdatedAt) {
        debugPrint(
          '[Manifest] Stale for $itemId: manifest updatedAt=$updatedAt < '
          'shelf $newerThanUpdatedAt',
        );
        return null;
      }

      final files = (data['files'] as List<dynamic>?) ?? const [];
      if (files.isEmpty) return null;
      return {
        'files': files,
        'totalDuration': (data['totalDuration'] as num?)?.toDouble() ?? 0.0,
      };
    } catch (e) {
      debugPrint('[Manifest] Failed to load $itemId: $e');
      return null;
    }
  }

  /// Drop one book's manifest (a failed start proves its file list is wrong).
  static Future<void> clear(String itemId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(itemId));
    } catch (_) {}
  }

  /// Clear every manifest for the active account scope (settings > clear cache).
  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scope = UserAccountService().activeScopeKey;
      final prefix = scope.isEmpty ? '' : '$scope:';
      final manifestPrefix = '${prefix}playback_manifest_';
      var cleared = 0;
      for (final k in prefs.getKeys().toList()) {
        if (k.startsWith(manifestPrefix)) {
          await prefs.remove(k);
          cleared++;
        }
      }
      if (cleared > 0) debugPrint('[Manifest] Cleared $cleared entries');
    } catch (_) {}
  }

  /// Approximate on-disk footprint for the active user scope, in bytes (the
  /// stored strings re-encoded as UTF-8). Feeds the settings cache sheet, which
  /// cannot see SharedPreferences files directly.
  static Future<int> byteSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scope = UserAccountService().activeScopeKey;
      final prefix = scope.isEmpty ? '' : '$scope:';
      final manifestPrefix = '${prefix}playback_manifest_';
      var total = 0;
      for (final k in prefs.getKeys().toList()) {
        if (k.startsWith(manifestPrefix)) {
          final raw = prefs.getString(k);
          if (raw != null) total += utf8.encode(raw).length;
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
