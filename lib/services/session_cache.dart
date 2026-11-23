import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_account_service.dart';

/// Caches playback session metadata (track URLs, chapters, duration) per item
/// so the app can start playback immediately on cold start without waiting for
/// a `startPlaybackSession` network call.
///
/// The session ID itself is NOT cached - that's created fresh in the background
/// on every play. Only the parts needed to build the AudioSource are stored.
///
/// Per-user scoped via active account prefix so accounts don't share caches.
class SessionCache {
  SessionCache._();

  static String _key(String itemId, String? episodeId) {
    final scope = UserAccountService().activeScopeKey;
    final prefix = scope.isEmpty ? '' : '$scope:';
    return episodeId != null
        ? '${prefix}session_cache_${itemId}_$episodeId'
        : '${prefix}session_cache_$itemId';
  }

  /// A URL kept for a later play must not keep the access token it was minted
  /// with: the token rotates, the cached URL does not. The URL is rebuilt with
  /// the current token at start time instead.
  static String _withoutToken(String url) {
    final queryStart = url.indexOf('?');
    if (queryStart < 0) return url;
    final uri = Uri.tryParse(url);
    // Only server-relative ABS item-file URLs: an external/CDN or backend-
    // specific URL may carry a signed query that is not our access token and
    // must be stored verbatim.
    if (uri == null || uri.hasAuthority) return url;
    if (!uri.path.contains('/api/items/') ||
        !uri.path.contains('/file/')) {
      return url;
    }
    final params = Map<String, dynamic>.from(uri.queryParametersAll);
    if (!params.containsKey('token')) return url;
    params.remove('token');
    if (params.isEmpty) {
      final fragmentStart = url.indexOf('#', queryStart);
      return url.substring(0, queryStart) +
          (fragmentStart < 0 ? '' : url.substring(fragmentStart));
    }
    return uri.replace(queryParameters: params).toString();
  }

  static List<dynamic> _withoutTokens(List<dynamic> tracks) {
    return [
      for (final track in tracks)
        if (track is Map<String, dynamic>)
          {
            ...track,
            if (track['contentUrl'] is String)
              'contentUrl': _withoutToken(track['contentUrl'] as String),
          }
        else
          track,
    ];
  }

  /// Save session metadata for an item. Only stores what we need to rebuild
  /// the audio source on next play.
  static Future<void> save({
    required String itemId,
    String? episodeId,
    required List<dynamic> audioTracks,
    required List<dynamic> chapters,
    required double totalDuration,
    bool serverOrder = false,
    int? playMethod,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = {
        'audioTracks': _withoutTokens(audioTracks),
        'chapters': chapters,
        'totalDuration': totalDuration,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        // audioTracks came from a full server session, so their index fields
        // are the authoritative public-session track indexes (not local list
        // positions). Only such a cache may drive a tokenless start.
        'serverOrder': serverOrder,
        if (playMethod != null) 'playMethod': playMethod,
      };
      await prefs.setString(_key(itemId, episodeId), jsonEncode(data));
    } catch (e) {
      debugPrint('[SessionCache] Failed to save: $e');
    }
  }

  /// Load cached session metadata. Returns null if not cached.
  static Future<Map<String, dynamic>?> load({
    required String itemId,
    String? episodeId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(itemId, episodeId));
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[SessionCache] Failed to load: $e');
      return null;
    }
  }

  /// Clear the cache for a single item.
  static Future<void> clear({
    required String itemId,
    String? episodeId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (episodeId != null) {
        await prefs.remove(_key(itemId, episodeId));
      } else {
        // Clear the item key and any episode keys under it
        await prefs.remove(_key(itemId, null));
        final scope = UserAccountService().activeScopeKey;
        final prefix = scope.isEmpty ? '' : '$scope:';
        final itemPrefix = '${prefix}session_cache_${itemId}_';
        for (final k in prefs.getKeys().toList()) {
          if (k.startsWith(itemPrefix)) {
            await prefs.remove(k);
          }
        }
      }
    } catch (e) {
      debugPrint('[SessionCache] Failed to clear: $e');
    }
  }

  /// Approximate on-disk footprint of cached session metadata for the active
  /// user scope, in bytes (sum of stored strings encoded as UTF-8). Used by
  /// the settings clear-cache screen, which can't see SharedPreferences files
  /// directly.
  static Future<int> byteSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scope = UserAccountService().activeScopeKey;
      final prefix = scope.isEmpty ? '' : '$scope:';
      final cachePrefix = '${prefix}session_cache_';
      var total = 0;
      for (final k in prefs.getKeys().toList()) {
        if (k.startsWith(cachePrefix)) {
          final raw = prefs.getString(k);
          if (raw != null) total += utf8.encode(raw).length;
        }
      }
      return total;
    } catch (e) {
      debugPrint('[SessionCache] Failed to measure size: $e');
      return 0;
    }
  }

  /// Clear all session cache entries for the active user scope.
  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scope = UserAccountService().activeScopeKey;
      final prefix = scope.isEmpty ? '' : '$scope:';
      final cachePrefix = '${prefix}session_cache_';
      int cleared = 0;
      for (final k in prefs.getKeys().toList()) {
        if (k.startsWith(cachePrefix)) {
          await prefs.remove(k);
          cleared++;
        }
      }
      debugPrint('[SessionCache] Cleared $cleared entries');
    } catch (e) {
      debugPrint('[SessionCache] Failed to clear all: $e');
    }
  }
}
