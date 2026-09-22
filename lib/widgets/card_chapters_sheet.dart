import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../screens/app_shell.dart';
import '../services/audio_player_service.dart';
import '../services/chromecast_service.dart';
import '../utils/series_id.dart';
import 'absorbing_shared.dart';

void showChaptersSheet({
  required BuildContext context,
  required Color accent,
  required TextTheme tt,
  required List<dynamic> chapters,
  required double totalDuration,
  required double currentPosition,
  required bool isPlaybackActive,
  required bool isCastingThis,
  required double displaySpeed,
  required AudioPlayerService player,
  String? itemId,
}) {
  if (chapters.isEmpty) return;

  int currentIdx = -1;
  for (int i = 0; i < chapters.length; i++) {
    final ch = chapters[i] as Map<String, dynamic>;
    final start = (ch['start'] as num?)?.toDouble() ?? 0;
    final end = (ch['end'] as num?)?.toDouble() ?? 0;
    if (currentPosition >= start && currentPosition < end) { currentIdx = i; break; }
  }

  showModalBottomSheet(
    context: context, isScrollControlled: true, useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false, initialChildSize: 0.6, minChildSize: 0.05, snap: true, maxChildSize: 0.9,
      builder: (_, sc) => _ChaptersSheetBody(
        sc: sc,
        accent: accent,
        tt: tt,
        chapters: chapters,
        totalDuration: totalDuration,
        isPlaybackActive: isPlaybackActive,
        isCastingThis: isCastingThis,
        displaySpeed: displaySpeed,
        player: player,
        itemId: itemId,
        initialIndex: currentIdx,
      ),
    ),
  );
}

class _ChaptersSheetBody extends StatefulWidget {
  final ScrollController sc;
  final Color accent;
  final TextTheme tt;
  final List<dynamic> chapters;
  final double totalDuration;
  final bool isPlaybackActive;
  final bool isCastingThis;
  final double displaySpeed;
  final AudioPlayerService player;
  final String? itemId;
  final int initialIndex;

  const _ChaptersSheetBody({
    required this.sc,
    required this.accent,
    required this.tt,
    required this.chapters,
    required this.totalDuration,
    required this.isPlaybackActive,
    required this.isCastingThis,
    required this.displaySpeed,
    required this.player,
    this.itemId,
    required this.initialIndex,
  });

  @override
  State<_ChaptersSheetBody> createState() => _ChaptersSheetBodyState();
}

