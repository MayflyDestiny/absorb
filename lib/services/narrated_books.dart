import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Audiobookshelf books whose EPUB reads itself aloud, as found on this
/// phone (the server only sees an ebook). Held in memory so the quick "is
/// this ebook only" checks can count them as audiobooks. Item ids are unique
/// across servers, so one list serves every account.
class NarratedBooks {
  NarratedBooks._();

  static const _key = 'narrated_books';
  static final Map<String, double> _durations = {};
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      (jsonDecode(raw) as Map<String, dynamic>).forEach((id, d) {
        if (d is num && d > 0) _durations[id] = d.toDouble();
      });
    } catch (e) {
      debugPrint('[Narration] reading the narrated books failed: $e');
    }
  }

  static bool contains(Object? itemId) => itemId is String && _durations.containsKey(itemId);

  static double? duration(String itemId) => _durations[itemId];

  /// Notes [itemId] as narrated with [duration] seconds, or as not narrated.
  static Future<void> set(String itemId, double? duration) async {
    await load();
    if (duration != null && duration > 0) {
      if (_durations[itemId] == duration) return;
      _durations[itemId] = duration;
    } else if (_durations.remove(itemId) == null) {
      return;
    }
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(_durations));
    } catch (e) {
      debugPrint('[Narration] saving the narrated books failed: $e');
    }
  }

  @visibleForTesting
  static void debugSet(Map<String, double> durations) {
    _loading = Future.value();
    _durations
      ..clear()
      ..addAll(durations);
  }
}
