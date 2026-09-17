import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'absorbing_shared.dart';

/// Outcome of the batch chapter download panel.
class ChapterDownloadSheetResult {
  /// Chapters the user picked that are not already downloaded.
  final List<int> selectedIndices;

  const ChapterDownloadSheetResult({required this.selectedIndices});
}

/// Batch chapter download panel opened from the More menu.
///
/// Chapters are shown one page at a time ([pageSize] = 100 rows). Each row can
/// be selected individually; the top-right "选集" button jumps between pages and
/// the "全选" button toggles the whole current page (a small dot shows whether
/// the current page is fully selected). Chapters in [downloadedChapters] are
/// greyed out with a downloaded marker and cannot be re-picked. Returns a
/// [ChapterDownloadSheetResult], or null when dismissed.
Future<ChapterDownloadSheetResult?> showChapterDownloadSheet(
  BuildContext context, {
  required Color accent,
  required String title,
  required List<dynamic> chapters,
  double displaySpeed = 1.0,
  Set<int> downloadedChapters = const <int>{},
}) {
  if (chapters.isEmpty) return Future.value(null);
  return showModalBottomSheet<ChapterDownloadSheetResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ChapterDownloadSheet(
      accent: accent,
      title: title,
      chapters: chapters,
      displaySpeed: displaySpeed,
      downloadedChapters: downloadedChapters,
    ),
  );
}

class _ChapterDownloadSheet extends StatefulWidget {
  final Color accent;
  final String title;
  final List<dynamic> chapters;
  final double displaySpeed;
  final Set<int> downloadedChapters;

  const _ChapterDownloadSheet({
    required this.accent,
    required this.title,
    required this.chapters,
    this.displaySpeed = 1.0,
    this.downloadedChapters = const <int>{},
  });

  @override
  State<_ChapterDownloadSheet> createState() => _ChapterDownloadSheetState();
}

class _ChapterDownloadSheetState extends State<_ChapterDownloadSheet> {
  static const int _pageSize = 100;
  final Set<int> _selected = {};
  int _page = 0;

  int get _count => widget.chapters.length;
  int get _selectedCount => _selected.length;

  bool _isDownloaded(int index) => widget.downloadedChapters.contains(index);

  int get _pageStart => _page * _pageSize;
  int get _pageEnd =>
      (_pageStart + _pageSize) < _count ? (_pageStart + _pageSize) : _count;

  bool get _pageAllSelected {
    if (_pageStart >= _pageEnd) return false;
    var selectable = 0;
    for (int i = _pageStart; i < _pageEnd; i++) {
      if (_isDownloaded(i)) continue;
      selectable++;
      if (!_selected.contains(i)) return false;
    }
    // A fully downloaded page has nothing to select, so it must not read as
    // "all selected".
    return selectable > 0;
  }

  void _toggleChapter(int index) {
    if (_isDownloaded(index)) return;
    setState(() {
      if (!_selected.remove(index)) _selected.add(index);
    });
  }

  void _togglePage() {
    final selectable = <int>[
      for (int i = _pageStart; i < _pageEnd; i++)
        if (!_isDownloaded(i)) i,
    ];
    if (selectable.isEmpty) return;
    setState(() {
      final add =
          !selectable.every(_selected.contains);
      if (add) {
        _selected.addAll(selectable);
      } else {
        _selected.removeWhere(selectable.contains);
      }
    });
  }

  void _openRangePicker() {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final pages = (_count + _pageSize - 1) ~/ _pageSize;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Stack(children: [
              Center(child: Text(l.chapterIndex,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
              Positioned(
                left: 0, top: 0, bottom: 0,
                child: Center(child: Text(l.chaptersCount(_count),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant))),
              ),
            ]),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (int p = 0; p < pages; p++)
                    ChoiceChip(
                      label: Text('${p * _pageSize + 1}-${((p + 1) * _pageSize).clamp(0, _count)}'),
                      selected: p == _page,
                      selectedColor: widget.accent.withValues(alpha: 0.18),
                      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: p == _page ? FontWeight.w700 : FontWeight.w500,
                        color: p == _page ? widget.accent : cs.onSurfaceVariant,
                      ),
                      onSelected: (_) {
                        setState(() => _page = p);
                        Navigator.pop(ctx);
                      },
                    ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final sheetColor = Theme.of(context).bottomSheetTheme.backgroundColor ?? cs.surface;
    final height = MediaQuery.of(context).size.height * 0.75;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: sheetColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: widget.accent.withValues(alpha: 0.2), width: 1)),
      ),
      child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(vertical: 12),
          child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.24), borderRadius: BorderRadius.circular(2)))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.selectChaptersToDownload,
                style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(widget.title,
                style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                overflow: TextOverflow.ellipsis),
            ])),
            TextButton(
              onPressed: _openRangePicker,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  l.selectRange(_pageStart + 1, _pageEnd),
                  style: TextStyle(fontWeight: FontWeight.w600, color: widget.accent, fontSize: 13),
                ),
                const SizedBox(width: 2),
                Icon(Icons.arrow_drop_down_rounded, size: 18, color: widget.accent),
              ]),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: _togglePage,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(l.selectAll,
                  style: TextStyle(fontWeight: FontWeight.w600, color: widget.accent, fontSize: 13)),
                const SizedBox(width: 6),
                Container(
                  width: 14, height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _pageAllSelected ? widget.accent : Colors.transparent,
                    border: Border.all(
                      color: _pageAllSelected
                          ? widget.accent
                          : cs.onSurfaceVariant.withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            cacheExtent: 1200,
            itemCount: _pageEnd - _pageStart,
            itemBuilder: (_, i) {
              final index = _pageStart + i;
              final ch = widget.chapters[index] as Map<String, dynamic>;
              final chTitle = ch['title'] as String? ?? l.chapterNumber(index + 1);
              final start = (ch['start'] as num?)?.toDouble() ?? 0;
              final end = (ch['end'] as num?)?.toDouble() ?? 0;
              final isSel = _selected.contains(index);
              final done = _isDownloaded(index);
              return ListTile(
                dense: true,
                enabled: !done,
                onTap: () => _toggleChapter(index),
                leading: Icon(
                  done
                      ? Icons.download_done_rounded
                      : isSel
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                  size: 22,
                  color: done
                      ? cs.onSurfaceVariant.withValues(alpha: 0.4)
                      : isSel
                          ? widget.accent
                          : cs.onSurfaceVariant.withValues(alpha: 0.4),
                ),
                title: Text(chTitle,
                  style: tt.bodyMedium?.copyWith(
                    fontWeight: isSel ? FontWeight.w600 : FontWeight.w400,
                    color: done ? cs.onSurfaceVariant : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (done)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(l.downloaded,
                        style: tt.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
                      ),
                    ),
                  Text(fmtDur((end - start) / widget.displaySpeed),
                    style: tt.labelSmall?.copyWith(
                        color: done
                            ? cs.onSurfaceVariant.withValues(alpha: 0.5)
                            : cs.onSurfaceVariant)),
                ]),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        SafeArea(top: false, child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _selectedCount == 0
                    ? null
                    : () {
                        final indices = _selected.toList()..sort();
                        Navigator.pop(
                            context,
                            ChapterDownloadSheetResult(
                                selectedIndices: indices));
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: widget.accent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(_selectedCount == 0 ? l.download : l.startDownloadSelected(_selectedCount),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        )),
      ]),
    );
  }
}