import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/app_log.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../services/ebook_cache.dart';
import '../services/offline_source.dart';
import '../services/wording.dart';
import '../widgets/absorb_page_header.dart';
import '../widgets/ebook_router.dart';
import 'app_shell.dart';
import '../widgets/overlay_toast.dart';
import '../l10n/app_localizations.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});
  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  bool _loading = true;
  List<DownloadInfo> _items = [];
  Set<String> _itemIds = <String>{};
  Map<String, int> _fileSizes = {};
  Map<String, DateTime> _downloadedTimes = {};
  Map<String, bool> _isPodcast = {};

  /// Ebooks on the phone that no record lists: cached copies the reader made
  /// when an ebook was opened (the reader-only path can fail to write a record
  /// offline or on a server hiccup) and copies the user exported to the device
  /// ("save to device"). Resolved from the item cache so the row carries the
  /// book's real title instead of a file name.
  List<DownloadInfo> _ebookOnlyItems = [];

  /// Item ids whose ebook was exported to the device's download folder. Kept
  /// so the rows can offer "read" and so a delete sweeps the real file too.
  Set<String> _exportedEbookIds = {};

  /// Rows dropped from the list ahead of their delete landing. DownloadService
  /// still reports them until the delete finishes, and this screen ticks on
  /// every service notify - so without this the row would be re-added by
  /// [_addFinishedItems] and blink back for as long as the unlink takes.
  /// [_load] clears it, since that rebuilds the list from live state.
  final Set<String> _dropping = {};
  bool _selecting = false;
  final Set<String> _selected = {};
  bool _mergeLibraries = false;
  bool _metadataRefreshScheduled = false;
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

  /// [validate] walks every downloaded file to drop entries whose audio was
  /// deleted outside the app (SAF content URIs especially). Skipped after our
  /// own delete: the removed rows are already known, and the walk awaits one
  /// File.exists() per remaining track, which on a large library is seconds of
  /// queued IO for information we don't need.
  Future<void> _load({bool validate = true}) async {
    final dl = DownloadService();
    // Warm the ebook cache directory handle: the kept-ebook rows below (and
    // their share of the summary) read their sizes through the synchronous
    // accessor, which sees nothing until the handle exists.
    await hydrateEbookCacheDir();
    // Re-check downloaded files before rendering so entries whose audio was
    // deleted externally (SAF content URIs especially) drop off the list.
    if (validate) await dl.validateDownloads();
    final items = dl.downloadedItems;
    // Size / newest-timestamp are per-file synchronous stat calls. Run them on
    // a background isolate: opening a large download library used to block the
    // route animation on the main isolate for hundreds of stat round-trips.
    final statTasks = <List<Object?>>[];
    final cachedIds = <String>{};
    final safByItem = <String, List<String>>{};
    for (final item in items) {
      // After our own delete, surviving rows already have their size / timestamp
      // / podcast flag cached. Re-stat-ing every remaining file is what made
      // removing one book out of a large library feel like a freeze.
      final cached = !validate && _itemIds.contains(item.itemId);
      if (cached) {
        cachedIds.add(item.itemId);
      } else {
        statTasks.add(<Object?>[item.itemId, item.localPaths]);
        // SAF (content://) files can't be stat-ed from Dart; the native resolver
        // reports their sizes separately below.
        final uris = item.localPaths.where(isContentUri).toList();
        if (uris.isNotEmpty) safByItem[item.itemId] = uris;
      }
    }
    final sizes = <String, int>{
      for (final id in cachedIds) id: _fileSizes[id] ?? 0,
    };
    final times = <String, DateTime>{
      for (final id in cachedIds)
        if (_downloadedTimes[id] != null) id: _downloadedTimes[id]!,
    };
    if (statTasks.isNotEmpty) {
      final results = await compute(_statDownloadsInBackground, statTasks);
      for (final r in results) {
        final id = r[0] as String;
        sizes[id] = r[1] as int;
        final iso = r[2] as String?;
        if (iso != null) times[id] = DateTime.parse(iso);
      }
    }
    // SAF audio lives behind content:// URIs the Dart isolate can't stat, so
    // the native probe (checkSafFiles) also returns their byte sizes. Reuse
    // those so a huge library never gets a second native walk of the same URIs;
    // fall back to a size-only probe for any URI the validate pass didn't see.
    if (safByItem.isNotEmpty) {
      final all = {for (final list in safByItem.values) ...list}.toList();
      final probe = dl.probedSafSizes;
      final missing =
          all.where((uri) => !probe.containsKey(uri)).toList();
      Map<String, int> extra = const {};
      if (missing.isNotEmpty) {
        extra = await dl.getSafFileSizes(missing);
      }
      for (final item in items) {
        final list = safByItem[item.itemId];
        if (list == null) continue;
        var totalSize = sizes[item.itemId] ?? 0;
        for (final uri in list) {
          totalSize += probe[uri] ?? extra[uri] ?? 0;
        }
        sizes[item.itemId] = totalSize;
      }
    }
    final pods = <String, bool>{
      for (final item in items)
        item.itemId:
            _isPodcast[item.itemId] ?? _sessionIsPodcast(item.sessionData),
    };
    // Ebooks on the phone that no record lists (see [_ebookOnlyItems]).
    // Metadata comes from the item cache first, then the server, so the row
    // shows the book's title rather than a cache file name.
    final api = context.read<AuthProvider>().apiService;
    final recordIds = <String>{
      for (final item in items) item.itemId,
      for (final kept in dl.keptEbooks) kept.itemId,
    };
    final cachedEbookIds = cachedEbookItemIdsSync();
    final exportedEbookIds = await dl.savedEbookItemIds();
    // Any ebook on the device the records don't already cover: cached copies
    // the reader made, plus copies exported to the download folder.
    final onDeviceEbookIds = <String>{
      ...cachedEbookIds,
      ...exportedEbookIds,
    };
    final ebookOnly = <DownloadInfo>[
      for (final r in _ebookOnlyItems)
        if (onDeviceEbookIds.contains(r.itemId) && !recordIds.contains(r.itemId))
          r,
    ];
    final knownIds = <String>{
      ...recordIds,
      for (final r in ebookOnly) r.itemId,
    };
    if (api != null) {
      for (final id in onDeviceEbookIds) {
        if (knownIds.contains(id)) continue;
        try {
          final item =
              await api.getCachedLibraryItem(id) ?? await api.getLibraryItem(id);
          if (item == null) continue;
          final media = item['media'] as Map<String, dynamic>?;
          final metadata = media?['metadata'] as Map<String, dynamic>?;
          ebookOnly.add(
            DownloadInfo(
              itemId: id,
              status: DownloadStatus.downloaded,
              sessionData: jsonEncode({
                'libraryItem': item,
                'mediaMetadata': metadata,
                'duration': 0,
                'chapters': const <dynamic>[],
              }),
              title: metadata?['title'] as String?,
              author: metadata?['authorName'] as String?,
              libraryId: item['libraryId'] as String?,
            ),
          );
        } catch (e) {
          verboseLog('[Downloads] ebook row metadata failed for $id: $e');
        }
      }
    }
    final merge = await PlayerSettings.getMergeAbsorbingLibraries();
    if (mounted) {
      setState(() {
        _items = items;
        _itemIds = {for (final item in items) item.itemId};
        _fileSizes = sizes;
        _downloadedTimes = times;
        _isPodcast = pods;
        _ebookOnlyItems = ebookOnly;
        _exportedEbookIds = exportedEbookIds;
        _mergeLibraries = merge;
        _loading = false;
        // Live state is authoritative again, so the optimistic-drop guard has
        // done its job.
        _dropping.clear();
      });
      // A download that finished after the snapshot above ticked while
      // [_loading] was still set, so it was dropped with no second tick coming.
      // Re-check now the gate is open; both sides are the same set, so this
      // settles after one extra pass.
      _maybeRefreshMetadata(dl);
    }
  }

  /// Queues an update when the completed set changes, so rows that finished
  /// after the first load get real sort keys instead of zeros. Runs on every
  /// DownloadService tick (~4x/s), so it stays cheap and never setStates here.
  void _maybeRefreshMetadata(DownloadService ds) {
    if (_metadataRefreshScheduled || _loading) return;
    final liveIds = ds.downloadedItemIds
        .where((id) => !_dropping.contains(id))
        .toSet();
    if (liveIds.length == _itemIds.length && liveIds.containsAll(_itemIds)) {
      return;
    }
    _metadataRefreshScheduled = true;
    Future.microtask(() {
      if (!mounted) {
        _metadataRefreshScheduled = false;
        return;
      }
      _addFinishedItems(DownloadService());
    });
  }

  /// Adds rows for newly finished downloads WITHOUT the full
  /// [DownloadService.validateDownloads] walk: completing a download can only
  /// add to the set, and a finished row's size/time/podcast can't change since.
  ///
  /// If a row we already show is missing from the live set, a file was deleted
  /// externally or an item was deleted, and only `validateDownloads` can tell
  /// that apart from a partial file, so that case takes the slow [_load] path.
  void _addFinishedItems(DownloadService ds) {
    final items = ds.downloadedItems;
    final added = <DownloadInfo>[];
    var kept = 0;
    for (final item in items) {
      if (_dropping.contains(item.itemId)) continue;
      if (_itemIds.contains(item.itemId)) {
        kept++;
      } else {
        added.add(item);
      }
    }
    // Counting survivors rather than comparing lengths also catches a delete
    // that landed in the same tick as a fresh completion, which would leave the
    // length unchanged.
    if (kept != _items.length) {
      // Release the flag before the slow path: keeping it set would stall every
      // later tick until the reload lands, and validateDownloads() coalesces
      // any duplicate reload anyway.
      _metadataRefreshScheduled = false;
      _load();
      return;
    }
    if (added.isEmpty) {
      _metadataRefreshScheduled = false;
      return;
    }
    setState(() {
      _items = [..._items, ...added];
      for (final item in added) {
        _itemIds.add(item.itemId);
        _fileSizes[item.itemId] = ds.getItemFileSize(item.itemId);
        final t = _latestFileTime(item);
        if (t != null) _downloadedTimes[item.itemId] = t;
        _isPodcast[item.itemId] = _sessionIsPodcast(item.sessionData);
      }
    });
    _metadataRefreshScheduled = false;
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

  /// Runs on a background isolate (see [_load]). [payload] is a list of
  /// `[itemId, localPaths]` pairs; the result is `[itemId, size, isoTime?]`
  /// triplets matching [DownloadService.getItemFileSize] / [_latestFileTime].
  static List<List<Object?>> _statDownloadsInBackground(List<Object?> payload) {
    final out = <List<Object?>>[];
    for (final entry in payload) {
      final e = entry as List<Object?>;
      final itemId = e[0] as String;
      final paths = (e[1] as List<Object?>).cast<String>();
      int size = 0;
      DateTime? latest;
      for (final p in paths) {
        if (p.startsWith('content://')) continue; // SAF audio is not stat-able
        try {
          final f = File(p);
          if (f.existsSync()) {
            size += f.lengthSync();
            final t = f.lastModifiedSync();
            if (latest == null || t.isAfter(latest)) latest = t;
          }
        } catch (_) {}
      }
      out.add(<Object?>[itemId, size, latest?.toIso8601String()]);
    }
    return out;
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

  /// The completed rows currently visible, honoring the same library filter as
  /// the list - select-all must never grab hidden items or a bulk delete would
  /// remove downloads the user can't see. Mirrors the rendered set, so ebook-only
  /// books (kept ebooks and lone cached copies) are selectable too.
  List<DownloadInfo> _visibleCompleted() {
    final lib = context.read<LibraryProvider>();
    final activeLibId = lib.selectedLibraryId;
    final shouldFilter =
        !lib.isOffline && !_mergeLibraries && activeLibId != null;
    final ds = DownloadService();
    final seenIds = <String>{};
    final rows = <DownloadInfo>[
      for (final r in <DownloadInfo>[
        ...ds.downloadedItems,
        ...ds.keptEbooks,
        ..._ebookOnlyItems,
      ])
        if (seenIds.add(r.itemId)) r,
    ];
    if (!shouldFilter) return rows;
    return rows
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

    // Same reasoning as _performDelete: drop the rows and confirm before the
    // filesystem work, and don't pay for a validating reload afterwards.
    // Snapshot the ids first - _exitSelection() clears the selection.
    final ids = _selected.toList();
    _removeRows(ids);
    _exitSelection();
    showOverlayToast(
      context,
      l.downloadsDeletedCount(count),
      icon: Icons.delete_outline_rounded,
    );
    for (final itemId in ids) {
      await _deleteArtifacts(itemId);
    }
    if (mounted) _load(validate: false);
  }

  /// Removes every on-device artifact for one row: the download record (audio),
  /// a kept ebook, or a lone cached copy, plus any file exported to the download
  /// folder.
  Future<void> _deleteArtifacts(String itemId) async {
    final ds = DownloadService();
    if (ds.isDownloaded(itemId)) {
      await ds.deleteDownload(itemId, byUser: true);
    } else if (ds.keptEbook(itemId) != null) {
      // An ebook the reader keeps has no download record to remove.
      await ds.deleteKeptEbook(itemId);
    } else {
      // Nothing but a cached copy: drop it, and remember that so the catch-up
      // does not fetch it straight back.
      await ds.deleteEbookCopy(itemId);
    }
    // An exported copy (the real file in the download folder) goes with the
    // row too, not just the app's cache.
    if (_exportedEbookIds.contains(itemId)) {
      await ds.deleteSavedEbook(itemId);
    }
  }

  /// Confirms deleting a completed row. [hasEbook] adds a line saying the
  /// cached ebook goes with it, since the row shows both halves of the book.
  Future<bool> _confirmDelete(DownloadInfo info, {bool hasEbook = false}) async {
    final l = AppLocalizations.of(context)!;
    final content = hasEbook
        ? '${l.downloadsRemoveContent(info.title ?? '')}\n'
              '${l.downloadsRemoveEbookClause}'
        : l.downloadsRemoveContent(info.title ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text(l.downloadsRemoveTitle),
        content: Text(content),
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

  /// Drops rows and everything cached for them in one rebuild, and marks them as
  /// dropping so the service tick can't add them back before the delete lands.
  /// The list updates the moment a delete is confirmed instead of after the
  /// filesystem work.
  void _removeRows(List<String> itemIds) {
    if (!mounted || itemIds.isEmpty) return;
    final gone = itemIds.toSet();
    setState(() {
      _items = _items.where((d) => !gone.contains(d.itemId)).toList();
      _itemIds.removeAll(gone);
      for (final id in gone) {
        _fileSizes.remove(id);
        _downloadedTimes.remove(id);
        _isPodcast.remove(id);
      }
      _selected.removeAll(gone);
      _dropping.addAll(gone);
    });
  }

  Future<void> _performDelete(DownloadInfo info) async {
    final l = AppLocalizations.of(context)!;
    // Update first, delete after. deleteDownload() unlinks every track one at a
    // time and then rewrites the whole registry, so all of it - plus the
    // validating reload that used to follow - ran before any feedback: the row
    // sat there with its audio already gone, and no toast appeared until seconds
    // later.
    _removeRows([info.itemId]);
    showOverlayToast(
      context,
      l.downloadsRemovedTitle(info.title ?? ''),
      icon: Icons.delete_outline_rounded,
    );
    await _deleteArtifacts(info.itemId);
    // Cheap refresh: our own delete needs no revalidation.
    if (mounted) _load(validate: false);
  }

  /// Opens an ebook that is on the device. Both shapes end up here: a copy the
  /// reader cached beside its audio, and an ebook-only book (no audio at all).
  /// When only an exported copy exists the reader gets the item's ebookFile so
  /// it can fetch and open the book itself.
  Future<void> _openEbook(DownloadInfo info) async {
    final l = AppLocalizations.of(context)!;
    var ebookFile = await cachedEbookFileFor(info.itemId);
    ebookFile ??= resolveEbookFile(_sessionLibraryItem(info.sessionData));
    if (!mounted) return;
    if (ebookFile == null) {
      showOverlayToast(
        context,
        l.noEbookFileFound,
        icon: Icons.menu_book_outlined,
      );
      return;
    }
    await openEbookReader(
      context,
      itemId: info.itemId,
      title: info.title ?? '',
      ebookFile: ebookFile,
    );
  }

  /// The stored library item from a record's session JSON, needed to open an
  /// ebook whose file only lives as an export (no cached copy to synthesize
  /// an ebookFile from).
  Map<String, dynamic>? _sessionLibraryItem(String? sessionJson) {
    if (sessionJson == null) return null;
    try {
      final session = jsonDecode(sessionJson) as Map<String, dynamic>;
      return session['libraryItem'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// The cover URL to fall back on when a record carries none of its own: the
  /// reader-made ebook-only records never store one, and without this their rows
  /// would show placeholder artwork even though the server has a cover.
  String? _fallbackCoverUrl(DownloadInfo info) {
    if (info.coverUrl != null && info.coverUrl!.isNotEmpty) return null;
    return context.read<AuthProvider>().apiService?.getCoverUrl(info.itemId);
  }

  /// One row of the completed list. A book can carry audio files, an ebook, or
  /// both: play is offered when there is audio, read when the ebook is on the
  /// phone, and tapping the row opens the file manager (audio) or the reader
  /// (ebook only). Every row can join multi-select.
  Widget _completedRow(DownloadInfo info, Set<String> ebookIds) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hasAudio = info.localPaths.isNotEmpty;
    final hasEbook = ebookIds.contains(info.itemId);
    return Dismissible(
      // Swiping takes the whole row: the audio files and, for a book that has
      // one, the cached ebook (deleteDownload decides what may stay behind).
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
      confirmDismiss: (_) => _confirmDelete(info, hasEbook: hasEbook),
      onDismissed: (_) => unawaited(_performDelete(info)),
      child: _DownloadCard(
        info: info,
        // The ebook half of the book counts here as well, matching the summary.
        // An ebook-only row has no audio to measure.
        fileSize: (hasAudio ? (_fileSizes[info.itemId] ?? 0) : 0) +
            (hasEbook ? cachedEbookBytesSync(info.itemId) : 0),
        cs: cs,
        tt: tt,
        selecting: _selecting,
        isSelected: _selected.contains(info.itemId),
        hasEbook: hasEbook,
        onToggle: () => _toggleSelect(info.itemId),
        onLongPress: () => _enterSelection(info.itemId),
        onOpen: _selecting
            ? null
            : (hasAudio || hasEbook
                  ? () => _openTrackManager(info, hasEbook)
                  : null),
        onPlay: hasAudio ? () => _play(info) : null,
        onRead: hasEbook ? () => _openEbook(info) : null,
        fallbackCoverUrl: _fallbackCoverUrl(info),
        formatBytes: _formatBytes,
        mediaHeaders: context.read<LibraryProvider>().mediaHeaders,
      ),
    );
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
    _removeRows([for (final info in paused) info.itemId]);
    showOverlayToast(
      context,
      l.downloadsDeletedCount(count),
      icon: Icons.delete_outline_rounded,
    );
    for (final info in paused) {
      await DownloadService().deleteDownload(info.itemId, byUser: true);
    }
    // No validating reload: these rows are gone by construction.
    if (mounted) _load(validate: false);
  }

  /// Play a completed download straight from the list, online or offline.
  /// The session cached in [DownloadInfo.sessionData] supplies the duration
  /// and chapters playItem needs; playItem itself moves onto the local files.
  Future<void> _play(DownloadInfo info) async {
    final api = context.read<AuthProvider>().apiService;
    if (api == null || info.localPaths.isEmpty) return;
    verboseLog('[Downloads] Play ${info.itemId} from the downloads list');
    final isEpisode = info.itemId.length > 36;
    final itemId = isEpisode ? info.itemId.substring(0, 36) : info.itemId;
    final episodeId = isEpisode ? info.itemId.substring(37) : null;
    // Play the download itself, not a resume of the book: for a book, force
    // the start onto the first downloaded track so a "Play" on the row starts
    // what is actually there instead of re-entering the book's last-listened
    // position (which may sit on an un-downloaded stretch).
    final localTracks = DownloadService().getLocalTracks(info.itemId);
    final firstTrackStart = !isEpisode && localTracks.isNotEmpty
        ? localTracks.first.absoluteStart
        : 0.0;
    double duration = 0;
    List<dynamic> chapters = const [];
    final sessionJson = info.sessionData;
    if (sessionJson != null) {
      try {
        final session = jsonDecode(sessionJson) as Map<String, dynamic>;
        duration = (session['duration'] as num?)?.toDouble() ?? 0;
        chapters = session['chapters'] as List<dynamic>? ?? const [];
      } catch (_) {}
    }
    final title = info.title ?? '';
    final lib = context.read<LibraryProvider>();
    final error = await AudioPlayerService().playItem(
      api: api,
      itemId: itemId,
      title: title,
      author: info.author ?? '',
      coverUrl: api.getCoverUrl(itemId),
      totalDuration: duration,
      chapters: isEpisode ? const [] : chapters,
      episodeId: episodeId,
      episodeTitle: isEpisode ? title : null,
      startTime: firstTrackStart,
      forceStartTime: !isEpisode && localTracks.isNotEmpty,
      libraryId: info.libraryId,
      fromUi: true,
    );
    if (!mounted) return;
    if (error != null) {
      showOverlayToast(context, error, icon: Icons.error_outline_rounded);
      return;
    }
    unawaited(lib.rememberStartedInAbsorbing(info.itemId, null));
    unawaited(lib.syncQueueAutoDownloads());
    lib.refreshLocalProgress();
    lib.refresh();
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    AppShell.goToAbsorbingGlobal();
  }

  Future<void> _openTrackManager(DownloadInfo info, bool hasEbook) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (_) => _TrackManagementSheet(
        info: info,
        isPodcast: _isPodcast[info.itemId] ?? false,
        hasEbook: hasEbook,
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
                            if (_visibleCompleted().isNotEmpty)
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
                          _maybeRefreshMetadata(ds);
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
                          // One row per book: download records, the ebooks the
                          // app keeps for offline reading, and cached copies no
                          // record lists. The first source to claim an id wins.
                          final seenIds = <String>{};
                          final rows = <DownloadInfo>[
                            for (final r in <DownloadInfo>[
                              ...completedAll,
                              ...filterByLibrary(ds.keptEbooks),
                              ...filterByLibrary(_ebookOnlyItems),
                            ])
                              if (seenIds.add(r.itemId)) r,
                          ];
                          final completed = _sortedCompleted(
                            rows.where(_matchesQuery).toList(),
                          );
                          // Books whose ebook is on the device - cached or
                          // exported - get the badge and the read button, and
                          // their cached bytes count toward the row and summary.
                          final ebookIds = <String>{
                            ...cachedEbookItemIdsSync(),
                            ..._exportedEbookIds,
                          };
                          int completedBytes = 0;
                          for (final d in rows) {
                            completedBytes += _fileSizes[d.itemId] ?? 0;
                            if (ebookIds.contains(d.itemId)) {
                              completedBytes += cachedEbookBytesSync(d.itemId);
                            }
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
                                    rows.length,
                                    _formatBytes(completedBytes),
                                  ),
                                  style: tt.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              // The rows no longer carry a delete button, so
                              // say the gesture once, at the top.
                              if (completed.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    bottom: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.swipe_left_rounded,
                                        size: 16,
                                        color: cs.onSurfaceVariant.withValues(
                                          alpha: 0.7,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          l.downloadsSwipeHint,
                                          style: tt.bodySmall?.copyWith(
                                            color: cs.onSurfaceVariant
                                                .withValues(alpha: 0.7),
                                          ),
                                        ),
                                      ),
                                    ],
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
                                  _completedRow(info, ebookIds),
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
  /// The book's ebook is on the phone: draw the badge and offer "read".
  final bool hasEbook;
  final VoidCallback onToggle;
  final VoidCallback? onLongPress;
  /// Tap action: the file manager for a download, the reader for an ebook-only
  /// book. Null when the row has nothing to open.
  final VoidCallback? onOpen;
  /// Play this download. Null for a book with no audio files.
  final VoidCallback? onPlay;
  /// Read the cached ebook. Null when there is no ebook on the phone.
  final VoidCallback? onRead;
  final String Function(int) formatBytes;
  final Map<String, String> mediaHeaders;
  /// Used when the record carries no cover URL of its own.
  final String? fallbackCoverUrl;

  const _DownloadCard({
    required this.info,
    required this.fileSize,
    required this.cs,
    required this.tt,
    required this.selecting,
    required this.isSelected,
    this.hasEbook = false,
    required this.onToggle,
    this.onLongPress,
    this.onOpen,
    this.onPlay,
    this.onRead,
    required this.formatBytes,
    required this.mediaHeaders,
    this.fallbackCoverUrl,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    // A record with no cover URL of its own still has one on the server.
    final coverUrl = (info.coverUrl == null || info.coverUrl!.isEmpty)
        ? fallbackCoverUrl
        : info.coverUrl;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          onTap: selecting ? onToggle : onOpen,
          onLongPress: !selecting ? onLongPress : null,
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
                      coverUrl: coverUrl,
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
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              info.title ?? l.unknown,
                              style: tt.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // A quiet mark so the ebook half of a row is visible
                          // at a glance; the read button is its action.
                          if (hasEbook) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.menu_book_rounded,
                              size: 14,
                              color: cs.onSurfaceVariant,
                            ),
                          ],
                        ],
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
                  if (onPlay != null)
                    IconButton(
                      icon: Icon(
                        Icons.play_circle_outline_rounded,
                        color: cs.primary,
                        size: 26,
                      ),
                      tooltip: Wording.of(context).absorb,
                      onPressed: onPlay,
                    ),
                  if (onRead != null)
                    IconButton(
                      icon: Icon(
                        Icons.menu_book_rounded,
                        color: cs.primary,
                        size: 26,
                      ),
                      tooltip: l.readEbook,
                      onPressed: onRead,
                    ),
                ],
                if (selecting)
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
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
          useOldImageOnUrlChange: true,
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
  // Whether the book has an ebook on the device, known synchronously by the
  // list from the cached/exported id sets. Passing it in lets the sheet lay out
  // the audio/ebook split on its first frame instead of probing and re-flowing.
  final bool hasEbook;
  final String Function(int) formatBytes;

  const _TrackManagementSheet({
    required this.info,
    this.isPodcast = false,
    this.hasEbook = false,
    required this.formatBytes,
  });

  @override
  State<_TrackManagementSheet> createState() => _TrackManagementSheetState();
}

class _TrackManagementSheetState extends State<_TrackManagementSheet> {
  bool _deleting = false;
  bool _selecting = false;
  final Set<int> _selected = {};
  /// Which half of the download the selector shows (audio files or the ebook).
  _SheetPane _pane = _SheetPane.audio;
  // Real byte sizes of SAF tracks, resolved natively (Dart can't stat
  // content:// files). Empty until the probe lands.
  Map<String, int> _safSizes = const {};
  bool _safSizesLoaded = false;
  // The ebook cached or exported for this book, when it has one. Loaded once -
  // it only disappears with the whole download, which closes the sheet.
  Map<String, dynamic>? _ebookFile;
  int _ebookBytes = 0;
  // The ebook's real file name (what the user sees in their folder), resolved
  // from the stored item or a fresh fetch - never the book's title.
  String? _ebookName;
  // Whether this book has an ebook on the device at all (cached or exported).
  // Drives the audio/ebook split. Seeded from the list (which knows
  // synchronously) so the split is right on the very first frame.
  bool _hasEbook = false;
  bool _ebookReady = false;

  @override
  void initState() {
    super.initState();
    _hasEbook = widget.hasEbook;
    // An ebook-only book opens straight on the ebook half.
    if (widget.hasEbook && widget.info.localPaths.isEmpty) {
      _pane = _SheetPane.ebook;
    }
    unawaited(_loadEbook());
    final uris = widget.info.localPaths.where(isContentUri).toList();
    if (uris.isEmpty) {
      _safSizesLoaded = true;
      return;
    }
    // Seed from the sizes the list's last validate already probed, so rows and
    // the total don't visibly fill in a beat after the sheet opens. A fresh
    // probe then refines them, only repainting when something actually changed.
    final seeded = DownloadService().probedSafSizes;
    if (uris.every(seeded.containsKey)) {
      _safSizes = seeded;
      _safSizesLoaded = true;
    }
    DownloadService().getSafFileSizes(uris).then((sizes) {
      if (!mounted) return;
      if (_safSizesLoaded && mapEquals(sizes, _safSizes)) return;
      setState(() {
        _safSizes = sizes;
        _safSizesLoaded = true;
      });
    });
  }

  int _trackBytes(LocalTrackInfo t) {
    if (!t.isSaf) return t.sizeBytes;
    return t.sizeBytes + (_safSizes[t.path] ?? 0);
  }

  /// Loads the ebook half of this download, if the book has one on the phone.
  /// The sheet only reads it: an audiobook opens that same cached file for
  /// offline reading, so it leaves with the whole download, not on its own. An
  /// exported copy (in the download folder) counts too, so it can be read or
  /// deleted from here even when no cached copy exists.
  ///
  /// This never blocks the first frame: the split is laid out from
  /// [widget.hasEbook], and the name/size fill in as they resolve.
  Future<void> _loadEbook() async {
    final api = context.read<AuthProvider>().apiService;
    final cached = await cachedEbookFileFor(widget.info.itemId);
    // The list already told us whether an ebook is on the device, so when none
    // is cached it must be the exported copy - no SAF probe needed here.
    final exported = cached == null && widget.hasEbook;
    final hasEbook = cached != null || exported;
    final ebookFile =
        cached ??
        (exported
            ? resolveEbookFile(_sessionLibraryItem(widget.info.sessionData))
            : null);
    // The pane shows the file's real name, never the book title. The stored
    // session is the cheap source; an audiobook's session can omit the ebook
    // metadata, so fall back to the item's disk cache. A network refresh (if
    // any) is fired in the background so the sheet never waits on it.
    var name = _ebookNameFromItem(_sessionLibraryItem(widget.info.sessionData));
    if (hasEbook && name == null && api != null) {
      name = _ebookNameFromItem(
        await api.getCachedLibraryItem(widget.info.itemId),
      );
      if (name == null && mounted) {
        unawaited(
          api.getLibraryItem(widget.info.itemId).then((item) {
            final fresh = _ebookNameFromItem(item);
            if (fresh != null && mounted && _ebookName == null) {
              setState(() => _ebookName = fresh);
            }
          }),
        );
      }
    }
    var bytes = cached == null ? 0 : cachedEbookBytesSync(widget.info.itemId);
    if (exported) {
      bytes += await DownloadService().savedEbookBytes(widget.info.itemId);
    }
    if (!mounted) return;
    setState(() {
      _ebookFile = ebookFile;
      _ebookName = name;
      _hasEbook = hasEbook;
      _ebookBytes = bytes;
      _ebookReady = true;
      if (!_hasEbook) _pane = _SheetPane.audio;
    });
  }

  /// The ebook's real file name from a library item, or null when it has none.
  String? _ebookNameFromItem(Map<String, dynamic>? item) {
    if (item == null) return null;
    final ebookFile = resolveEbookFile(item);
    final name =
        ((ebookFile?['metadata'] as Map<String, dynamic>?)?['filename']
                as String?) ??
            ebookFile?['name'] as String?;
    final trimmed = name?.trim();
    return (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
  }

  /// The stored library item from this record's session JSON, used to open an
  /// ebook that only exists as an exported copy.
  Map<String, dynamic>? _sessionLibraryItem(String? sessionJson) {
    if (sessionJson == null) return null;
    try {
      final session = jsonDecode(sessionJson) as Map<String, dynamic>;
      return session['libraryItem'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openEbook() async {
    final l = AppLocalizations.of(context)!;
    final ebookFile =
        _ebookFile ?? await cachedEbookFileFor(widget.info.itemId);
    if (!mounted) return;
    if (ebookFile == null) {
      showOverlayToast(
        context,
        l.noEbookFileFound,
        icon: Icons.menu_book_outlined,
      );
      return;
    }
    await openEbookReader(
      context,
      itemId: widget.info.itemId,
      title: widget.info.title ?? '',
      ebookFile: ebookFile,
    );
  }

  /// Removes the ebook copy at the user's request, keeping the audio files. The
  /// service remembers the id so the startup catch-up does not fetch it back.
  Future<void> _deleteEbookCopy() async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text(l.downloadsRemoveEbookTitle),
        content: Text(l.downloadsRemoveEbookBody),
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
    final ds = DownloadService();
    await ds.deleteEbookCopy(widget.info.itemId);
    // Sweep the exported copy too: the "download" the user sees in their
    // folder is the real file, not just this cache.
    await ds.deleteSavedEbook(widget.info.itemId);
    if (!mounted) return;
    setState(() {
      _ebookFile = null;
      _ebookName = null;
      _ebookBytes = 0;
      _hasEbook = false;
      _pane = _SheetPane.audio;
    });
    showOverlayToast(
      context,
      l.downloadsRemovedTitle(widget.info.title ?? ''),
      icon: Icons.delete_outline_rounded,
    );
  }

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

  void _toggleSelectAll(List<LocalTrackInfo> tracks) {
    setState(() {
      if (tracks.isNotEmpty && _selected.length == tracks.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(tracks.map((t) => t.index));
      }
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
    await DownloadService().deleteLocalTracks(
      widget.info.itemId,
      _selected.toList(),
    );
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
          if (tracks.isEmpty && !_hasEbook) {
            // The last episode was removed: the download is gone. Wait for the
            // ebook probe before popping in case the list missed an ebook.
            if (_ebookReady) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) Navigator.pop(context);
              });
            }
            return const SizedBox(height: 200);
          }
          var totalBytes = 0;
          var selectedBytes = 0;
          for (final t in tracks) {
            totalBytes += _trackBytes(t);
            if (_selected.contains(t.index)) selectedBytes += _trackBytes(t);
          }
          final anySaf = tracks.any((t) => t.isSaf);
          // Per-track SAF sizes are resolvable now; the "no per-file size" hint
          // stays only for tracks the native probe couldn't measure.
          final anyUncountedSaf = _safSizesLoaded &&
              anySaf &&
              tracks.any((t) => t.isSaf && _trackBytes(t) <= 0);
          final canSelect = tracks.length > 1;
          final allSelected =
              tracks.isNotEmpty && _selected.length == tracks.length;
          final showGap = _hasGap(tracks);
          // The two halves of the sheet. The ebook opens on a tap of its name,
          // mirroring the audio files where tapping a row plays it.
          final ebookPane = <Widget>[
            if (_hasEbook)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: _openEbook,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.menu_book_rounded,
                              color: cs.primary,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _ebookName ?? l.downloadsEbooks,
                                style: tt.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 28),
                      child: Text(
                        widget.formatBytes(_ebookBytes),
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: Text(l.delete),
                        style: TextButton.styleFrom(
                          foregroundColor: cs.error,
                        ),
                        onPressed: _deleteEbookCopy,
                      ),
                    ),
                    const Divider(height: 1),
                  ],
                ),
              ),
          ];
          // The audio files, plus the two hints for tracks the app could not
          // measure.
          final audioPane = <Widget>[
            if (anyUncountedSaf)
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
                    if (t.durationSeconds > 0) _fmtDuration(t.durationSeconds),
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
                      !t.isSaf
                          ? (meta.isEmpty
                                ? widget.formatBytes(t.sizeBytes)
                                : meta)
                          : (_trackBytes(t) > 0
                                ? '${widget.formatBytes(_trackBytes(t))}'
                                      ' · ${l.downloadsStoredExternally}'
                                : l.downloadsStoredExternally),
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
                    trailing: _selecting
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
          ];
          // The split only appears when the book has both halves. With a single
          // half the pane for it is shown directly, no selector. Multi-select
          // belongs to the audio files, so flipping to the ebook leaves it.
          final showEbook =
              _hasEbook && (tracks.isEmpty || _pane == _SheetPane.ebook);
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
                                : (showEbook
                                      ? widget.formatBytes(_ebookBytes)
                                      : '${tracks.length} · '
                                            '${widget.formatBytes(totalBytes)}'),
                            style: tt.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_selecting) ...[
                      TextButton.icon(
                        icon: Icon(
                          allSelected
                              ? Icons.deselect_rounded
                              : Icons.select_all_rounded,
                          size: 18,
                          color: cs.onSurfaceVariant,
                        ),
                        label: Text(
                          allSelected ? l.deselectAll : l.selectAll,
                        ),
                        onPressed: () => _toggleSelectAll(tracks),
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
                      if (canSelect && !showEbook)
                        IconButton(
                          icon: Icon(
                            Icons.checklist_rounded,
                            color: cs.onSurfaceVariant,
                          ),
                          tooltip: l.downloadsSelect,
                          onPressed: () => setState(() {
                            _pane = _SheetPane.audio;
                            _selecting = true;
                          }),
                        ),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: cs.onSurfaceVariant,
                        ),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ],
                ),
              ),
              // A download with both an audio copy and an ebook has two halves
              // to look at, so let the user pick one. A single half shows on its
              // own without this selector, and multi-select shows a single pane.
              if (tracks.isNotEmpty && _hasEbook && !_selecting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: SegmentedButton<_SheetPane>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: [
                      ButtonSegment(
                        value: _SheetPane.audio,
                        icon: const Icon(Icons.graphic_eq_rounded, size: 16),
                        label: Text(l.downloadsAudioFiles),
                      ),
                      ButtonSegment(
                        value: _SheetPane.ebook,
                        icon: const Icon(Icons.menu_book_rounded, size: 16),
                        label: Text(l.downloadsEbooks),
                      ),
                    ],
                    selected: {_pane},
                    onSelectionChanged: (sel) {
                      setState(() {
                        _pane = sel.first;
                        if (_pane == _SheetPane.ebook) {
                          _selecting = false;
                          _selected.clear();
                        }
                      });
                    },
                  ),
                ),
              ...(showEbook ? ebookPane : audioPane),
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

/// Which half of a download the file manager shows. Only used when the book has
/// an ebook: the selector then flips between the audio files and the copy.
enum _SheetPane { audio, ebook }
