/// Pure chapter index lookup, extracted from AudioPlayerService.
///
/// Finds which chapter contains a given playback position. Used by the
/// audio handler to drive Android Auto's current-chapter highlight,
/// notification chapter mode, and the queue index.
///
/// Extracted so the boundary logic can be unit-tested without spinning up
/// just_audio. Behavior must match the inline loop in
/// `audio_player_service.dart` exactly. Change one, change both.
class ChapterLookup {
  /// Return the index of the chapter containing [positionSeconds], or `null`
  /// if no chapter contains it (or if the chapter list is empty).
  ///
  /// Each chapter is expected to be a `Map<String, dynamic>` with `start`
  /// and `end` numeric fields (in seconds). Missing `start` defaults to 0;
  /// missing `end` defaults to [totalDuration].
  ///
  /// Boundary semantics: `start <= positionSeconds < end` (inclusive at
  /// start, exclusive at end). This means the boundary instant belongs to
  /// the next chapter, not the previous one.
  static int? indexAt(
    List<dynamic> chapters,
    double positionSeconds,
    double totalDuration,
  ) {
    if (chapters.isEmpty) return null;
    for (int i = 0; i < chapters.length; i++) {
      final ch = chapters[i] as Map<String, dynamic>;
      final start = (ch['start'] as num?)?.toDouble() ?? 0;
      final end = (ch['end'] as num?)?.toDouble() ?? totalDuration;
      if (positionSeconds >= start && positionSeconds < end) return i;
    }
    return null;
  }

  /// How far past the last chapter's end a position may sit while still
  /// counting as the last chapter (covers rounding and trailing gaps).
  /// Positions grossly past that mean the chapters don't cover the item's
  /// timeline - e.g. duplicate audio files doubling the duration (GH #345) -
  /// and resolve to no chapter instead of pinning the last one.
  static const graceSeconds = 120.0;

  /// Like [indexAt], but keeps the last chapter for positions within
  /// [graceSeconds] past its end.
  static int? indexAtWithGrace(
    List<dynamic> chapters,
    double positionSeconds,
    double totalDuration,
  ) {
    final idx = indexAt(chapters, positionSeconds, totalDuration);
    if (idx != null) return idx;
    if (chapters.isEmpty) return null;
    final last = chapters.last as Map<String, dynamic>;
    final end = (last['end'] as num?)?.toDouble() ?? totalDuration;
    if (positionSeconds >= end && positionSeconds <= end + graceSeconds) {
      return chapters.length - 1;
    }
    return null;
  }

  static ({double seconds, bool finishesItem})? nextSkipTarget(
    List<dynamic> chapters,
    double positionSeconds,
    double totalDuration,
  ) {
    if (chapters.isEmpty) return null;
    for (final chapter in chapters) {
      final map = chapter as Map<String, dynamic>;
      final start = (map['start'] as num?)?.toDouble() ?? 0;
      if (start > positionSeconds + 1.0) {
        return (seconds: start, finishesItem: false);
      }
    }

    final lastChapter = chapters.last as Map<String, dynamic>;
    final lastEnd = (lastChapter['end'] as num?)?.toDouble() ?? 0;
    final end = totalDuration > 0 ? totalDuration : lastEnd;
    if (end <= 0) return null;
    return (seconds: end, finishesItem: true);
  }

  /// Whether [a] and [b] describe the same chapters in the same order.
  ///
  /// Chapters are re-fetched whenever the server reports an item change, and the
  /// overwhelming majority of those changes are cover/progress metadata. Only a
  /// real difference must be pushed into the player, since replacing the live
  /// chapter array mid-playback re-derives the current-chapter latch.
  ///
  /// Compares the fields the UI and seeking actually read - title, start, end -
  /// and ignores server bookkeeping (`updatedAt`, `id`) that never changes what
  /// the user sees. Start/end are compared with sub-millisecond tolerance
  /// because they round-trip through JSON as doubles.
  static bool equivalent(List<dynamic>? a, List<dynamic>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) {
      // One side absent: only "both effectively empty" counts as equal, so a
      // first fetch that yields nothing isn't mistaken for no change.
      return (a == null || a.isEmpty) && (b == null || b.isEmpty);
    }
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x is! Map || y is! Map) return false;
      if ((x['title'] as String?) != (y['title'] as String?)) return false;
      if (!_sameInstant(x['start'], y['start'])) return false;
      if (!_sameInstant(x['end'], y['end'])) return false;
    }
    return true;
  }

  static bool _sameInstant(dynamic x, dynamic y) {
    final dx = (x as num?)?.toDouble() ?? 0;
    final dy = (y as num?)?.toDouble() ?? 0;
    return (dx - dy).abs() < 0.001;
  }
}
