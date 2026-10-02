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

  // ── File-timeline chapter bounds ────────────────────────────────────────
  //
  // The player reports and seeks in the FILE timeline: an absolute position is
  // the track-relative position plus that track's start offset. The `start` /
  // `end` fields on the chapter maps live in a SEPARATE timeline that drifts
  // away from the file timeline by a few seconds once a book has been split and
  // re-encoded.
  //
  // Comparing a file-timeline position against metadata-timeline boundaries
  // pays that drift twice - once when the trigger fires, once when the target
  // is re-interpreted. On a 1:1 book whose files ran 4s long against the
  // metadata, an "intro 20s" skip advanced only 16s and an "outro 7s" skip
  // fired with 5s still audible.
  //
  // These helpers rebase chapter bounds onto the file timeline, where they are
  // exact by construction:
  //   chapter i starts at the start of the FILE holding its metadata start
  //   chapter i ends   at the start of the FILE holding chapter i+1's start
  // A single-file book has only one timeline, so its metadata is already exact
  // and is returned verbatim.

  /// Whether chapter bounds must be read from the file timeline. Only a
  /// multi-file book can have two disagreeing timelines.
  ///
  /// The discriminator is the track COUNT, not the offsets length: every caller
  /// appends a sentinel to [trackStartOffsets], so a single file still measures
  /// length 2. A genuine one-track book goes through the same encoding, and it
  /// does have only one timeline, so metadata is correct for it either way.
  static bool useFileTimeline(
    List<double> trackStartOffsets,
    List<double> trackDurations,
  ) => trackDurations.length > 1;

  /// Metadata start of chapter [i] - chapter 0 falls back to 0 when absent.
  static double metaStart(List<dynamic> chapters, int i) {
    if (i < 0 || i >= chapters.length) return 0;
    return ((chapters[i] as Map)['start'] as num?)?.toDouble() ?? 0;
  }

  /// Duration of track [i], falling back to the start-offset delta for the
  /// legacy callers that populate offsets without a duration list.
  static double _trackDurationAt(
    int i,
    List<double> trackStartOffsets,
    List<double> trackDurations,
  ) {
    if (i >= 0 && i < trackDurations.length) return trackDurations[i];
    if (i >= 0 && i + 1 < trackStartOffsets.length) {
      return trackStartOffsets[i + 1] - trackStartOffsets[i];
    }
    return 0;
  }

  /// Track whose START is nearest [absoluteSeconds].
  ///
  /// Chapter boundaries are located by nearest-start rather than by containment
  /// on purpose. When the metadata drifts a few seconds behind the real audio,
  /// chapter i+1's metadata start can land *inside* file i, and a containment
  /// lookup would map both chapters onto the same file and collapse chapter i
  /// to a zero-width window. Snapping to the closest file start recovers the
  /// intended file in either drift direction, and is exact when the timelines
  /// agree.
  static int nearestTrackAt(
    double absoluteSeconds,
    List<double> trackStartOffsets,
  ) {
    if (trackStartOffsets.length < 2) return 0;
    final lastTrack = trackStartOffsets.length - 2;
    var best = 0;
    var bestDelta = (trackStartOffsets[0] - absoluteSeconds).abs();
    for (var i = 1; i <= lastTrack; i++) {
      final delta = (trackStartOffsets[i] - absoluteSeconds).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = i;
      }
    }
    return best;
  }

  /// File-timeline start of chapter [i] - the first frame of its audio.
  static double fileStart(
    List<dynamic> chapters,
    List<double> trackStartOffsets,
    List<double> trackDurations,
    int i,
  ) {
    if (!useFileTimeline(trackStartOffsets, trackDurations)) {
      return metaStart(chapters, i);
    }
    return trackStartOffsets[nearestTrackAt(
      metaStart(chapters, i),
      trackStartOffsets,
    )];
  }

  /// File-timeline end of chapter [i]. The last chapter ends with the last
  /// FILE rather than at the metadata's end, which may sit past or short of the
  /// real audio.
  static double fileEnd(
    List<dynamic> chapters,
    List<double> trackStartOffsets,
    List<double> trackDurations,
    double totalDuration,
    int i,
  ) {
    if (!useFileTimeline(trackStartOffsets, trackDurations)) {
      if (i < 0 || i >= chapters.length) return totalDuration;
      final endFromData = (chapters[i] as Map)['end'] as num?;
      if (endFromData != null) return endFromData.toDouble();
      return i + 1 < chapters.length
          ? metaStart(chapters, i + 1)
          : totalDuration;
    }
    final start = fileStart(chapters, trackStartOffsets, trackDurations, i);
    if (i + 1 >= chapters.length) {
      final lastTrack = trackStartOffsets.length - 2;
      return trackStartOffsets[lastTrack] +
          _trackDurationAt(lastTrack, trackStartOffsets, trackDurations);
    }
    final nextStart = fileStart(
      chapters,
      trackStartOffsets,
      trackDurations,
      i + 1,
    );
    // Never return an inverted window: a non-monotonic or noisy metadata can
    // otherwise make chapter i+1 start before chapter i, which would leave the
    // `end - pos < outroSkip` window permanently true and fire the outro
    // immediately on entry.
    return nextStart > start ? nextStart : start;
  }

  /// Precomputed file-timeline bounds for every chapter.
  ///
  /// [fileStart] and [fileEnd] each walk the entire track list through
  /// [nearestTrackAt]. Running them per position tick - and the skip check runs
  /// on a 120ms poll for as long as playback sits inside the outro window -
  /// meant several full track scans every tick, which showed up as a stutter on
  /// chapter navigation once a book had enough files. The mapping only depends
  /// on (chapters, tracks, totalDuration), so it is built once per generation
  /// and read as plain array lookups afterwards.
  static ({List<double> starts, List<double> ends}) buildFileBounds({
    required List<dynamic> chapters,
    required List<double> trackStartOffsets,
    required List<double> trackDurations,
    required double totalDuration,
  }) {
    final n = chapters.length;
    final starts = List<double>.filled(n, 0);
    final ends = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      starts[i] = fileStart(chapters, trackStartOffsets, trackDurations, i);
    }
    for (var i = 0; i < n; i++) {
      ends[i] = fileEnd(
        chapters,
        trackStartOffsets,
        trackDurations,
        totalDuration,
        i,
      );
    }
    return (starts: starts, ends: ends);
  }

  /// [indexAtFilePosition] over bounds already produced by [buildFileBounds] -
  /// no track-list scan, so it is cheap enough for the per-tick path.
  static int indexAtPrecomputed({
    required List<double> starts,
    required List<double> ends,
    required int hint,
    required double posSec,
  }) {
    var i = hint;
    while (i > 0 && posSec < starts[i]) {
      i--;
    }
    while (i + 1 < ends.length && posSec >= ends[i]) {
      i++;
    }
    return i;
  }

  /// Chapter index for [posSec], refined from the metadata [hint] into the file
  /// timeline. Near a boundary the two can disagree by one chapter, and the
  /// outro window is half-open, so a stale index would immediately satisfy
  /// `end - pos < outroSkip` at the very top of a chapter and jump the listener
  /// straight past it. Bounds are monotonic, so this settles in a step or two.
  ///
  /// Convenience wrapper that rebuilds the bounds; hot callers should cache
  /// [buildFileBounds] and call [indexAtPrecomputed] instead.
  static int indexAtFilePosition({
    required List<dynamic> chapters,
    required List<double> trackStartOffsets,
    required List<double> trackDurations,
    required double totalDuration,
    required double posSec,
    required int hint,
  }) {
    if (!useFileTimeline(trackStartOffsets, trackDurations)) return hint;
    final bounds = buildFileBounds(
      chapters: chapters,
      trackStartOffsets: trackStartOffsets,
      trackDurations: trackDurations,
      totalDuration: totalDuration,
    );
    return indexAtPrecomputed(
      starts: bounds.starts,
      ends: bounds.ends,
      hint: hint,
      posSec: posSec,
    );
  }
}
