/// Extracts the first non-empty series ID from a library item map.
///
/// Audiobookshelf stamps series as either a list of maps (`[{id, name}]`) or a
/// single map on `media.metadata.series`. Podcasts have no series.
String? seriesIdFromItem(Map<String, dynamic>? item) {
  final rawSeries =
      ((item?['media'] as Map<String, dynamic>?)?['metadata']
          as Map<String, dynamic>?)?['series'];
  if (rawSeries is List) {
    for (final s in rawSeries.whereType<Map<String, dynamic>>()) {
      final id = (s['id'] as String? ?? '').trim();
      if (id.isNotEmpty) return id;
    }
  } else if (rawSeries is Map<String, dynamic>) {
    final id = (rawSeries['id'] as String? ?? '').trim();
    if (id.isNotEmpty) return id;
  }
  return null;
}