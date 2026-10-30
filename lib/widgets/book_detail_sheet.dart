import 'package:flutter_svg/flutter_svg.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'overlay_toast.dart';
import 'narration_download_dialog.dart';
import '../services/media_overlay.dart';
import '../services/narration_service.dart';
import '../services/read_listen_sync.dart';
import '../services/book_dock.dart';
import '../services/bookorbit_mapper.dart';
import 'absorb_placement.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../utils/cover_accent.dart';
import '../utils/series_id.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../utils/read_status.dart';
import 'book_stats_sheet.dart';
import 'book_activity_card.dart';
import '../screens/reading_log_screen.dart';
import '../services/book_stats_service.dart';
import '../services/wording.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import 'card_buttons.dart';
import 'download_confirm.dart';
import '../services/api_service.dart';
import '../services/bookmark_preview_player.dart';
import '../services/bookmark_service.dart';
import '../services/download_service.dart';
import '../services/narrated_books.dart';
import 'book_files_sheet.dart';
import '../services/transcription_service.dart';
import '../services/ebook_cache.dart';
import '../services/ebook_preferences.dart';
import '../services/inflight_temp_writes.dart';
import '../services/progress_sync_service.dart';
import '../services/metadata_override_service.dart';
import '../services/socket_service.dart';
import '../main.dart' show rootNavigatorKey, colorSourceNotifier, useColorEverywhereNotifier, manualSeedNotifier, manualColorScheme;
import '../screens/app_shell.dart';
import '../screens/book_edit_screen.dart';
import 'author_books_sheet.dart';
import 'narrator_books_sheet.dart';
import 'series_books_sheet.dart';
import 'absorbing_shared.dart';
import 'html_description.dart';
import 'metadata_lookup_sheet.dart';
import 'playlist_picker_sheet.dart';
import 'collection_picker_sheet.dart';
import 'delete_confirm_dialog.dart';
import 'absorb_wave_icon.dart';
import 'stackable_sheet.dart';
import 'ebook_router.dart';
import '../utils/duration_format.dart';
import '../utils/share_origin.dart';

// ─── BOOK DETAIL BOTTOM SHEET ───────────────────────────────

/// Palette derivation decodes the full-res cover and quantizes it — a few
/// hundred ms of main-thread work. Running it while the sheet's open animation
/// plays stalls the opening frames and flashes a different background into the
/// still-running animation; deferring it until the sheet settles and caching
/// the derived scheme per (brightness, cover) keeps repeat opens jank-free.
final Map<String, ColorScheme> _coverSchemeCache = {};

/// [initialItem] is the tile's library-item map: pass it so the detail sheet
/// paints the known fields (title, cover, actions) instantly and refines the
/// rest in the background, instead of spinning until the server round-trip.
void showBookDetailSheet(
  BuildContext context,
  String itemId, {
  Map<String, dynamic>? initialItem,
  String? sourcePlaylistId,
  String? sourceCollectionId,
  String? sourceCollectionName,
}) {
  showStackableSheet(
    context: context,
    useSafeArea: true,
    initialChildSize: 0.85,
    maxChildSize: 0.95,
    builder: (ctx, sc) => _BookDetailSheetContent(
      itemId: itemId,
      scrollController: sc,
      initialItem: initialItem,
      sourcePlaylistId: sourcePlaylistId,
      sourceCollectionId: sourceCollectionId,
      sourceCollectionName: sourceCollectionName,
    ),
  );
}

/// Long-press shortcut: a compact sheet with Absorb + Download up top and the
/// full set of book actions as pills, skipping the trip into the detail sheet.
/// Pass [initialItem] (the tile's library-item map) so it renders instantly.
void showQuickActionsSheet(
  BuildContext context,
  String itemId, {
  Map<String, dynamic>? initialItem,
  String? sourcePlaylistId,
  String? sourceCollectionId,
  String? sourceCollectionName,
}) {
  showStackableSheet(
    context: context,
    useSafeArea: true,
    initialChildSize: 0.6,
    maxChildSize: 0.92,
    builder: (ctx, sc) => _BookDetailSheetContent(
      itemId: itemId,
      scrollController: sc,
      quick: true,
      initialItem: initialItem,
      sourcePlaylistId: sourcePlaylistId,
      sourceCollectionId: sourceCollectionId,
      sourceCollectionName: sourceCollectionName,
    ),
  );
}

class BookDetailInfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const BookDetailInfoChip({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pill = Container(
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: onTap != null
            ? cs.tertiary.withValues(alpha: 0.10)
            : cs.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: onTap != null
              ? cs.tertiary.withValues(alpha: 0.30)
              : cs.onSurface.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: onTap != null
                ? cs.tertiary
                : cs.onSurface.withValues(alpha: 0.3),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(
                color: onTap != null ? cs.tertiary : cs.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return pill;
    return GestureDetector(onTap: onTap, child: pill);
  }
}

class _BookDetailSheetContent extends StatefulWidget {
  final String itemId;
  final ScrollController scrollController;
  final bool quick;
  final Map<String, dynamic>? initialItem;
  final String? sourcePlaylistId;
  final String? sourceCollectionId;
  final String? sourceCollectionName;
  const _BookDetailSheetContent({
    required this.itemId,
    required this.scrollController,
    this.quick = false,
    this.initialItem,
    this.sourcePlaylistId,
    this.sourceCollectionId,
    this.sourceCollectionName,
  });
  @override State<_BookDetailSheetContent> createState() => _BookDetailSheetContentState();
}

class _BookDetailSheetContentState extends State<_BookDetailSheetContent> with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _item;
  Map<String, dynamic>? _rating;
  String? _asin;
  // BookOrbit only: its "more like this" picks for the book.
  List<Map<String, dynamic>> _similar = const [];
  bool _similarLoaded = false;
  bool _savingStatus = false;
  // A Book Dock action (filing, removing, using found details) is running.
  bool _dockBusy = false;
  // Re-reads a dock file while the server is still reading or looking it
  // up; BookOrbit tells its web page over a socket Absorb doesn't keep.
  Timer? _dockPoll;
  bool _isLoading = true;
  bool _seededFromCache = false;
  bool _bookmarksExpanded = false;
  bool _chaptersExpanded = false;
  BookmarkPreviewPlayer? _preview;
  bool? _loggedPreviewVisible;
  List<Bookmark> _bookmarks = [];
  bool _isAbsorbing = false;
  bool _hasLocalOverride = false;
  bool _showGoodreads = false;
  bool _ebookSaved = false;
  bool _ebookOfflineDownloading = false;
  bool _authorsExpanded = false;
  bool _narratorsExpanded = false;
  bool _squareCovers = false;
  bool _isUpdatingProgressDate = false;
  bool _speedAdjustedTime = false;
  double _savedSpeed = 1.0;
  // Ebook synthesized from the offline reader cache, for downloads whose
  // persisted metadata predates the trimmed-libraryItem fix. Read-only
  // surfaces fall back to it; Save/Send still need the server's file entry.
  Map<String, dynamic>? _cachedEbookFallback;
  // The main grid only needs local, fast reads: per-item settings plus a
  // non-null item (the quick sheet seeds one from its tile instantly). The
  // three eBook pills depend on the server's file entry, which can lag several
  // seconds on an uncached book over a weak link — so they're deliberately
  // kept OUT of this gate and appended to the grid's tail as keyed fade-ins
  // (see _actionPillGrid), never holding the rest of the actions hostage.
  bool _settingsDone = false;
  bool get _pillsReady => _settingsDone && _item != null;
  ColorScheme? _rawCoverScheme;

  void _markSettingsDone() {
    _settingsDone = true;
    if (mounted && _pillsReady) setState(() {});
  }
  String? _coverSchemeUrl; // URL the current scheme was derived from
  Timer? _coverSchemeTimer;
  // Cross-fades a new cover-derived scheme over the current one so the accent
  // and background don't pop in harshly the moment the palette resolves.
  late final AnimationController _schemeAnim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
  late final Animation<double> _schemeCurve = CurvedAnimation(
      parent: _schemeAnim, curve: Curves.easeInOutCubic)
    ..addListener(() {
      if (mounted && !_dismissing) setState(() {});
    });

  /// Set once the sheet starts closing (drag past a slack, or the modal route
  /// reversing). Stops the cover cross-fade mid-flight so exiting never
  /// rebuilds the whole sheet every frame while the dismiss animation plays —
  /// which otherwise hitches the exit right after the palette resolves.
  bool _dismissing = false;
  Animation<double>? _routeAnim;
  bool _routeHooked = false;

  void _beginDismissal() {
    if (_dismissing) return;
    _dismissing = true;
    _coverSchemeTimer?.cancel();
    if (_schemeAnim.isAnimating) _schemeAnim.stop();
  }

  void _onRouteAnimChanged() {
    if (!_dismissing && _routeAnim?.status == AnimationStatus.reverse) {
      _beginDismissal();
    }
  }

  void _onSheetScroll() {
    if (_dismissing) return;
    final sc = widget.scrollController;
    // Pulling the sheet down past a slack is the drag-to-dismiss gesture; stop
    // the fade rebuilds during the drag, before the route reverse commits.
    if (sc.hasClients && sc.offset < -48) _beginDismissal();
  }

  double get _displaySpeed {
    if (!_speedAdjustedTime) return 1.0;
    final player = AudioPlayerService();
    return player.currentItemId == widget.itemId ? player.speed : _savedSpeed;
  }

  /// The cover-derived scheme, unless the user has chosen a manual app color
  /// and opted to use it everywhere - then book pages wear that color too.
  ColorScheme? get _coverScheme {
    if (colorSourceNotifier.value == 'manual' && useColorEverywhereNotifier.value) {
      return manualColorScheme(manualSeedNotifier.value, Theme.of(context).brightness);
    }
    final target = _rawCoverScheme;
    if (target == null) return null;
    final from = Theme.of(context).colorScheme;
    if (!_schemeAnim.isAnimating) return target;
    return ColorScheme.lerp(from, target, _schemeCurve.value);
  }

  /// Update the cover-derived scheme with a smooth cross-fade. Every resolution
  /// fades in from the app's neutral color scheme (never from whatever tint was
  /// shown before), so switching between books always starts from the theme
  /// color instead of bleeding the previous book's palette into the fade.
  void _applyCoverScheme(ColorScheme? target) {
    if (target == null || !mounted || _dismissing) return;
    if (!_schemeAnim.isAnimating && target == _coverScheme) return;
    setState(() {
      _rawCoverScheme = target;
    });
    _schemeAnim.forward(from: 0);
  }

  // An Audiobookshelf ebook-only book whose EPUB reads itself aloud: the
  // sheet shows it as an audiobook, the way BookOrbit's arrive.
  MediaOverlay? _localNarration;
  // An EPUB this phone hasn't looked into yet is being looked at: the main
  // button waits for the answer rather than showing Read and then switching
  // to Absorb.
  bool _lookingForNarration = false;
  // Whether the automatic reading and listening sync is on; with it off, an
  // audiobook with an EPUB gets a Sync position button.
  bool _autoSync = true;
  // Transcription on with a model downloaded, which Sync position needs.
  bool _transcriptionReady = false;

  /// Looks into an Audiobookshelf ebook-only EPUB on the server (its index
  /// and timings only) to see whether it reads itself aloud.
  Future<void> _probeNarration() async {
    final item = _item;
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (item == null || api == null || auth.isBookOrbit || _localNarration != null) return;
    if (!PlayerSettings.isEbookOnly(item, countNarration: false)) return;
    final ebookFile = resolveEbookFile(item);
    final unknown = ebookFile != null &&
        ebookExtFromFile(ebookFile) == '.epub' &&
        !NarratedBooks.checked(widget.itemId);
    if (unknown) {
      setState(() => _lookingForNarration = true);
      // A slow server doesn't hold the buttons back for long.
      Timer(const Duration(seconds: 8), () {
        if (mounted && _lookingForNarration) {
          debugPrint('[Narration] ${widget.itemId}: still looking after 8s, showing the ebook buttons');
          setState(() => _lookingForNarration = false);
        }
      });
    }
    MediaOverlay? o;
    // A look that fails (rather than finding no narration) gets one more go,
    // so a hiccup doesn't leave a narrated EPUB showing as a plain ebook.
    for (var attempt = 1; attempt <= 2 && mounted; attempt++) {
      try {
        o = await NarrationService.instance.probe(api, item, onNarrated: (duration) {
          // The package says it reads itself aloud: that settles the buttons
          // while the timings are still coming.
          if (duration == null || duration <= 0 || !mounted) return;
          debugPrint('[Narration] ${widget.itemId}: narrated by its package - showing it as an audiobook now');
          unawaited(NarratedBooks.set(widget.itemId, duration).then((_) {
            if (mounted && _lookingForNarration) setState(() => _lookingForNarration = false);
          }));
        });
        if (o != null) await NarrationService.instance.markAudiobook(widget.itemId, o);
        final known = await NarrationService.instance.knownNarrated(widget.itemId);
        // Looked at before the list kept plain EPUBs too.
        if (o == null && known == false && !NarratedBooks.checked(widget.itemId)) {
          await NarratedBooks.set(widget.itemId, null);
        }
        if (o != null || known != null) break;
        debugPrint('[Narration] ${widget.itemId}: the EPUB on the server could not be looked into '
            '(try $attempt of 2)');
      } catch (e) {
        debugPrint('[Narration] ${widget.itemId}: looking for narration failed (try $attempt of 2): $e');
      }
      if (attempt == 1) await Future.delayed(const Duration(seconds: 2));
    }
    if (!mounted) return;
    setState(() {
      _localNarration = o;
      _lookingForNarration = false;
    });
  }

  Future<void> _checkTranscriptionReady() async {
    if (!await PlayerSettings.getTranscriptionEnabled()) return;
    for (final size in TranscriptionModelSize.values) {
      if (await TranscriptionService.instance.isModelDownloaded(size)) {
        if (mounted) setState(() => _transcriptionReady = true);
        return;
      }
    }
  }

  /// An Audiobookshelf EPUB that reads itself aloud plays from the phone, so
  /// until its narration is downloaded the Absorb button offers that instead.
  /// An Audiobookshelf narrated EPUB streams from the server, so only one
  /// that isn't on the phone while offline has to be downloaded first.
  bool _needsNarrationDownload(AuthProvider auth) =>
      !auth.isBookOrbit &&
      context.read<LibraryProvider>().isOffline &&
      (NarratedBooks.contains(widget.itemId) ||
          ((_item?['media'] as Map?)?['narration'] as Map?)?['local'] == true) &&
      !NarrationService.instance.hasLocalAudio(widget.itemId);

  Widget _lookingButton(Color accent, Color onAccent, {double height = 52, double radius = 16}) => SizedBox(
        height: height,
        child: Material(
          color: accent.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(radius),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: onAccent),
            ),
          ),
        ),
      );

  @override void initState() {
    super.initState();
    // Quick-actions sheet seeds from the tile's item map so it paints instantly
    // instead of flashing a spinner; _loadItem still runs to refine overrides.
    if (widget.initialItem != null) {
      _item = widget.initialItem;
      _isLoading = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scheduleCoverScheme();
      });
    }
    if (widget.quick) {
      Future.delayed(_coverSchemeDeriveDelay, () {
        if (mounted) _loadItem();
      });
    } else {
      _loadItem();
    }
    if (!widget.quick) _loadBookmarks();
    _warmStats();
    PlayerSettings.getSyncReadingListening().then((on) {
      if (mounted && on != _autoSync) setState(() => _autoSync = on);
    });
    _checkTranscriptionReady();
    SocketService().addItemUpdatedListener(_onSocketItemUpdated);
    _loadQuickSettings().whenComplete(_markSettingsDone);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeHooked) return;
    _routeHooked = true;
    // Watch the modal route so exit-during-cross-fade stops the tint animation
    // instead of rebuilding the whole sheet every frame of the dismiss.
    final route = ModalRoute.of(context);
    _routeAnim = route?.animation;
    _routeAnim?.addListener(_onRouteAnimChanged);
    widget.scrollController.addListener(_onSheetScroll);
  }

  /// Lightweight per-item settings/state reads. Each result only paints
  /// secondary UI (rectangle covers, Goodreads button, speed label, saved
  /// indicators), so they're batched into a single [Future.wait] and one
  /// setState instead of six staggered full-sheet rebuilds during the sheet's
  /// open animation.
  Future<void> _loadQuickSettings() async {
    final results = await Future.wait<Object?>([
      PlayerSettings.getRectangleCovers().then<bool>((v) => v),
      PlayerSettings.getShowGoodreadsButton().then<bool>((v) => v),
      PlayerSettings.getSpeedAdjustedTime().then<bool>((v) => v),
      PlayerSettings.getBookSpeed(widget.itemId).then<double?>((v) => v),
      DownloadService()
          .savedEbookCopyExists(widget.itemId)
          .then<bool>((v) => v),
      PlayerSettings.getDefaultSpeed().then<double?>((v) => v),
      cachedEbookFileFor(widget.itemId).then<Map<String, dynamic>?>((v) => v),
    ]);
    if (!mounted) return;
    setState(() {
      _squareCovers = !(results[0] as bool);
      _showGoodreads = results[1] as bool;
      _speedAdjustedTime = results[2] as bool;
      _savedSpeed = (results[3] as num?)?.toDouble() ??
          (results[5] as num?)?.toDouble() ??
          1.0;
      _ebookSaved = results[4] as bool;
      if (!_ebookSaved) {
        // The copy was recorded but its file no longer exists (deleted outside
        // the app) - drop the stale "exported" state so the button offers
        // "export" again the next time this sheet opens.
        unawaited(DownloadService().clearSavedEbook(widget.itemId));
      }
      _cachedEbookFallback = results[6] as Map<String, dynamic>?;
    });
  }

  @override
  void dispose() {
    SocketService().removeItemUpdatedListener(_onSocketItemUpdated);
    _liveRefreshDebounce?.cancel();
    _coverSchemeTimer?.cancel();
    _dockPoll?.cancel();
    _preview?.removeListener(_onPreviewChanged);
    _preview?.dispose();
    _routeAnim?.removeListener(_onRouteAnimChanged);
    widget.scrollController.removeListener(_onSheetScroll);
    super.dispose();
    _schemeAnim.dispose();
  }

  // Live-refresh when this item changes on the server (web UI edit, scan,
  // match) so an open sheet shows the new cover/metadata without reopening.
  Timer? _liveRefreshDebounce;
  void _onSocketItemUpdated(Map<String, dynamic> data) {
    if (!mounted || data['id'] != widget.itemId) return;
    _liveRefreshDebounce?.cancel();
    _liveRefreshDebounce = Timer(const Duration(milliseconds: 800), () {
      if (mounted) _loadItem();
    });
  }

  bool _finishedChaptersExpanded = false;

  /// Start the stats load (own sessions, and the server-wide scan for
  /// admins) the moment the sheet opens, so the stats card fills in on its
  /// own and the stats sheet opens on numbers already fetched or already on
  /// their way instead of starting over.
  void _warmStats() {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) return;
    unawaited(BookStatsService.instance
        .ensureLoaded(widget.itemId, api, isAdmin: auth.isAdmin));
  }

  Widget _listeningStatsBlock(BuildContext context, ColorScheme cs, TextTheme tt, Color accent, String title) {
    final auth = context.read<AuthProvider>();
    final bookOrbit = auth.apiService?.isBookOrbit == true;
    return BookActivityCard(
      itemId: widget.itemId,
      bookOrbit: bookOrbit,
      accent: accent,
      me: auth.username,
      onOpen: () => bookOrbit
          ? Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
              builder: (_) => ReadingLogScreen(itemId: widget.itemId, title: title, item: _item, accent: accent)))
          : showBookStatsSheet(context, itemId: widget.itemId, title: title),
      onOthers: () => showBookStatsSheet(context, itemId: widget.itemId, title: title),
      onAllSessions: bookOrbit
          ? null
          : () => showPlaybackHistorySheet(
                context,
                itemId: widget.itemId,
                initialTab: PlaybackHistoryTab.sessions,
                accent: accent,
              ),
    );
  }

  Future<void> _loadBookmarks() async {
    final bm = await BookmarkService().getBookmarks(widget.itemId, sort: 'position');
    if (mounted) setState(() => _bookmarks = bm);
  }

  /// The cover shape set for the book's own library (or the one being
  /// browsed until the book has loaded), the same lookup the cards use.
  void _loadCoverShape() {
    final libraryId = _item?['libraryId'] as String? ??
        context.read<LibraryProvider>().selectedLibraryId;
    PlayerSettings.getRectangleCoversFor(libraryId).then((rect) {
      if (mounted && _squareCovers == rect) setState(() => _squareCovers = !rect);
    });
  }

  Future<void> _loadItem() async {
    debugPrint('[BookDetail] _loadItem start item=${widget.itemId}');
    final loadStart = DateTime.now();
    // Force re-derivation of cover scheme on reload (cover may have changed).
    _coverSchemeUrl = null;
    final auth = context.read<AuthProvider>();
    final lib = context.read<LibraryProvider>();
    final api = auth.apiService;

    // Paint the on-disk full-detail cache before touching the network: the
    // initialItem passed from a tile is minified (no chapters), and the server
    // fetch below can spend tens of seconds on a weak link. Only the first
    // load seeds, so live item-update callbacks don't resurrect a stale
    // snapshot over the newer data they were triggered by.
    // The quick sheet already painted its initialItem; this seed is deferred
    // until after the open animation (see initState), so the disk-cache decode
    // below won't land on a compositor frame, and the full item it yields also
    // feeds the eBook pills.
    if (api != null && !_seededFromCache) {
      _seededFromCache = true;
      final cached = await api.getCachedLibraryItem(widget.itemId);
      if (cached != null && mounted) {
        final override = await MetadataOverrideService().get(widget.itemId);
        setState(() {
          _item = override != null
              ? MetadataOverrideService().applyOverrides(cached, override)
              : cached;
          _hasLocalOverride = override != null;
          _isLoading = false;
        });
        _scheduleCoverScheme();
      }
    }

    // Try server first
    if (api != null && !lib.isOffline) {
      try {
        final item = await api.getLibraryItem(widget.itemId);
        debugPrint('[BookDetail] server fetch done in ${DateTime.now().difference(loadStart).inMilliseconds}ms (item=${item != null ? "ok" : "null"})');
        if (item != null && mounted) {
          // Apply local metadata overrides
          final overrideService = MetadataOverrideService();
          final override = await overrideService.get(widget.itemId);
          Map<String, dynamic> finalItem = item;
          if (override != null) {
            finalItem = overrideService.applyOverrides(item, override);
            _hasLocalOverride = true;
          }

          // Refreshing overrides shouldn't force a full-sheet rebuild while
          // the sheet is still animating in/out: if nothing visible changed,
          // keep the fresh data without a rebuild so the animation stays at 60fps.
          if (_visuallySameItem(finalItem)) {
            _item = finalItem;
          } else {
            setState(() { _item = finalItem; _isLoading = false; });
          }
          unawaited(_probeNarration());
          _loadCoverShape();
          if (BookDockInfo.of(finalItem)?.isWorking ?? false) {
            _dockPoll?.cancel();
            _dockPoll = Timer(const Duration(seconds: 3), () {
              if (mounted) _loadItem();
            });
          }
          _scheduleCoverScheme();
          if (api.isBookOrbit && !_similarLoaded && !ApiService.isBookDockItem(widget.itemId)) {
            _similarLoaded = true;
            unawaited(_loadSimilar(api));
          }
          // Server item is in: the eBook pills can fade in via the grid's
          // trailing dynamic section on the rebuild this block triggers.

          // Fetch Audible rating
          final media = finalItem['media'] as Map<String, dynamic>? ?? {};
          final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
          final asin = metadata['asin'] as String?;
          final title = metadata['title'] as String? ?? '';
          final author = metadata['authorName'] as String?;

          // Show any cached rating immediately so the stars don't blink in
          // and out between detail opens. The fresh fetch below replaces it
          // if Audnexus answers; if it doesn't, the cached value stays.
          final cached = await ApiService.getCachedAudibleRating(widget.itemId);
          if (cached != null && mounted) {
            setState(() {
              _rating = cached;
              _asin = cached['asin'] as String? ?? asin;
            });
          }

          Map<String, dynamic>? rating;
          if (asin != null && asin.isNotEmpty) {
            rating = await ApiService.getAudibleRating(asin);
          }
          if ((rating == null || (rating['rating'] as num).toDouble() <= 0) &&
              title.isNotEmpty) {
            final fallback = await api.searchAudibleRating(title, author);
            if (fallback != null && (fallback['rating'] as num).toDouble() > 0) {
              rating = fallback;
            }
          }
          if (rating != null && mounted) {
            final freshRating = (rating['rating'] as num).toDouble();
            final freshAsin = rating['asin'] as String? ?? asin;
            setState(() {
              _rating = rating;
              _asin = freshAsin;
            });
            await ApiService.setCachedAudibleRating(
                widget.itemId, freshRating, freshAsin,
                count: (rating['count'] as num?)?.toInt());
          }
          return;
        }
      } catch (_) {
        // Server unreachable — fall through to offline
      }
    }

    // Offline fallback: build item from local download data
    final dl = DownloadService().getInfo(widget.itemId);
    final sessionData =
        dl.sessionData ?? DownloadService().keptEbook(widget.itemId)?.sessionData;
    if (sessionData != null) {
      try {
        final session = jsonDecode(sessionData) as Map<String, dynamic>;
        // Prefer full libraryItem if it wasn't stripped
        final localItem = session['libraryItem'] as Map<String, dynamic>?;
        if (localItem != null && mounted) {
          setState(() { _item = localItem; _isLoading = false; });
          _scheduleCoverScheme();
          return;
        }
        // Build a synthetic item from session-level fields (mediaMetadata,
        // chapters, duration) which survive the libraryItem strip.
        final meta = session['mediaMetadata'] as Map<String, dynamic>?;
        if (meta != null && mounted) {
          setState(() {
            _item = {
              'id': widget.itemId,
              'media': {
                'metadata': meta,
                'duration': session['duration'],
                'chapters': session['chapters'],
              },
            };
            _isLoading = false;
          });
          _scheduleCoverScheme();
          return;
        }
      } catch (_) {}
    }
    // Minimal fallback from DownloadInfo metadata
    if (dl.title != null && mounted) {
      setState(() {
        _item = {
          'id': widget.itemId,
          'media': {
            'metadata': {
              'title': dl.title,
              'authorName': dl.author ?? '',
            },
          },
        };
        _isLoading = false;
      });
      _scheduleCoverScheme();
      return;
    }

    if (mounted) setState(() => _isLoading = false);
  }

  /// Palette generation happens on the main isolate; running it while the
  /// sheet's slide-up animation is playing stalls the opening frames and flips
  /// the cover-derived background mid-animation. Wait for the animation to
  /// settle, then derive (or reuse the cached scheme for this cover).
  static const _coverSchemeDeriveDelay = Duration(milliseconds: 450);

  void _scheduleCoverScheme() {
    _coverSchemeTimer?.cancel();
    _coverSchemeTimer = Timer(_coverSchemeDeriveDelay, () {
      if (mounted) _deriveCoverScheme();
    });
  }

  void _deriveCoverScheme() {
    try {
    final url = _coverUrl;
    if (url == null) {
      debugPrint('[BookDetail] _deriveCoverScheme skipped (no cover url)');
      return;
    }
    // Skip if the scheme was already derived from this exact URL.
    if (url == _coverSchemeUrl) {
      debugPrint('[BookDetail] _deriveCoverScheme skipped (cached for this url)');
      return;
    }
    _coverSchemeUrl = url;
    final brightness = Theme.of(context).brightness;
    // Cached across sheet opens: the palette decode is expensive and the cover
    // rarely changes, so repeat visits reuse the derived scheme without
    // touching the image again.
    final cacheKey = '$brightness|$url';
    final cachedScheme = _coverSchemeCache[cacheKey];
    if (cachedScheme != null) {
      _applyCoverScheme(cachedScheme);
      return;
    }
    final ImageProvider provider;
    if (url.startsWith('/')) {
      // Bound the decode: the palette only needs a coarse tint, and decoding
      // the full-res cover here stalls the main isolate right about when the
      // sheet settles and the user starts scrolling.
      provider = ResizeImage(FileImage(File(url)), width: 240, height: 240);
    } else {
      final lib = context.read<LibraryProvider>();
      provider = ResizeImage(
          CachedNetworkImageProvider(url, headers: lib.mediaHeaders),
          width: 240,
          height: 240);
    }
    final t0 = DateTime.now();
    debugPrint('[BookDetail] _deriveCoverScheme start url=$url');
    PaletteGenerator.fromImageProvider(provider, maximumColorCount: 16)
        .then((palette) {
      debugPrint('[BookDetail] PaletteGenerator ok in ${DateTime.now().difference(t0).inMilliseconds}ms');
      final seedColor = accentFromCoverPalette(palette);
      if (seedColor == null || !mounted || _dismissing) return;
      final scheme = ColorScheme.fromSeed(
          seedColor: seedColor, brightness: brightness);
      _coverSchemeCache[cacheKey] = scheme;
      _applyCoverScheme(scheme);
    }).catchError((e) {
      debugPrint('[BookDetail] PaletteGenerator error after ${DateTime.now().difference(t0).inMilliseconds}ms: $e');
      if (!mounted || _dismissing) return;
      setState(() => _coverSchemeUrl = null);
      _applyCoverScheme(ColorScheme.fromSeed(
        seedColor: Theme.of(context).colorScheme.primary,
        brightness: brightness,
      ));
    });
    } catch (e) {
      debugPrint('[BookDetail] _deriveCoverScheme failed (non-fatal): $e');
    }
  }

  String? get _coverUrl {
    final localCover = _item?['_localCoverUrl'] as String?;
    if (localCover != null && localCover.isNotEmpty) return localCover;
    final media = _item?['media'] as Map<String, dynamic>?;
    final coverPath = media?['coverPath'] as String?;
    if (coverPath == null || coverPath.isEmpty) return null;
    return context.read<LibraryProvider>().getCoverUrl(widget.itemId, width: 800);
  }

  /// Full-res cover for the viewer and sharing.
  String? get _fullResCoverUrl {
    final localCover = _item?['_localCoverUrl'] as String?;
    if (localCover != null && localCover.isNotEmpty) return localCover;
    final media = _item?['media'] as Map<String, dynamic>?;
    final coverPath = media?['coverPath'] as String?;
    if (coverPath == null || coverPath.isEmpty) return null;
    return context.read<LibraryProvider>().getCoverUrl(widget.itemId, width: 4000);
  }


  /// Placeholder matching the detail sheet's header + primary actions + pill
  /// grid, so an uncached first open (no [initialItem] available, e.g. search
  /// results) paints a calm silhouette instead of a bare spinner, then
  /// cross-fades into the loaded content via the AnimatedSwitcher in build.
  Widget _detailLoadingSkeleton(ColorScheme cs, TextTheme tt) {
    final base = cs.surfaceContainerHighest.withValues(alpha: 0.55);
    Widget block(double w, double h, {double r = 6}) => Container(
          width: w, height: h,
          decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(r)));
    final width = MediaQuery.of(context).size.width;
    return SingleChildScrollView(
      key: const ValueKey('loading'),
      controller: widget.scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + MediaQuery.of(context).viewPadding.bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          block(56, 56, r: 10),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            block(width * 0.55, 18),
            const SizedBox(height: 8),
            block(width * 0.32, 14),
          ])),
        ]),
        const SizedBox(height: 18),
        block(width - 40, 44, r: 12),
        const SizedBox(height: 10),
        block(width - 40, 40, r: 12),
        const SizedBox(height: 18),
        Wrap(spacing: 10, runSpacing: 10,
          children: List.generate(6, (i) => block((width - 40 - 20) / 3, 80, r: 16))),
      ]),
    );
  }

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: Stack(children: [
        // Cover-derived color gradient background - lighter than blurred image.
        Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          stops: const [0.0, 0.4, 1.0],
          colors: [
            (_coverScheme?.primaryContainer ?? Theme.of(context).scaffoldBackgroundColor).withValues(alpha: 0.5),
            Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.85),
            Theme.of(context).scaffoldBackgroundColor,
          ],
        )))),
        // Don't block sheet rendering on cover-scheme palette generation -
        // on iOS it can stall indefinitely when a download is saturating the
        // connection pool, leaving the sheet stuck with an undismissable
        // spinner. Accent colors fall back to the default scheme until the
        // palette resolves. Loading/failed states are wrapped in a scrollable
        // so drag-to-dismiss works even before content arrives.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: _isLoading
              ? _detailLoadingSkeleton(cs, tt)
              : _item == null
                  ? SingleChildScrollView(
                      key: const ValueKey('failed'),
                      controller: widget.scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SizedBox(
                        height: MediaQuery.of(context).size.height * 0.85,
                        child: Center(child: Text(l.failedToLoad, style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
                      ),
                    )
                  : AnimatedOpacity(
                      key: const ValueKey('content'),
                      opacity: 1.0, duration: const Duration(milliseconds: 300),
                      child: BookDockInfo.of(_item) != null
                          ? _buildDockContent(context, cs, tt, l, BookDockInfo.of(_item)!)
                          : widget.quick
                              ? _buildQuickContent(context, cs, tt, l)
                              : _buildContent(context, cs, tt, l)),
        ),
      ]),
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme cs, TextTheme tt, AppLocalizations l) {
    final accent =
        (PlayerSettings.einkMode ? null : _coverScheme?.primary) ?? cs.primary;
    // A reload brings the server's ebook-only shape back; the narration found
    // on this phone makes it an audiobook again.
    final narration = _localNarration;
    if (narration != null) _item = NarrationService.instance.withNarration(_item!, narration);
    final media = _item!['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final chapters = media['chapters'] as List<dynamic>? ?? [];
    final title = metadata['title'] as String? ?? l.unknown;
    final subtitle = metadata['subtitle'] as String? ?? '';
    final authorName = metadata['authorName'] as String? ?? '';
    final descRaw = metadata['description'] as String? ?? '';
    final duration = (media['duration'] as num?)?.toDouble() ?? 0;
    final seriesEntries = metadata['series'] as List<dynamic>? ?? [];
    final genres = (metadata['genres'] as List<dynamic>?)?.cast<String>() ?? [];
    // ABS puts tags on the media object (LibraryItem.media.tags), not in
    // metadata. Some endpoints may stash them in metadata too — fall back to
    // that if media doesn't have them.
    final tagsRaw = (media['tags'] as List<dynamic>?)
        ?? (metadata['tags'] as List<dynamic>?)
        ?? const [];
    final tags = tagsRaw.cast<String>();
    final publisher = metadata['publisher'] as String? ?? '';
    final year = metadata['publishedYear'] as String? ?? '';
    final lib = context.watch<LibraryProvider>();
    final progress = lib.getProgress(widget.itemId);
    final auth = context.read<AuthProvider>();

    final progressData = lib.getProgressData(widget.itemId);
    final isFinished = progressData?['isFinished'] == true;
    final currentTime = (progressData?['currentTime'] as num?)?.toDouble() ?? 0;
    final ebookFile = resolveEbookFile(_item) ?? _cachedEbookFallback;
    final bookOrbitOnline = auth.isBookOrbit && !lib.isOffline;
    final readStatus = _displayReadStatus(isFinished);
    final providerBadges = auth.isBookOrbit ? _providerBadges() : const <Map<String, dynamic>>[];

    final isEbookOnly = PlayerSettings.isEbookOnly(_item!);
    // Preview only makes sense before the book has been started. The 60s
    // grace means an accidental tap-and-close doesn't hide it forever. Check
    // the override-aware progress fraction too - the server currentTime can
    // lag local playback.
    final showPreview = !isEbookOnly && !isFinished && currentTime < 60 &&
        progress * duration < 60 && duration > 0;
    // Deduped on the value so this fires once per change, not once per rebuild.
    // "I don't have a preview button" needs the inputs, not just the outcome.
    if (showPreview != _loggedPreviewVisible) {
      _loggedPreviewVisible = showPreview;
      debugPrint('[Preview] book ${widget.itemId}: button ${showPreview ? "shown" : "hidden"} '
          '(ebookOnly=$isEbookOnly finished=$isFinished '
          'currentTime=${currentTime.toStringAsFixed(0)}s '
          'played=${(progress * duration).toStringAsFixed(0)}s '
          'duration=${duration.toStringAsFixed(0)}s)');
    }

    return ListView(controller: widget.scrollController, padding: EdgeInsets.fromLTRB(20, 8, 20, 32 + MediaQuery.of(context).viewPadding.bottom), children: [
      Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.24), borderRadius: BorderRadius.circular(2)))),
      if (_coverUrl != null) ...[
        Center(child: GestureDetector(
          onTap: () => _showFullCover(context, _fullResCoverUrl ?? _coverUrl!, lib.mediaHeaders, title),
          child: Container(
            height: 240,
            width: _squareCovers ? 240 : null,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 4))],
            ),
            clipBehavior: Clip.antiAlias,
            child: _squareCovers
                ? (_coverUrl!.startsWith('/')
                    ? BlurPaddedCover(
                        blurChild: Image.file(File(_coverUrl!), fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                        child: Image.file(File(_coverUrl!), fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const SizedBox()),
                      )
                    : BlurPaddedCover(
                        blurChild: CachedNetworkImage(
                          imageUrl: _coverUrl!, fit: BoxFit.cover,
                          useOldImageOnUrlChange: true,
                          httpHeaders: lib.mediaHeaders,
                          errorWidget: (_, __, ___) => const SizedBox.shrink(),
                        ),
                        child: CachedNetworkImage(
                          imageUrl: _coverUrl!, fit: BoxFit.contain,
                          useOldImageOnUrlChange: true,
                          httpHeaders: lib.mediaHeaders,
                          placeholder: (_, __) => const SizedBox(),
                          errorWidget: (_, __, ___) => const SizedBox(),
                        ),
                      ))
                : CachedNetworkImage(
                    imageUrl: _coverUrl!, fit: BoxFit.contain,
                    useOldImageOnUrlChange: true,
                    httpHeaders: lib.mediaHeaders,
                    placeholder: (_, __) => const SizedBox(),
                    errorWidget: (_, __, ___) => const SizedBox(),
                  ),
          ),
        )),
        const SizedBox(height: 16),
      ],
      Text(title, textAlign: TextAlign.center, style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: cs.onSurface)),
      if (subtitle.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(subtitle, textAlign: TextAlign.center,
          style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
      ],
      const SizedBox(height: 4),
      _buildAuthorLinks(context, metadata, cs, tt, accent),
      _buildNarratorLinks(context, metadata, cs, tt, accent),
      // Series as a pill in the rating's style: a bounded target with its
      // own edges, so it can't be mistaken for the narrator line above it.
      if (seriesEntries.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final s in seriesEntries)
              GestureDetector(
                onTap: () => _openSeries(context, s['id'] as String?, s['name'] as String? ?? ''),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: accent.withValues(alpha: 0.18)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.auto_stories_rounded, size: 14, color: accent),
                    const SizedBox(width: 6),
                    Text(
                      '${s['name'] as String? ?? ''}'
                      '${(s['sequence'] as String? ?? '').isNotEmpty ? ' #${s['sequence']}' : ''}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: accent),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right_rounded, size: 16, color: accent.withValues(alpha: 0.6)),
                  ]),
                ),
              ),
          ],
        ),
      ],
      // ─── AUDIBLE RATING (space always reserved) ─────────
      const SizedBox(height: 8),
      if (providerBadges.isNotEmpty)
        _providerBadgeRow(cs, lib, providerBadges)
      else if (_rating != null && (_rating!['rating'] as num).toDouble() > 0)
        Center(
          child: GestureDetector(
            onTap: _asin != null ? () => _showAudibleReviews(context) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                ..._buildStars((_rating!['rating'] as num).toDouble(), accent),
                const SizedBox(width: 6),
                Text((_rating!['rating'] as num).toStringAsFixed(1),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
                if (((_rating!['count'] as num?) ?? 0) > 0) ...[
                  const SizedBox(width: 3),
                  Text('(${_formatRatingCount((_rating!['count'] as num).toInt(), l.localeName)})',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                ],
                const SizedBox(width: 4),
                Text(l.onAudible, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ]),
            ),
          ),
        )
      else
        const SizedBox(height: 20),
      const SizedBox(height: 12),
      if (_lookingForNarration)
        _lookingButton(accent, _coverScheme?.onPrimary ?? cs.onPrimary)
      else if (isEbookOnly && ebookFile != null && canReadEbook(ebookFile))
        // Reading progress fills the button the same way listening progress
        // fills Absorb.
        Builder(builder: (context) {
          final onAccent = _coverScheme?.onPrimary ?? cs.onPrimary;
          // A library refresh on BookOrbit carries an ebook-only book's
          // reading percent as its plain progress, with no ebook field.
          final saved = lib.getEbookProgress(widget.itemId);
          final ebookProgress = saved > 0 ? saved : progress;
          final showFill = ebookProgress > 0 && ebookProgress < 1 && !isFinished;
          return SizedBox(
            height: 52,
            child: Material(
              color: accent,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _readEbook(context, auth, title),
                child: Stack(children: [
                  if (showFill)
                    FractionallySizedBox(
                      widthFactor: ebookProgress.clamp(0.0, 1.0),
                      child: Container(color: onAccent.withValues(alpha: 0.22)),
                    ),
                  Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.menu_book_rounded, size: 24, color: onAccent),
                      const SizedBox(width: 8),
                      Text(l.readEbook,
                          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: onAccent)),
                    ]),
                  ),
                  if (showFill)
                    Positioned(
                      right: 14,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Text(
                          '${(ebookProgress * 100).toStringAsFixed(0)}%',
                          style: tt.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: onAccent.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          );
        })
      else if (isEbookOnly && ebookFile != null)
        // Ebook-only but not readable in-app (CBR) - can't open it, so the
        // primary action exports the file to the device instead.
        SizedBox(height: 52, child: FilledButton.icon(
          onPressed: () => _ebookSaved
              ? _deleteEbookExport(context)
              : _exportEbook(context, auth, title),
          icon: Icon(_ebookSaved ? Icons.download_done_rounded : Icons.save_alt_rounded, size: 24),
          label: Text(_ebookSaved ? l.ebookExportedLabel : l.ebookSaveToDevice,
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onPrimary)),
          style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ))
      else if (isEbookOnly)
        SizedBox(height: 52, child: FilledButton.icon(
          onPressed: null,
          icon: const Icon(Icons.menu_book_rounded, size: 24),
          label: Text(l.ebookOnlyNoAudio,
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ))
      else
      SizedBox(
        height: 52,
        child: ListenableBuilder(
          listenable: Listenable.merge([AudioPlayerService(), DownloadService()]),
          builder: (_, __) {
            final player = AudioPlayerService();
            final isCurrentPlaying =
                player.currentItemId == widget.itemId && player.isPlaying;
            final showAbsorbingState = _isAbsorbing || isCurrentPlaying;
            final onAccent = _coverScheme?.onPrimary ?? cs.onPrimary;
            final needsDownload = !showAbsorbingState && _needsNarrationDownload(auth);
            final fetching = needsDownload && DownloadService().isDownloading(widget.itemId);
            // How far into the book you are fills the button from the left,
            // the way the download button fills while it fetches. A narration
            // on its way down fills with the download instead.
            final fill = fetching ? DownloadService().downloadProgress(widget.itemId) : progress;
            final showFill = fetching || (!needsDownload && progress > 0 && !isFinished);
            // Offline with nothing to play: only the ebook may be on the
            // phone, and the Read button below still works.
            if (lib.isOffline &&
                !showAbsorbingState &&
                !DownloadService().isDownloaded(widget.itemId)) {
              return Material(
                color: accent.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(16),
                child: Center(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.cloud_off_rounded, size: 22, color: onAccent),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        ebookFile != null && canReadEbook(ebookFile)
                            ? l.absorbAudioNotDownloadedEbookOnly
                            : l.absorbAudioNotDownloaded,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600, color: onAccent),
                      ),
                    ),
                  ]),
                ),
              );
            }

            return Material(
              color: accent,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: showAbsorbingState
                    ? () async {
                        if (isCurrentPlaying) {
                          final lib = context.read<LibraryProvider>();
                          await _activateQueueSource();
                          unawaited(lib.syncQueueAutoDownloads());
                        }
                        if (!context.mounted) return;
                        Navigator.of(context).popUntil((route) => route.isFirst);
                        AppShell.goToAbsorbingGlobal();
                      }
                    : () {
                        setState(() => _isAbsorbing = true);
                        _startAbsorb(
                          context,
                          auth: auth,
                          title: title,
                          author: authorName,
                          coverUrl: _coverUrl,
                          duration: duration,
                          chapters: chapters,
                        );
                      },
                child: Stack(children: [
                  if (showFill)
                    FractionallySizedBox(
                      widthFactor: fill.clamp(0.0, 1.0),
                      child: Container(color: onAccent.withValues(alpha: 0.22)),
                    ),
                  Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      showAbsorbingState
                          ? SizedBox(
                              width: 24,
                              height: 24,
                              child: AbsorbingWave(color: onAccent),
                            )
                          : needsDownload
                              ? Icon(Icons.download_rounded, size: 24, color: onAccent)
                              : isFinished
                                  ? AbsorbReplayIcon(size: 24, color: onAccent)
                                  : Icon(Icons.waves_rounded, size: 24, color: onAccent),
                      const SizedBox(width: 8),
                      Text(
                        showAbsorbingState
                            ? Wording.of(context).absorbing
                            : fetching
                                ? l.downloadsDownloading
                                : needsDownload
                                    ? Wording.of(context).downloadToAbsorb
                                    : isFinished
                                        ? Wording.of(context).absorbAgain
                                        : Wording.of(context).absorb,
                        style: tt.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600, color: onAccent),
                      ),
                    ]),
                  ),
                  if (showFill)
                    Positioned(
                      right: 14,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Text(
                          '${(fill * 100).toStringAsFixed(0)}%',
                          style: tt.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: onAccent.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            );
          },
        ),
      ),
      ListenableBuilder(
        listenable: Listenable.merge([ReadListenSync.instance.syncing, ReadListenSync.instance.failed]),
        builder: (context, _) {
          final to = ReadListenSync.instance.syncing.value[widget.itemId];
          final failed = to == null && ReadListenSync.instance.failed.value.containsKey(widget.itemId);
          return AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: to == null && !failed
                ? const SizedBox(width: double.infinity)
                : failed
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => ReadListenSync.instance.syncNow(widget.itemId),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.sync_problem_rounded, size: 16, color: cs.error),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              l.syncFailed,
                              style: tt.labelMedium?.copyWith(color: cs.error),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(l.retry,
                              style: tt.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: accent)),
                        ]),
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          to == SyncTarget.audio ? l.syncFindingAudio : l.syncFindingEbook,
                          style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ]),
                  ),
          );
        },
      ),
      // A companion ebook gets its own, smaller button under Absorb with the
      // reading progress filled in the same way. Ebook-only books already
      // have Read as the big button above.
      if (!isEbookOnly && ebookFile != null && canReadEbook(ebookFile)) ...[
        const SizedBox(height: 8),
        Builder(builder: (context) {
          // Show the default version's progress (the one the Read button opens)
          // rather than whichever version was read last on this device.
          final defaultEbook = resolveEbookFile(_item) ?? _cachedEbookFallback;
          final ebookProgress = lib.getEbookProgress(widget.itemId,
              versionId: defaultEbook == null
                  ? null
                  : ebookVersionKey(defaultEbook),
              multiVersion: ebookFileChoices(_item).length > 1);
          final showFill = ebookProgress > 0 && ebookProgress < 1;
          return SizedBox(
            height: 40,
            child: Material(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _readEbook(context, auth, title),
                child: Stack(children: [
                  if (showFill)
                    FractionallySizedBox(
                      widthFactor: ebookProgress.clamp(0.0, 1.0),
                      child: Container(color: accent.withValues(alpha: 0.22)),
                    ),
                  Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.menu_book_rounded, size: 18, color: accent),
                      const SizedBox(width: 8),
                      Text(l.readEbook,
                          style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: accent)),
                    ]),
                  ),
                  if (showFill)
                    Positioned(
                      right: 14,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Text(
                          '${(ebookProgress * 100).toStringAsFixed(0)}%',
                          style: tt.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: accent.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          );
        }),
      ],
      // With the automatic sync off, an audiobook and its separate EPUB come
      // together by hand: whichever is behind moves up to the other.
      if (!_autoSync &&
          _transcriptionReady &&
          !isEbookOnly &&
          ebookFile != null &&
          ebookExtFromFile(ebookFile) == '.epub' &&
          media['narration'] == null &&
          !NarratedBooks.contains(widget.itemId)) ...[
        const SizedBox(height: 8),
        ValueListenableBuilder<Map<String, SyncTarget>>(
          valueListenable: ReadListenSync.instance.syncing,
          builder: (context, syncing, _) {
            final busy = syncing.containsKey(widget.itemId);
            return SizedBox(
              height: 36,
              child: Material(
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: accent.withValues(alpha: 0.3)),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: busy ? null : () => ReadListenSync.instance.syncNow(widget.itemId),
                  child: Center(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.sync_rounded, size: 16, color: accent.withValues(alpha: busy ? 0.4 : 1)),
                      const SizedBox(width: 8),
                      Text(l.syncPosition,
                          style: tt.labelLarge?.copyWith(
                              fontWeight: FontWeight.w600, color: accent.withValues(alpha: busy ? 0.4 : 1))),
                    ]),
                  ),
                ),
              ),
            );
          },
        ),
      ],
      // Primary action row: Download | Fully Absorb | ebook download (ebook-only)
      const SizedBox(height: 12),
      Row(children: [
        if (!isEbookOnly) ...[
          Expanded(child: DownloadWideButton(itemId: widget.itemId, coverUrl: _coverUrl, title: title, author: authorName, accent: accent, chapters: chapters)),
          const SizedBox(width: 8),
        ],
        Expanded(child: GestureDetector(
          onTap: () => isFinished
              ? _markNotFinished(context, auth, currentTime, duration)
              : _markFinished(context, auth, duration),
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: isFinished ? Colors.green.withValues(alpha: 0.06) : cs.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isFinished ? Colors.green.withValues(alpha: 0.15) : cs.onSurface.withValues(alpha: 0.08)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(
                isFinished ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
                size: 16,
                color: isFinished ? Colors.green : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                isFinished ? Wording.of(context).fullyAbsorbed : Wording.of(context).fullyAbsorbAction,
                style: TextStyle(
                  color: isFinished ? Colors.green : cs.onSurfaceVariant,
                  fontSize: 12, fontWeight: FontWeight.w500,
                ),
              ),
            ]),
          ),
        )),
        if (isEbookOnly && !_lookingForNarration && ebookFile != null && canReadEbook(ebookFile)) ...[
          const SizedBox(width: 8),
          // For ebook-only books the big button above is already "Read", so this
          // slot is the offline download (matching the audiobook download
          // button's Saved/green styling). Audiobooks with a companion ebook
          // have the Read button under Absorb instead, and the audio download
          // already pulls the ebook along.
          Expanded(child: ListenableBuilder(
                  listenable: DownloadService(),
                  builder: (_, __) {
                    final saved = DownloadService().isDownloaded(widget.itemId);
                    final dlGreen = Theme.of(context).brightness == Brightness.dark
                        ? Colors.greenAccent : Colors.green.shade700;
                    return GestureDetector(
                      onTap: _ebookOfflineDownloading
                          ? null
                          : (saved
                              ? () => _removeEbookOffline(context)
                              : () => _offlineEbook(context, auth, title)),
                      child: Container(
                        height: 36,
                        decoration: BoxDecoration(
                          color: saved ? dlGreen.withValues(alpha: 0.08) : cs.onSurface.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: saved ? dlGreen.withValues(alpha: 0.2) : cs.onSurface.withValues(alpha: 0.08)),
                        ),
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          if (_ebookOfflineDownloading)
                            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurfaceVariant))
                          else
                            Icon(saved ? Icons.download_done_rounded : Icons.download_rounded,
                                size: 16, color: saved ? dlGreen : cs.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Text(saved ? l.saved : l.ebookDownload,
                              style: TextStyle(color: saved ? dlGreen : cs.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w500)),
                        ]),
                      ),
                    );
                  },
                )),
        ],
      ]),
      if (showPreview) ...[
        const SizedBox(height: 8),
        GestureDetector(
          onTap: () => _togglePreview(context, chapters, duration),
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (_preview?.isLoading ?? false)
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onSurfaceVariant))
              else
                Icon((_preview?.isPlaying ?? false) ? Icons.stop_rounded : Icons.headphones_rounded,
                    size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Text((_preview?.isPlaying ?? false) ? l.chapterStopPreview : l.preview,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      ],
      // More button below primary row
      const SizedBox(height: 8),
      GestureDetector(
        onTap: () => _showMoreSheet(context, auth, lib, title, authorName, progress, isFinished, duration, ebookFile, isEbookOnly,
          ),
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.onSurface.withValues(alpha: 0.1)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.more_horiz_rounded, size: 16, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(l.moreActions, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
      if (!lib.isOffline && !isEbookOnly) ...[
        const SizedBox(height: 16),
        _listeningStatsBlock(context, cs, tt, accent, title),
      ],
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (bookOrbitOnline)
          _chip(
            _readStatusIcon(readStatus),
            _readStatusLabel(l, readStatus),
            onTap: _savingStatus ? null : () => _pickReadStatus(auth, lib, readStatus),
          ),
        if (year.isNotEmpty) _chip(Icons.calendar_today_rounded, year),
        _chip(Icons.schedule_rounded, formatHm(duration)),
        if (chapters.isNotEmpty) _chip(Icons.list_rounded, l.chaptersChip(chapters.length)),
        ..._audioInfoChips(media),
        if (publisher.isNotEmpty) _chip(Icons.business_rounded, publisher),
        ...genres.map((g) => _chip(
              Icons.tag_rounded,
              g,
              onTap: () {
                Navigator.of(context).pop();
                AppShell.openLibraryWithGenreFilterGlobal(g);
              },
            )),
        ...tags.map((t) => _chip(
              Icons.local_offer_outlined,
              t,
              onTap: () {
                Navigator.of(context).pop();
                AppShell.openLibraryWithTagFilterGlobal(t);
              },
            )),
        if (progressData?['startedAt'] is num)
          _chip(Icons.play_circle_outline_rounded, l.startedDate(_fmtDate((progressData!['startedAt'] as num).toInt())),
                key: ValueKey('book-started-date-${widget.itemId}'),
                onTap: () => _editProgressDate(
                  auth: auth,
                  lib: lib,
                  editingFinishedDate: false,
                  startedAt: (progressData['startedAt'] as num).toInt(),
                  finishedAt: (progressData['finishedAt'] as num?)?.toInt(),
                ),
              ),
        if (progressData?['finishedAt'] is num)
          _chip(Icons.check_circle_outline_rounded, l.finishedDate(_fmtDate((progressData!['finishedAt'] as num).toInt()),
                ),
                key: ValueKey('book-finished-date-${widget.itemId}'),
                onTap: () => _editProgressDate(
                  auth: auth,
                  lib: lib,
                  editingFinishedDate: true,
                  startedAt: (progressData['startedAt'] as num).toInt(),
                  finishedAt: (progressData['finishedAt'] as num).toInt())),
      ]),
      if (descRaw.isNotEmpty) ...[const SizedBox(height: 16),
        Text(l.aboutSection, style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        HtmlDescription(
          html: descRaw,
          maxLines: null,
          style: tt.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.7), height: 1.5),
          linkColor: accent,
        )],
      if (bookOrbitOnline) ...[
        const SizedBox(height: 16),
        _personalNoteBlock(cs, tt, auth),
      ],
      if (chapters.isNotEmpty) ...[const SizedBox(height: 16),
        GestureDetector(onTap: () => setState(() => _chaptersExpanded = !_chaptersExpanded),
          child: Row(children: [
            Expanded(child: Text(l.chaptersCount(chapters.length), style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600))),
            const SizedBox(width: 4),
            AnimatedRotation(
                turns: _chaptersExpanded ? 0.5 : 0,
                duration: PlayerSettings.einkMode ? Duration.zero : const Duration(milliseconds: 250),
                child: Icon(Icons.expand_more_rounded, size: 18, color: cs.onSurfaceVariant)),
          ])),
        // Collapsed by default so the list opens on the book, not the chapter
        // index; expanding lays out like the card's chapter list: the chapter
        // you're in is lit, the ones behind you are ticked, and a tap jumps
        // there after a confirmation.
        if (_chaptersExpanded) ...[const SizedBox(height: 4),
        ListenableBuilder(
          listenable: AudioPlayerService(),
          builder: (context, _) {
            final player = AudioPlayerService();
            final isActive = player.hasBook && player.currentItemId == widget.itemId;
            final pos = isActive ? player.position.inMilliseconds / 1000.0 : currentTime;
            // Chapters behind you fold into one row so the list opens on
            // where you are, not on what you've already heard.
            var done = 0;
            while (done < chapters.length &&
                pos >= (((chapters[done] as Map<String, dynamic>)['end'] as num?)?.toDouble() ?? 0)) {
              done++;
            }
            // Accordion open and close; instant on e-ink, where animation
            // only smears.
            final anim = PlayerSettings.einkMode
                ? Duration.zero
                : const Duration(milliseconds: 250);
            return Column(children: [
              if (done > 0) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _finishedChaptersExpanded = !_finishedChaptersExpanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                    child: Row(children: [
                      SizedBox(width: 28, child: AnimatedRotation(
                          turns: _finishedChaptersExpanded ? 0.5 : 0,
                          duration: anim,
                          child: Icon(Icons.expand_more_rounded,
                              size: 18, color: cs.onSurface.withValues(alpha: 0.4)))),
                      Expanded(child: Text(l.detailChaptersFinished(done),
                          style: tt.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.5)))),
                    ]),
                  ),
                ),
                ClipRect(
                  child: AnimatedSize(
                    duration: anim,
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: _finishedChaptersExpanded
                        ? Column(children: [
                            for (var i = 0; i < done; i++)
                              _chapterRow(context, cs, tt, accent, auth, chapters, i, pos, isActive, title, authorName, duration),
                          ])
                        : const SizedBox(width: double.infinity),
                  ),
                ),
              ],
              for (var i = done; i < chapters.length; i++)
                _chapterRow(context, cs, tt, accent, auth, chapters, i, pos, isActive, title, authorName, duration),
            ]);
          },
        ),
        ],
      ],
      if (_bookmarks.isNotEmpty) ...[const SizedBox(height: 16),
        GestureDetector(onTap: () => setState(() => _bookmarksExpanded = !_bookmarksExpanded),
          child: Row(children: [
            Text(l.bookmarksWithCount(_bookmarks.length), style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const Spacer(), Icon(_bookmarksExpanded ? Icons.expand_less : Icons.expand_more, color: cs.onSurface.withValues(alpha: 0.3), size: 20)])),
        if (_bookmarksExpanded) ...[const SizedBox(height: 8),
          ..._bookmarks.map((bm) {
            final hasNote = bm.note != null && bm.note!.isNotEmpty;
            return Padding(padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 56, child: Text(bm.formattedAt(_displaySpeed), style: tt.labelSmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.3)))),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(bm.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
                  if (hasNote)
                    Text(bm.note!, maxLines: 2, overflow: TextOverflow.ellipsis, style: tt.labelSmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.35))),
                ])),
              ]));
          })]],
      if (_similar.isNotEmpty && !lib.isOffline) ...[
        const SizedBox(height: 16),
        Text(l.moreLikeThis, style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SizedBox(
          height: (_squareCovers ? 100.0 : 135.0) + 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _similar.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) => _similarTile(cs, tt, lib, auth, _similar[i]),
          ),
        ),
      ],
      const SizedBox(height: 20),
      ]);
  }

