import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/overlay_toast.dart';
import '../l10n/app_localizations.dart';
import 'app_shell.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});
  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  bool _loading = true;
  List<DownloadInfo> _items = [];
  Map<String, int> _fileSizes = {};
  Map<String, DateTime> _downloadedTimes = {};
  Map<String, bool> _isPodcast = {};
  bool _selecting = false;
  final Set<String> _selected = {};
  bool _mergeLibraries = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  _DownloadSort _sort = _DownloadSort.recent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final items = DownloadService().downloadedItems;
    final sizes = <String, int>{};
    final times = <String, DateTime>{};
    final pods = <String, bool>{};
    for (final item in items) {
      sizes[item.itemId] = DownloadService().getItemFileSize(item.itemId);
      final t = _latestFileTime(item);
      if (t != null) times[item.itemId] = t;
      pods[item.itemId] = _sessionIsPodcast(item.sessionData);
    }
    final merge = await PlayerSettings.getMergeAbsorbingLibraries();
    if (mounted) {
      setState(() {
        _items = items;
        _fileSizes = sizes;
        _downloadedTimes = times;
        _isPodcast = pods;
        _mergeLibraries = merge;
        _loading = false;
      });
    }
  }

  /// The newest local file timestamp of [info] - a reasonable stand-in for when
  /// the download finished. SAF files can't be stat-ed and are skipped.
  static DateTime? _latestFileTime(DownloadInfo info) {
    DateTime? latest;
    for (final p in info.localPaths) {
      if (p.startsWith('content://')) continue;
      try {
        final t = File(p).lastModifiedSync();
        if (latest == null || t.isAfter(latest)) latest = t;
      } catch (_) {}
    }
    return latest;
  }

  static bool _sessionIsPodcast(String? sessionData) {
    if (sessionData == null) return false;
    try {
      final s = jsonDecode(sessionData) as Map<String, dynamic>;
      final libItem = s['libraryItem'] as Map<String, dynamic>?;
      return (libItem?['mediaType'] as String?) == 'podcast';
    } catch (_) {}
    return false;
  }

  bool _matchesQuery(DownloadInfo d) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return (d.title ?? '').toLowerCase().contains(q) ||
        (d.author ?? '').toLowerCase().contains(q);
  }

  List<DownloadInfo> _sortedCompleted(List<DownloadInfo> list) {
    final out = List<DownloadInfo>.from(list);
    switch (_sort) {
      case _DownloadSort.recent:
        out.sort((a, b) {
          final ta = _downloadedTimes[a.itemId];
          final tb = _downloadedTimes[b.itemId];
          if (ta == null && tb == null) return 0;
          if (ta == null) return 1;
          if (tb == null) return -1;
          return tb.compareTo(ta);
        });
      case _DownloadSort.title:
        out.sort(
          (a, b) => (a.title ?? '').toLowerCase().compareTo(
            (b.title ?? '').toLowerCase(),
          ),
        );
      case _DownloadSort.size:
        out.sort(
          (a, b) =>
              (_fileSizes[b.itemId] ?? 0).compareTo(_fileSizes[a.itemId] ?? 0),
        );
    }
    return out;
  }

  void _toggleSelect(String itemId) {
    setState(() {
      if (_selected.contains(itemId)) {
        _selected.remove(itemId);
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(itemId);
      }
    });
  }

  void _enterSelection(String itemId) {
    setState(() {
      _selecting = true;
      _selected.add(itemId);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  /// The completed downloads currently visible, honoring the same library
  /// filter as the list - select-all must never grab hidden items or a bulk
  /// delete would remove downloads the user can't see.
  List<DownloadInfo> _visibleCompleted() {
    final lib = context.read<LibraryProvider>();
    final activeLibId = lib.selectedLibraryId;
    final shouldFilter =
        !lib.isOffline && !_mergeLibraries && activeLibId != null;
    final completed = DownloadService().downloadedItems;
    if (!shouldFilter) return completed;
    return completed
        .where((d) => d.libraryId == null || d.libraryId == activeLibId)
        .toList();
  }

  void _toggleSelectAll() {
    final visible = _visibleCompleted().map((d) => d.itemId).toList();
    setState(() {
      final allSelected =
          visible.isNotEmpty && visible.every(_selected.contains);
      _selected.clear();
      if (!allSelected) _selected.addAll(visible);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;

    final l = AppLocalizations.of(context)!;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text(l.downloadsDeleteCount(count)),
        content: Text(l.downloadsDeleteContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    for (final itemId in _selected.toList()) {
      await DownloadService().deleteDownload(itemId, byUser: true);
    }

    _exitSelection();
    await _load();

    if (mounted) {
      showOverlayToast(
        context,
        l.downloadsDeletedCount(count),
        icon: Icons.delete_outline_rounded,
      );
    }
  }

  Future<bool> _confirmDelete(DownloadInfo info) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text(l.downloadsRemoveTitle),
        content: Text(l.downloadsRemoveContent(info.title ?? '')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  Future<void> _performDelete(DownloadInfo info) async {
    final l = AppLocalizations.of(context)!;
    await DownloadService().deleteDownload(info.itemId, byUser: true);
    await _load();
    if (mounted) {
      showOverlayToast(
        context,
        l.downloadsRemovedTitle(info.title ?? ''),
        icon: Icons.delete_outline_rounded,
      );
    }
  }

  Future<void> _deleteSingle(DownloadInfo info) async {
    if (await _confirmDelete(info)) await _performDelete(info);
  }

  Future<void> _resumeAllPaused(List<DownloadInfo> paused) async {
    final api = context.read<AuthProvider>().apiService;
    if (api == null) return;
    final ds = DownloadService();
    for (final info in paused) {
      ds.resumeDownload(info.itemId, api: api);
    }
  }

  Future<void> _deleteAllPaused(List<DownloadInfo> paused) async {
    if (paused.isEmpty) return;
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text(l.downloadsDeleteAll),
        content: Text(l.downloadsDeleteAllContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final count = paused.length;
    for (final info in paused) {
      await DownloadService().deleteDownload(info.itemId, byUser: true);
    }
    await _load();
    if (mounted) {
      showOverlayToast(
        context,
        l.downloadsDeletedCount(count),
        icon: Icons.delete_outline_rounded,
      );
    }
  }

  Future<void> _openTrackManager(DownloadInfo info) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (_) => _TrackManagementSheet(
        info: info,
        isPodcast: _isPodcast[info.itemId] ?? false,
        formatBytes: _formatBytes,
      ),
    );
    // Recompute the cached sizes (a track may have been deleted).
    await _load();
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    // Back exits open search / multi-select first; only a second press closes
    // the screen. Sort and selection share this single exit affordance.
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _exitSelection();
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: AbsorbPageHeader(
                              title: l.downloadsTitle,
                              padding: EdgeInsets.zero,
                            ),
                          ),
                          if (_selecting) ...[
                            // Listens to DownloadService so a download completing
                            // mid-selection doesn't leave a stale all-selected look.
                            ListenableBuilder(
                              listenable: DownloadService(),
                              builder: (_, __) {
                                final visible = _visibleCompleted();
                                final allSelected =
                                    visible.isNotEmpty &&
                                    visible.every(
                                      (d) => _selected.contains(d.itemId),
                                    );
                                return IconButton(
                                  icon: Icon(
                                    allSelected
                                        ? Icons.deselect_rounded
                                        : Icons.select_all_rounded,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  tooltip: allSelected
                                      ? l.deselectAll
                                      : l.selectAll,
                                  onPressed: _toggleSelectAll,
                                );
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.close_rounded,
                                color: cs.onSurfaceVariant,
                              ),
                              tooltip: l.downloadsCancelSelection,
                              onPressed: _exitSelection,
                            ),
                          ] else ...[
                            if (_items.isNotEmpty)
                              PopupMenuButton<_DownloadSort>(
                                icon: Icon(
                                  Icons.sort_rounded,
                                  color: cs.onSurfaceVariant,
                                ),
                                tooltip: l.downloadsSort,
                                onSelected: (v) => setState(() => _sort = v),
                                itemBuilder: (ctx) => [
                                  CheckedPopupMenuItem(
                                    value: _DownloadSort.recent,
                                    checked: _sort == _DownloadSort.recent,
                                    child: Text(l.downloadsSortRecent),
                                  ),
                                  CheckedPopupMenuItem(
                                    value: _DownloadSort.title,
                                    checked: _sort == _DownloadSort.title,
                                    child: Text(l.downloadsSortTitle),
                                  ),
                                  CheckedPopupMenuItem(
                                    value: _DownloadSort.size,
                                    checked: _sort == _DownloadSort.size,
                                    child: Text(l.downloadsSortSize),
                                  ),
                                ],
                              ),
                            if (_items.isNotEmpty)
                              IconButton(
                                icon: Icon(
                                  Icons.checklist_rounded,
                                  color: cs.onSurfaceVariant,
                                ),
                                tooltip: l.downloadsSelect,
                                onPressed: () =>
                                    setState(() => _selecting = true),
                              ),
                          ],
                        ],
                      ),
                    ),
                    if (!_selecting)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                        child: TextField(
                          controller: _searchCtrl,
                          onChanged: (v) => setState(() => _query = v),
                          style: tt.bodyMedium,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: l.downloadsSearchHint,
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 20,
                            ),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 18,
                                    ),
                                    onPressed: () => setState(() {
                                      _query = '';
                                      _searchCtrl.clear();
                                    }),
                                  ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 8,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),

                    // Content
                    Expanded(
                      child: ListenableBuilder(
                        listenable: DownloadService(),
                        builder: (ctx, _) {
                          final ds = DownloadService();
                          final lib = context.watch<LibraryProvider>();
                          final activeLibId = lib.selectedLibraryId;
                          final shouldFilter =
                              !lib.isOffline &&
                              !_mergeLibraries &&
                              activeLibId != null;

                          List<DownloadInfo> filterByLibrary(
                            List<DownloadInfo> items,
                          ) {
                            if (!shouldFilter) return items;
                            return items
                                .where(
                                  (d) =>
                                      d.libraryId == null ||
                                      d.libraryId == activeLibId,
                                )
                                .toList();
                          }

                          final active = filterByLibrary(
                            ds.activeDownloads,
                          ).where(_matchesQuery).toList();
                          final paused = filterByLibrary(
                            ds.pausedDownloads,
                          ).where(_matchesQuery).toList();
                          final queued = filterByLibrary(
                            ds.queuedDownloads,
                          ).where(_matchesQuery).toList();
                          final completedAll = filterByLibrary(
                            ds.downloadedItems,
                          );
                          final completed = _sortedCompleted(
                            completedAll.where(_matchesQuery).toList(),
                          );
                          int completedBytes = 0;
                          for (final d in completedAll) {
                            completedBytes += _fileSizes[d.itemId] ?? 0;
                          }
                          final hasAny =
                              active.isNotEmpty ||
                              paused.isNotEmpty ||
                              queued.isNotEmpty ||
                              completed.isNotEmpty;

                          if (!hasAny) {
                            final searching = _query.trim().isNotEmpty;
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    searching
                                        ? Icons.search_off_rounded
                                        : Icons.download_done_rounded,
                                    size: 48,
                                    color: cs.onSurfaceVariant.withValues(
                                      alpha: 0.4,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    searching
                                        ? l.downloadsNoResults
                                        : l.downloadsNoDownloads,
                                    style: tt.bodyLarge?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }

                          return ListView(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                            children: [
                              // Summary: count + total size on disk
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 4,
                                  bottom: 10,
                                ),
                                child: Text(
                                  l.downloadsSummary(
                                    completedAll.length,
                                    _formatBytes(completedBytes),
                                  ),
                                  style: tt.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              // Active downloads
                              if (active.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    bottom: 8,
                                  ),
                                  child: Text(
                                    l.downloadsDownloading,
                                    style: tt.labelMedium?.copyWith(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                for (final info in active)
                                  _ActiveDownloadCard(
                                    info: info,
                                    cs: cs,
                                    tt: tt,
                                    onCancel: () =>
                                        ds.cancelDownload(info.itemId),
                                    onPause: () =>
                                        ds.pauseDownload(info.itemId),
                                    mediaHeaders: context
                                        .read<LibraryProvider>()
                                        .mediaHeaders,
                                  ),
                              ],
                              // Paused downloads
                              if (paused.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    top: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      Text(
                                        l.downloadsPaused,
                                        style: tt.labelMedium?.copyWith(
                                          color: cs.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const Spacer(),
                                      TextButton(
                                        onPressed: () =>
                                            _resumeAllPaused(paused),
                                        style: TextButton.styleFrom(
                                          minimumSize: Size.zero,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          foregroundColor: cs.onSurfaceVariant,
                                          textStyle: tt.labelMedium?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        child: Text(l.downloadsResumeAll),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            _deleteAllPaused(paused),
                                        style: TextButton.styleFrom(
                                          minimumSize: Size.zero,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          foregroundColor: cs.error,
                                          textStyle: tt.labelMedium?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        child: Text(l.downloadsDeleteAll),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                for (final info in paused)
                                  _PausedDownloadCard(
                                    info: info,
                                    cs: cs,
                                    tt: tt,
                                    onResume: () {
                                      final api = context
                                          .read<AuthProvider>()
                                          .apiService;
                                      if (api != null) {
                                        ds.resumeDownload(
                                          info.itemId,
                                          api: api,
                                        );
                                      }
                                    },
                                    onCancel: () =>
                                        ds.cancelDownload(info.itemId),
                                    mediaHeaders: context
                                        .read<LibraryProvider>()
                                        .mediaHeaders,
                                  ),
                              ],
                              // Queued downloads
                              if (queued.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    top: 4,
                                    bottom: 8,
                                  ),
                                  child: Text(
                                    l.downloadsQueued,
                                    style: tt.labelMedium?.copyWith(
                                      color: cs.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                for (final info in queued)
                                  _ActiveDownloadCard(
                                    info: info,
                                    cs: cs,
                                    tt: tt,
                                    isQueued: true,
                                    onCancel: () =>
                                        ds.cancelDownload(info.itemId),
                                    mediaHeaders: context
                                        .read<LibraryProvider>()
                                        .mediaHeaders,
                                  ),
                              ],
                              // Completed downloads
                              if (completed.isNotEmpty) ...[
                                if (active.isNotEmpty ||
                                    paused.isNotEmpty ||
                                    queued.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 4,
                                      top: 4,
                                      bottom: 8,
                                    ),
                                    child: Text(
                                      l.downloadsCompleted,
                                      style: tt.labelMedium?.copyWith(
                                        color: cs.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                for (final info in completed)
                                  Dismissible(
                                    key: ValueKey('dismiss_${info.itemId}'),
                                    direction: _selecting
                                        ? DismissDirection.none
                                        : DismissDirection.endToStart,
                                    background: Container(
                                      alignment: Alignment.centerRight,
                                      padding: const EdgeInsets.only(right: 20),
                                      margin: const EdgeInsets.only(bottom: 8),
                                      decoration: BoxDecoration(
                                        color: cs.errorContainer,
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Icon(
                                        Icons.delete_outline_rounded,
                                        color: cs.onErrorContainer,
                                      ),
                                    ),
                                    confirmDismiss: (_) => _confirmDelete(info),
                                    onDismissed: (_) =>
                                        unawaited(_performDelete(info)),
                                    child: _DownloadCard(
                                      info: info,
                                      fileSize: _fileSizes[info.itemId] ?? 0,
                                      cs: cs,
                                      tt: tt,
                                      selecting: _selecting,
                                      isSelected: _selected.contains(
                                        info.itemId,
                                      ),
                                      isPodcast:
                                          _isPodcast[info.itemId] ?? false,
                                      onToggle: () =>
                                          _toggleSelect(info.itemId),
                                      onLongPress: () =>
                                          _enterSelection(info.itemId),
                                      onDelete: () => _deleteSingle(info),
                                      onManageTracks: () =>
                                          _openTrackManager(info),
                                      formatBytes: _formatBytes,
                                      mediaHeaders: context
                                          .read<LibraryProvider>()
                                          .mediaHeaders,
                                    ),
                                  ),
                              ],
                            ],
                          );
                        },
                      ),
                    ),

                    // Bottom delete bar
                    if (_selecting)
                      Container(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          border: Border(
                            top: BorderSide(
                              color: cs.outlineVariant.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: Row(
                            children: [
                              Text(
                                l.downloadsSelectedCount(_selected.length),
                                style: tt.bodyMedium?.copyWith(
                                  color: cs.onSurface,
                                ),
                              ),
                              const Spacer(),
                              Builder(
                                builder: (_) {
                                  final visible = _visibleCompleted();
                                  final allSelected =
                                      visible.isNotEmpty &&
                                      visible.every(
                                        (d) => _selected.contains(d.itemId),
                                      );
                                  return TextButton(
                                    onPressed: _toggleSelectAll,
                                    child: Text(
                                      allSelected ? l.deselectAll : l.selectAll,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 4),
                              FilledButton.tonalIcon(
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                ),
                                label: Text(l.delete),
                                style: FilledButton.styleFrom(
                                  backgroundColor: cs.errorContainer,
                                  foregroundColor: cs.onErrorContainer,
                                ),
                                onPressed: _selected.isEmpty
                                    ? null
                                    : _deleteSelected,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _DownloadCard extends StatelessWidget {
  final DownloadInfo info;
  final int fileSize;
  final ColorScheme cs;
  final TextTheme tt;
  final bool selecting;
  final bool isSelected;
  final bool isPodcast;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  final VoidCallback onManageTracks;
  final String Function(int) formatBytes;
  final Map<String, String> mediaHeaders;

  const _DownloadCard({
    required this.info,
    required this.fileSize,
    required this.cs,
    required this.tt,
    required this.selecting,
    required this.isSelected,
    this.isPodcast = false,
    required this.onToggle,
    required this.onLongPress,
    required this.onDelete,
    required this.onManageTracks,
    required this.formatBytes,
    required this.mediaHeaders,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    // Open the per-file / per-episode manager for any completed download, so a
    // single-file (e.g. one podcast episode) can still be managed or removed.
    final canManageTracks = info.localPaths.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          onTap: selecting
              ? onToggle
              : (canManageTracks ? onManageTracks : null),
          onLongPress: !selecting ? onLongPress : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                if (selecting)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Icon(
                      isSelected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 22,
                      color: isSelected
                          ? cs.primary
                          : cs.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
                  ),
                // Cover art
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: _DownloadCover(
                      cs: cs,
                      localCoverPath: info.localCoverPath,
                      coverUrl: info.coverUrl,
                      mediaHeaders: mediaHeaders,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Title, author, size
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.title ?? l.unknown,
                        style: tt.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (info.author != null && info.author!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            info.author!,
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (fileSize > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            formatBytes(fileSize),
                            style: tt.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!selecting) ...[
                  if (canManageTracks)
                    IconButton(
                      icon: Icon(
                        Icons.library_music_rounded,
                        color: cs.onSurfaceVariant,
                        size: 22,
                      ),
                      tooltip: isPodcast
                          ? l.downloadsManageTracks
                          : l.downloadsManageFiles,
                      onPressed: onManageTracks,
                    ),
                  IconButton(
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: cs.error,
                      size: 22,
                    ),
                    tooltip: l.delete,
                    onPressed: onDelete,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveDownloadCard extends StatelessWidget {
  final DownloadInfo info;
  final ColorScheme cs;
  final TextTheme tt;
  final bool isQueued;
  final VoidCallback onCancel;
  final VoidCallback? onPause;
  final Map<String, String> mediaHeaders;

  const _ActiveDownloadCard({
    required this.info,
    required this.cs,
    required this.tt,
    this.isQueued = false,
    required this.onCancel,
    this.onPause,
    required this.mediaHeaders,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final progress = info.progress;
    final pct = (progress * 100).round();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Cover art
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: _DownloadCover(
                    cs: cs,
                    localCoverPath: info.localCoverPath,
                    coverUrl: info.coverUrl,
                    mediaHeaders: mediaHeaders,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Title, status, progress
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.title ?? l.unknown,
                      style: tt.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    if (isQueued)
                      Text(
                        l.downloadsWaiting,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      )
                    else ...[
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 6,
                                backgroundColor: cs.surfaceContainerHighest,
                                valueColor: AlwaysStoppedAnimation(cs.primary),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$pct%',
                            style: tt.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (!isQueued && onPause != null) ...[
                IconButton(
                  icon: Icon(
                    Icons.pause_circle_outline_rounded,
                    color: cs.onSurfaceVariant,
                    size: 22,
                  ),
                  tooltip: l.downloadsPause,
                  onPressed: onPause,
                ),
                const SizedBox(width: 4),
              ],
              IconButton(
                icon: Icon(
                  Icons.close_rounded,
                  color: cs.onSurfaceVariant,
                  size: 20,
                ),
                tooltip: l.cancel,
                onPressed: onCancel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PausedDownloadCard extends StatelessWidget {
  final DownloadInfo info;
  final ColorScheme cs;
  final TextTheme tt;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final Map<String, String> mediaHeaders;

  const _PausedDownloadCard({
    required this.info,
    required this.cs,
    required this.tt,
    required this.onResume,
    required this.onCancel,
    required this.mediaHeaders,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final pct = (info.progress * 100).round();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: _DownloadCover(
                    cs: cs,
                    localCoverPath: info.localCoverPath,
                    coverUrl: info.coverUrl,
                    mediaHeaders: mediaHeaders,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.title ?? l.unknown,
                      style: tt.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${l.downloadsPaused} · $pct%',
                      style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.play_circle_outline_rounded,
                  color: cs.primary,
                  size: 28,
                ),
                tooltip: l.downloadsResume,
                onPressed: onResume,
              ),
              const SizedBox(width: 2),
              IconButton(
                icon: Icon(
                  Icons.close_rounded,
                  color: cs.onSurfaceVariant,
                  size: 20,
                ),
                tooltip: l.cancel,
                onPressed: onCancel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A download's cover art: local file first, then the network URL, falling
/// back to a headphones placeholder. Shared by the active/paused/completed
/// download cards.
class _DownloadCover extends StatelessWidget {
  final ColorScheme cs;
  final String? localCoverPath;
  final String? coverUrl;
  final Map<String, String> mediaHeaders;

  const _DownloadCover({
    required this.cs,
    this.localCoverPath,
    this.coverUrl,
    required this.mediaHeaders,
  });

  @override
  Widget build(BuildContext context) {
    final local = localCoverPath;
    if (local != null && local.isNotEmpty) {
      final file = File(local);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(),
        );
      }
    }
    final url = coverUrl;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('/')) {
        final file = File(url);
        if (file.existsSync()) {
          return Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder(),
          );
        }
      } else {
        return CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          httpHeaders: mediaHeaders,
          placeholder: (_, __) => _placeholder(),
          errorWidget: (_, __, ___) => _placeholder(),
        );
      }
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          size: 24,
          color: cs.onSurfaceVariant.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}

/// Per-episode manager for one completed download: lists every local audio
/// file, shows its length/size/date, supports batch deletion and lets a tap
/// jump playback to that episode (episodes saved to SAF are listed but can't
/// be deleted individually).
class _TrackManagementSheet extends StatefulWidget {
  final DownloadInfo info;
  final bool isPodcast;
  final String Function(int) formatBytes;

  const _TrackManagementSheet({
    required this.info,
    this.isPodcast = false,
    required this.formatBytes,
  });

  @override
  State<_TrackManagementSheet> createState() => _TrackManagementSheetState();
}

class _TrackManagementSheetState extends State<_TrackManagementSheet> {
  bool _deleting = false;
  bool _selecting = false;
  final Set<int> _selected = {};

  static String _fmtDuration(double seconds) {
    if (seconds <= 0) return '';
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  static String _fmtDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  void _toggleSelect(int index) {
    setState(() {
      if (_selected.contains(index)) {
        _selected.remove(index);
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(index);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _deleteTrack(LocalTrackInfo track) async {
    if (_deleting) return;
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text(l.downloadsTrackDeleteTitle),
        content: Text(l.downloadsTrackDeleteContent(track.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    await DownloadService().deleteLocalTrack(widget.info.itemId, track.index);
    if (!mounted) return;
    setState(() => _deleting = false);
  }

  Future<void> _deleteSelected() async {
    if (_deleting || _selected.isEmpty) return;
    final l = AppLocalizations.of(context)!;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text(l.downloadsTrackDeleteTitle),
        content: Text(l.downloadsDeleteTracksCount(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    // Removing by index shifts every later entry, so delete from the end.
    final indices = _selected.toList()..sort((a, b) => b.compareTo(a));
    for (final i in indices) {
      await DownloadService().deleteLocalTrack(widget.info.itemId, i);
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _selecting = false;
      _selected.clear();
    });
    if (DownloadService().getLocalTracks(widget.info.itemId).isEmpty &&
        mounted) {
      Navigator.pop(context);
    }
  }

  /// Play the book starting at [track], so the user jumps straight to that
  /// episode's point on the full-book timeline (gaps preserved).
  Future<void> _playFrom(LocalTrackInfo track) async {
    final l = AppLocalizations.of(context)!;
    final api =
        AudioPlayerService().currentApi ??
        context.read<AuthProvider>().apiService;
    if (api == null) {
      showOverlayToast(
        context,
        l.chapterNotConnected,
        icon: Icons.cloud_off_rounded,
      );
      return;
    }
    final info = widget.info;
    var title = info.title ?? '';
    var author = info.author ?? '';
    var coverUrl = info.coverUrl;
    var duration = 0.0;
    var chapters = <dynamic>[];
    if (info.sessionData != null) {
      try {
        final s = jsonDecode(info.sessionData!) as Map<String, dynamic>;
        final libItem = s['libraryItem'] as Map<String, dynamic>?;
        final media = libItem?['media'] as Map<String, dynamic>?;
        if (media != null) {
          final md = media['metadata'] as Map<String, dynamic>?;
          title = (md?['title'] as String?) ?? title;
          author = (md?['authorName'] as String?) ?? author;
          coverUrl = (md?['coverPath'] as String?) ?? coverUrl;
          duration = (media['duration'] as num?)?.toDouble() ?? 0;
          chapters = (media['chapters'] as List<dynamic>?) ?? const [];
        }
      } catch (_) {}
    }
    final error = await AudioPlayerService().playItem(
      api: api,
      itemId: info.itemId,
      title: title,
      author: author,
      coverUrl: coverUrl,
      totalDuration: duration,
      chapters: chapters,
      startTime: track.absoluteStart,
      forceStartTime: true,
      fromUi: true,
      libraryId: info.libraryId,
    );
    if (!mounted) return;
    if (error != null) {
      showOverlayToast(context, error, icon: Icons.error_outline_rounded);
      return;
    }
    Navigator.pop(context);
    AppShell.goToAbsorbingGlobal();
  }

  /// True when the remaining files no longer tile the timeline - e.g. a
  /// middle episode was deleted, so playback will skip a stretch.
  bool _hasGap(List<LocalTrackInfo> tracks) {
    for (var i = 1; i < tracks.length; i++) {
      final prev = tracks[i - 1];
      if (prev.durationSeconds > 0 &&
          tracks[i].absoluteStart >
              prev.absoluteStart + prev.durationSeconds + 0.5) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    final title = widget.isPodcast
        ? l.downloadsManageTracks
        : l.downloadsManageFiles;

    return SafeArea(
      child: ListenableBuilder(
        listenable: DownloadService(),
        builder: (context, _) {
          final tracks = DownloadService().getLocalTracks(widget.info.itemId);
          if (tracks.isEmpty) {
            // The last episode was removed: the download is gone.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) Navigator.pop(context);
            });
            return const SizedBox(height: 200);
          }
          var totalBytes = 0;
          var selectedBytes = 0;
          for (final t in tracks) {
            totalBytes += t.sizeBytes;
            if (_selected.contains(t.index)) selectedBytes += t.sizeBytes;
          }
          final anySaf = tracks.any((t) => t.isSaf);
          final canSelect = tracks.length > 1;
          final showGap = _hasGap(tracks);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: tt.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _selecting
                                ? '${l.downloadsSelectedCount(_selected.length)}'
                                      ' · ${widget.formatBytes(selectedBytes)}'
                                : '${tracks.length} · '
                                      '${widget.formatBytes(totalBytes)}',
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (canSelect && !_selecting)
                      IconButton(
                        icon: Icon(
                          Icons.checklist_rounded,
                          color: cs.onSurfaceVariant,
                        ),
                        tooltip: l.downloadsSelect,
                        onPressed: () => setState(() => _selecting = true),
                      ),
                    IconButton(
                      icon: Icon(
                        _selecting
                            ? Icons.deselect_rounded
                            : Icons.close_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                      tooltip: _selecting
                          ? l.downloadsCancelSelection
                          : MaterialLocalizations.of(
                              context,
                            ).closeButtonTooltip,
                      onPressed: _selecting
                          ? _exitSelection
                          : () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              if (anySaf)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l.downloadsNoPerTrackSaf,
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (showGap)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.content_cut_rounded,
                        size: 18,
                        color: cs.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l.downloadsGapSkipped,
                          style: tt.bodySmall?.copyWith(color: cs.tertiary),
                        ),
                      ),
                    ],
                  ),
                ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.55,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: tracks.length,
                  itemBuilder: (context, i) {
                    final t = tracks[i];
                    final selected = _selected.contains(t.index);
                    final meta = <String>[
                      if (t.durationSeconds > 0)
                        _fmtDuration(t.durationSeconds),
                      if (t.sizeBytes > 0) widget.formatBytes(t.sizeBytes),
                      if (t.downloadedAt != null) _fmtDate(t.downloadedAt!),
                    ].join(' · ');
                    return ListTile(
                      dense: true,
                      selected: _selecting && selected,
                      leading: _selecting
                          ? Icon(
                              selected
                                  ? Icons.check_circle_rounded
                                  : Icons.circle_outlined,
                              size: 22,
                              color: selected
                                  ? cs.primary
                                  : cs.onSurfaceVariant.withValues(alpha: 0.5),
                            )
                          : SizedBox(
                              width: 28,
                              child: Text(
                                '${t.index + 1}',
                                textAlign: TextAlign.center,
                                style: tt.labelMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.bodyMedium,
                      ),
                      subtitle: Text(
                        t.isSaf
                            ? l.downloadsStoredExternally
                            : (meta.isEmpty
                                  ? widget.formatBytes(t.sizeBytes)
                                  : meta),
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      onTap: _selecting
                          ? () => _toggleSelect(t.index)
                          : (_deleting ? null : () => _playFrom(t)),
                      onLongPress: canSelect && !_selecting
                          ? () => setState(() {
                              _selecting = true;
                              _selected.add(t.index);
                            })
                          : null,
                      trailing: _selecting || t.isSaf || !t.exists
                          ? null
                          : IconButton(
                              icon: Icon(
                                Icons.delete_outline_rounded,
                                color: cs.error,
                                size: 22,
                              ),
                              tooltip: l.delete,
                              onPressed: _deleting
                                  ? null
                                  : () => _deleteTrack(t),
                            ),
                    );
                  },
                ),
              ),
              if (_selecting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${l.downloadsSelectedCount(_selected.length)}'
                          ' · ${widget.formatBytes(selectedBytes)}',
                          style: tt.bodyMedium?.copyWith(color: cs.onSurface),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          final all = tracks.length > 1;
                          if (all && _selected.length == tracks.length) {
                            _selected.clear();
                          } else {
                            _selected
                              ..clear()
                              ..addAll(tracks.map((t) => t.index));
                          }
                        }),
                        child: Text(
                          _selected.length == tracks.length
                              ? l.deselectAll
                              : l.selectAll,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
                        label: Text(l.delete),
                        style: FilledButton.styleFrom(
                          backgroundColor: cs.errorContainer,
                          foregroundColor: cs.onErrorContainer,
                        ),
                        onPressed: _selected.isEmpty || _deleting
                            ? null
                            : _deleteSelected,
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }
}

enum _DownloadSort { recent, title, size }