class _ChaptersSheetBodyState extends State<_ChaptersSheetBody> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _searchOpen = false;
  String _query = '';

  /// Stable per-chapter keys so a chapter's row can be located by its number
  /// (and scrolled to the top with [Scrollable.ensureVisible]) without relying
  /// on any assumed row height.
  final Map<int, GlobalKey> _rowKeys = {};
  final GlobalKey _listKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _recomputeVisibleIndices();
    // Open the list at the currently-playing chapter so the selection badge
    // and the visible rows agree on what's "now". A single first-frame jumpTo
    // (uniform rows -> exact pixel math) lands straight on the right chapter;
    // waiting for the entrance to finish only showed chapter 1 then flashed
    // over to the current one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialIndex > 0) {
        _anchorAtTop(widget.initialIndex);
      }
    });
  }

  int get _groupSize => 50;

  /// Original indices into [widget.chapters] matching the current query (all of
  /// them when empty). Keeping the original index means a row's number and its
  /// "finished" tick stay tied to the real chapter, not the filtered position.
  /// Recomputed only when the query changes — rebuilding the whole list on
  /// every build (including every frame of the sheet's entrance animation)
  /// was pure allocation churn for thousand-chapter books.
  List<int> _visibleIndices = const [];

  void _recomputeVisibleIndices() {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      _visibleIndices = [for (int i = 0; i < widget.chapters.length; i++) i];
      return;
    }
    _visibleIndices = [
      for (int i = 0; i < widget.chapters.length; i++)
        if (((widget.chapters[i] as Map<String, dynamic>)['title'] as String? ??
                '')
            .toLowerCase()
            .contains(q))
          i,
    ];
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _setQuery(String v) => setState(() {
          _query = v;
          _recomputeVisibleIndices();
        });

  void _closeSearch() {
    setState(() {
      _query = '';
      _searchCtrl.clear();
      _searchOpen = false;
      _recomputeVisibleIndices();
    });
  }

  void _jumpTo(int index) {
    if (_searchOpen) _closeSearch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorAtTop(index);
    });
  }

  /// True uniform height of a chapter row. Rows are single-line [ListTile]s
  /// drawn at 56 via the list's [ListView.itemExtent], so the pixel-math scroll
  /// below is exact without measuring (a first-frame measure+setState just
  /// added a second layout to the entrance frame it was trying to smooth).
  final double _rowHeight = 56;

  /// Visible (filtered-list) position of an original chapter index. With an
  /// empty query the filtered list is the identity, so this is just [index].
  int _visiblePositionOf(int index) {
    final q = _query.trim();
    if (q.isEmpty) return index;
    return _visibleIndices.indexOf(index);
  }

  void _anchorAtTop(int index) {
    if (!mounted) return;
    if (index < 0) return;
    if (_anchorNow(index)) return;
    if (!widget.sc.hasClients) return;
    final pos = widget.sc.position;
    final vpos = _visiblePositionOf(index);
    // Rows are uniform ([itemExtent] == [_rowHeight], measured in the same
    // frame), so pixel math places the row exactly — the extra post-frame
    // [Scrollable.ensureVisible] snap was a redundant second layout.
    pos.jumpTo((vpos * _rowHeight).clamp(0.0, pos.maxScrollExtent).toDouble());
  }

  bool _anchorNow(int index) {
    final ctx = _rowKeys[index]?.currentContext;
    if (ctx == null) return false;
    Scrollable.ensureVisible(ctx, alignment: 0.0, duration: Duration.zero);
    return true;
  }

  /// Original index of the chapter currently occupying the top edge of the
  /// list. With uniform rows and an exact [itemExtent] this is simple pixel
  /// math; filtering maps the visible slot back to the real chapter.
  int _topVisibleOriginalIndex() {
    if (!widget.sc.hasClients) {
      return widget.initialIndex >= 0 ? widget.initialIndex : 0;
    }
    final pos = widget.sc.position;
    final vis = _visibleIndices;
    if (vis.isEmpty) return 0;
    final vpos = (pos.pixels / _rowHeight).floor();
    return vis[vpos.clamp(0, vis.length - 1)];
  }

  void _openIndexSheet() {
    final n = widget.chapters.length;
    // Which group is actually on screen right now: derive it from the real
    // row positions so the highlighted range follows the list instead of
    // being stuck on the chapter the sheet originally opened at.
    final topIdx = _topVisibleOriginalIndex().clamp(0, n - 1);
    final curPage = topIdx ~/ _groupSize;
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final groups = (n + _groupSize - 1) ~/ _groupSize;
    // Uniform label area: every range button gets a label box of the widest
    // natural *label* width (e.g. "1001-1050"), so the text spans the same
    // block in every button instead of 1-50 looking narrower than its peers.
    final labelPaint = TextPainter(
      text: TextSpan(text: '', style: widget.tt.labelMedium),
      textDirection: Directionality.of(context),
    );
    var widestLabel = 0.0;
    for (var g = 0; g < groups; g++) {
      final t =
          '${g * _groupSize + 1}-${((g + 1) * _groupSize).clamp(0, n)}';
      labelPaint.text = TextSpan(text: t, style: widget.tt.labelMedium);
      labelPaint.layout();
      if (labelPaint.width > widestLabel) widestLabel = labelPaint.width;
    }
    labelPaint.dispose();
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                children: [
                  Center(
                    child: Text(
                      l.chapterIndex,
                      style: widget.tt.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Text(
                        l.chaptersCount(n),
                        style: widget.tt.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: GridView.builder(
                  padding: EdgeInsets.zero,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    mainAxisExtent: 44,
                  ),
                  itemCount: groups,
                  itemBuilder: (_, g) => ChoiceChip(
                    label: SizedBox(
                      width: widestLabel,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: Text(
                          '${g * _groupSize + 1}-${((g + 1) * _groupSize).clamp(0, n)}',
                          maxLines: 1,
                        ),
                      ),
                    ),
                    selected: g == curPage,
                    selectedColor: widget.accent.withValues(alpha: 0.18),
                    labelStyle: widget.tt.labelMedium?.copyWith(
                      fontWeight: g == curPage
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: g == curPage
                          ? widget.accent
                          : cs.onSurfaceVariant,
                    ),
                    showCheckmark: false,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    labelPadding: const EdgeInsets.symmetric(
                      horizontal: 0,
                      vertical: 6,
                    ),
                    onSelected: (_) {
                      _jumpTo(g * _groupSize);
                      Navigator.pop(ctx);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chapterTile(int idx, AppLocalizations l, ColorScheme cs) {
    final ch = widget.chapters[idx] as Map<String, dynamic>;
    final chTitle = ch['title'] as String? ?? l.chapterNumber(idx + 1);
    final start = (ch['start'] as num?)?.toDouble() ?? 0;
    final end = (ch['end'] as num?)?.toDouble() ?? 0;
    final cast = ChromecastService();
    final pos = widget.isCastingThis
        ? cast.castPosition.inMilliseconds / 1000.0
        : (widget.player.currentItemId != null
              ? widget.player.position.inMilliseconds / 1000.0
              : 0.0);
    final isCurrent = widget.isPlaybackActive && pos >= start && pos < end;
    final isFinished = widget.isPlaybackActive && pos >= end;
    final pct = widget.totalDuration > 0
        ? (end / widget.totalDuration * 100).round()
        : 0;
    return ListTile(
      key: _rowKeys.putIfAbsent(idx, () => GlobalKey()),
      dense: true,
      selected: isCurrent,
      selectedTileColor: widget.accent.withValues(alpha: 0.1),
      leading: SizedBox(
        width: 32,
        child: isFinished
            ? Center(
                child: Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                ),
              )
            : Center(
                child: Text(
                  '${idx + 1}',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: widget.tt.labelMedium?.copyWith(
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
                    color: isCurrent ? widget.accent : cs.onSurfaceVariant,
                  ),
                ),
              ),
      ),
      title: Text(
        chTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.tt.bodyMedium?.copyWith(
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
          color: isCurrent
              ? cs.onSurface
              : isFinished
              ? cs.onSurface.withValues(alpha: 0.4)
              : cs.onSurface.withValues(alpha: 0.7),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$pct%',
            style: widget.tt.labelSmall?.copyWith(
              color: isCurrent
                  ? widget.accent.withValues(alpha: 0.7)
                  : cs.onSurface.withValues(alpha: 0.24),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            fmtDur((end - start) / widget.displaySpeed),
            style: widget.tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
      onTap: () async {
        // "章节跳转确认" gate: OFF (default) asks before EVERY chapter jump;
        // ON only asks when the book isn't already loaded in the player — an
        // active book jumps straight, skipping the dialog.
        final alwaysConfirm =
            !await PlayerSettings.getConfirmEveryChapterJump();
        if (widget.isPlaybackActive && !alwaysConfirm) {
          final seekDur = Duration(seconds: start.round());
          if (widget.isCastingThis) {
            cast.seekTo(seekDur);
          } else {
            widget.player.seekTo(seekDur, chapterJump: true);
          }
          Navigator.pop(context);
          return;
        }
        final canAct = widget.isPlaybackActive || widget.itemId != null;
        if (!canAct) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dlg) => AlertDialog(
            title: Text(l.cardChaptersPlayFromChapterTitle),
            content: Text(l.cardChaptersPlayFromChapterContent(chTitle)),
            actions: [
                      TextButton(onPressed: () => Navigator.pop(dlg, false), child: Text(l.cancel)),
                      FilledButton(onPressed: () => Navigator.pop(dlg, true), child: Text(l.cardChaptersPlay)),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
        Navigator.pop(context); // Close chapter sheet first
        if (widget.isPlaybackActive) {
          final seekDur = Duration(seconds: start.round());
          if (widget.isCastingThis) {
            cast.seekTo(seekDur);
          } else {
            widget.player.seekTo(seekDur, chapterJump: true);
          }
          return;
        }
        final api = context.read<AuthProvider>().apiService;
        if (api == null) return;
        final lib = context.read<LibraryProvider>();
        // Prefer the disk-cached item — the sheet is already showing this
        // book's chapter/timing data on screen, so a weak link should never
        // gate a chapter jump behind a full network fetch. Fall back to the
        // network only when the item was never cached.
        final cachedItem = await api.getCachedLibraryItem(widget.itemId!);
        final fullItem = cachedItem ?? await api.getLibraryItem(widget.itemId!);
        if (fullItem == null) return;
        final media = fullItem['media'] as Map<String, dynamic>? ?? {};
        final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
        final title = metadata['title'] as String? ?? '';
        final author = metadata['authorName'] as String? ?? '';
        final coverUrl = lib.getCoverUrl(widget.itemId!);
        final dur = (media['duration'] is num)
            ? (media['duration'] as num).toDouble()
            : widget.totalDuration;
        final mediaChapters = (media['chapters'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            [];
        final chs = mediaChapters.isNotEmpty ? mediaChapters : widget.chapters;
        await widget.player.playItem(
          api: api,
          itemId: widget.itemId!,
          title: title,
          author: author,
          coverUrl: coverUrl,
          totalDuration: dur,
          chapters: chs,
          startTime: start,
          forceStartTime: true,
          libraryId: fullItem['libraryId'] as String?,
          seriesId: seriesIdFromItem(fullItem),
        );
        AppShell.goToAbsorbingGlobal();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final visible = _visibleIndices;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).bottomSheetTheme.backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(
            color: widget.accent.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l.chaptersCount(widget.chapters.length),
                    style: widget.tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _IconLabelButton(
                  icon: Icons.search_rounded,
                  label: l.search,
                  accent: widget.accent,
                  active: _searchOpen,
                  onTap: () => setState(() => _searchOpen = !_searchOpen),
                ),
                const SizedBox(width: 4),
                _IconLabelButton(
                  icon: Icons.format_list_numbered_rounded,
                  label: l.chapterIndex,
                  accent: widget.accent,
                  onTap: _openIndexSheet,
                ),
              ],
            ),
          ),
          if (_searchOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                onChanged: _setQuery,
                style: widget.tt.bodyMedium,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l.search,
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: _closeSearch,
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: widget.accent.withValues(alpha: 0.35),
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          if (_searchOpen) const SizedBox(height: 8),
          const SizedBox(height: 8),
          if (visible.isEmpty && _query.trim().isNotEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l.noResultsFound,
                    style: widget.tt.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                key: _listKey,
                controller: widget.sc,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemExtent: _rowHeight,
                cacheExtent: 250,
                itemCount: visible.length,
                itemBuilder: (_, i) => _chapterTile(visible[i], l, cs),
              ),
            ),
        ],
      ),
    );
  }
}

class _IconLabelButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;
  final bool active;

  const _IconLabelButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: active ? accent : cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? accent : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