/// True when [newItem] would paint identically to [_item] (same title, author,
  /// cover art, duration). Used to skip a full-sheet rebuild when the server
  /// fetch returns data that doesn't change anything the user can see — the
  /// rebuild would otherwise land right in the middle of the sheet's open/close
  /// animation and drop a frame.
  bool _visuallySameItem(Map<String, dynamic>? newItem) {
    if (_item == null || newItem == null) return false;
    String? pick(Map<String, dynamic>? m, List<String> keys) {
      for (final k in keys) {
        final v = m?[k];
        if (v is String && v.isNotEmpty) return v;
      }
      return null;
    }
    final oldMedia = _item!['media'] as Map<String, dynamic>?;
    final newMedia = newItem['media'] as Map<String, dynamic>?;
    final oldMeta = oldMedia?['metadata'] as Map<String, dynamic>?;
    final newMeta = newMedia?['metadata'] as Map<String, dynamic>?;
    if (pick(oldMeta, ['title']) != pick(newMeta, ['title'])) return false;
    if (pick(oldMeta, ['authorName']) != pick(newMeta, ['authorName'])) return false;
    if (pick(oldMedia, ['coverPath']) != pick(newMedia, ['coverPath'])) return false;
    if (pick(oldMedia, ['cover']) != pick(newMedia, ['cover'])) return false;
    final oldDur = (oldMedia?['duration'] as num?)?.toDouble() ?? 0;
    final newDur = (newMedia?['duration'] as num?)?.toDouble() ?? 0;
    if ((oldDur - newDur).abs() > 0.5) return false;
    // A flip in whether an eBook is attached changes the grid's eBook pills
    // (read / save-to-device / send-to-reader), which are visible UI — don't
    // let this guard swallow that.
    if ((resolveEbookFile(_item) != null) != (resolveEbookFile(newItem) != null)) {
      return false;
    }
    // isFinished lives on the progress object in the library, not the media
    // metadata, so it's deliberately absent here — progress changes are already
    // replayed through LibraryProvider notifications during playback.
    return true;
  }

  Future<void> _loadSimilar(ApiService api) async {
    final list = await api.getSimilarBooks(widget.itemId);
    if (mounted && list.isNotEmpty) setState(() => _similar = list.take(20).toList());
  }

  Widget _similarTile(ColorScheme cs, TextTheme tt, LibraryProvider lib, AuthProvider auth, Map<String, dynamic> book) {
    final id = book['id'] as String;
    final width = _squareCovers ? 100.0 : 90.0;
    final height = _squareCovers ? 100.0 : 135.0;
    final url = book['hasCover'] == true ? auth.apiService?.getCoverUrl(id) : null;
    final blank = Container(
      color: cs.surfaceContainerHighest,
      child: Icon(Icons.menu_book_rounded, color: cs.onSurfaceVariant),
    );
    return SizedBox(
      width: width,
      child: GestureDetector(
        onTap: () => showBookDetailSheet(context, id),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: width,
              height: height,
              child: url == null
                  ? blank
                  : CachedNetworkImage(
                      imageUrl: url,
                      httpHeaders: lib.mediaHeaders,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: cs.surfaceContainerHighest),
                      errorWidget: (_, __, ___) => blank,
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            book['title'] as String? ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: tt.labelSmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.8), height: 1.2),
          ),
        ]),
      ),
    );
  }

  /// BookOrbit's status for the book, squared with the finish button, which
  /// changes the server without reloading the book here.
  String _displayReadStatus(bool isFinished) {
    final s = ((_item?['bookOrbit'] as Map?)?['readStatus'] as Map?)?['status'] as String? ?? 'unread';
    final done = s == 'read' || s == 'skimmed';
    if (isFinished && !done) return 'read';
    if (!isFinished && done) return 'reading';
    return s;
  }

  static String _readStatusLabel(AppLocalizations l, String s) => readStatusLabel(l, s);

  static IconData _readStatusIcon(String s) => readStatusIcon(s);

  // Unread and Read stay with the finish button: a hand-set Unread would
  // keep BookOrbit from ever moving the book back to Reading.
  static const _pickableReadStatuses = ['want_to_read', 'reading', 'rereading', 'on_hold', 'skimmed', 'abandoned'];

  Future<void> _pickReadStatus(AuthProvider auth, LibraryProvider lib, String current) async {
    final l = AppLocalizations.of(context)!;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final tt = Theme.of(ctx).textTheme;
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text(l.readStatusTitle, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(l.readStatusHint, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
            for (final s in _pickableReadStatuses)
              ListTile(
                leading: Icon(_readStatusIcon(s)),
                title: Text(_readStatusLabel(l, s)),
                trailing: s == current ? Icon(Icons.check_rounded, color: cs.primary) : null,
                onTap: () => Navigator.pop(ctx, s),
              ),
          ]),
        );
      },
    );
    final api = auth.apiService;
    if (picked == null || picked == current || api == null || !mounted) return;
    setState(() => _savingStatus = true);
    final ok = await api.setReadStatus(widget.itemId, picked);
    if (!mounted) return;
    setState(() {
      _savingStatus = false;
      if (ok) {
        final bo = Map<String, dynamic>.from((_item?['bookOrbit'] as Map?) ?? const {});
        bo['readStatus'] = {...?(bo['readStatus'] as Map?)?.cast<String, dynamic>(), 'status': picked};
        _item = {..._item!, 'bookOrbit': bo};
      }
    });
    if (ok) {
      unawaited(lib.refresh());
    } else {
      showOverlayToast(context, l.failedToUpdateCheckConnection, icon: Icons.error_outline_rounded);
    }
  }

  Widget _personalNoteBlock(ColorScheme cs, TextTheme tt, AuthProvider auth) {
    final l = AppLocalizations.of(context)!;
    final note = ((_item?['bookOrbit'] as Map?)?['personalNote'] as String?)?.trim() ?? '';
    if (note.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _editPersonalNote(auth, note),
          icon: const Icon(Icons.edit_note_rounded, size: 18),
          label: Text(l.personalNoteAdd),
        ),
      );
    }
    return InkWell(
      onTap: () => _editPersonalNote(auth, note),
      borderRadius: BorderRadius.circular(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(l.personalNoteTitle, style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
          const Spacer(),
          Icon(Icons.edit_rounded, size: 16, color: cs.onSurface.withValues(alpha: 0.4)),
        ]),
        const SizedBox(height: 6),
        Text(note, style: tt.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.7), height: 1.5)),
      ]),
    );
  }

  Future<void> _editPersonalNote(AuthProvider auth, String current) async {
    final l = AppLocalizations.of(context)!;
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _PersonalNoteDialog(initial: current),
    );
    final api = auth.apiService;
    if (result == null || result.trim() == current || api == null || !mounted) return;
    final ok = await api.setPersonalNote(widget.itemId, result);
    if (!mounted) return;
    if (!ok) {
      showOverlayToast(context, l.failedToUpdateCheckConnection, icon: Icons.error_outline_rounded);
      return;
    }
    setState(() {
      final bo = Map<String, dynamic>.from((_item?['bookOrbit'] as Map?) ?? const {});
      bo['personalNote'] = result.trim().isEmpty ? null : result.trim();
      _item = {..._item!, 'bookOrbit': bo};
    });
  }

  /// BookOrbit's provider links and ratings the way its web book page shows
  /// them, with the live Audible rating folded into the Audible badge.
  List<Map<String, dynamic>> _providerBadges() {
    final bo = _item?['bookOrbit'] as Map?;
    if (bo == null) return const [];
    final badges = BookOrbitMapper.providerBadges(bo['providerIds'] as Map?, bo['communityRatings'] as List?);
    final live = _rating != null && (_rating!['rating'] as num).toDouble() > 0 ? _rating! : null;
    if (live == null) return badges;
    final i = badges.indexWhere((b) => b['key'] == 'audible');
    final audible = i >= 0 ? badges[i] : BookOrbitMapper.providerBadge('audible');
    if (audible['rating'] == null) {
      audible['rating'] = (live['rating'] as num).toDouble();
      audible['count'] = (live['count'] as num?)?.toInt();
    }
    if (i < 0) badges.add(audible);
    return badges;
  }

  Widget _providerBadgeRow(ColorScheme cs, LibraryProvider lib, List<Map<String, dynamic>> badges) {
    final base = context.read<AuthProvider>().apiService?.baseUrl.replaceAll(RegExp(r'/+$'), '');
    return Center(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < badges.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            _providerBadgeChip(cs, lib, base, badges[i]),
          ],
        ]),
      ),
    );
  }

  Widget _providerBadgeChip(ColorScheme cs, LibraryProvider lib, String? base, Map<String, dynamic> b) {
    final l = AppLocalizations.of(context)!;
    final color = Color(b['color'] as int);
    final rating = (b['rating'] as num?)?.toDouble();
    final count = (b['count'] as num?)?.toInt() ?? 0;
    final label = b['label'] as String;
    final url = b['url'] as String?;
    final VoidCallback? onTap = b['key'] == 'audible' && _asin != null
        ? () => _showAudibleReviews(context)
        : url == null
            ? null
            : () => _openProviderPage(url);
    final mark = Text(b['mark'] as String,
        style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: cs.onSurface));
    final icon = b['icon'] as String?;
    return Tooltip(
      message: rating == null
          ? label
          : '$label ${rating.toStringAsFixed(1)}${count > 0 ? ' (${_formatRatingCount(count, l.localeName)})' : ''}',
      child: Material(
        color: color.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: color.withValues(alpha: 0.45)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 24,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 24,
                child: Center(
                  child: icon == null || base == null
                      ? mark
                      : SvgPicture.network(
                          '$base/assets/provider-icons/$icon',
                          width: 14,
                          height: 14,
                          headers: lib.mediaHeaders,
                          placeholderBuilder: (_) => mark,
                          errorBuilder: (_, __, ___) => mark,
                        ),
                ),
              ),
              if (rating != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.surface.withValues(alpha: 0.5),
                    border: Border(left: BorderSide(color: color.withValues(alpha: 0.3))),
                  ),
                  child: Text(
                    rating == rating.roundToDouble() ? rating.toStringAsFixed(0) : rating.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _openProviderPage(String url) async {
    final uri = Uri.parse(url);
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ─── QUICK ACTIONS (long-press) ─────────────────────────────
  // Compact long-press layout: cover + title, an Absorb/Download grid, then
  // the same actions as the detail sheet's "more" menu rendered as pills.
  // Actions run on this (live) sheet context just like the detail sheet, so we
  // never pop-then-touch a defunct context; navigation actions dismiss us.
  Widget _buildQuickContent(BuildContext context, ColorScheme cs, TextTheme tt, AppLocalizations l) {
    final accent =
        (PlayerSettings.einkMode ? null : _coverScheme?.primary) ?? cs.primary;
    final onAccent =
        (PlayerSettings.einkMode ? null : _coverScheme?.onPrimary) ?? cs.onPrimary;
    final media = _item!['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final chapters = media['chapters'] as List<dynamic>? ?? [];
    final title = metadata['title'] as String? ?? l.unknown;
    final authorName = metadata['authorName'] as String? ?? '';
    final duration = (media['duration'] as num?)?.toDouble() ?? 0;
    final ebookFile = resolveEbookFile(_item) ?? _cachedEbookFallback;
    final isEbookOnly = PlayerSettings.isEbookOnly(_item!);

    final lib = context.watch<LibraryProvider>();
    final auth = context.read<AuthProvider>();
    final progress = lib.getProgress(widget.itemId);
    final progressData = lib.getProgressData(widget.itemId);
    final isFinished = progressData?['isFinished'] == true;
    final currentTime = (progressData?['currentTime'] as num?)?.toDouble() ?? 0;

    // Continue-shelf actions (mirror the detail sheet's more menu).
    final continueShelf = lib.continueShelfOf(widget.itemId);
    final rawSeries = ((_item?['media'] as Map<String, dynamic>?)?['metadata']
        as Map<String, dynamic>?)?['series'];
    final bookSeriesIds = <String>[];
    if (rawSeries is List) {
      for (final s in rawSeries.whereType<Map<String, dynamic>>()) {
        final id = (s['id'] as String? ?? '').trim();
        if (id.isNotEmpty) bookSeriesIds.add(id);
      }
    } else if (rawSeries is Map<String, dynamic>) {
      final id = (rawSeries['id'] as String? ?? '').trim();
      if (id.isNotEmpty) bookSeriesIds.add(id);
    }
    final continueSeriesId = lib.continueSeriesShelfMatch(bookSeriesIds);

    return ListView(
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + MediaQuery.of(context).viewPadding.bottom),
      children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.24), borderRadius: BorderRadius.circular(2)))),
        // Header: cover thumb + title/author
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _quickThumb(56, lib.mediaHeaders, cs),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: cs.onSurface)),
            if (authorName.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(authorName, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ])),
        ]),
        const SizedBox(height: 18),
        // Primary actions: Absorb | Download side by side
        if (_lookingForNarration)
          _lookingButton(accent, onAccent, height: 36, radius: 14)
        else if (!isEbookOnly)
          Row(children: [
            Expanded(child: _quickAbsorbButton(context, cs, tt, auth, accent, onAccent, title, authorName, duration, chapters, isFinished, progress)),
            const SizedBox(width: 10),
            Expanded(child: DownloadWideButton(itemId: widget.itemId, coverUrl: _coverUrl, title: title, author: authorName, accent: accent, chapters: chapters)),
          ])
        else
          SizedBox(height: 44, child: Center(child: Text(l.ebookOnlyNoAudio,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)))),
        const SizedBox(height: 10),
        // Mark finished toggle
        _quickFinishedPill(context, cs, auth, isFinished, currentTime, duration),
        const SizedBox(height: 18),
        // Secondary actions as the shared responsive pill grid. The quick sheet
        // stays open behind navigation actions, so dismiss is a no-op here.
        _actionPillGrid(context, cs, tt, l, auth, lib, title, authorName, progress,
          isFinished, duration, ebookFile, isEbookOnly,
          continueShelf,
          continueSeriesId, dismiss: () {}, includeOpenDetails: true),
      ],
    );
  }

  /// The book's secondary actions as a responsive pill grid (admin-Users-page
  /// style). Shared by the long-press quick sheet and the detail sheet's
  /// overflow menu. [dismiss] closes the surrounding sheet before an action
  /// runs (the overflow menu pops itself; the quick sheet passes a no-op and
  /// stays open). [includeOpenDetails] adds a "Book Details" pill (quick sheet
  /// only — pointless when you're already in the detail sheet).
  Widget _actionPillGrid(BuildContext context, ColorScheme cs, TextTheme tt, AppLocalizations l,
      AuthProvider auth, LibraryProvider lib, String title, String authorName, double progress,
      bool isFinished, double duration, Map<String, dynamic>? ebookFile, bool isEbookOnly,
    String? continueShelf, String? continueSeriesId,
      {required VoidCallback dismiss, bool includeOpenDetails = false}) {
    final onAbsorbing = lib.isOnAbsorbingList(widget.itemId);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      LayoutBuilder(builder: (ctx, constraints) {
        const gap = 10.0;
        // Responsive grid: 3 pills across normally, but drop to 2 on a narrow
        // screen or when the system font is scaled up, so labels keep room to
        // show in full. Cell height tracks the text scale so 2-line labels at a
        // large zoom don't get clipped.
        final textScale = MediaQuery.textScalerOf(context).scale(1.0);
        final cols = (constraints.maxWidth < 340 || textScale >= 1.3) ? 2 : 3;
        final cellW = (constraints.maxWidth - gap * (cols - 1)) / cols;
        final cellH = (cols == 2 ? 72.0 : 80.0) * textScale.clamp(1.0, 1.7) + 8;
        final pills = <Widget>[];
        void add(IconData icon, String label, VoidCallback onTap, {Color? tint}) {
          final cell = SizedBox(width: cellW, height: cellH,
            child: _quickPill(cs, tt, icon, label, () { dismiss(); onTap(); }, tint: tint));
          pills.add(cell);
        }
        add(onAbsorbing ? Icons.remove_circle_outline_rounded : Icons.add_circle_outline_rounded,
          onAbsorbing ? Wording.of(context).removeFromAbsorbing : Wording.of(context).addToAbsorbing, () async {
            if (onAbsorbing) {
              await lib.removeFromAbsorbing(widget.itemId);
              HapticFeedback.mediumImpact();
              if (context.mounted) showOverlayToast(context, Wording.of(context).removedFromAbsorbing, icon: Icons.remove_circle_outline_rounded);
            } else {
              await addToAbsorbingWithPicker(context, widget.itemId,
                  item: _item, addedToast: Wording.of(context).addedToAbsorbing);
            }
          });
        // BookOrbit has no playlists; its collections are personal, so
        // everyone gets Add to Collection there instead.
        if (!lib.isOffline && !auth.isBookOrbit) {
          add(Icons.playlist_add_rounded, l.addToPlaylist, () => PlaylistPickerSheet.show(context, widget.itemId));
        }
        if (!includeOpenDetails && !lib.isOffline) {
          add(
            Icons.history_rounded,
            l.historyServerTab,
            () => showPlaybackHistorySheet(
              context,
              itemId: widget.itemId,
              initialTab: PlaybackHistoryTab.sessions,
              accent: _coverScheme?.primary ?? cs.primary,
            ),
          );
        }
        if (!lib.isOffline && !lib.isPodcastLibrary && (auth.isAdmin || auth.isBookOrbit)) {
          add(Icons.collections_bookmark_rounded, l.addToCollection, () => CollectionPickerSheet.show(context, widget.itemId));
        }
        if (progress > 0 || isFinished) {
          add(Icons.restart_alt_rounded, l.resetProgress, () => _resetProgress(context, auth, duration));
        }
        if (continueShelf != null && !lib.isOffline) {
          final reading = continueShelf == 'continue-reading';
          add(Icons.playlist_remove_rounded, reading ? l.removeFromContinueReading : l.removeFromContinueListening,
            () => _removeFromContinueListening(context, auth, lib, reading: reading));
        }
        if (continueSeriesId != null && !lib.isOffline) {
          add(Icons.bookmark_remove_rounded, l.removeSeriesFromContinueSeries, () => _removeSeriesFromContinueSeries(context, auth, lib, continueSeriesId));
        }
        if (auth.apiService != null && !lib.isOffline) {
          add(Icons.manage_search_rounded, _hasLocalOverride ? l.reLookupLocalMetadata : l.lookupLocalMetadata,
            () => _openMetadataLookup(context, auth, title, authorName));
        }
        if (_hasLocalOverride) {
          add(Icons.layers_clear_rounded, l.clearLocalMetadata, () => _clearOverride(context));
        }
        if (_showGoodreads) {
          add(Icons.local_library_rounded, l.searchOnGoodreads, () => _openGoodreads(title, authorName));
        }
        if (auth.canUpdateMetadata && !lib.isOffline) {
          add(Icons.edit_rounded, l.edit, () => _openEditPage(auth, title, isEbookOnly));
        }
        final item = _item;
        if (item != null) {
          add(Icons.info_outline_rounded, l.fileInfoTitle, () => showBookFilesSheet(context, item));
        }
        if (auth.canDelete && !lib.isOffline) {
          add(Icons.delete_outline_rounded, l.deleteFromServerAction,
            () => _deleteFromServer(context, auth, lib, title), tint: cs.error);
        }
        if (includeOpenDetails) {
          add(Icons.open_in_full_rounded, l.bookDetailsLabel, () {
            final rc = rootNavigatorKey.currentContext;
            Navigator.of(context).pop();
            if (rc != null) {
              showBookDetailSheet(
                rc,
                widget.itemId,
                sourcePlaylistId: widget.sourcePlaylistId,
                sourceCollectionId: widget.sourceCollectionId,
                sourceCollectionName: widget.sourceCollectionName,
              );
            }
          });
        }
        // eBook pills depend on the full item (server call or disk cache),
        // which lands after the sheet opens on an uncached book over a weak
        // link — so they're deliberately NOT part of the `_pillsReady` gate.
        // Rendered here as a trailing, keyed fade-in, they append to the grid
        // without shoving settled neighbours around; the AnimatedSize below
        // eases the height change. Keyed by label so only newly-appearing
        // entries animate on re-layout.
        final serverEbookFile = resolveEbookFile(_item);
        void addDynamic(IconData icon, String label, VoidCallback onTap, {Color? tint}) {
          pills.add(TweenAnimationBuilder<double>(
            key: ValueKey('ebook-pill-$label'),
            tween: Tween(begin: 0.0, end: 1.0),
            // Generous on purpose: these pills appear seconds after the grid in
            // an uncached, slow-network open — a short fade reads as a pop.
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
            child: SizedBox(width: cellW, height: cellH,
              child: _quickPill(cs, tt, icon, label, () { dismiss(); onTap(); }, tint: tint)),
            builder: (_, value, child) => Opacity(
              opacity: value,
              child: Transform.translate(
                  offset: Offset(0, 10 * (1 - value)), child: child)),
          ));
        }
        if (ebookFile != null && canReadEbook(ebookFile)) {
          addDynamic(Icons.menu_book_rounded, l.readEbook, () => _readEbook(context, auth, title));
        }
        // Save/Send push the file elsewhere, which needs the server's own file
        // entry (with ino) - the cache-synthesized fallback can't serve them.
        if (serverEbookFile != null) {
          addDynamic(
              _ebookSaved ? Icons.download_done_rounded : Icons.save_alt_rounded,
              _ebookSaved ? l.ebookExportedLabel : l.ebookSaveToDevice,
              () => _ebookSaved
                  ? _deleteEbookExport(context)
                  : _exportEbook(context, auth, title));
        }
        if (serverEbookFile != null && auth.ereaderDevices.isNotEmpty) {
          addDynamic(Icons.send_to_mobile_rounded, l.sendToEreader, () => _sendToEreader(context, auth));
        }
        // The main grid is gated on `_pillsReady` (local, fast reads only):
        // a skeleton holds the height briefly, then the grid cross-fades in.
        final skeleton = Wrap(
          key: const ValueKey('pill-skeleton'),
          spacing: gap,
          runSpacing: gap,
          children: List.generate(cols * 2, (i) => Container(
            width: cellW,
            height: cellH,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(16),
            ),
          )),
        );
        return AnimatedSize(
          // Slower than the pill fade so the grid height change (a trailing
          // row appearing on a slow open) trails the pills instead of snapping.
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _pillsReady
                ? Wrap(key: const ValueKey('pills'), spacing: gap, runSpacing: gap, children: pills)
                : skeleton,
          ),
        );
      }),
      ]);
  }

  Widget _quickThumb(double size, Map<String, String> headers, ColorScheme cs) {
    final url = _coverUrl;
    Widget img;
    if (url == null) {
      img = Container(color: cs.surfaceContainerHighest,
        child: Icon(Icons.headphones_rounded, size: 24, color: cs.onSurfaceVariant.withValues(alpha: 0.4)));
    } else if (url.startsWith('/')) {
      img = Image.file(File(url), fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(color: cs.surfaceContainerHighest));
    } else {
      img = CachedNetworkImage(imageUrl: url, fit: BoxFit.cover, httpHeaders: headers,
        useOldImageOnUrlChange: true,
        placeholder: (_, __) => Container(color: cs.surfaceContainerHighest),
        errorWidget: (_, __, ___) => Container(color: cs.surfaceContainerHighest));
    }
    return ClipRRect(borderRadius: BorderRadius.circular(10),
      child: SizedBox(width: size, height: size, child: img));
  }

  Widget _quickAbsorbButton(BuildContext context, ColorScheme cs, TextTheme tt, AuthProvider auth,
      Color accent, Color onAccent, String title, String author, double duration, List<dynamic> chapters, bool isFinished,
      double progress) {
    return ListenableBuilder(
      listenable: Listenable.merge([AudioPlayerService(), DownloadService()]),
      builder: (_, __) {
        final player = AudioPlayerService();
        final isCurrentPlaying = player.currentItemId == widget.itemId && player.isPlaying;
        final showAbsorbingState = _isAbsorbing || isCurrentPlaying;
        final needsDownload = !showAbsorbingState && _needsNarrationDownload(auth);
        final fetching = needsDownload && DownloadService().isDownloading(widget.itemId);
        final fill = fetching ? DownloadService().downloadProgress(widget.itemId) : progress;
        final showFill = fetching || (!needsDownload && progress > 0 && !isFinished);
        return GestureDetector(
          onTap: showAbsorbingState
              ? () async {
                  if (isCurrentPlaying) {
                    final lib = context.read<LibraryProvider>();
                    await _activateQueueSource();
                    unawaited(lib.syncQueueAutoDownloads());
                  }
                  if (!context.mounted) return;
                  Navigator.of(context).popUntil((route) => route.isFirst);
                  AppShell.goToAbsorbingGlobal();
                }
              : () {
                  setState(() => _isAbsorbing = true);
                  _startAbsorb(context, auth: auth, title: title, author: author,
                    coverUrl: _coverUrl, duration: duration, chapters: chapters);
                },
          child: Container(
            height: 36,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(14)),
            child: Stack(children: [
              if (showFill)
                FractionallySizedBox(
                  widthFactor: fill.clamp(0.0, 1.0),
                  child: Container(color: onAccent.withValues(alpha: 0.22)),
                ),
              Positioned.fill(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                showAbsorbingState
                    ? SizedBox(width: 16, height: 16, child: AbsorbingWave(color: onAccent))
                    : needsDownload
                        ? Icon(Icons.download_rounded, size: 16, color: onAccent)
                        : isFinished
                            ? AbsorbReplayIcon(size: 16, color: onAccent)
                            : Icon(Icons.waves_rounded, size: 16, color: onAccent),
                const SizedBox(width: 8),
                Flexible(child: Text(
                  showAbsorbingState
                      ? Wording.of(context).absorbing
                      : fetching
                          ? AppLocalizations.of(context)!.downloadsDownloading
                          : needsDownload
                              ? Wording.of(context).downloadToAbsorb
                              : isFinished
                                  ? Wording.of(context).absorbAgain
                                  : Wording.of(context).absorb,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: onAccent),
                )),
              ])),
            ]),
          ),
        );
      },
    );
  }

  Widget _quickFinishedPill(BuildContext context, ColorScheme cs, AuthProvider auth,
      bool isFinished, double currentTime, double duration) {
    return GestureDetector(
      onTap: () => isFinished
          ? _markNotFinished(context, auth, currentTime, duration)
          : _markFinished(context, auth, duration),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: isFinished ? Colors.green.withValues(alpha: 0.06) : cs.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: isFinished ? Colors.green.withValues(alpha: 0.15) : cs.onSurface.withValues(alpha: 0.08)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(isFinished ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
            size: 16, color: isFinished ? Colors.green : cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(child: Text(isFinished ? Wording.of(context).fullyAbsorbed : Wording.of(context).fullyAbsorbAction,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: isFinished ? Colors.green : cs.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w500))),
        ]),
      ),
    );
  }

  // Grid pill styled like the admin Users page cells: rounded card, centered
  // icon over a short label, fixed height so the Wrap rows line up.
  Widget _quickPill(ColorScheme cs, TextTheme tt, IconData icon, String label, VoidCallback onTap, {Color? tint}) {
    final iconColor = tint ?? cs.onSurfaceVariant;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
        ),
        child: Column(mainAxisSize: MainAxisSize.max, mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 22, color: iconColor),
          const SizedBox(height: 7),
          // Loose Flexible so an extra-long label ellipsises inside the cell at
          // big font scales rather than overflowing the fixed cell height.
          Flexible(child: Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: tt.labelSmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w500, height: 1.15, fontSize: 11))),
        ]),
      ),
    );
  }

  void _showMoreSheet(BuildContext context, AuthProvider auth, LibraryProvider lib,
      String title, String authorName, double progress, bool isFinished,
      double duration, Map<String, dynamic>? ebookFile, bool isEbookOnly,
  ) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    // Continue-shelf actions only make sense when this book is actually shown
    // in the relevant home shelf right now.
    final continueShelf = lib.continueShelfOf(widget.itemId);
    final rawSeries = ((_item?['media'] as Map<String, dynamic>?)?['metadata']
        as Map<String, dynamic>?)?['series'];
    final bookSeriesIds = <String>[];
    if (rawSeries is List) {
      for (final s in rawSeries.whereType<Map<String, dynamic>>()) {
        final id = (s['id'] as String? ?? '').trim();
        if (id.isNotEmpty) bookSeriesIds.add(id);
      }
    } else if (rawSeries is Map<String, dynamic>) {
      final id = (rawSeries['id'] as String? ?? '').trim();
      if (id.isNotEmpty) bookSeriesIds.add(id);
    }
    final continueSeriesId = lib.continueSeriesShelfMatch(bookSeriesIds);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.24), borderRadius: BorderRadius.circular(2)))),
              Flexible(
                child: SingleChildScrollView(
                  child: _actionPillGrid(context, cs, tt, l, auth, lib, title, authorName,
                    progress, isFinished, duration, ebookFile, isEbookOnly,
                    continueShelf, continueSeriesId, dismiss: () => Navigator.pop(ctx)),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }

  /// All ebook versions the detail sheet knows about for this book. When a
  /// book ships several (a big image-packed EPUB/PDF next to a plain text
  /// one, like 极品家丁's 161MB 精校多图 vs the 6MB plain EPUB), lets the user
  /// pick which one to read / export / download and shows each version's size
  /// so the wrong (huge) file doesn't get pulled by accident. A single
  /// version skips the prompt and is returned at once. With [readableOnly]
  /// the list is trimmed to formats the in-app readers can actually open.
  Future<Map<String, dynamic>?> _pickEbook(BuildContext context,
      {bool readableOnly = false, AuthProvider? auth}) async {
    var choices = ebookFileChoices(_item);
    if (readableOnly) {
      final readable = choices.where(canReadEbook).toList();
      if (readable.isNotEmpty) choices = readable;
    }
    if (choices.length <= 1) {
      return choices.isNotEmpty ? choices.first : _cachedEbookFallback;
    }
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final api = auth?.apiService;
    final primary =
        ((_item?['media'] as Map<String, dynamic>?)?['ebookFile'])
            as Map<String, dynamic>?;
    var serverIno = primary?['ino']?.toString();
    // Effective default: a local override (set only when the server can't be
    // changed, e.g. BookOrbit or a failed PATCH), when it's offered in this
    // list, else the server's primary.
    String? localIno = EbookPreferences.defaultIno(widget.itemId);
    if (localIno != null &&
        !choices.any((f) => f['ino']?.toString() == localIno)) {
      localIno = null;
    }
    var effectiveIno = localIno ?? serverIno;
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          Widget tile(Map<String, dynamic> f) {
            final ino = f['ino']?.toString();
            final hasIno = ino != null && ino.isNotEmpty;
            final name = f['metadata']?['filename'] as String? ??
                f['name'] as String? ?? '';
            return _EbookVersionTile(
              leading: Icon(_ebookTypeIcon(f), color: cs.primary),
              title: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: tt.bodyMedium?.copyWith(color: cs.onSurface),
              ),
              subtitle: Text(
                _ebookVersionSubtitle(f, serverIno, localIno, l),
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              trailing: (hasIno && ino == effectiveIno)
                  ? Icon(Icons.check_circle_rounded, color: cs.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, f),
              onLongPress: !hasIno
                  ? null
                  : () async {
                      final isServerPrimary = ino == serverIno;
                      // Nothing to do: already the server default with no
                      // local override on top of it.
                      if (isServerPrimary && localIno == null) {
                        if (context.mounted) {
                          showOverlayToast(context, l.ebookAlreadyDefault,
                              icon: Icons.check_circle_rounded);
                        }
                        return;
                      }
                      // Prefer changing the server's primary (ABS only) so the
                      // choice follows the account onto every device. Fall back
                      // to a local override when the server can't be changed
                      // (BookOrbit, missing permission, offline) or when the
                      // user re-picks the version that's already the primary.
                      var serverDone = false;
                      if (api != null && !isServerPrimary) {
                        serverDone =
                            await api.updateEbookFileStatus(widget.itemId, ino);
                      }
                      if (context.mounted) HapticFeedback.mediumImpact();
                      if (serverDone) {
                        await EbookPreferences.clearDefaultIno(widget.itemId);
                        localIno = null;
                        serverIno = ino;
                        effectiveIno = ino;
                        unawaited(_loadItem());
                        if (context.mounted) {
                          showOverlayToast(context, l.ebookDefaultSet(name),
                              icon: Icons.check_circle_rounded);
                        }
                      } else if (isServerPrimary) {
                        // Server already has this as primary; just drop any
                        // local override so the two agree again.
                        await EbookPreferences.clearDefaultIno(widget.itemId);
                        localIno = null;
                        effectiveIno = serverIno;
                        if (context.mounted) {
                          showOverlayToast(context, l.ebookDefaultCleared,
                              icon: Icons.restore_rounded);
                        }
                      } else if (localIno == ino) {
                        // Long-press the current local pick again to drop it.
                        await EbookPreferences.clearDefaultIno(widget.itemId);
                        localIno = null;
                        effectiveIno = serverIno;
                        if (context.mounted) {
                          showOverlayToast(context, l.ebookDefaultCleared,
                              icon: Icons.restore_rounded);
                        }
                      } else {
                        await EbookPreferences.setDefaultIno(widget.itemId, ino);
                        localIno = ino;
                        effectiveIno = ino;
                        if (context.mounted) {
                          showOverlayToast(context, l.ebookDefaultSet(name),
                              icon: Icons.check_circle_rounded);
                        }
                      }
                      if (ctx.mounted) setSheet(() {});
                    },
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Center(child: Container(width: 40, height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.24), borderRadius: BorderRadius.circular(2)))),
                Text(l.chooseEbookVersion,
                    style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface)),
                const SizedBox(height: 4),
                Text(l.ebookChooseHoldHint,
                    textAlign: TextAlign.center,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final f in choices) tile(f),
                  ]),
                ),
              ]),
            ),
          );
        });
      },
    );
  }

  IconData _ebookTypeIcon(Map<String, dynamic> f) {
    switch (ebookExtFromFile(f)) {
      case '.pdf': return Icons.picture_as_pdf_rounded;
      case '.epub': return Icons.menu_book_rounded;
      case '.cbz': case '.cbr': case '.cb7': return Icons.image_rounded;
      case '.mobi': case '.azw3': return Icons.book_rounded;
      default: return Icons.insert_drive_file_rounded;
    }
  }

  String _ebookVersionSubtitle(
      Map<String, dynamic> f, String? serverIno, String? localIno, AppLocalizations l) {
    final ext = ebookExtFromFile(f).replaceFirst('.', '').toUpperCase();
    final size = ebookFileSize(f);
    final sizeText = size != null ? _fmtSize(size) : '';
    final ino = f['ino']?.toString();
    final parts = <String>[];
    if (ext.isNotEmpty) parts.add(ext);
    if (sizeText.isNotEmpty) parts.add(sizeText);
    if (ino != null && ino == localIno) parts.add(l.ebookLocalDefault);
    if (ino != null && ino == serverIno) parts.add(l.ebookPrimaryVersion);
    return parts.join('  ·  ');
  }

  Future<void> _readEbook(BuildContext context, AuthProvider auth, String title) async {
    final ef = await _pickEbook(context, readableOnly: true, auth: auth);
    if (ef == null || !mounted) return;
    _openEbookReader(context, auth, ef, title);
  }

  Future<void> _exportEbook(BuildContext context, AuthProvider auth, String title) async {
    final ef = await _pickEbook(context, auth: auth);
    if (ef == null || !mounted) return;
    await _saveEbook(context, auth, ef, title);
  }

  Future<void> _offlineEbook(BuildContext context, AuthProvider auth, String title) async {
    final ef = await _pickEbook(context, auth: auth);
    if (ef == null || !mounted) return;
    await _downloadEbookOffline(context, auth, ef, title);
  }

  Future<void> _removeFromContinueListening(
      BuildContext context, AuthProvider auth, LibraryProvider lib, {bool reading = false}) async {
    final l = AppLocalizations.of(context)!;
    final api = auth.apiService;
    final progressId = lib.getProgressData(widget.itemId)?['id'] as String?;
    if (api == null || progressId == null) {
      if (context.mounted) {
        showOverlayToast(context, l.couldNotUpdate, icon: Icons.error_outline_rounded);
      }
      return;
    }
    final ok = await api.removeItemFromContinueListening(progressId);
    if (ok) {
      lib.hideFromContinueShelves(itemId: widget.itemId);
      await lib.refreshProgressShelves(force: true, reason: 'remove-continue-listening');
    }
    if (!context.mounted) return;
    HapticFeedback.mediumImpact();
    showOverlayToast(context,
        ok ? (reading ? l.removedFromContinueReading : l.removedFromContinueListening) : l.couldNotUpdate,
        icon: ok ? Icons.playlist_remove_rounded : Icons.error_outline_rounded);
  }

  Future<void> _removeSeriesFromContinueSeries(
      BuildContext context, AuthProvider auth, LibraryProvider lib, String seriesId) async {
    final l = AppLocalizations.of(context)!;
    final api = auth.apiService;
    if (api == null) {
      if (context.mounted) {
        showOverlayToast(context, l.couldNotUpdate, icon: Icons.error_outline_rounded);
      }
      return;
    }
    final ok = await api.removeSeriesFromContinueListening(seriesId);
    if (ok) {
      lib.hideFromContinueShelves(seriesId: seriesId);
      await lib.refreshProgressShelves(force: true, reason: 'remove-continue-series');
    }
    if (!context.mounted) return;
    HapticFeedback.mediumImpact();
    showOverlayToast(context,
        ok ? l.removedSeriesFromContinueSeries : l.couldNotUpdate,
        icon: ok ? Icons.bookmark_remove_rounded : Icons.error_outline_rounded);
  }

  /// Opens the unified per-book edit page (Chapters / Details / Match / Encode)
  /// from the "..." menu.
  void _openEditPage(AuthProvider auth, String title, bool isEbookOnly) {
    final media = _item!['media'] as Map<String, dynamic>? ?? {};
    final meta = media['metadata'] as Map<String, dynamic>? ?? {};
    final mediaTags = ((media['tags'] as List<dynamic>?) ?? const []).cast<String>();
    final audioFiles = (media['audioFiles'] as List<dynamic>?) ?? const [];
    final libraryFiles = (_item!['libraryFiles'] as List<dynamic>?) ?? const [];
    final rel = _item!['relPath'] as String? ?? '';
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (_) => BookEditScreen(
        itemId: widget.itemId,
        bookTitle: title,
        metadata: meta,
        tags: mediaTags,
        audioFiles: audioFiles,
          libraryFiles: libraryFiles,
          relPath: rel,
        isEbookOnly: isEbookOnly,
        isAdmin: auth.isAdmin,
        libraryId: _item!['libraryId'] as String?,
        isBookDock: BookDockInfo.of(_item) != null,
      ),
    ));
  }

  /// A BookOrbit Book Dock file, shown the way BookOrbit's web Book Dock
  /// shows it: status, match, where it will go, what filing would change,
  /// and its files. It can't be played or downloaded until it is filed.
  Widget _buildDockContent(BuildContext context, ColorScheme cs, TextTheme tt,
      AppLocalizations l, BookDockInfo dock) {
    final accent =
        (PlayerSettings.einkMode ? null : _coverScheme?.primary) ?? cs.primary;
    final auth = context.read<AuthProvider>();
    final lib = context.watch<LibraryProvider>();
    final media = _item!['media'] as Map<String, dynamic>? ?? {};
    final metadata = media['metadata'] as Map<String, dynamic>? ?? {};
    final title = metadata['title'] as String? ?? dock.fileName;
    final subtitle = metadata['subtitle'] as String? ?? '';
    final authorName = metadata['authorName'] as String? ?? '';
    final narratorName = metadata['narratorName'] as String? ?? '';
    final seriesName = metadata['seriesName'] as String? ?? '';
    final descRaw = metadata['description'] as String? ?? '';
    final duration = (media['duration'] as num?)?.toDouble() ?? 0;
    final year = metadata['publishedYear'] as String? ?? '';
    final publisher = metadata['publisher'] as String? ?? '';
    final genres = (metadata['genres'] as List<dynamic>?)?.cast<String>() ?? const [];
    final busy = _dockBusy || lib.isOffline;
    final good = Theme.of(context).brightness == Brightness.dark ? Colors.greenAccent : Colors.green.shade700;
    const warn = Colors.orange;
    final destination = dock.hasDestination ? _libraryName(lib, dock.targetLibraryId!) : null;
    final unitSize = dock.unitFiles.fold<int>(0, (sum, f) => sum + (f.fileSize ?? 0));
    final size = dock.unitFiles.length > 1 && unitSize > 0 ? unitSize : dock.fileSize;

    Color matchColor(int c) => c >= 85 ? good : c >= BookDockInfo.reviewBelow ? warn : cs.error;
    final statusBadge = switch (dock.status) {
      'pending' => (l.bookDockBadgePending, warn),
      'extracting' => (l.bookDockBadgeExtracting, Colors.blue),
      'fetching' => (l.bookDockBadgeFetching, Colors.blue),
      'error' => (l.bookDockBadgeError, cs.error),
      _ => null,
    };

    return ListView(controller: widget.scrollController, padding: EdgeInsets.fromLTRB(20, 8, 20, 32 + MediaQuery.of(context).viewPadding.bottom), children: [
      Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.24), borderRadius: BorderRadius.circular(2)))),
      if (_coverUrl != null) ...[
        Center(child: Container(
          height: 200,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 4))],
          ),
          clipBehavior: Clip.antiAlias,
          child: CachedNetworkImage(
            imageUrl: _coverUrl!, fit: BoxFit.contain,
            httpHeaders: lib.mediaHeaders,
            placeholder: (_, __) => const SizedBox(width: 140),
            errorWidget: (_, __, ___) => Container(
              width: 140,
              color: cs.surfaceContainerHigh,
              child: Icon(Icons.move_to_inbox_rounded, size: 40, color: cs.onSurfaceVariant),
            ),
          ),
        )),
        const SizedBox(height: 16),
      ],
      Text(title, textAlign: TextAlign.center, style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: cs.onSurface)),
      if (subtitle.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(subtitle, textAlign: TextAlign.center, style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
      ],
      for (final line in [authorName.isNotEmpty ? authorName : l.bookDockNoAuthor, narratorName, seriesName])
        if (line.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(line, textAlign: TextAlign.center, style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        ],
      const SizedBox(height: 14),
      Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 6, children: [
        if (statusBadge != null)
          _dockBadge(statusBadge.$1, statusBadge.$2, working: dock.isWorking),
        if (dock.needsReview) _dockBadge(l.bookDockNeedsReview, warn, icon: Icons.flag_outlined),
        if (dock.hasMatch)
          _dockBadge(l.bookDockMatch(dock.confidence!), matchColor(dock.confidence!))
        else if (dock.status == 'ready')
          _dockBadge(l.bookDockNoMatch, cs.onSurfaceVariant),
        if (dock.detailsState == 'edited')
          _dockBadge(l.bookDockApplied, good, icon: Icons.check_rounded)
        else if (dock.detailsState == 'fetched')
          _dockBadge(l.bookDockNotApplied, warn, icon: Icons.auto_fix_high_rounded),
        if (dock.unitFiles.length > 1)
          _dockBadge(l.bookDockFileCount(dock.unitFiles.length), cs.onSurfaceVariant, icon: Icons.folder_copy_outlined),
      ]),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(dock.hasDestination ? Icons.drive_folder_upload_rounded : Icons.error_outline_rounded,
            size: 16, color: dock.hasDestination ? cs.onSurfaceVariant : warn),
        const SizedBox(width: 6),
        Flexible(child: Text(
          dock.hasDestination ? l.bookDockGoesTo(destination ?? l.libraryFallback) : l.bookDockNoDestination,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: tt.bodySmall?.copyWith(color: dock.hasDestination ? cs.onSurfaceVariant : warn),
        )),
      ]),
      const SizedBox(height: 14),
      SizedBox(height: 52, child: FilledButton.icon(
        onPressed: busy || dock.isWorking ? null : () => _fileDockItem(context, auth, lib, title, dock),
        icon: _dockBusy
            ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
            : const Icon(Icons.library_add_rounded, size: 22),
        label: Text(l.bookDockAddToLibrary,
            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onPrimary)),
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      )),
      if (dock.detailsState == 'fetched') ...[
        const SizedBox(height: 8),
        _dockAction(cs, Icons.auto_fix_high_rounded, l.bookDockUseFound,
            busy ? null : () => _useFoundDockDetails(context, auth), color: warn),
      ],
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: _dockAction(cs, Icons.edit_rounded, l.edit,
            busy ? null : () => _openEditPage(auth, title, false))),
        const SizedBox(width: 8),
        Expanded(child: _dockAction(cs, Icons.refresh_rounded, l.bookDockLookUpAgain,
            busy || dock.isWorking ? null : () => _lookUpDockDetails(context, auth))),
        const SizedBox(width: 8),
        Expanded(child: _dockAction(cs, Icons.delete_outline_rounded, l.remove,
            busy ? null : () => _removeDockItem(context, auth, lib, title),
            color: cs.error)),
      ]),
      const SizedBox(height: 18),
      Row(children: [
        Text(l.bookDockProposedChanges, style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
        const Spacer(),
        if (dock.changes.isNotEmpty)
          Text(l.bookDockChangedFields(dock.changes.length), style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
      const SizedBox(height: 8),
      if (dock.changes.isNotEmpty)
        for (final change in dock.changes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 80, child: Text(_dockFieldLabel(l, change.field),
                  style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600))),
              Expanded(child: change.from == null
                  ? Text('+ ${change.to}', style: tt.bodySmall?.copyWith(color: good, fontWeight: FontWeight.w600))
                  : Text.rich(TextSpan(children: [
                      TextSpan(text: change.from, style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant, decoration: TextDecoration.lineThrough)),
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(Icons.arrow_forward_rounded, size: 12, color: cs.onSurfaceVariant),
                        ),
                      ),
                      TextSpan(text: change.to, style: tt.bodySmall?.copyWith(
                          color: cs.onSurface, fontWeight: FontWeight.w600)),
                    ]))),
            ]),
          )
      else if ((dock.errorMessage ?? '').isNotEmpty)
        Text(dock.errorMessage!, style: tt.bodySmall?.copyWith(color: cs.error))
      else
        Text(dock.isWorking ? l.bookDockStillReading : l.bookDockNoChanges,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      if (dock.unitFiles.length > 1) ...[
        const SizedBox(height: 18),
        Text(l.bookDockFilesInEntry(dock.unitFiles.length),
            style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (var i = 0; i < dock.unitFiles.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              SizedBox(width: 28, child: Text('${i + 1}', textAlign: TextAlign.right,
                  style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant))),
              const SizedBox(width: 10),
              Expanded(child: Text(dock.unitFiles[i].fileName, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: tt.bodySmall)),
              const SizedBox(width: 8),
              Text([
                _dockRoleLabel(l, dock.unitFiles[i].role),
                if ((dock.unitFiles[i].fileSize ?? 0) > 0) _fmtSize(dock.unitFiles[i].fileSize!),
              ].join(' \u00b7 '), style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
      ],
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (dock.fileName.isNotEmpty) _chip(Icons.insert_drive_file_outlined, dock.fileName),
        if ((dock.format ?? '').isNotEmpty) _chip(Icons.description_outlined, dock.format!.toUpperCase()),
        if ((size ?? 0) > 0) _chip(Icons.storage_rounded, _fmtSize(size!)),
        if (duration > 0) _chip(Icons.schedule_rounded, formatHm(duration)),
        if (dock.addedAt != null) _chip(Icons.move_to_inbox_rounded, l.bookDockAdded(_fmtDate(dock.addedAt!))),
        if (year.isNotEmpty) _chip(Icons.calendar_today_rounded, year),
        if (publisher.isNotEmpty) _chip(Icons.business_rounded, publisher),
        for (final g in genres) _chip(Icons.tag_rounded, g),
      ]),
      if (descRaw.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(l.aboutSection, style: tt.titleSmall?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        HtmlDescription(
          html: descRaw,
          maxLines: null,
          style: tt.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.7), height: 1.5),
          linkColor: accent,
        ),
      ],
      const SizedBox(height: 20),
    ]);
  }

  String? _libraryName(LibraryProvider lib, String libraryId) {
    for (final library in lib.libraries) {
      if (library is Map && library['id'] == libraryId) return library['name'] as String?;
    }
    return null;
  }

  String _dockFieldLabel(AppLocalizations l, String field) => switch (field) {
        'title' => l.bookDockFieldTitle,
        'subtitle' => l.bookDockFieldSubtitle,
        'authors' => l.bookDockFieldAuthors,
        'seriesName' => l.bookDockFieldSeries,
        'publisher' => l.bookDockFieldPublisher,
        'publishedYear' => l.bookDockFieldYear,
        'language' => l.bookDockFieldLanguage,
        'isbn13' => l.bookDockFieldIsbn,
        _ => field,
      };

  String _dockRoleLabel(AppLocalizations l, String? role) => switch (role) {
        'cover' => l.bookDockRoleCover,
        'metadata' => l.bookDockRoleMetadata,
        'supplement' => l.bookDockRoleExtra,
        _ => l.bookDockRoleBook,
      };

  Widget _dockBadge(String label, Color color, {IconData? icon, bool working = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (working)
          Padding(
            padding: const EdgeInsets.only(right: 5),
            child: SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: color)),
          )
        else if (icon != null)
          Padding(padding: const EdgeInsets.only(right: 4), child: Icon(icon, size: 12, color: color)),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  Future<void> _lookUpDockDetails(BuildContext context, AuthProvider auth) async {
    final l = AppLocalizations.of(context)!;
    final api = auth.apiService;
    if (api == null) return;
    setState(() => _dockBusy = true);
    final ok = await api.lookUpBookDockDetails(widget.itemId);
    if (!mounted) return;
    setState(() => _dockBusy = false);
    if (ok) await _loadItem();
    if (!context.mounted) return;
    showOverlayToast(context, ok ? l.bookDockLookingUp : l.bookDockLookUpFailed,
        icon: ok ? Icons.refresh_rounded : Icons.error_outline_rounded);
  }

  Widget _dockAction(ColorScheme cs, IconData icon, String label, VoidCallback? onTap, {Color? color}) {
    final c = color ?? cs.onSurfaceVariant;
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 36,
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 16, color: c),
            const SizedBox(width: 6),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w500))),
          ]),
        ),
      ),
    );
  }

  Future<void> _fileDockItem(BuildContext context, AuthProvider auth,
      LibraryProvider lib, String title, BookDockInfo dock) async {
    final l = AppLocalizations.of(context)!;
    final api = auth.apiService;
    if (api == null) return;
    setState(() => _dockBusy = true);
    final destinations = await api.bookDockDestinations();
    if (!mounted) return;
    setState(() => _dockBusy = false);
    if (destinations.isEmpty) {
      showOverlayToast(context, l.bookDockNoLibraries, icon: Icons.lock_outline_rounded);
      return;
    }
    final picked = await _pickDockDestination(context, destinations, dock);
    if (picked == null || !mounted) return;
    final navigator = Navigator.of(context);
    final rootNavigator = rootNavigatorKey.currentState;
    setState(() => _dockBusy = true);
    final result = await api.fileBookDockItem(widget.itemId, picked);
    if (!mounted) return;
    setState(() => _dockBusy = false);
    if (result.success) {
      if (navigator.canPop()) navigator.pop();
      await lib.refresh();
      showNavigatorOverlayToast(rootNavigator, l.bookDockFiled(title, picked.libraryName),
          icon: Icons.library_add_check_rounded);
    } else if (result.duplicate) {
      final remove = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.bookDockDuplicateTitle(picked.libraryName)),
          content: Text(l.bookDockDuplicateBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.remove)),
          ],
        ),
      );
      if (remove == true && mounted && context.mounted) {
        await _removeDockItem(context, auth, lib, title, confirm: false);
      }
    } else {
      final reason = result.message ?? '';
      showOverlayToast(
        context,
        reason.isNotEmpty ? l.bookDockFileFailedReason(reason) : l.bookDockFileFailed,
        icon: Icons.error_outline_rounded,
      );
    }
  }

  Future<BookDockDestination?> _pickDockDestination(BuildContext context,
      List<BookDockDestination> destinations, BookDockInfo dock) {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    // A library with more than one folder names the folder too.
    final folderCount = <String, int>{};
    for (final d in destinations) {
      folderCount[d.libraryId] = (folderCount[d.libraryId] ?? 0) + 1;
    }
    return showModalBottomSheet<BookDockDestination>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(l.bookDockPickLibrary, style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 16), children: [
                for (final d in destinations)
                  ListTile(
                    leading: Icon(Icons.auto_stories_rounded, color: cs.onSurfaceVariant),
                    title: Text(d.libraryName),
                    subtitle: (folderCount[d.libraryId] ?? 0) > 1 ? Text(d.folderName) : null,
                    // The destination BookOrbit already set for this file.
                    trailing: d.libraryId == dock.targetLibraryId && d.folderId == dock.targetFolderId
                        ? Icon(Icons.check_circle_rounded, color: cs.primary)
                        : null,
                    onTap: () => Navigator.pop(ctx, d),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _removeDockItem(BuildContext context, AuthProvider auth,
      LibraryProvider lib, String title, {bool confirm = true}) async {
    final l = AppLocalizations.of(context)!;
    final api = auth.apiService;
    if (api == null) return;
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.bookDockRemoveTitle),
          content: Text(l.bookDockRemoveBody(title)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.remove, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ),
          ],
        ),
      );
      if (ok != true || !mounted || !context.mounted) return;
    }
    final navigator = Navigator.of(context);
    final rootNavigator = rootNavigatorKey.currentState;
    setState(() => _dockBusy = true);
    final ok = await api.removeBookDockItem(widget.itemId);
    if (!mounted) return;
    setState(() => _dockBusy = false);
    if (ok) {
      if (navigator.canPop()) navigator.pop();
      await lib.refresh();
      showNavigatorOverlayToast(rootNavigator, l.bookDockRemoved(title),
          icon: Icons.delete_outline_rounded);
    } else if (context.mounted) {
      showOverlayToast(context, l.bookDockRemoveFailed, icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _useFoundDockDetails(BuildContext context, AuthProvider auth) async {
    final l = AppLocalizations.of(context)!;
    final api = auth.apiService;
    if (api == null) return;
    setState(() => _dockBusy = true);
    final ok = await api.useFoundBookDockDetails(widget.itemId);
    if (!mounted) return;
    setState(() => _dockBusy = false);
    if (ok) await _loadItem();
    if (!context.mounted) return;
    showOverlayToast(context, ok ? l.bookDockDetailsUpdated : l.bookDockUseFoundFailed,
        icon: ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded);
  }

  List<Widget> _audioInfoChips(Map<String, dynamic> media) {
    final audioFiles = media['audioFiles'] as List<dynamic>?;
    if (audioFiles == null || audioFiles.isEmpty) return [];
    final first = audioFiles.first as Map<String, dynamic>;
    final codec = (first['codec'] as String?)?.toUpperCase();
    final bitRate = (first['bitRate'] as num?)?.toInt();
    // Sum size across all audio files
    int totalSize = 0;
    for (final af in audioFiles) {
      if (af is Map<String, dynamic>) {
        final meta = af['metadata'] as Map<String, dynamic>?;
        totalSize += (meta?['size'] as num?)?.toInt() ?? 0;
      }
    }
    final l = AppLocalizations.of(context)!;
    final item = _item;
    final showFiles = item == null ? null : () => showBookFilesSheet(context, item);
    return [
      if (codec != null && codec.isNotEmpty) _chip(Icons.audio_file_rounded, codec, onTap: showFiles),
      if (bitRate != null && bitRate > 0) _chip(Icons.speed_rounded, l.kbpsValue((bitRate / 1000).round()), onTap: showFiles),
      if (totalSize > 0) _chip(Icons.storage_rounded, _fmtSize(totalSize), onTap: showFiles),
    ];
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).round()} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  Widget _chip(IconData icon, String text, {Key? key, VoidCallback? onTap}) {
    return BookDetailInfoChip(key: key, icon: icon, label: text, onTap: onTap);
  }

  String _fmtDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  Future<void> _editProgressDate({
    required AuthProvider auth,
    required LibraryProvider lib,
    required bool editingFinishedDate,
    required int startedAt,
    int? finishedAt,
  }) async {
    if (_isUpdatingProgressDate) return;
    final l = AppLocalizations.of(context)!;
    final api = auth.apiService;
    if (api == null || lib.isOffline) {
      showOverlayToast(
        context,
        l.failedToUpdateCheckConnection,
        icon: Icons.cloud_off_rounded,
      );
      return;
    }

    final currentTimestamp = editingFinishedDate ? finishedAt : startedAt;
    if (currentTimestamp == null) return;
    final initialDate = DateUtils.dateOnly(
      DateTime.fromMillisecondsSinceEpoch(currentTimestamp),
    );
    var firstDate = DateTime(1900);
    var lastDate = DateUtils.dateOnly(DateTime.now());
    if (editingFinishedDate) {
      final startedDate = DateUtils.dateOnly(
        DateTime.fromMillisecondsSinceEpoch(startedAt),
      );
      if (startedDate.isAfter(firstDate)) firstDate = startedDate;
    } else if (finishedAt != null) {
      final finishedDate = DateUtils.dateOnly(
        DateTime.fromMillisecondsSinceEpoch(finishedAt),
      );
      if (finishedDate.isBefore(lastDate)) lastDate = finishedDate;
    }
    if (initialDate.isBefore(firstDate)) firstDate = initialDate;
    if (initialDate.isAfter(lastDate)) lastDate = initialDate;

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: editingFinishedDate ? l.dateFinished : l.dateStarted,
      cancelText: l.cancel,
      confirmText: l.save,
    );
    if (picked == null || !mounted) return;
    if (picked.year == initialDate.year &&
        picked.month == initialDate.month &&
        picked.day == initialDate.day) {
      return;
    }

    final timestamp = DateTime.utc(
      picked.year,
      picked.month,
      picked.day,
      12,
    ).millisecondsSinceEpoch;
    setState(() => _isUpdatingProgressDate = true);
    final updated = editingFinishedDate
        ? await api.updateProgressFinishedDate(widget.itemId, timestamp)
        : await api.updateProgressStartDate(widget.itemId, timestamp);
    if (!mounted) return;
    setState(() => _isUpdatingProgressDate = false);

    if (updated) {
      lib.applyLocalProgressDates(
        widget.itemId,
        startedAt: editingFinishedDate ? null : timestamp,
        finishedAt: editingFinishedDate ? timestamp : null,
      );
      showOverlayToast(
        context,
        l.sessionSaved,
        icon: Icons.event_available_rounded,
      );
    } else {
      showOverlayToast(
        context,
        l.sessionSaveFailed,
        icon: Icons.error_outline_rounded,
      );
    }
  }


  List<Widget> _buildStars(double rating, Color accent) {
    final cs = Theme.of(context).colorScheme;
    final stars = <Widget>[];
    final fullStars = rating.floor();
    final hasHalf = (rating - fullStars) >= 0.4;
    for (int i = 0; i < 5; i++) {
      if (i < fullStars) {
        stars.add(Icon(Icons.star_rounded, size: 16, color: accent));
      } else if (i == fullStars && hasHalf) {
        stars.add(Icon(Icons.star_half_rounded, size: 16, color: accent));
      } else {
        stars.add(Icon(Icons.star_outline_rounded, size: 16, color: cs.onSurface.withValues(alpha: 0.24)));
      }
    }
    return stars;
  }

  static String get _audibleDomain {
    final code = (ui.PlatformDispatcher.instance.locale.countryCode ?? 'US').toUpperCase();
    const domains = {
      'US': 'audible.com',
      'GB': 'audible.co.uk',
      'AU': 'audible.com.au',
      'CA': 'audible.ca',
      'DE': 'audible.de',
      'FR': 'audible.fr',
      'IT': 'audible.it',
      'ES': 'audible.es',
      'JP': 'audible.co.jp',
      'IN': 'audible.in',
      'BR': 'audible.com.br',
    };
    return domains[code] ?? 'audible.com';
  }

  static String _formatRatingCount(int count, String locale) {
    try {
      return NumberFormat.decimalPattern(locale).format(count);
    } catch (_) {
      return NumberFormat.decimalPattern().format(count);
    }
  }

  void _showAudibleReviews(BuildContext context) {
    final asin = _asin;
    if (asin == null) return;
    final url = 'https://www.$_audibleDomain/pd/$asin#customer-reviews';
    final cs = Theme.of(context).colorScheme;

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(cs.surface)
      ..loadRequest(Uri.parse(url));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      enableDrag: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.92,
        child: Container(
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(width: 32, height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(2))),
                  Row(
                    children: [
                      const Spacer(),
                      IconButton(
                        icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: SizedBox.expand(
                child: WebViewWidget(
                  controller: controller,
                  gestureRecognizers: {
                    Factory<VerticalDragGestureRecognizer>(
                      () => VerticalDragGestureRecognizer(),
                    ),
                  },
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // The name and its comma are one Wrap child so the comma can never start
  // the next line. Padding makes the tap target the full line height, not
  // just the glyphs, so a thumb between two stacked links lands on one.
  Widget _nameLink(String name, TextStyle? linkStyle, TextStyle? commaStyle,
      {required bool comma, required VoidCallback onTap}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(2, 6, comma ? 0 : 2, 6),
              child: Text(name, style: linkStyle),
            ),
          ),
        ),
        if (comma)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(', ', style: commaStyle),
          ),
      ],
    );
  }

  Widget _buildAuthorLinks(BuildContext context, Map<String, dynamic> metadata, ColorScheme cs, TextTheme tt, Color accent) {
    final authors = metadata['authors'] as List<dynamic>? ?? [];
    // Fall back to authorName string if no structured authors array
    if (authors.isEmpty) {
      final name = metadata['authorName'] as String? ?? '';
      if (name.isEmpty) return const SizedBox.shrink();
      return Text(name, textAlign: TextAlign.center, style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant));
    }

    const int collapsedCount = 3;
    final showAll = _authorsExpanded || authors.length <= collapsedCount;
    final visible = showAll ? authors : authors.sublist(0, collapsedCount);
    final remaining = authors.length - collapsedCount;

    final linkStyle = tt.bodyMedium?.copyWith(
      color: accent,
      decoration: TextDecoration.underline,
      decorationColor: accent.withValues(alpha: 0.4),
    );
    final commaStyle = tt.bodyMedium?.copyWith(color: accent);

    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        for (int i = 0; i < visible.length; i++)
          _nameLink(
            (visible[i] as Map<String, dynamic>?)?['name'] as String? ?? '',
            linkStyle,
            commaStyle,
            comma: i < visible.length - 1 || (!showAll && remaining > 0),
            onTap: () {
              final a = visible[i] as Map<String, dynamic>? ?? {};
              final id = a['id'] as String? ?? '';
              final name = a['name'] as String? ?? '';
              if (id.isEmpty || name.isEmpty) return;
              showAuthorDetailSheet(context, authorId: id, authorName: name);
            },
          ),
        if (!showAll)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _authorsExpanded = true),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Text(AppLocalizations.of(context)!.andCountMore(remaining), style: tt.bodyMedium?.copyWith(
                color: accent.withValues(alpha: 0.7),
              )),
            ),
          ),
      ],
    );
  }

  Widget _buildNarratorLinks(BuildContext context, Map<String, dynamic> metadata, ColorScheme cs, TextTheme tt, Color accent) {
    final raw = metadata['narrators'] as List<dynamic>? ?? [];
    final names = <String>[
      for (final n in raw)
        if (n is String && n.trim().isNotEmpty)
          n.trim()
        else if (n is Map<String, dynamic>)
          (n['name'] as String? ?? '').trim()
    ].where((s) => s.isNotEmpty).toList();

    if (names.isEmpty) {
      final fallback = (metadata['narratorName'] as String? ?? '').trim();
      if (fallback.isEmpty) return const SizedBox.shrink();
      names.addAll(fallback.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty));
    }
    if (names.isEmpty) return const SizedBox.shrink();

    final l = AppLocalizations.of(context)!;
    // Split the localized "Narrated by {narrator}" template so we can prepend
    // the prefix (and append any suffix, e.g. Chinese colon) around clickable
    // narrator links.
    final parts = l.narratedBy('||X||').split('||X||');
    final prefix = parts.isNotEmpty ? parts[0] : '';
    final suffix = parts.length > 1 ? parts[1] : '';

    const int collapsedCount = 3;
    final showAll = _narratorsExpanded || names.length <= collapsedCount;
    final visible = showAll ? names : names.sublist(0, collapsedCount);
    final remaining = names.length - collapsedCount;

    final baseStyle = tt.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final linkStyle = tt.bodySmall?.copyWith(
      color: accent,
      decoration: TextDecoration.underline,
      decorationColor: accent.withValues(alpha: 0.4),
    );
    final commaStyle = tt.bodySmall?.copyWith(color: accent);

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        alignment: WrapAlignment.center,
        children: [
          if (prefix.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(prefix, style: baseStyle),
            ),
          for (int i = 0; i < visible.length; i++)
            _nameLink(
              visible[i],
              linkStyle,
              commaStyle,
              comma: i < visible.length - 1 || (!showAll && remaining > 0),
              onTap: () => showNarratorBooksSheet(context, narratorName: visible[i]),
            ),
          if (!showAll)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _narratorsExpanded = true),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                child: Text(l.andCountMore(remaining), style: tt.bodySmall?.copyWith(
                  color: accent.withValues(alpha: 0.7),
                )),
              ),
            ),
          if (suffix.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(suffix, style: baseStyle),
            ),
        ],
      ),
    );
  }

  Future<void> _openSeries(BuildContext context, String? seriesId, String seriesName) async {
    if (seriesId == null) return;
    final auth = context.read<AuthProvider>();
    final itemLibraryId = _item?['libraryId'] as String?;
    // This book is in the series by definition, so the sheet can show it at
    // once instead of a spinner while the server answers.
    final item = _item;
    showSeriesBooksSheet(
      context,
      seriesName: seriesName,
      seriesId: seriesId,
      books: item != null ? [item] : const [],
      serverUrl: auth.serverUrl,
      token: auth.token,
      libraryId: itemLibraryId,
    );
  }

  void _openEbookReader(BuildContext context, AuthProvider auth, Map<String, dynamic> ebookFile, String title) {
    openEbookReader(context, itemId: widget.itemId, title: title, ebookFile: ebookFile);
  }

  /// Caches the ebook for offline reading and registers it as a download so it
  /// shows in the offline library and its detail sheet loads offline. Distinct
  /// from "Save to device", which exports a copy elsewhere.
  Future<void> _downloadEbookOffline(
      BuildContext context, AuthProvider auth, Map<String, dynamic> ebookFile, String title) async {
    if (_ebookOfflineDownloading) return;
    final l = AppLocalizations.of(context)!;
    final api = auth.apiService;
    if (api == null) return;
    final ok = await confirmDownload(context, title, sizeBytes: ebookFileSize(ebookFile));
    if (!ok || !mounted) return;
    setState(() => _ebookOfflineDownloading = true);
    try {
      await NarrationService.instance.readerFile(api, widget.itemId, ebookFile, title);
      await DownloadService().registerEbookDownload(
        api: api,
        itemId: widget.itemId,
        item: _item,
        libraryId: _item?['libraryId'] as String?,
        ebookFile: ebookFile,
      );
      if (mounted) {
        setState(() => _ebookOfflineDownloading = false);
        showOverlayToast(context, l.ebookSavedOffline, icon: Icons.download_done_rounded);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _ebookOfflineDownloading = false);
        showOverlayToast(context, l.ebookOfflineFailed, icon: Icons.error_outline_rounded);
      }
    }
  }

  Future<void> _removeEbookOffline(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    await DownloadService().deleteDownload(widget.itemId, byUser: true);
    if (mounted) showOverlayToast(context, l.ebookRemovedOffline, icon: Icons.delete_outline_rounded);
  }

  bool _ebookSaving = false;

  Future<void> _saveEbook(BuildContext context, AuthProvider auth, Map<String, dynamic> ebookFile, String bookTitle) async {
    if (_ebookSaving) return;
    final l = AppLocalizations.of(context)!;
    final dl = DownloadService();

    // Always confirm the export before writing. With a custom download folder
    // set (Android SAF) the copy lands straight in its "ebooks" subfolder; the
    // prompt keeps the download/export distinction explicit either way.
    final hasSafExportFolder =
        dl.customDownloadUri != null && dl.customDownloadUri!.isNotEmpty;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final sizeBytes = ebookFileSize(ebookFile);
        return AlertDialog(
          title: Text(l.ebookSaveToDeviceTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.ebookSaveToDeviceBody),
              if (sizeBytes != null && sizeBytes > 0) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Icon(Icons.storage_rounded, size: 16,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text('${l.fileSize}: ${_fmtSize(sizeBytes)}',
                      style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                ]),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.ebookSaveToDevice)),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _ebookSaving = true);

    try {
      final api = auth.apiService;
      if (api == null) return;

      final ino = ebookFile['ino'] as String?;
      if (ino == null) {
        if (mounted) {
          showOverlayToast(
            context,
            l.noEbookFileFound,
            icon: Icons.error_outline_rounded,
          );
        }
        return;
      }

      final ebookName = ebookFile['metadata']?['filename'] as String? ?? ebookFile['name'] as String? ?? '';
      final ext = ebookName.contains('.')
          ? ebookName.substring(ebookName.lastIndexOf('.'))
          : '.epub';

      // Prefer the original server-side filename for the exported copy; fall
      // back to the book title (kept intact for non-ASCII scripts) when it's
      // missing. The legacy ASCII-only '\w' scrub would strip CJK titles to
      // nothing and produce a bare ".epub".
      final rawName = ebookName.trim();
      final exportName = rawName.isNotEmpty &&
              !rawName.contains('/') && !rawName.contains('\\')
          ? rawName
          : (() {
              final cleanTitle = bookTitle
                  .replaceAll(RegExp(r'[^\p{L}\p{N}\s\-_]', unicode: true), '')
                  .trim();
              return cleanTitle.isEmpty ? 'book.epub' : '$cleanTitle$ext';
            })();

      // Reuse the reader's offline cache when this book's ebook is already on
      // the device: exporting a cached book must not hit the network. The cache
      // is keyed by itemId + format (ebookCacheFileFor derives the same
      // extension this export would write), so a hit is the exact file.
      final readerCache = await ebookCacheFileFor(widget.itemId, ebookFile);
      final cacheDir = await getTemporaryDirectory();
      final cachedFile = File('${cacheDir.path}/$exportName');
      final sourceFile = readerCache.existsSync() ? readerCache : cachedFile;

      if (!sourceFile.existsSync()) {
        final cleanBase = api.baseUrl.endsWith('/') ? api.baseUrl.substring(0, api.baseUrl.length - 1) : api.baseUrl;
        final url = api.isBookOrbit
            ? api.buildEbookUrl(widget.itemId, ino)
            : '$cleanBase/api/items/${widget.itemId}/file/$ino';

        // Use streamed download with proper headers (including custom
        // reverse-proxy headers) and manual redirect following so auth
        // headers are preserved across redirects.
        final request = http.Request('GET', Uri.parse(url));
        request.followRedirects = false;
        api.mediaHeaders.forEach((k, v) => request.headers[k] = v);
        final client = http.Client();
        try {
          var response = await client.send(request);

          // Manually follow redirects while preserving auth headers
          var redirects = 0;
          while ([301, 302, 303, 307, 308].contains(response.statusCode) && redirects < 5) {
            final location = response.headers['location'];
            if (location == null) break;
            final redirectUrl = Uri.parse(url).resolve(location);
            final rReq = http.Request('GET', redirectUrl);
            api.mediaHeaders.forEach((k, v) => rReq.headers[k] = v);
            rReq.followRedirects = false;
            response = await client.send(rReq);
            redirects++;
          }

          if (response.statusCode != 200) {
            if (mounted) {
              showOverlayToast(
                context,
                l.failedToDownloadEbook(response.statusCode),
                icon: Icons.error_outline_rounded,
              );
            }
            return;
          }

          // Sanity-check: if the server returned HTML instead of a binary
          // file, the download is likely an error/login page.
          final ct = response.headers['content-type'] ?? '';
          if (ct.contains('text/html')) {
            debugPrint('[Ebook] Server returned HTML instead of ebook file (content-type: $ct)');
            if (mounted) {
              showOverlayToast(
                context,
                l.serverReturnedErrorPage,
                icon: Icons.error_outline_rounded,
              );
            }
            return;
          }

          final sink = cachedFile.openWrite();
          registerInFlightWrite(cachedFile.path);
          try {
            await response.stream.pipe(sink);
          } finally {
            await sink.close();
            unregisterInFlightWrite(cachedFile.path);
          }
        } finally {
          client.close();
        }
      }

      // With a custom download location the file lands in its "ebooks"
      // subfolder (sibling of where audiobooks download) without further
      // prompting; fall back to the manual dialog when that fails or when
      // there is no stable parent folder to write to.
      String? savedPath;
      String? savedMetaUri;
      if (hasSafExportFolder) {
        final moved = await dl.saveEbookCopyToSaf(
          sourceFile.path,
          exportName,
          jsonEncode({
            'itemId': widget.itemId,
            'title': bookTitle,
            'ino': ino,
          }),
        );
        if (moved != null) {
          savedPath = moved.fileUri;
          savedMetaUri = moved.metaUri;
        } else {
          final bytes = await sourceFile.readAsBytes();
          savedPath = await FilePicker.platform.saveFile(
            dialogTitle: l.saveEbook,
            fileName: exportName,
            bytes: Uint8List.fromList(bytes),
          );
        }
      } else {
        final bytes = await sourceFile.readAsBytes();
        savedPath = await FilePicker.platform.saveFile(
          dialogTitle: l.saveEbook,
          fileName: exportName,
          bytes: Uint8List.fromList(bytes),
        );
      }

      if (savedPath == null) return; // user cancelled

      // Track that this ebook has been saved and where the copy landed
      // (content:// URI or file path) so the "exported" button can offer a
      // delete with a real target. The optional `<name>.absorb-ebook` metadata
      // URI is stored too, so it's removed together with the copy.
      await dl.recordSavedEbook(widget.itemId, savedPath, savedMetaUri, ino);
      // The export is now the on-device copy: drop the reader cache for this
      // exact version so the book isn't stored twice. The reader reads the
      // exported copy in place next time (see resolveEbookOpenSource).
      await deleteCachedEbookVersion(widget.itemId, ebookFile);
      if (mounted) setState(() => _ebookSaved = true);

      if (mounted) {
        showOverlayToast(
          context,
          hasSafExportFolder
              ? l.ebookExportedToFolder(exportName)
              : l.ebookSaved(exportName),
          icon: Icons.download_done_rounded,
        );
      }
    } catch (e) {
      debugPrint('[Ebook] Save error: $e');
      if (mounted) {
        showOverlayToast(
          context,
          l.errorSavingEbook(e.toString()),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _ebookSaving = false);
    }
  }

  /// Remove the exported ebook copy for this book and flip the button back to
  /// "export". Always confirmed by the user first; a missing/stale reference
  /// (e.g. old records from before refs were stored) just clears the state.
  Future<void> _deleteEbookExport(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.ebookDeleteExportTitle),
        content: Text(l.ebookDeleteExportBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.ebookDeleteExportConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final ref = await DownloadService().savedEbookRef(widget.itemId);
    if (ref != null) {
      if (ref.uri != null && ref.uri!.isNotEmpty) {
        await DownloadService().deleteBookFileAt(ref.uri!);
      }
      if (ref.meta != null && ref.meta!.isNotEmpty) {
        await DownloadService().deleteBookFileAt(ref.meta!);
      }
    }
    await DownloadService().clearSavedEbook(widget.itemId);

    if (mounted) {
      setState(() => _ebookSaved = false);
      showOverlayToast(context, l.ebookExportDeleted,
          icon: Icons.delete_outline_rounded);
    }
  }

  Future<void> _sendToEreader(BuildContext context, AuthProvider auth) async {
    final api = auth.apiService;
    final devices = auth.ereaderDevices;
    if (api == null || devices.isEmpty) return;
    final l = AppLocalizations.of(context)!;

    String? deviceName;
    if (devices.length == 1) {
      deviceName = devices.first['name'] as String?;
    } else {
      deviceName = await _pickEreaderDevice(context, devices);
    }
    if (deviceName == null || !context.mounted) return;

    showOverlayToast(context, l.sendingToEreader(deviceName),
        icon: Icons.send_to_mobile_rounded);

    final ok = await api.sendEBookToDevice(
      libraryItemId: widget.itemId,
      deviceName: deviceName,
    );
    if (!context.mounted) return;
    if (ok) {
      showOverlayToast(context, l.sendToEreaderSuccess(deviceName),
          icon: Icons.check_circle_outline_rounded);
    } else {
      showOverlayToast(context, l.sendToEreaderFailed,
          icon: Icons.error_outline_rounded);
    }
  }

  Future<String?> _pickEreaderDevice(
      BuildContext context, List<Map<String, dynamic>> devices) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context)!;
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: cs.onSurface.withValues(alpha: 0.24), borderRadius: BorderRadius.circular(2)))),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(l.pickEreaderDevice,
                  style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                    color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: devices.map((d) {
                    final name = d['name'] as String? ?? '';
                    final email = d['email'] as String? ?? '';
                    return ListTile(
                      leading: Icon(Icons.send_to_mobile_rounded, color: cs.onSurfaceVariant),
                      title: Text(name),
                      subtitle: Text(email, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5))),
                      onTap: () => Navigator.pop(ctx, name),
                    );
                  }).toList(),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }

  /// Where a preview should start. Front matter (credits, dedication, intro)
  /// is always short, so the first chapter long enough to be real prose is the
  /// sample point - capped to the first 10% of the book so a preview can never
  /// spoil. Books without a usable chapter land shortly past the credits.
  /// Returns the start point and the rule that produced it. Every branch here
  /// can land on the same number, so the reason has to be logged alongside it
  /// or a "preview started somewhere odd" report is undiagnosable.
  ({double seconds, String why}) _previewStartSeconds(
      List<dynamic> chapters, double duration) {
    const minRealChapter = 300.0;
    const fallback = 90.0;
    final clampedFallback = duration * 0.25 < fallback ? duration * 0.25 : fallback;
    final spoilerCap = duration * 0.10;
    var index = -1;
    for (final c in chapters) {
      index++;
      if (c is! Map<String, dynamic>) continue;
      final start = (c['start'] as num?)?.toDouble() ?? 0;
      final end = (c['end'] as num?)?.toDouble() ?? 0;
      if (end - start >= minRealChapter && start <= spoilerCap) {
        // A qualifying chapter at 0:00 means the credits are baked into it
        // (single-file books) - nudge past them instead.
        if (start == 0) {
          return (
            seconds: clampedFallback,
            why: 'chapter[$index] qualifies but starts at 0:00, nudged past credits'
          );
        }
        return (
          seconds: start,
          why: 'chapter[$index] is ${(end - start).toStringAsFixed(0)}s long '
              'and starts at ${start.toStringAsFixed(0)}s (cap ${spoilerCap.toStringAsFixed(0)}s)'
        );
      }
    }
    return (
      seconds: clampedFallback,
      why: 'no chapter >=${minRealChapter.toInt()}s starting within the first '
          '${spoilerCap.toStringAsFixed(0)}s, fell back'
    );
  }

  Future<void> _togglePreview(BuildContext context, List<dynamic> chapters, double duration) async {
    final l = AppLocalizations.of(context)!;
    if (_preview?.isLoading ?? false) {
      // Every tap is a no-op while loading, which reads as a dead button if the
      // audio never finishes buffering.
      debugPrint('[Preview] book ${widget.itemId}: tap ignored, still loading');
      return;
    }
    if (_preview?.isPlaying ?? false) {
      await _preview!.stop();
      return;
    }
    _preview ??= BookmarkPreviewPlayer(
        itemId: widget.itemId,
        api: context.read<AuthProvider>().apiService,
        label: 'book')
      ..clipLength = const Duration(minutes: 5)
      ..stopOnClipEnd = true
      ..addListener(_onPreviewChanged);
    final pick = _previewStartSeconds(chapters, duration);
    debugPrint('[Preview] book ${widget.itemId}: start ${pick.seconds.toStringAsFixed(1)}s '
        'of ${duration.toStringAsFixed(0)}s across ${chapters.length} chapters - ${pick.why}');
    try {
      await _preview!.toggleAt(pick.seconds);
    } catch (e) {
      debugPrint('[Preview] book ${widget.itemId}: failed: $e');
      // stop() resumes the main book we paused and resets for a retry.
      await _preview?.stop();
      if (mounted) {
        showOverlayToast(context, l.bookmarkPreviewFailed, icon: Icons.error_outline_rounded);
      }
    }
  }

  void _onPreviewChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _activateQueueSource() async {
    final playlistId = widget.sourcePlaylistId;
    final collectionId = widget.sourceCollectionId;
    if (playlistId != null && playlistId.isNotEmpty) {
      await PlayerSettings.setQueueModePlaylist(playlistId);
    } else if (collectionId != null && collectionId.isNotEmpty) {
      await PlayerSettings.setQueueModeCollection(
        collectionId,
        widget.sourceCollectionName ?? '',
      );
    }
  }

  Future<void> _restoreActivatedQueueSource(QueueModeSnapshot backup) async {
    final playlistId = widget.sourcePlaylistId;
    final collectionId = widget.sourceCollectionId;
    if (playlistId != null && playlistId.isNotEmpty) {
      await PlayerSettings.restoreQueueModeIfPlaylistActive(playlistId, backup);
    } else if (collectionId != null && collectionId.isNotEmpty) {
      await PlayerSettings.restoreQueueModeIfCollectionActive(
          collectionId, backup);
    }
  }

  /// [startTime] plays from there instead of the saved position (a chapter
  /// tapped in the list); on the live session it is a seek.
  Future<void> _startAbsorb(BuildContext context, {required AuthProvider auth, required String title, required String author, required String? coverUrl, required double duration, required List<dynamic> chapters, double? startTime}) async {
    // An Audiobookshelf narrated EPUB that can't stream right now plays once
    // its narration is downloaded: asked first, with the reason.
    if (_needsNarrationDownload(auth)) {
      if (mounted) setState(() => _isAbsorbing = false);
      if (DownloadService().isDownloading(widget.itemId)) {
        showOverlayToast(context, AppLocalizations.of(context)!.narrationDownloadStarted, icon: Icons.download_rounded);
        return;
      }
      await showNarrationDownloadDialog(
        context,
        itemId: widget.itemId,
        title: title,
        author: author,
        coverUrl: coverUrl,
        libraryId: _item?['libraryId'] as String?,
      );
      return;
    }
    // Leaving the reader may still be finding this book's spot in the audio:
    // wait for it, so playback starts at the page rather than moving later.
    final finding = ReadListenSync.instance.audioSpotBeingFound(widget.itemId);
    if (startTime == null && finding != null) {
      debugPrint('[SyncSpot] ${widget.itemId}: waiting for the reading spot before playing');
      final t = await finding.timeout(const Duration(seconds: 20), onTimeout: () => null);
      if (!context.mounted) return;
      if (t != null) startTime = t;
    }
    // Discard, not stop: we're about to start playback ourselves, so briefly
    // resuming the previous book would just be an audible blip.
    await _preview?.discard();
    final player = AudioPlayerService();
    // Grab the root navigator before we pop the sheet
    final rootNav = Navigator.of(context, rootNavigator: true);
    final lib = context.read<LibraryProvider>();

    if (player.currentItemId == widget.itemId) {
      await _activateQueueSource();
      if (startTime != null) {
        await player.seekTo(Duration(milliseconds: (startTime * 1000).round()));
      }
      if (!player.isPlaying) await player.play(fromUi: true);
      unawaited(lib.syncQueueAutoDownloads());
      rootNav.popUntil((route) => route.isFirst);
      Future.delayed(const Duration(milliseconds: 100), () {
        AppShell.goToAbsorbingGlobal();
      });
      return;
    }
    final api = auth.apiService;
    if (api == null) return;
    final queueModeBackup = await PlayerSettings.queueModeSnapshot();
    await _activateQueueSource();

    // Pop sheets and switch tab BEFORE starting playback. Otherwise the
    // auto-expand triggered by playItem pushes the expanded player on top
    // of the sheet, and the popUntil below kills the expanded player too.
    rootNav.popUntil((route) => route.isFirst);
    AppShell.goToAbsorbingGlobal();

    final error = await player.playItem(api: api, itemId: widget.itemId, title: title, author: author, coverUrl: coverUrl, totalDuration: duration, chapters: chapters, libraryId: _item?['libraryId'] as String?, seriesId: seriesIdFromItem(_item), fromUi: true, startTime: startTime ?? 0, forceStartTime: startTime != null);
    if (error != null) {
      unawaited(_restoreActivatedQueueSource(queueModeBackup));
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null) showErrorToast(ctx, error);
    } else {
      unawaited(lib.rememberStartedInAbsorbing(widget.itemId, _item));
      unawaited(lib.syncQueueAutoDownloads());
    }
    lib.refreshLocalProgress();
    lib.refresh();
  }

  Widget _chapterRow(BuildContext context, ColorScheme cs, TextTheme tt, Color accent, AuthProvider auth,
      List<dynamic> chapters, int i, double pos, bool isActive, String title, String author, double duration) {
    final l = AppLocalizations.of(context)!;
    final ch = chapters[i] as Map<String, dynamic>;
    final chTitle = ch['title'] as String? ?? l.chapterNumber(i + 1);
    final start = (ch['start'] as num?)?.toDouble() ?? 0;
    final end = (ch['end'] as num?)?.toDouble() ?? 0;
    final isCurrent = pos >= start && pos < end;
    final done = pos >= end;
    final pct = duration > 0 ? (end / duration * 100).round() : 0;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selected: isCurrent,
      selectedTileColor: accent.withValues(alpha: 0.1),
      leading: SizedBox(width: 28, child: done
          ? Icon(Icons.check_rounded, size: 16, color: cs.onSurfaceVariant.withValues(alpha: 0.4))
          : Text('${i + 1}', textAlign: TextAlign.center,
              style: tt.labelMedium?.copyWith(
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400,
                  color: isCurrent ? accent : cs.onSurfaceVariant))),
      title: Text(chTitle, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: tt.bodyMedium?.copyWith(
              fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
              color: isCurrent
                  ? cs.onSurface
                  : done
                      ? cs.onSurface.withValues(alpha: 0.4)
                      : cs.onSurface.withValues(alpha: 0.7))),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$pct%', style: tt.labelSmall?.copyWith(
            color: isCurrent ? accent.withValues(alpha: 0.7) : cs.onSurface.withValues(alpha: 0.24),
            fontSize: 10, fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Text(formatHm((end - start) / _displaySpeed), style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
      ]),
      onTap: () => _jumpToChapter(context, auth, chTitle, start, isActive, title, author, duration, chapters),
    );
  }

  /// Confirm, then seek the live session or start the book at [start].
  Future<void> _jumpToChapter(BuildContext context, AuthProvider auth, String chTitle, double start,
      bool isActive, String title, String author, double duration, List<dynamic> chapters) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dlg) => AlertDialog(
        title: Text(isActive ? l.detailChaptersJumpTitle : l.cardChaptersPlayFromChapterTitle),
        content: Text(isActive
            ? l.detailChaptersJumpContent(chTitle)
            : l.cardChaptersPlayFromChapterContent(chTitle)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlg, false), child: Text(l.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(dlg, true),
              child: Text(isActive ? l.detailChaptersJump : l.cardChaptersPlay)),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    if (isActive) {
      await AudioPlayerService().seekTo(Duration(milliseconds: (start * 1000).round()));
      return;
    }
    setState(() => _isAbsorbing = true);
    await _startAbsorb(context, auth: auth, title: title, author: author,
        coverUrl: _coverUrl, duration: duration, chapters: chapters, startTime: start);
  }

  Future<void> _markFinished(BuildContext context, AuthProvider auth, double duration) async {
    final l = AppLocalizations.of(context)!;
    final w = Wording.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(w.markAsFullyAbsorbedQuestion),
        content: Text(l.markAsFullyAbsorbedContent),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(w.fullyAbsorbAction)),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = auth.apiService;
    if (api == null) return;
    // Capture the provider + root navigator while the sheet is still on
    // screen, so a mid-request dismissal can't cancel the local update, the
    // shelf refresh or the toast (they must not depend on the sheet's context).
    if (!context.mounted) return;
    final navigator = rootNavigatorKey.currentState;
    final lib = context.read<LibraryProvider>();
    final player = AudioPlayerService();
    // Mark finished locally first so the card updates immediately
    // when the player stops (which triggers the expanded card to pop)
    lib.markFinishedLocally(widget.itemId, skipRefresh: true, skipAutoAdvance: true);
    if (player.currentItemId == widget.itemId) await player.stopWithoutSaving();
    try {
      await api.markFinished(widget.itemId, duration);
      await ProgressSyncService().deleteLocal(widget.itemId);
      // Only progress-driven shelves changed. Skip the full personalized
      // re-fetch (and the extra getAllProgress it triggered) that
      // lib.refresh() used to run here; the sheet rebuilds off the
      // provider's progress map, so no item re-fetch is needed either.
      unawaited(lib.refreshProgressOnly());
      unawaited(lib.refreshProgressShelves(force: true, reason: 'mark-finished'));
      await lib.removeFromAbsorbing(widget.itemId);
      if (mounted) setState(() {});
      showNavigatorOverlayToast(navigator, l.markedAsFinishedNiceWork, icon: Icons.check_circle_rounded);
    } catch (_) {
      showNavigatorOverlayToast(navigator, l.failedToUpdateCheckConnection, icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _markNotFinished(BuildContext context, AuthProvider auth, double currentTime, double duration) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.markAsNotFinishedQuestion),
        content: Text(l.markAsNotFinishedContent),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.unmark)),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = auth.apiService;
    if (api == null) return;
    // Capture the provider + root navigator while the sheet is still on
    // screen, so a mid-request dismissal can't cancel the local update, the
    // shelf refresh or the toast (they must not depend on the sheet's context).
    if (!context.mounted) return;
    final navigator = rootNavigatorKey.currentState;
    final lib = context.read<LibraryProvider>();
    try {
      await api.markNotFinished(widget.itemId, currentTime: currentTime, duration: duration);
      await lib.markNotFinishedLocally(widget.itemId);
      lib.unblockFromAbsorbing(widget.itemId);
      // Progress-only change: skip the full personalized re-fetch.
      unawaited(lib.refreshProgressOnly());
      unawaited(lib.refreshProgressShelves(force: true, reason: 'mark-not-finished'));
      if (mounted) setState(() {});
      showNavigatorOverlayToast(navigator, l.markedAsNotFinishedBackAtIt, icon: Icons.replay_rounded);
    } catch (_) {
      showNavigatorOverlayToast(navigator, l.failedToUpdateCheckConnection, icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _resetProgress(BuildContext context, AuthProvider auth, double duration) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.resetProgressQuestion),
        content: Text(l.resetProgressContent),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(l.reset)),
        ],
      ),
    );
    if (confirmed != true) return;
    final api = auth.apiService;
    if (api == null) return;
    // Capture the provider + root navigator while the sheet is still on
    // screen, so a mid-request dismissal can't cancel the local update, the
    // shelf refresh or the toast (they must not depend on the sheet's context).
    if (!context.mounted) return;
    final navigator = rootNavigatorKey.currentState;
    final lib = context.read<LibraryProvider>();
    final player = AudioPlayerService();

    // Stop player without saving progress
    if (player.currentItemId == widget.itemId) {
      await player.stopWithoutSaving();
    }

    // Clear local progress
    await ProgressSyncService().deleteLocal(widget.itemId);

    // Reset server progress (PATCH to zero + hide from continue listening)
    final progressData = lib.getProgressData(widget.itemId);
    final progressId = progressData?['id'] as String?;
    final serverSuccess =
        await api.resetProgress(widget.itemId, duration, progressId: progressId);

    // Clear from library provider (mark as reset — forces 0 progress)
    lib.resetProgressFor(widget.itemId);
    // Progress-only change: skip the full personalized re-fetch.
    unawaited(lib.refreshProgressOnly());
    unawaited(lib.refreshProgressShelves(force: true, reason: 'reset-progress'));
    if (mounted) setState(() {});
    showNavigatorOverlayToast(
      navigator,
      serverSuccess ? l.progressResetFreshStart : l.resetMayNotHaveSynced,
      icon: serverSuccess ? Icons.restart_alt_rounded : Icons.warning_amber_rounded,
    );
  }

  /// Delete the item on the server, optionally taking its files with it.
  /// Needs the `delete` permission — the server answers 403 without it.
  Future<void> _deleteFromServer(BuildContext context, AuthProvider auth,
      LibraryProvider lib, String title) async {
    final l = AppLocalizations.of(context)!;
    final api = auth.apiService;
    if (api == null) return;
    final choice = await showDeleteConfirmDialog(
      context,
      title: l.deleteFromServerTitle,
      message: l.deleteFromServerContent(title),
    );
    if (choice == null || !mounted) return;
    // Grab these before the sheet goes: the toast needs an overlay that
    // outlives it, and the pop needs the navigator the sheet sits on.
    final navigator = Navigator.of(context);
    final rootNavigator = rootNavigatorKey.currentState;
    final status = await api.deleteLibraryItem(widget.itemId, hard: choice.hardDelete);
    if (!mounted) return;
    if (status == 200) {
      final player = AudioPlayerService();
      if (player.currentItemId == widget.itemId) {
        await player.stopWithoutSaving();
      }
      await lib.removeFromAbsorbing(widget.itemId);
      if (navigator.canPop()) navigator.pop();
      await lib.refresh();
      showNavigatorOverlayToast(rootNavigator, l.deletedFromServer(title),
        icon: Icons.delete_outline_rounded);
    } else if (status == 403) {
      showOverlayToast(context, l.deletePermissionRequired, icon: Icons.lock_outline_rounded);
    } else {
      showOverlayToast(context, l.deleteFromServerFailed, icon: Icons.error_outline_rounded);
    }
  }

  void _openGoodreads(String title, String author) async {
    // A BookOrbit book matched on Goodreads carries its id, which opens the
    // book itself the way the web app links it; anything else is searched.
    // An ISBN opens the book too, on any server.
    final id = ((_item?['bookOrbit'] as Map?)?['providerIds'] as Map?)?['goodreads'];
    final rawIsbn = (((_item?['media'] as Map?)?['metadata'] as Map?)?['isbn'] ?? '')
        .toString()
        .replaceAll(RegExp(r'[^0-9Xx]'), '');
    final isbn = rawIsbn.length == 10 || rawIsbn.length == 13 ? rawIsbn : null;
    final exact = id is String && id.trim().isNotEmpty
        ? BookOrbitMapper.providerUrl('goodreads', id.trim())
        : isbn != null
            ? 'https://www.goodreads.com/book/isbn/$isbn'
            : null;
    final q = author.isNotEmpty ? '$title $author' : title;
    final uri = exact != null
        ? Uri.parse(exact)
        : Uri.https('www.goodreads.com', '/search', {'q': q});
    debugPrint('[Goodreads] ${exact != null ? 'book page' : 'search'}: $uri');
    try {
      // Open in Goodreads app if installed
      if (!await launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      // App not installed — fall back to browser
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _openMetadataLookup(BuildContext context, AuthProvider auth, String title, String author) {
    final api = auth.apiService;
    if (api == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.05, snap: true,
        maxChildSize: 0.95,
        builder: (ctx, sc) => MetadataLookupSheet(
          scrollController: sc,
          itemId: widget.itemId,
          api: api,
          initialTitle: title,
          initialAuthor: author,
          currentMetadata: (_item?['media'] as Map<String, dynamic>?)?['metadata'] as Map<String, dynamic>?,
          onApplied: () {
            // Reload the item to show the new override, and repaint the
            // library so the grid/absorbing card pick up the override cover.
            _loadItem();
            if (mounted) {
              context.read<LibraryProvider>().notifyCoverOverridesChanged();
            }
          },
        ),
      ),
    );
  }

  Future<void> _clearOverride(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.clearLocalMetadataQuestion),
        content: Text(l.clearLocalMetadataContent),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.clear)),
        ],
      ),
    );
    if (confirmed != true) return;
    await MetadataOverrideService().delete(widget.itemId);
    if (mounted) {
      setState(() => _hasLocalOverride = false);
      await _loadItem();
      if (context.mounted) {
        // Repaint the library so the grid/card drop the override cover too.
        context.read<LibraryProvider>().notifyCoverOverridesChanged();
        showOverlayToast(
          context,
          l.localMetadataCleared,
          icon: Icons.delete_outline_rounded,
        );
      }
    }
  }

  void _showFullCover(BuildContext context, String url, Map<String, String> headers, String title) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (_, __, ___) => _FullCoverViewer(url: url, headers: headers, title: title),
      transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
    ));
  }
}

