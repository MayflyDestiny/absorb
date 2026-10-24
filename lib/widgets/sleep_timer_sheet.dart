import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/audio_player_service.dart';
import '../services/sleep_timer_service.dart';

// ═════════════════ SHARED SLEEP TIMER SHEET ═════════════════
void showSleepTimerSheet(BuildContext context, Color accent) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => SleepTimerSheet(accent: accent),
  );
}

class SleepTimerSheet extends StatefulWidget {
  final Color accent;
  const SleepTimerSheet({super.key, required this.accent});
  @override
  State<SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<SleepTimerSheet>
    with SingleTickerProviderStateMixin {
  int _tabIndex = 0; // 0 = Timer, 1 = End of Chapter
  int _hours = 0;
  int _minutes = 30;
  bool _customOpen = false;
  bool _programmaticWheel = false;
  final FixedExtentScrollController _hourController =
      FixedExtentScrollController();
  final FixedExtentScrollController _minuteController =
      FixedExtentScrollController();
  int _customChapters = 1;
  String _shakeMode = 'addTime'; // 'off', 'addTime', 'resetTimer'
  int _shakeAddMinutes = 5;
  int _sleepRewindSeconds = 0;
  int _selectedChapterIndex = 0;
  bool _useChapterEnd = true;
  final ScrollController _chapterScroll = ScrollController();
  // Smoothly thickens the chapter-list scrollbar thumb while the user drags
  // (Material Scrollbar has no tween for its drag thickness on touch).
  late final AnimationController _chapterBarAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 300),
  );

  static const _maxRewindMinutes = 120;
  static const _virtualHourCount = 24 * 100;
  static const _virtualMinuteCount = 60 * 100;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final results = await Future.wait([
      PlayerSettings.getShakeMode(),
      PlayerSettings.getShakeAddMinutes(),
      PlayerSettings.getSleepTimerMinutes(),
      PlayerSettings.getSleepTimerChapters(),
      PlayerSettings.getEffectiveSleepRewindSeconds(
        AudioPlayerService().currentItemId,
      ),
      PlayerSettings.getSleepTimerTab(),
    ]);
    if (!mounted) return;
    final savedMinutes = results[2] as int;
    _hours = (savedMinutes ~/ 60).clamp(0, 23);
    _minutes = (savedMinutes % 60).clamp(0, 59);
    setState(() {
      _shakeMode = results[0] as String;
      _shakeAddMinutes = results[1] as int;
      _customChapters = results[3] as int;
      _sleepRewindSeconds = results[4] as int;
      _tabIndex = results[5] as int;
      // Podcast episodes only have Timer + End-of-Episode tabs; clamp a saved
      // "specific chapter" tab index (2) so it doesn't fall off the end.
      if (AudioPlayerService().currentEpisodeId != null && _tabIndex > 1) {
        _tabIndex = 1;
      }
      final currentIdx = _getCurrentChapterIndexFromPlayer();
      if (currentIdx >= 0) _selectedChapterIndex = currentIdx;
    });
    _syncWheelsToValue();
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    _chapterScroll.dispose();
    _chapterBarAnim.dispose();
    super.dispose();
  }

  int _getCurrentChapterIndexFromPlayer() {
    final player = AudioPlayerService();
    final chapters = player.chapters;
    final pos = player.position.inMilliseconds / 1000.0;
    for (int i = 0; i < chapters.length; i++) {
      final ch = chapters[i] as Map<String, dynamic>;
      final start = (ch['start'] as num?)?.toDouble() ?? 0;
      final end = (ch['end'] as num?)?.toDouble() ?? 0;
      if (pos >= start && pos < end) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final accent = widget.accent;
    final l = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: SleepTimerService(),
      builder: (_, __) {
        final sleep = SleepTimerService();
        final isActive = sleep.isActive;
        final isEpisode = AudioPlayerService().currentEpisodeId != null;

        final navBarPad = MediaQuery.of(context).viewPadding.bottom;

        return Container(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 24 + navBarPad),
          decoration: BoxDecoration(
            color: Theme.of(context).bottomSheetTheme.backgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: accent.withValues(alpha: 0.2), width: 1),
            ),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l.sleepTimer,
                  style: tt.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 16),
                if (isActive)
                  _buildActiveState(sleep, accent, tt, l)
                else ...[
                  // Tab bar
                  Container(
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.all(3),
                    child: Row(
                      children: [
                        _tab(l.timer, Icons.timer_outlined, 0, accent),
                        const SizedBox(width: 4),
                        _tab(
                          isEpisode ? l.endOfEpisode : l.endOfChapter,
                          isEpisode
                              ? Icons.podcasts_outlined
                              : Icons.auto_stories_outlined,
                          1,
                          accent,
                        ),
                        if (!isEpisode) ...[
                          const SizedBox(width: 4),
                          _tab(
                            l.sleepTimerSheetTabSpecificChapter,
                            Icons.bookmark_outlined,
                            2,
                            accent,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Tab content
                  if (_tabIndex == 0)
                    _buildTimerTab(accent, tt, l)
                  else if (_tabIndex == 1)
                    (isEpisode
                        ? _buildEpisodeTab(accent, tt, l)
                        : _buildChapterTab(accent, tt, l))
                  else
                    _buildSpecificChapterTab(accent, tt, l),
                  const SizedBox(height: 16),
                  Container(
                    height: 0.5,
                    color: cs.onSurface.withValues(alpha: 0.08),
                  ),
                  const SizedBox(height: 12),

                  // Rewind on sleep
                  _buildRewindSection(accent, tt, l),

                  const SizedBox(height: 12),
                  Container(
                    height: 0.5,
                    color: cs.onSurface.withValues(alpha: 0.08),
                  ),
                  const SizedBox(height: 12),

                  // Shake toggle
                  _buildShakeToggle(accent, tt, l),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActiveState(
    SleepTimerService sleep,
    Color accent,
    TextTheme tt,
    AppLocalizations l,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isTime = sleep.mode == SleepTimerMode.time;
    final isEpisode = sleep.mode == SleepTimerMode.episodes;

    String countdownLabel;
    if (isTime) {
      final r = sleep.timeRemaining;
      final m = r.inMinutes;
      final s = r.inSeconds % 60;
      countdownLabel =
          '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    } else if (isEpisode) {
      countdownLabel = l.endOfEpisode;
    } else {
      countdownLabel = l.sleepTimerSheetChaptersLeft(sleep.chaptersRemaining);
    }

    return Column(
      children: [
        // Countdown display
        if (isTime) ...[
          Text(
            countdownLabel,
            style: TextStyle(
              color: accent,
              fontSize: 40,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 8),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: sleep.timeProgress,
              minHeight: 4,
              backgroundColor: cs.onSurface.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation(accent.withValues(alpha: 0.6)),
            ),
          ),
        ] else ...[
          Icon(
            isEpisode ? Icons.podcasts_outlined : Icons.auto_stories_outlined,
            size: 28,
            color: accent.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 8),
          Text(
            countdownLabel,
            style: TextStyle(
              color: accent,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        const SizedBox(height: 20),

        // Quick add buttons (not applicable to "end of episode")
        if (!isEpisode) ...[
          Text(
            l.addMoreTime,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (isTime)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final mins in [5, 10, 15, 30])
                  _presetChip(
                    accent,
                    l.sleepTimerSheetAddMinutesChip(mins),
                    false,
                    () {
                      sleep.addTime(Duration(minutes: mins));
                    },
                  ),
              ],
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final ch in [1, 2, 3])
                  _presetChip(
                    accent,
                    l.sleepTimerSheetAddChaptersChip(ch),
                    false,
                    () {
                      for (int i = 0; i < ch; i++) sleep.addChapter();
                    },
                  ),
              ],
            ),
          const SizedBox(height: 20),
        ],

        // Cancel button
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.close_rounded, size: 18),
            label: Text(l.cancelTimer),
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.onSurfaceVariant,
              side: BorderSide(color: cs.onSurface.withValues(alpha: 0.12)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              sleep.cancelByUser();
              Navigator.pop(context);
            },
          ),
        ),

        const SizedBox(height: 12),
        Container(height: 0.5, color: cs.onSurface.withValues(alpha: 0.08)),
        const SizedBox(height: 12),
        _buildRewindSection(accent, tt, l),
        const SizedBox(height: 12),
        Container(height: 0.5, color: cs.onSurface.withValues(alpha: 0.08)),
        const SizedBox(height: 12),
        _buildShakeToggle(accent, tt, l),
      ],
    );
  }

  Widget _buildSpecificChapterTab(
    Color accent,
    TextTheme tt,
    AppLocalizations l,
  ) {
    final cs = Theme.of(context).colorScheme;
    final player = AudioPlayerService();
    final chapters = player.chapters;

    if (chapters.isEmpty) {
      return Center(
        child: Text(
          l.sleepTimerSheetSpecificNoChapters,
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
        ),
      );
    }

    final selectedChapter =
        chapters[_selectedChapterIndex] as Map<String, dynamic>;
    final refTimeSec = _useChapterEnd
        ? (selectedChapter['end'] as num?)?.toDouble() ?? 0
        : (selectedChapter['start'] as num?)?.toDouble() ?? 0;

    final currentPosSec = player.position.inMilliseconds / 1000.0;
    final secondsUntilTarget = refTimeSec - currentPosSec;
    final realSecondsUntil = secondsUntilTarget / player.speed;
    final endTime = DateTime.now().add(
      Duration(milliseconds: (realSecondsUntil * 1000).round()),
    );

    final isPast = secondsUntilTarget <= 0;

    return Column(
      children: [
        // Chapter picker
        Builder(
          builder: (ctx) {
            final selectedCh =
                chapters[_selectedChapterIndex] as Map<String, dynamic>;
            final selTitle =
                selectedCh['title'] as String? ??
                l.sleepTimerSheetSpecificChapterFallback(
                  _selectedChapterIndex + 1,
                );
            final selEndSec = (selectedCh['end'] as num?)?.toDouble() ?? 0;
            final curPosSec = player.position.inMilliseconds / 1000.0;
            final selSeconds = (selEndSec - curPosSec) / player.speed;
            final selTimeLabel = selSeconds > 0
                ? _formatWallClock(
                    DateTime.now().add(
                      Duration(milliseconds: (selSeconds * 1000).round()),
                    ),
                  )
                : l.sleepTimerSheetSpecificPassedShort;
            return GestureDetector(
              onTap: () => _openChapterPicker(chapters, accent),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.15)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.bookmark_outline_rounded,
                        size: 18,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            selTimeLabel,
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.arrow_drop_down_rounded,
                      color: cs.onSurfaceVariant,
                      size: 22,
                    ),
                  ],
                ),
              ),
            );
          },
        ),

        const SizedBox(height: 12),

        // Start / End toggle
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: false,
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(l.sleepTimerSheetSpecificStart, maxLines: 1),
                ),
              ),
              ButtonSegment(
                value: true,
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(l.sleepTimerSheetSpecificEnd, maxLines: 1),
                ),
              ),
            ],
            selected: {_useChapterEnd},
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: const WidgetStatePropertyAll(
                TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? accent.withValues(alpha: 0.18)
                    : Colors.transparent,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? accent
                    : cs.onSurfaceVariant,
              ),
              side: WidgetStatePropertyAll(
                BorderSide(color: cs.onSurface.withValues(alpha: 0.12)),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            onSelectionChanged: (v) => setState(() => _useChapterEnd = v.first),
          ),
        ),

        const SizedBox(height: 20),

        // Estimated end time
        if (!isPast) ...[
          Text(
            l.sleepTimerSheetSpecificEndsAt,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            _formatWallClock(endTime),
            style: TextStyle(
              color: accent,
              fontSize: 36,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l.sleepTimerSheetSpecificCountdown(
              _formatCountdown(Duration(seconds: realSecondsUntil.round())),
            ),
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ] else
          Text(
            l.sleepTimerSheetSpecificAlreadyPassed,
            style: TextStyle(color: cs.error, fontSize: 13),
          ),

        const SizedBox(height: 16),

        // Start button
        SizedBox(
          width: double.infinity,
          height: 44,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: isPast
                  ? cs.onSurface.withValues(alpha: 0.12)
                  : accent,
              foregroundColor: isPast
                  ? cs.onSurface.withValues(alpha: 0.38)
                  : cs.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: isPast
                ? null
                : () {
                    SleepTimerService().setTimeSleep(
                      Duration(milliseconds: (realSecondsUntil * 1000).round()),
                    );
                    Navigator.pop(context);
                  },
            child: Text(
              isPast
                  ? l.sleepTimerSheetSpecificStartButtonPassed
                  : l.sleepTimerSheetSpecificStartButton,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }

  void _openChapterPicker(List chapters, Color accent) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context)!;
    final player = AudioPlayerService();
    showDialog(
      context: context,
      builder: (dctx) => Dialog(
        backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 500),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l.sleepTimerSheetTabSpecificChapter,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    // Jump straight to the "grabbed" size while the user is
                    // actively dragging (a fade-in is easy to miss while the
                    // list is scrolling); only animate back on release.
                    if (n is ScrollStartNotification && n.dragDetails != null) {
                      _chapterBarAnim.value = 1;
                    } else if (n is ScrollUpdateNotification &&
                        n.dragDetails != null) {
                      _chapterBarAnim.value = 1;
                    } else if (n is ScrollEndNotification) {
                      _chapterBarAnim.reverse();
                    }
                    return false;
                  },
                  child: AnimatedBuilder(
                    animation: _chapterBarAnim,
                    builder: (bctx, listChild) {
                      final t = Curves.easeOut.transform(_chapterBarAnim.value);
                      final bcs = Theme.of(bctx).colorScheme;
                      return RawScrollbar(
                        controller: _chapterScroll,
                        thumbVisibility: true,
                        interactive: true,
                        // Keep the thumb clear of the dialog's rounded corners.
                        mainAxisMargin: 4,
                        // Default minThumbLength is only 18px, which looks like a
                        // tiny stub when the chapter list is long. Give it a
                        // comfortable minimum size.
                        minThumbLength: 36,
                        thickness: 5.0 + 4.0 * t,
                        radius: const Radius.circular(8),
                        thumbColor: bcs.onSurface.withValues(
                          alpha: 0.28 + 0.22 * t,
                        ),
                        child: listChild!,
                      );
                    },
                    child: ListView.builder(
                      controller: _chapterScroll,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      itemCount: chapters.length,
                      itemBuilder: (ctx, i) {
                        final ch = chapters[i] as Map<String, dynamic>;
                        final title =
                            ch['title'] as String? ??
                            l.sleepTimerSheetSpecificChapterFallback(i + 1);
                        final endSec = (ch['end'] as num?)?.toDouble() ?? 0;
                        final curPos = player.position.inMilliseconds / 1000.0;
                        final secs = (endSec - curPos) / player.speed;
                        final timeLabel = secs > 0
                            ? _formatWallClock(
                                DateTime.now().add(
                                  Duration(milliseconds: (secs * 1000).round()),
                                ),
                              )
                            : l.sleepTimerSheetSpecificPassedShort;
                        final selected = i == _selectedChapterIndex;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Material(
                            color: selected
                                ? accent.withValues(alpha: 0.15)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                setState(() => _selectedChapterIndex = i);
                                Navigator.pop(dctx);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: selected
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      timeLabel,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: secs > 0
                                            ? cs.onSurfaceVariant
                                            : cs.error,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              // Bottom breathing room so the scrollbar and last chapter row
              // do not sit flush against the dialog's bottom rounded edge.
              SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
  }

  String _timePeriodLabel(AppLocalizations l, int hour) {
    if (hour < 5) return l.timePeriodDawn;
    if (hour < 9) return l.timePeriodMorningEarly;
    if (hour < 11) return l.timePeriodMorning;
    if (hour < 13) return l.timePeriodNoon;
    if (hour < 18) return l.timePeriodAfternoon;
    if (hour < 20) return l.timePeriodDusk;
    if (hour < 23) return l.timePeriodNight;
    return l.timePeriodLateNight;
  }

  String _formatWallClock(DateTime dt) {
    final l = AppLocalizations.of(context)!;
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${_timePeriodLabel(l, dt.hour)}';
  }

  String _formatCountdown(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return '${d.inSeconds}s';
  }

  Widget _tab(String label, IconData icon, int index, Color accent) {
    final cs = Theme.of(context).colorScheme;
    final selected = _tabIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _tabIndex = index);
          PlayerSettings.setSleepTimerTab(index);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? accent : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? accent : cs.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimerTab(Color accent, TextTheme tt, AppLocalizations l) {
    final cs = Theme.of(context).colorScheme;
    final valid = _hours * 60 + _minutes > 0;
    return Column(
      children: [
        Text(
          _durationLabel(l),
          style: TextStyle(
            color: accent,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 16),
        // Presets
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final mins in [15, 30, 60, 90])
              _presetChip(
                accent,
                l.sleepTimerSheetMinShort(mins),
                !_customOpen && _hours * 60 + _minutes == mins,
                () {
                  setState(() {
                    _hours = mins ~/ 60;
                    _minutes = mins % 60;
                    _customOpen = false;
                  });
                  _syncWheelsToValue();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        // Custom button — visually distinct, full-width below the presets
        _buildCustomButton(accent, cs, l),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _customOpen
              ? Column(
                  children: [
                    const SizedBox(height: 12),
                    _buildWheelCard(accent, cs, l),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 16),
        // Start button
        SizedBox(
          width: double.infinity,
          height: 44,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: cs.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: valid
                ? () {
                    final total = _hours * 60 + _minutes;
                    PlayerSettings.setSleepTimerMinutes(total);
                    SleepTimerService().setTimeSleep(Duration(minutes: total));
                    Navigator.pop(context);
                  }
                : null,
            child: Text(
              l.sleepTimerStartDuration(_durationLabel(l)),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCustomButton(Color accent, ColorScheme cs, AppLocalizations l) {
    return GestureDetector(
      onTap: () {
        setState(() => _customOpen = !_customOpen);
        _syncWheelsToValue();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _customOpen
              ? accent.withValues(alpha: 0.2)
              : cs.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _customOpen
                ? accent.withValues(alpha: 0.4)
                : cs.onSurface.withValues(alpha: 0.1),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.tune_rounded,
              size: 18,
              color: _customOpen ? accent : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              l.sleepTimerCustom,
              style: TextStyle(
                color: _customOpen ? accent : cs.onSurfaceVariant,
                fontSize: 13,
                fontWeight: _customOpen ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(width: 2),
            AnimatedRotation(
              turns: _customOpen ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.expand_more_rounded,
                size: 18,
                color: _customOpen ? accent : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWheelCard(Color accent, ColorScheme cs, AppLocalizations l) {
    const itemExtent = 32.0;
    final wheelHeight = itemExtent * 5;
    final cardBg = cs.onSurface.withValues(alpha: 0.06);
    final maskColor =
        Theme.of(context).bottomSheetTheme.backgroundColor ?? cs.surface;
    final cardColor = Color.alphaBlend(cardBg, maskColor);

    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
      ),
      child: SizedBox(
        height: wheelHeight,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // Wheels + fixed units
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _infiniteWheel(
                  itemCount: 24,
                  virtualCount: _virtualHourCount,
                  controller: _hourController,
                  onChanged: _onHourWheelChanged,
                  cs: cs,
                  itemExtent: itemExtent,
                ),
                Text(
                  l.sleepTimerWheelHourUnit,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 16),
                _infiniteWheel(
                  itemCount: 60,
                  virtualCount: _virtualMinuteCount,
                  controller: _minuteController,
                  onChanged: _onMinuteWheelChanged,
                  cs: cs,
                  itemExtent: itemExtent,
                ),
                Text(
                  l.sleepTimerWheelMinuteUnit,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            // Selection highlight band
            IgnorePointer(
              child: Align(
                alignment: Alignment.center,
                child: Container(
                  height: itemExtent,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),
            // Top edge fade-out
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: itemExtent * 2,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [cardColor, cardColor.withValues(alpha: 0.0)],
                    ),
                  ),
                ),
              ),
            ),
            // Bottom edge fade-out
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: itemExtent * 2,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [cardColor, cardColor.withValues(alpha: 0.0)],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(opacity: value, child: card),
    );
  }

  Widget _infiniteWheel({
    required int itemCount,
    required int virtualCount,
    required FixedExtentScrollController controller,
    required void Function(int) onChanged,
    required ColorScheme cs,
    required double itemExtent,
  }) {
    return SizedBox(
      height: itemExtent * 5,
      width: 56,
      child: ListWheelScrollView(
        controller: controller,
        itemExtent: itemExtent,
        physics: const FixedExtentScrollPhysics(),
        diameterRatio: 100,
        overAndUnderCenterOpacity: 0.25,
        onSelectedItemChanged: onChanged,
        children: [
          for (var i = 0; i < virtualCount; i++)
            Center(
              child: Text(
                '${i % itemCount}',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  int _hourVirtualIndex(int h) {
    final mid = _virtualHourCount ~/ 2;
    return (mid - (mid % 24)) + h;
  }

  int _minuteVirtualIndex(int m) {
    final mid = _virtualMinuteCount ~/ 2;
    return (mid - (mid % 60)) + m;
  }

  void _syncWheelsToValue() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _programmaticWheel = true;
      _hourController.jumpToItem(_hourVirtualIndex(_hours));
      _minuteController.jumpToItem(_minuteVirtualIndex(_minutes));
      _programmaticWheel = false;
    });
  }

  void _onHourWheelChanged(int virtualIndex) {
    if (_programmaticWheel) return;
    _recenterWheel(virtualIndex, _hourController, _virtualHourCount, 24);
    setState(() => _hours = virtualIndex % 24);
  }

  void _onMinuteWheelChanged(int virtualIndex) {
    if (_programmaticWheel) return;
    _recenterWheel(virtualIndex, _minuteController, _virtualMinuteCount, 60);
    setState(() => _minutes = virtualIndex % 60);
  }

  void _recenterWheel(
    int index,
    FixedExtentScrollController ctrl,
    int total,
    int cycle,
  ) {
    final mid = total ~/ 2;
    if (index < cycle * 2) {
      _programmaticWheel = true;
      ctrl.jumpToItem(index + mid);
      _programmaticWheel = false;
    } else if (index >= total - cycle * 2) {
      _programmaticWheel = true;
      ctrl.jumpToItem(index - mid);
      _programmaticWheel = false;
    }
  }

  String _durationLabel(AppLocalizations l) {
    if (_hours == 0) return l.sleepTimerSheetMinShort(_minutes);
    if (_minutes == 0) return l.sleepTimerHoursOnly(_hours);
    return l.sleepTimerHoursMinutes(_hours, _minutes);
  }

  Widget _buildChapterTab(Color accent, TextTheme tt, AppLocalizations l) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        // Stepper: 减 + 大数字 + 加
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _circleButton(
              Icons.remove_rounded,
              accent,
              _customChapters > 1
                  ? () => setState(() => _customChapters--)
                  : null,
            ),
            const SizedBox(width: 28),
            Text(
              l.sleepTimerSheetChaptersValue(_customChapters),
              style: TextStyle(
                color: accent,
                fontSize: 28,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 28),
            _circleButton(
              Icons.add_rounded,
              accent,
              _customChapters < 20
                  ? () => setState(() => _customChapters++)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Quick presets
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final ch in [1, 2, 3, 5])
              _presetChip(
                accent,
                l.sleepTimerSheetChaptersChip(ch),
                _customChapters == ch,
                () {
                  setState(() => _customChapters = ch);
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: accent,
            inactiveTrackColor: cs.onSurface.withValues(alpha: 0.1),
            thumbColor: accent,
            overlayColor: accent.withValues(alpha: 0.1),
            trackHeight: 3,
          ),
          child: Slider(
            value: _customChapters.toDouble(),
            min: 1,
            max: 20,
            divisions: 19,
            label: l.sleepTimerSheetChaptersValue(_customChapters),
            onChanged: (v) => setState(() => _customChapters = v.round()),
          ),
        ),
        const SizedBox(height: 8),
        // Start button
        SizedBox(
          width: double.infinity,
          height: 44,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: cs.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              PlayerSettings.setSleepTimerChapters(_customChapters);
              SleepTimerService().setChapterSleep(_customChapters);
              Navigator.pop(context);
            },
            child: Text(
              l.sleepTimerSheetStartChapterSleep(_customChapters),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEpisodeTab(Color accent, TextTheme tt, AppLocalizations l) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Icon(
          Icons.podcasts_outlined,
          size: 40,
          color: accent.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 16),
        // Stops at the end of the current episode (no counter — episodes only roll
        // forward when a queue mode is feeding the next one).
        SizedBox(
          width: double.infinity,
          height: 44,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: cs.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              SleepTimerService().setEpisodeSleep();
              Navigator.pop(context);
            },
            child: Text(
              l.sleepTimerSheetEpisodeSleepStart,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }

  /// Format seconds as a human-readable label (e.g. "30s", "5m", "1m 30s").
  String _rewindLabel(int seconds, AppLocalizations l) {
    if (seconds == 0) return l.off;
    if (seconds < 60) return l.sleepTimerSheetSecondsShort(seconds);
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s > 0
        ? l.sleepTimerSheetMinSecShort(m, s)
        : l.sleepTimerSheetMinShort(m);
  }

  Widget _buildRewindSection(Color accent, TextTheme tt, AppLocalizations l) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = _sleepRewindSeconds > 0;
    final rewindMinutes = (_sleepRewindSeconds / 60).clamp(
      0.0,
      _maxRewindMinutes.toDouble(),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.replay_rounded,
              size: 18,
              color: isEnabled ? accent : cs.onSurface.withValues(alpha: 0.24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l.sleepTimerSheetRewindOnSleep,
                style: TextStyle(
                  color: isEnabled
                      ? cs.onSurface.withValues(alpha: 0.7)
                      : cs.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              isEnabled ? _rewindLabel(_sleepRewindSeconds, l) : l.off,
              style: TextStyle(
                color: isEnabled ? accent : cs.onSurface.withValues(alpha: 0.3),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: accent,
            inactiveTrackColor: cs.onSurface.withValues(alpha: 0.1),
            thumbColor: accent,
            overlayColor: accent.withValues(alpha: 0.1),
            trackHeight: 4,
          ),
          child: Slider(
            value: rewindMinutes,
            min: 0,
            max: _maxRewindMinutes.toDouble(),
            divisions: _maxRewindMinutes,
            onChanged: (v) {
              final seconds = (v * 60).round();
              setState(() => _sleepRewindSeconds = seconds);
              // Modal edits the current book only; settings sets the default.
              final itemId = AudioPlayerService().currentItemId;
              if (itemId != null) {
                PlayerSettings.setBookSleepRewindSeconds(itemId, seconds);
              } else {
                PlayerSettings.setSleepRewindSeconds(seconds);
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l.off,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.3),
                  fontSize: 11,
                ),
              ),
              Text(
                l.sleepTimerSheetMinShort(120),
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.3),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        if (isEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 2, 12, 0),
            child: Text(
              l.sleepRewindUndoNote(
                SleepTimerService.sleepRewindUndoWindow.inMinutes,
              ),
              style: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.45),
                fontSize: 11,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildShakeToggle(Color accent, TextTheme tt, AppLocalizations l) {
    final cs = Theme.of(context).colorScheme;
    final isEnabled = _shakeMode != 'off';
    String subtitle;
    if (_shakeMode == 'addTime') {
      subtitle = _tabIndex == 0
          ? l.sleepTimerSheetAddsMinutes(_shakeAddMinutes)
          : l.sleepTimerSheetAddsOneChapter;
    } else if (_shakeMode == 'resetTimer') {
      subtitle = l.sleepTimerSheetResetsToFull;
    } else {
      subtitle = l.disabled;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.vibration_rounded,
              size: 18,
              color: isEnabled ? accent : cs.onSurface.withValues(alpha: 0.24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.sleepTimerSheetShake,
                    style: TextStyle(
                      color: isEnabled
                          ? cs.onSurface.withValues(alpha: 0.7)
                          : cs.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.3),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: 'off',
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(l.off, maxLines: 1),
                ),
              ),
              ButtonSegment(
                value: 'addTime',
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(l.shakeAddTime, maxLines: 1),
                ),
              ),
              ButtonSegment(
                value: 'resetTimer',
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(l.shakeReset, maxLines: 1),
                ),
              ),
            ],
            selected: {_shakeMode},
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
            ),
            onSelectionChanged: (v) {
              setState(() => _shakeMode = v.first);
              PlayerSettings.setShakeMode(v.first);
            },
          ),
        ),
        AnimatedOpacity(
          opacity: _shakeMode == 'addTime' ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: _shakeMode != 'addTime',
            child: Column(
              children: [
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l.shakeAdds,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      l.minutesValue(_shakeAddMinutes),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: accent,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: accent,
                    inactiveTrackColor: cs.onSurface.withValues(alpha: 0.1),
                    thumbColor: accent,
                    overlayColor: accent.withValues(alpha: 0.1),
                    trackHeight: 4,
                  ),
                  child: Slider(
                    value: _shakeAddMinutes.toDouble(),
                    min: 1,
                    max: 30,
                    divisions: 29,
                    onChanged: (v) {
                      setState(() => _shakeAddMinutes = v.round());
                      PlayerSettings.setShakeAddMinutes(v.round());
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _circleButton(IconData icon, Color accent, VoidCallback? onTap) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: enabled
              ? accent.withValues(alpha: 0.12)
              : cs.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: enabled
                ? accent.withValues(alpha: 0.35)
                : cs.onSurface.withValues(alpha: 0.08),
          ),
        ),
        child: Icon(
          icon,
          color: enabled ? accent : cs.onSurface.withValues(alpha: 0.24),
          size: 22,
        ),
      ),
    );
  }

  Widget _presetChip(
    Color accent,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? accent.withValues(alpha: 0.2)
              : cs.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? accent.withValues(alpha: 0.4)
                : cs.onSurface.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? accent : cs.onSurfaceVariant,
            fontSize: 13,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
