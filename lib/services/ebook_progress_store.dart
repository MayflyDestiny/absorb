import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'scoped_prefs.dart';

/// Per-version ebook reading positions.
///
/// An item can offer several versions of the same ebook - 极品家丁 ships a
/// 6.4 MB and a 161 MB EPUB, an AZW3, a MOBI and a PDF. The server (and
/// [LibraryProvider]'s item-level progress map) only stores ONE `ebookLocation`
/// per item, so resuming the 6.4 MB EPUB at chapter 3 and then opening the
/// 161 MB EPUB lands the second version at the first version's position - which
/// for a CFI/EPUB index is meaningless and reads as "it remembered the wrong
/// book".
///
/// This store keeps a position per (item, version) locally, scoped to the
/// active account, so each version resumes where that version left off. The
/// item-level position is still pushed to the server as before (cross-device
/// resume keeps working for the common single-version case); the version store
/// only decides what a reader opens at:
///
///   * a version with a saved position opens there;
///   * otherwise the item-level position is trusted only when no version has
///     written one, or the last writer was this same version (a fresh device
///     that has never saved locally, or the version that wrote it);
///   * when a *different* version last wrote the item-level position, it is
///     ignored and the reader starts fresh, so versions never bleed into each
///     other.
class EbookProgressStore {
  EbookProgressStore._();
  static final EbookProgressStore instance = EbookProgressStore._();

  static const _prefix = 'ebook_version_progress_';

  bool _loaded = false;
  Future<void>? _loading;
  final Map<String, _Versions> _items = {};

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loaded = true);
  }

  /// Re-read every stored version position from the active account's scope.
  /// Called after an in-app account switch or logout: the scope this data lives
  /// under changes, but the singleton (and its `_loaded` flag) does not, so
  /// without this the new account would inherit the previous one's positions.
  Future<void> reload() async {
    _items.clear();
    _loaded = false;
    _loading = null;
    await ensureLoaded();
  }

  Future<void> _load() async {
    final itemIds = await ScopedPrefs.suffixesWithPrefix(_prefix);
    for (final itemId in itemIds) {
      final raw = await ScopedPrefs.getString('$_prefix$itemId');
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          _items[itemId] = _Versions.fromJson(decoded);
        }
      } catch (e) {
        debugPrint('[EbookProgress] decode failed for $itemId: $e');
      }
    }
  }

  /// The position [versionId] of [itemId] should open at, given the item-level
  /// (server-backed) values in [itemLocation]/[itemProgress]. A null result
  /// means "start fresh"; when [versionId] is empty the item-level values are
  /// returned unchanged (no way to tell versions apart, so keep old behavior).
  Future<({String? location, double? progress})> resolve(
    String itemId,
    String versionId, {
    String? itemLocation,
    double? itemProgress,
  }) async {
    if (versionId.isEmpty) {
      return (location: itemLocation, progress: itemProgress);
    }
    await ensureLoaded();
    final item = _items[itemId];
    final saved = item?.versions[versionId];
    if (saved != null) {
      return (location: saved.location, progress: saved.progress);
    }
    if (item?.last == null || item!.last == versionId) {
      return (location: itemLocation, progress: itemProgress);
    }
    return (location: null, progress: null);
  }

  /// Progress of the version of [itemId] read most recently on this device, or
  /// null when nothing has been recorded yet (so a caller can fall back to the
  /// shared item-level value). Synchronous: relies on [ensureLoaded] having run
  /// (it's kicked off once at startup), so a build can read it directly.
  double? lastProgress(String itemId) {
    final item = _items[itemId];
    final last = item?.last;
    if (item == null || last == null) return null;
    return item.versions[last]?.progress;
  }

  /// The version of [itemId] read most recently on this device, or null when
  /// nothing has been recorded here yet. Lets a caller tell a shared item-level
  /// position of a known (other) version apart from an unknown one.
  String? lastVersion(String itemId) => _items[itemId]?.last;

  /// Progress recorded on this device for one specific [versionId] of [itemId],
  /// or null when that version has no saved position (so the caller can fall
  /// back to the shared item-level value). Unlike [lastProgress] this doesn't
  /// care which version was read most recently, so a caller can show the
  /// progress of the version that is actually the default. Synchronous, like
  /// [lastProgress].
  double? progressForVersion(String itemId, String versionId) {
    if (versionId.isEmpty) return null;
    return _items[itemId]?.versions[versionId]?.progress;
  }

  /// Record that [versionId] of [itemId] is now at [location]/[progress], and
  /// that this version is the last writer of the item-level position.
  Future<void> record(
    String itemId,
    String versionId,
    String location,
    double progress,
  ) async {
    if (versionId.isEmpty) return;
    // Already-loaded is the common case (eager load at startup): update the
    // in-memory map synchronously so a build running right after the reader's
    // own notifyListeners sees the new value, then persist.
    if (!_loaded) await ensureLoaded();
    final item = _items.putIfAbsent(itemId, () => _Versions());
    item.versions[versionId] = _Position(location, progress.clamp(0.0, 1.0));
    item.last = versionId;
    await _write(itemId, item);
  }

  /// Drop every saved version position for [itemId] (mark-unread / reset).
  Future<void> clear(String itemId) async {
    await ensureLoaded();
    if (_items.remove(itemId) == null) return;
    await ScopedPrefs.remove('$_prefix$itemId');
  }

  Future<void> _write(String itemId, _Versions item) async {
    await ScopedPrefs.setString('$_prefix$itemId', jsonEncode(item.toJson()));
  }
}

class _Versions {
  String? last;
  final Map<String, _Position> versions = {};

  _Versions();

  factory _Versions.fromJson(Map<String, dynamic> json) {
    final v = _Versions();
    v.last = json['last'] as String?;
    final rawVersions = json['v'];
    if (rawVersions is Map) {
      rawVersions.forEach((key, value) {
        if (key is String && value is Map) {
          final loc = value['loc'] as String?;
          final prog = (value['prog'] as num?)?.toDouble();
          if (loc != null) {
            v.versions[key] = _Position(loc, prog?.clamp(0.0, 1.0));
          }
        }
      });
    }
    return v;
  }

  Map<String, dynamic> toJson() => {
        'last': last,
        'v': {
          for (final e in versions.entries)
            e.key: {'loc': e.value.location, 'prog': e.value.progress},
        },
      };
}

class _Position {
  final String location;
  final double? progress;
  const _Position(this.location, this.progress);
}
