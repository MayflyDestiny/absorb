import 'scoped_prefs.dart';

/// The locally preferred ebook version for a book: which of an item's several
/// ebook files (its `ino`) the app should use by default, overriding the
/// server's own primary pick. Set from the "choose ebook version" sheet by
/// long-pressing a version.
///
/// Kept in memory for the synchronous readers ([resolveEbookFile] runs without
/// an await), warmed once from storage via [load].
class EbookPreferences {
  EbookPreferences._();

  static const _prefix = 'ebook_default_';
  static final Map<String, String> _defaults = {};

  /// The locally chosen default version (`ino`) for [itemId], or null when the
  /// book has no local override (use the server default).
  static String? defaultIno(String itemId) {
    if (itemId.isEmpty) return null;
    final v = _defaults[itemId];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Warm the in-memory map from storage. Call once at startup.
  static Future<void> load() async {
    _defaults.clear();
    final ids = await ScopedPrefs.suffixesWithPrefix(_prefix);
    for (final id in ids) {
      final v = await ScopedPrefs.getString('$_prefix$id');
      if (v != null && v.isNotEmpty) _defaults[id] = v;
    }
  }

  /// Record [ino] as the default version for [itemId].
  static Future<void> setDefaultIno(String itemId, String ino) async {
    if (itemId.isEmpty) return;
    if (ino.isEmpty) {
      await clearDefaultIno(itemId);
      return;
    }
    _defaults[itemId] = ino;
    await ScopedPrefs.setString('$_prefix$itemId', ino);
  }

  /// Drop the local override for [itemId], falling back to the server default.
  static Future<void> clearDefaultIno(String itemId) async {
    if (itemId.isEmpty) return;
    _defaults.remove(itemId);
    await ScopedPrefs.remove('$_prefix$itemId');
  }
}