class _FullCoverViewer extends StatefulWidget {
  final String url;
  final Map<String, String> headers;
  final String title;
  const _FullCoverViewer({required this.url, required this.headers, required this.title});
  @override State<_FullCoverViewer> createState() => _FullCoverViewerState();
}

class _FullCoverViewerState extends State<_FullCoverViewer> {
  bool _saving = false;
  final _transform = TransformationController();

  // How far a one-finger drag has pulled the (unzoomed) cover, so it follows
  // the finger and a flick dismisses like every other sheet in the app.
  double _dragY = 0;

  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.05;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _saveAndShare() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final response = await http.get(Uri.parse(widget.url), headers: widget.headers);
      if (response.statusCode != 200) throw Exception('Download failed');
      final ext = widget.url.contains('.png') ? '.png' : '.jpg';
      final safeTitle = widget.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$safeTitle$ext');
      registerInFlightWrite(file.path);
      try {
        await file.writeAsBytes(response.bodyBytes);
      } finally {
        unregisterInFlightWrite(file.path);
      }
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        sharePositionOrigin: shareOriginFor(context),
      );
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context)!;
        showOverlayToast(
          context,
          l.failedToSaveError(e.toString()),
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: [
        // Tap closes (a tap on a zoomed cover just zooms it back out first).
        // A one-finger swipe drags the unzoomed cover along and dismisses -
        // tracked through the viewer's own callbacks, because the viewer
        // claims every gesture and a competing detector would never win.
        Positioned.fill(
          child: GestureDetector(
            onTap: () {
              if (_zoomed) {
                setState(() => _transform.value = Matrix4.identity());
              } else {
                Navigator.pop(context);
              }
            },
            child: Transform.translate(
              offset: Offset(0, _dragY),
              child: InteractiveViewer(
                transformationController: _transform,
                clipBehavior: Clip.none,
                minScale: 1.0,
                maxScale: 5.0,
                onInteractionUpdate: (d) {
                  if (!_zoomed && d.pointerCount == 1) {
                    setState(() => _dragY += d.focalPointDelta.dy);
                  }
                },
                onInteractionEnd: (d) {
                  if (_zoomed) return;
                  if (_dragY.abs() > 120 ||
                      d.velocity.pixelsPerSecond.dy.abs() > 800) {
                    Navigator.pop(context);
                  } else if (_dragY != 0) {
                    setState(() => _dragY = 0);
                  }
                },
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: widget.url,
                    useOldImageOnUrlChange: true,
                    httpHeaders: widget.headers,
                    fit: BoxFit.contain,
                    placeholder: (_, __) => const CircularProgressIndicator(strokeWidth: 2),
                    errorWidget: (_, __, ___) => const Icon(Icons.broken_image_rounded, size: 48, color: Colors.white54),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Close button
        Positioned(
          top: MediaQuery.of(context).viewPadding.top + 8,
          left: 8,
          child: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            style: IconButton.styleFrom(backgroundColor: Colors.black45),
          ),
        ),
        // Save/share button
        Positioned(
          top: MediaQuery.of(context).viewPadding.top + 8,
          right: 8,
          child: IconButton(
            onPressed: _saving ? null : _saveAndShare,
            icon: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_alt_rounded, color: Colors.white),
            style: IconButton.styleFrom(backgroundColor: Colors.black45),
          ),
        ),
      ]),
    );
  }
}

