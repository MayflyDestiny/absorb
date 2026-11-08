import 'json_file_cache.dart';

/// One item's chapter list, cached on its own.
///
/// The full item payload (`library_item|<id>`) carries audio files, ebook
/// entries and more; the chapter list itself is a few KB. Keeping it under its
/// own key lets a book whose full item was never cached paint its chapters
/// straight away while the expanded fetch runs in the background.
class ChapterCache {
  ChapterCache._();

  static String keyFor(String itemId) => 'chapters|$itemId';

  /// The cached chapters, or null when this book never had its item fetched.
  /// Callers treat it as a first paint, not as the source of truth: the
  /// expanded fetch always replaces it, and `item_updated` sits on the same
  /// invalidation path as the item cache.
  static Future<List<dynamic>?> read(String itemId) async {
    final map = await JsonFileCache.readMap(keyFor(itemId));
    final chapters = map?['chapters'];
    return chapters is List && chapters.isNotEmpty ? chapters : null;
  }

  static Future<void> write(
    String itemId,
    int? updatedAt,
    List<dynamic> chapters,
  ) async {
    if (chapters.isEmpty) return;
    await JsonFileCache.write(keyFor(itemId), {
      'updatedAt': updatedAt ?? 0,
      'chapters': chapters,
    });
  }

  static Future<void> invalidate(String itemId) =>
      JsonFileCache.invalidate(keyFor(itemId));
}