/// Edits a BookOrbit private note. Owns its controller so the text field
/// outlives the dialog's closing animation.
class _PersonalNoteDialog extends StatefulWidget {
  final String initial;
  const _PersonalNoteDialog({required this.initial});

  @override
  State<_PersonalNoteDialog> createState() => _PersonalNoteDialogState();
}

class _PersonalNoteDialogState extends State<_PersonalNoteDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l.personalNoteTitle),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        minLines: 3,
        maxLines: 8,
        maxLength: 10000,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: l.personalNoteHint),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _ctrl.text), child: Text(l.save)),
      ],
    );
  }
}

/// One selectable ebook-version row in the version picker. It replaces a plain
/// [ListTile] so the press feedback is a rounded, primary-tinted ripple instead
/// of the default square white highlight, and so the row can dip slightly while
/// held for a tactile cue.
class _EbookVersionTile extends StatefulWidget {
  const _EbookVersionTile({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.onLongPress,
  });

  final Widget leading;
  final Widget title;
  final Widget subtitle;
  final Widget? trailing;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<_EbookVersionTile> createState() => _EbookVersionTileState();
}

class _EbookVersionTileState extends State<_EbookVersionTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(16);
    return AnimatedScale(
      scale: _pressed ? 0.98 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: radius,
          splashColor: cs.primary.withValues(alpha: 0.12),
          highlightColor: cs.primary.withValues(alpha: 0.08),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onHighlightChanged: (v) {
            if (v != _pressed) setState(() => _pressed = v);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              widget.leading,
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    widget.title,
                    const SizedBox(height: 2),
                    widget.subtitle,
                  ],
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 16),
                widget.trailing!,
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
