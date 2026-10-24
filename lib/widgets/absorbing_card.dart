import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../l10n/app_localizations.dart';
import '../utils/cover_accent.dart';
import '../utils/series_id.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../screens/app_shell.dart';
import '../services/audio_player_service.dart';
import '../services/chapter_lookup.dart';
import '../services/cover_blur_cache.dart';
import '../services/cover_palette_cache.dart';
import '../services/download_service.dart';
import 'absorbing_shared.dart';
import 'ebook_router.dart';
import 'overlay_toast.dart';
import '../services/ebook_cache.dart';
import '../services/find_in_ebook.dart';
import '../services/lyrics_service.dart';
import 'lyrics_overlay.dart';
import 'card_edge_progress_bar.dart';
import 'card_progress_bar.dart';
import 'card_playback_controls.dart';
import 'card_buttons.dart';
import '../services/chromecast_service.dart';
import 'expanded_card.dart';
import '../main.dart'
    show
        colorSourceNotifier,
        useColorEverywhereNotifier,
        manualSeedNotifier,
        manualColorScheme,
        snappyTransitionsNotifier;
import 'stable_cached_network_image.dart';

class AbsorbingCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final AudioPlayerService player;
  const AbsorbingCard({super.key, required this.item, required this.player});

  @override
  State<AbsorbingCard> createState() => AbsorbingCardState();
}

class AbsorbingCardState extends State<AbsorbingCard>
    with AutomaticKeepAliveClientMixin {
  ColorScheme? _rawCoverScheme;
  Brightness? _coverBrightness; // brightness used to generate _coverScheme

  /// Cover-derived scheme, unless a manual app color is set to apply everywhere.
  ColorScheme? get _coverScheme {
    if (colorSourceNotifier.value == 'manual' &&
        useColorEverywhereNotifier.value) {
      return manualColorScheme(
        manualSeedNotifier.value,
        Theme.of(context).brightness,
      );
    }
    return _rawCoverScheme;
  }

  ImageProvider? _coverProvider; // cached for re-deriving on theme change
  String? _coverProviderIdentity;
  bool _isStarting = false;
  List<dynamic>? _fetchedChapters;
  Map<String, dynamic>? _fetchedEbookFile;
  // Server-change tick last acted on, so a same-id item_updated (e.g. an ebook
  // file added to this book) re-runs the full-item fetch. The card is kept
  // alive with a stable key, so without this it never picks up a server change.
  int? _lastSeenUpdatedAt;
  // The shelf item's updatedAt is usually present before the library registers
  // it. If both are absent at mount, the first later registration is a baseline,
  // not a server change; treating it as one used to reset the cover colours on
  // cold start.
  bool _updatedAtBaselineKnown = false;
  bool _refetchingItem = false;
  // Set when a server change lands mid-fetch, so the in-flight pass is followed
  // by one more instead of swallowing the update.
  bool _refetchQueued = false;
  StreamSubscription<Duration>? _chapterTrackSub;
  int _lastChapterIdx = -1;
  CoverBlurLease? _blurLease; // Cached blurred background (owned by the cache)
  // 上一次落盘的模糊封面：当前 identity 还没稳定/模糊图还没好时先当首帧底图，
  // 让首帧直接是模糊封面，而不是主题色或提取色。
  CoverBlurLease? _placeholderBlurLease;
  String? _blurredCoverIdentity;
  String? _pendingBlurIdentity;
  // Mean brightness of the blurred cover's top strip, which is what the
  // progress row is drawn on. Null until the blur is ready, or when the card
  // isn't using the blurred background at all.
  double? _coverTopLuminance;
  // 封面平均色（落盘的 palette 缓存）；用于第一帧背景/占位，而不是 Material
  // scheme 里偏色/偏暗的 primaryContainer。
  Color? _coverAverageColor;
  List<String> _buttonOrder = PlayerSettings.defaultButtonOrder;
  int _buttonVisibleCount = PlayerSettings.defaultButtonVisibleCount;
  bool _iconsOnly = false;
  bool _moreInline = false;
  bool _rectangleCovers = false;
  bool _coverPlayButton = false;
  String _cardBackground = 'blurred';
  // 背景模式是异步读取的；读出之前先按默认的 blurred 预热模糊图，保证冷启动
  // 第一帧的封面占位/背景尽快拿到落盘的模糊图。
  bool _cardBackgroundReady = false;
  bool _speedAdjustedTime = false;
  double _progressTextScale =
      1.0; // elapsed/remaining/percent text size (GH #230)
  double _savedSpeed = 1.0; // per-book or default speed for inactive display
  final ValueNotifier<bool> _edgeBarExpanded = ValueNotifier(false);

  @override
  bool get wantKeepAlive => true;

  String get _itemId => widget.item['id'] as String? ?? '';
  Map<String, dynamic> get _media =>
      widget.item['media'] as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get _metadata =>
      _media['metadata'] as Map<String, dynamic>? ?? {};
  String get _title {
    final t = _metadata['title'] as String?;
    if (t != null && t.isNotEmpty) return t;
    return mounted ? AppLocalizations.of(context)!.unknown : 'Unknown';
  }

  String get _author => _metadata['authorName'] as String? ?? '';
  double get _duration => (_media['duration'] as num?)?.toDouble() ?? 0;
  // The freshest resolved version wins: the minified shelf item's inline
  // media.ebookFile is stale after a server-side default change (or an ebook
  // added/removed while the app is open), but _fetchedEbookFile was re-resolved
  // from the full item by the socket-triggered refetch. Preferring the inline
  // copy here is what kept Read/Read-along on the previous default.
  Map<String, dynamic>? get _ebookFile =>
      _fetchedEbookFile ?? (_media['ebookFile'] as Map<String, dynamic>?);
  String? get _ebookExt {
    final ext = ebookExt(_ebookFile);
    return ext.isEmpty ? null : ext;
  }

  List<dynamic> get _chapters {
    // Prefer fetched chapters (from full item or episode), fall back to inline data
    if (_fetchedChapters != null && _fetchedChapters!.isNotEmpty)
      return _fetchedChapters!;
    final inline = _media['chapters'] as List<dynamic>? ?? [];
    if (inline.isNotEmpty) return inline;
    // For podcast episodes, chapters live on the episode object
    final epChapters = _recentEpisode?['chapters'] as List<dynamic>? ?? [];
    if (epChapters.isNotEmpty) return epChapters;
    // For active podcast episodes, chapters come from the playback session
    if (_isActive && widget.player.chapters.isNotEmpty)
      return widget.player.chapters;
    return [];
  }

  bool get _isActive {
    if (widget.player.currentItemId != _itemId) return false;
    // For podcast episode cards, only active if the same episode is playing
    if (_episodeId != null && widget.player.currentEpisodeId != null) {
      return _episodeId == widget.player.currentEpisodeId;
    }
    return true;
  }

  bool get _isCastingThis {
    final cast = ChromecastService();
    return cast.isCasting && cast.castingItemId == _itemId;
  }

  bool get _isPlaybackActive => _isActive || _isCastingThis;
  bool get _isPodcastEpisode =>
      _isActive && widget.player.currentEpisodeId != null;

  // For inactive podcast show cards: recentEpisode is embedded in the continue-listening entity
  Map<String, dynamic>? get _recentEpisode =>
      widget.item['recentEpisode'] as Map<String, dynamic>?;

  /// Resolve full episode data for the current episode.
  // Episode ID: prefer recentEpisode, fall back to compound absorbing key
  String? get _episodeId {
    final re = _recentEpisode;
    if (re != null) return re['id'] as String?;
    // Compound absorbing keys are "showUUID-episodeId" (>36 chars)
    final absKey = widget.item['_absorbingKey'] as String?;
    if (absKey != null && absKey.length > 36) return absKey.substring(37);
    return null;
  }

  // Use episode duration for inactive podcast show cards (show duration is aggregate/incorrect)
  double get _effectiveDuration {
    if (!_isActive && _recentEpisode != null) {
      // Try top-level duration first, then audioFile.duration
      final epDur = (_recentEpisode!['duration'] as num?)?.toDouble();
      if (epDur != null && epDur > 0) return epDur;
      final audioFile = _recentEpisode!['audioFile'] as Map<String, dynamic>?;
      final afDur = (audioFile?['duration'] as num?)?.toDouble();
      if (afDur != null && afDur > 0) return afDur;
    }
    return _duration;
  }

  String? get _coverUrl => _resolveCoverUrl();

  String? _resolveCoverUrl() {
    final lib = context.read<LibraryProvider>();

    // Podcast episodes carry their own artwork - honour the player's resolved
    // URL so the cover matches the episode actually playing.
    if (_isPodcastEpisode) {
      final playingCover = widget.player.currentCoverUrl;
      if (playingCover != null && playingCover.isNotEmpty) {
        return playingCover;
      }
      final episodeLocal = _usableLocalCover(
        DownloadService().getInfo('$_itemId-$_episodeId').localCoverPath,
      );
      if (episodeLocal != null) return episodeLocal;
    }

    // A downloaded book's cover.jpg is rendered by the homescreen widget /
    // lockscreen, so it is guaranteed present and bytes if the record is marked
    // downloaded. However, DownloadService restores its records after the first
    // frame; preferring the local file made the card start on the shelf URL and
    // then switch to the local path, resetting the blur/palette and visibly
    // reloading the cover. While online, keep the shelf URL (it is prewarmed and
    // cached); use the local copy only when offline.
    final dl = DownloadService().getInfo(_itemId);
    final itemUpdatedAt = (widget.item['updatedAt'] as num?)?.toInt();
    final mapUpdatedAt = lib.itemUpdatedAt(_itemId);
    // Use the shelf item's ts from the first frame when possible: the library's
    // map can register it a frame later, and that URL/ts flip was resetting the
    // cover blur/palette on every cold start.
    final coverUpdatedAt =
        itemUpdatedAt != null &&
            (mapUpdatedAt == null || itemUpdatedAt >= mapUpdatedAt)
        ? itemUpdatedAt
        : mapUpdatedAt;
    final shelfUrl = lib.getCoverUrl(
      _itemId,
      width: 1200,
      updatedAt: coverUpdatedAt,
    );
    if (!lib.isOffline && shelfUrl != null && shelfUrl.isNotEmpty) {
      return shelfUrl;
    }
    if (dl.status == DownloadStatus.downloaded) {
      final local =
          _usableLocalCover(dl.localCoverPath) ??
          DownloadService().syncLocalCoverProbe(_itemId);
      if (local != null) return local;
    }
    if (shelfUrl != null && shelfUrl.isNotEmpty) return shelfUrl;

    final bookLocal = _usableLocalCover(
      DownloadService().getInfo(_itemId).localCoverPath,
    );
    if (bookLocal != null) return bookLocal;

    final playingCover = widget.player.currentCoverUrl;
    return (playingCover != null && playingCover.isNotEmpty)
        ? playingCover
        : null;
  }

  String? _usableLocalCover(String? path) {
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    if (file.lengthSync() == 0) return null;
    return path;
  }

  String? _coverIdentity(String? coverUrl, LibraryProvider lib) {
    if (coverUrl == null) return null;
    // 本地封面原地覆盖时路径不变，identity 里带上 mtime/size 才能让模糊背景
    // 和配色缓存跟着封面一起更新。
    return coverCacheIdentity(coverUrl);
  }

  String? _currentCoverIdentity() {
    final lib = context.read<LibraryProvider>();
    final coverUrl = _resolveCoverUrl();
    return _coverIdentity(coverUrl, lib);
  }

  /// 背景/封面占位共用的淡入时长：冷启动读盘时用 220ms 的交叉淡入，
  /// 避免纯色占位瞬间跳成图片。电子墨水/快速模式不做动画。
  Duration get _bgFadeDuration =>
      (PlayerSettings.einkMode || snappyTransitionsNotifier.value)
      ? Duration.zero
      : const Duration(milliseconds: 220);

  /// 封面从模糊/渐变占位淡入的时长；电子墨水/快速模式直接切换，避免残影。
  Duration get _coverFadeDuration =>
      (PlayerSettings.einkMode || snappyTransitionsNotifier.value)
      ? Duration.zero
      : const Duration(milliseconds: 180);

  /// Keep the outgoing blurred bitmap as the crossfade base when the cover
  /// identity changes, instead of releasing it before the new blur is ready.
  void _parkCurrentBlurForCrossfade() {
    final old = _blurLease;
    if (old == null) return;
    _placeholderBlurLease?.release();
    _placeholderBlurLease = old;
    _blurLease = null;
    _blurredCoverIdentity = null;
  }

  /// 封面加载/缺图时的占位：中性底色 + 已缓存的模糊封面（上一次落盘的或当前
  /// 的）。不再用提取的平均色/主题色做过场；模糊图出现时淡入，加载中不画图标，
  /// 只有真正缺图/错误时才显示图标。
  Widget _coverLoadingPlaceholder(
    ColorScheme cs, {
    bool showIcon = false,
  }) {
    final current = _blurLease;
    final placeholder = _placeholderBlurLease;
    final neutral = ColoredBox(
      color: cs.surfaceContainerHighest,
      child: showIcon
          ? Center(
              child: Icon(
                Icons.auto_stories_rounded,
                size: 36,
                color: cs.onSurfaceVariant.withValues(alpha: 0.35),
              ),
            )
          : const SizedBox.expand(),
    );
    if (current == null && placeholder == null) return neutral;
    return Stack(
      fit: StackFit.expand,
      children: [
        neutral,
        if (placeholder != null)
          RawImage(
            image: placeholder.image,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          ),
        if (current != null)
          TweenAnimationBuilder<double>(
            key: ValueKey(
              'blur-ph-${_blurredCoverIdentity ?? current.hashCode}',
            ),
            tween: Tween<double>(begin: 0, end: 1),
            duration: _bgFadeDuration,
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(opacity: t, child: child),
            child: RawImage(
              image: current.image,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            ),
          ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    // Baseline the server-change tick so only a CHANGE after mount re-fetches
    // (the initial fill is handled by _fetchChaptersIfNeeded below). Prefer the
    // shelf item's own updatedAt: the library may register it only a frame
    // later, and that first write must not look like a server cover change.
    final lib = context.read<LibraryProvider>();
    _lastSeenUpdatedAt = lib.itemUpdatedAt(_itemId) ??
        (widget.item['updatedAt'] as num?)?.toInt();
    _updatedAtBaselineKnown = _lastSeenUpdatedAt != null;
    _fetchChaptersIfNeeded();
    _startChapterTracking();
    ChromecastService().addListener(_onCastChanged);
    DownloadService().addListener(_onDownloadChanged);
    PlayerSettings.settingsChanged.addListener(_reloadButtonOrder);
    _reloadButtonOrder();
    // AbsorbingScreen prewarms the first two cards' blurs before building them;
    // take a synchronous lease here so the very first frame is that blurred
    // cover instead of waiting for an async acquire.
    final coverUrl = _resolveCoverUrl();
    final identity = _coverIdentity(coverUrl, lib);
    if (identity != null) {
      final cached = CoverBlurCache.instance.lease(identity);
      if (cached != null) {
        _blurLease = cached;
        _blurredCoverIdentity = identity;
      }
    }
    // 首帧底图：main() 已把上一次的模糊封面预加载到内存，这里同步取 lease，
    // 卡片第一帧就是模糊封面/背景；只有冷启动首次安装等没有缓存时才走异步。
    final cachedLatest = CoverBlurCache.instance.cachedLatestLeaseFor(
      _lyricsKey,
    );
    if (cachedLatest != null) {
      _placeholderBlurLease = cachedLatest;
    } else {
      unawaited(_loadPlaceholderBlur());
    }
  }

  Future<void> _loadPlaceholderBlur() async {
    final lease = await CoverBlurCache.instance.latestLeaseFor(_lyricsKey);
    if (!mounted || _blurLease != null) {
      lease?.release();
      return;
    }
    setState(() => _placeholderBlurLease = lease);
  }

  void _onSpeedMaybeChanged() => _loadSavedSpeed();

  /// Which library this card's item belongs to, for the per-library cover
  /// shape. The absorbing shelf item can be a lean/synthetic map without a
  /// libraryId (especially with merge on, where podcast items are pulled from
  /// other libraries), so fall back to the cached absorbing entry and then to
  /// the player when this is the item currently playing.
  String? _resolveLibraryId() {
    final direct = widget.item['libraryId'] as String?;
    if (direct != null && direct.isNotEmpty) return direct;
    final lib = context.read<LibraryProvider>();
    final epId = _episodeId;
    final key = epId != null ? '$_itemId-$epId' : _itemId;
    final cached = lib.absorbingItemCache[key]?['libraryId'] as String?;
    if (cached != null && cached.isNotEmpty) return cached;
    if (_itemId == widget.player.currentItemId)
      return widget.player.currentLibraryId;
    return null;
  }

  void _reloadCoverShape() {
    PlayerSettings.getRectangleCoversFor(_resolveLibraryId()).then((v) {
      if (mounted && v != _rectangleCovers)
        setState(() => _rectangleCovers = v);
    });
  }

  Future<void> _loadSavedSpeed() async {
    final bookSpeed = await PlayerSettings.getBookSpeed(_itemId);
    final speed = bookSpeed ?? await PlayerSettings.getDefaultSpeed();
    if (mounted && speed != _savedSpeed) setState(() => _savedSpeed = speed);
  }

  void _reloadButtonOrder() {
    PlayerSettings.getCardButtonOrder().then((o) {
      if (mounted && o.join(',') != _buttonOrder.join(','))
        setState(() => _buttonOrder = o);
    });
    PlayerSettings.getCardButtonVisibleCount().then((c) {
      if (mounted && c != _buttonVisibleCount)
        setState(() => _buttonVisibleCount = c);
    });
    PlayerSettings.getCardIconsOnly().then((v) {
      if (mounted && v != _iconsOnly) setState(() => _iconsOnly = v);
    });
    PlayerSettings.getCardMoreInline().then((v) {
      if (mounted && v != _moreInline) {
        setState(() {
          _moreInline = v;
          if (v && !_buttonOrder.contains('_more')) {
            final insertAt =
                (_buttonVisibleCount >= 9 ? 8 : _buttonVisibleCount).clamp(
                  0,
                  _buttonOrder.length,
                );
            _buttonOrder.insert(insertAt, '_more');
            _buttonVisibleCount = (_buttonVisibleCount < 9
                ? _buttonVisibleCount + 1
                : 9);
            PlayerSettings.setCardButtonOrder(_buttonOrder);
            PlayerSettings.setCardButtonVisibleCount(_buttonVisibleCount);
          }
        });
      }
    });
    _reloadCoverShape();
    PlayerSettings.getCoverPlayButton().then((v) {
      if (mounted && v != _coverPlayButton)
        setState(() => _coverPlayButton = v);
    });
    PlayerSettings.getSpeedAdjustedTime().then((v) {
      if (mounted && v != _speedAdjustedTime)
        setState(() => _speedAdjustedTime = v);
    });
    PlayerSettings.getProgressTextScale().then((v) {
      if (mounted && v != _progressTextScale)
        setState(() => _progressTextScale = v);
    });
    PlayerSettings.getCardBackground().then((v) {
      if (!mounted) return;
      if (v != _cardBackground) setState(() => _cardBackground = v);
      _cardBackgroundReady = true;
      if (v == 'blurred') _primeBlurFromCache();
    });
    _loadSavedSpeed();
  }

  void _onDownloadChanged() {
    if (!mounted) return;
    // 已下载封面的文件可能被原地替换（重新下载/清晰度升级）：路径不变，
    // 只有带 mtime/size 的 identity 会变。身份一变就丢掉旧的 blur/scheme，
    // 让 build 里的 fallback 重新走 _onCoverLoaded，按新身份重建背景。
    final lib = context.read<LibraryProvider>();
    final identity = _coverIdentity(_resolveCoverUrl(), lib);
    final previous = _blurredCoverIdentity ?? _coverProviderIdentity;
    if (identity != null && previous != null && identity != previous) {
      final brightness = Theme.of(context).brightness;
      final cachedScheme = CoverPaletteCache.instance.schemeFor(
        identity,
        brightness,
      );
      _parkCurrentBlurForCrossfade();
      _pendingBlurIdentity = null;
      _rawCoverScheme = cachedScheme;
      _coverBrightness = cachedScheme != null ? brightness : null;
      _coverTopLuminance = CoverPaletteCache.instance.luminanceFor(identity);
      _coverAverageColor = CoverPaletteCache.instance.averageColorFor(identity);
      _coverProvider = null;
      _coverProviderIdentity = null;
      // 新封面的模糊图可能已经在磁盘缓存里，立即起加载，不用等封面解码。
      _primeBlurFromCache();
    }
    setState(() {});
  }

  void _onCastChanged() {
    _startChapterTracking();
    if (mounted) setState(() {});
  }

  Future<void> _fetchChaptersIfNeeded() async {
    // Skip when the inline item already has both chapters and ebookFile
    final inlineEbook = _media['ebookFile'] as Map<String, dynamic>?;
    if (_chapters.isNotEmpty && inlineEbook != null) return;
    await _refetchItem();
  }

  /// Re-fetches the full item and applies whatever the card was missing.
  ///
  /// Split out of [_fetchChaptersIfNeeded] so a server-side change can force a
  /// re-read even when the card already has chapters: that "only fill the gaps"
  /// early-out is what kept a chapter list edited on the ABS web UI stale until
  /// the next cold start.
  Future<void> _refetchItem({bool forceChapters = false}) async {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) return;
    try {
      // Disk copy first: on a cold restart the network copy of the item can
      // take tens of seconds, while chapter switching on the active card
      // needs to unlock immediately. Only fetch when nothing was cached.
      final fullItem = forceChapters
          ? await api.getLibraryItem(_itemId)
          : await api.getCachedLibraryItem(_itemId) ??
                await api.getLibraryItem(_itemId);
      if (fullItem != null && mounted) {
        final media = fullItem['media'] as Map<String, dynamic>? ?? {};
        // Cache ebookFile if the inline item didn't have it. resolveEbookFile
        // also covers supplementary-only books (audiobooks-only libraries
        // never set media.ebookFile).
        if (forceChapters || _fetchedEbookFile == null) {
          final ef = resolveEbookFile(fullItem);
          if (ef != null) setState(() => _fetchedEbookFile = ef);
        }
        // Books: chapters at media level
        var chapters = media['chapters'] as List<dynamic>? ?? [];
        // Podcasts: chapters on the specific episode
        if (chapters.isEmpty && _episodeId != null) {
          final episodes = media['episodes'] as List<dynamic>? ?? [];
          for (final ep in episodes) {
            if (ep is Map<String, dynamic> && ep['id'] == _episodeId) {
              chapters = ep['chapters'] as List<dynamic>? ?? [];
              break;
            }
          }
        }
        if (chapters.isNotEmpty) {
          // Adopt only a genuine change. Most server updates are cover or
          // progress metadata; rebuilding the list (and re-deriving the player's
          // current-chapter latch) for those would be needless churn.
          if (ChapterLookup.equivalent(_chapters, chapters)) return;
          setState(() => _fetchedChapters = chapters);
          // Keep the live player in step so the chapter list the sheet reads
          // from player.chapters matches what the server now reports.
          if (_isActive) widget.player.adoptServerChapters(chapters);
        }
      }
    } catch (_) {}
  }

  /// Re-fetch the full item when the server reports this book changed (socket
  /// item_updated bumps the provider's per-item tick). Targets two cases where
  /// the card's minified entity is stale for the whole app session:
  ///
  ///  - an ebook file is added while the app is open, so the "Read" action would
  ///    otherwise stay disabled until a restart;
  ///  - chapters are edited on the ABS web UI (the usual way for a Docker
  ///    deployment), which the inline entity never picks up.
  ///
  /// Gated on the timestamp so ordinary cover/metadata updates are seen once
  /// and the re-read decides for itself whether anything the card cares about
  /// actually moved. [_refetchingItem] keeps a burst of updates from stacking
  /// duplicate requests.
  void _maybeRefetchOnServerChange(LibraryProvider lib) {
    final ts = lib.itemUpdatedAt(_itemId);
    // The first ts registration after a cold start is the baseline, not an
    // item_updated event; resetting here made the cover colours flip on every
    // start before the ts was known.
    if (!_updatedAtBaselineKnown) {
      _lastSeenUpdatedAt = ts;
      _updatedAtBaselineKnown = ts != null;
      return;
    }
    if (ts == _lastSeenUpdatedAt) return;
    _lastSeenUpdatedAt = ts;
    // The cover may have changed server-side. Drop the cached provider and
    // accent scheme so they re-derive from the new cache-busted URL (the
    // blurred background already re-derives itself on URL change in build).
    _coverProvider = null;
    _rawCoverScheme = null;
    _coverAverageColor = null;
    if (_refetchingItem) {
      // A request is already in flight. It was issued for an older item state,
      // so arrange one more pass rather than letting this update be dropped -
      // otherwise the change that arrived mid-flight never gets picked up.
      _refetchQueued = true;
      return;
    }
    _refetchingItem = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        // Bypass the disk cache: a chapter edit is precisely the case where the
        // cached copy is the stale one we're trying to replace.
        do {
          _refetchQueued = false;
          await _refetchItem(forceChapters: true);
        } while (_refetchQueued && mounted);
      } finally {
        _refetchingItem = false;
      }
    });
  }

  void _startChapterTracking() {
    _chapterTrackSub?.cancel();

    if (_isCastingThis) {
      final stream = ChromecastService().castPositionStream;
      if (stream == null) return;
      _chapterTrackSub = stream.listen((_) {
        if (!_isCastingThis) return;
        // Use translated book-level position from ChromecastService, not the raw
        // stream value (which is track-local in multi-track fallback mode).
        final cast = ChromecastService();
        final posS = cast.castPosition.inMilliseconds / 1000.0;
        final chapters = cast.castingChapters;
        if (chapters.isEmpty) {
          final sec = cast.castPosition.inSeconds;
          if (sec != _lastChapterIdx) {
            _lastChapterIdx = sec;
            if (mounted) setState(() {});
          }
          return;
        }
        int idx = 0;
        for (int i = 0; i < chapters.length; i++) {
          final ch = chapters[i] as Map<String, dynamic>;
          final start = (ch['start'] as num?)?.toDouble() ?? 0;
          final end = (ch['end'] as num?)?.toDouble() ?? 0;
          if (posS >= start && posS < end) {
            idx = i;
            break;
          }
        }
        if (idx != _lastChapterIdx) {
          _lastChapterIdx = idx;
          if (mounted) setState(() {});
        }
      });
      return;
    }

    _chapterTrackSub = widget.player.absolutePositionStream.listen((pos) {
      if (!_isActive) return;
      final posS = pos.inMilliseconds / 1000.0;
      final chapters = widget.player.chapters.isNotEmpty
          ? widget.player.chapters
          : _chapters;
      if (chapters.isEmpty) {
        final sec = pos.inSeconds;
        if (sec != _lastChapterIdx) {
          _lastChapterIdx = sec;
          if (mounted) setState(() {});
        }
        return;
      }
      int idx = 0;
      for (int i = 0; i < chapters.length; i++) {
        final ch = chapters[i] as Map<String, dynamic>;
        final start = (ch['start'] as num?)?.toDouble() ?? 0;
        final end = (ch['end'] as num?)?.toDouble() ?? 0;
        if (posS >= start && posS < end) {
          idx = i;
          break;
        }
      }
      if (idx != _lastChapterIdx) {
        _lastChapterIdx = idx;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 冷启动先用落盘的封面配色，避免第一帧主题色再跳成封面色调。
    _adoptCachedCoverPalette();
    // 封面 URL 一确定就先起模糊图加载；磁盘缓存通常已有，不必等 1200px
    // 封面解码完成，冷启动时背景/占位能更早从模糊图开始。
    _primeBlurFromCache();
    // Re-derive cover color scheme when theme brightness changes
    _rederiveCoverScheme();
  }

  @override
  void didUpdateWidget(AbsorbingCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.item['id'] as String? ?? '';
    if (oldId != _itemId) {
      // Item changed — reset all stale state
      _rawCoverScheme = null;
      _coverBrightness = null;
      _coverProvider = null;
      _coverProviderIdentity = null;
      _blurLease?.release();
      _blurLease = null;
      _blurredCoverIdentity = null;
      _pendingBlurIdentity = null;
      _coverTopLuminance = null;
      _coverAverageColor = null;
      _fetchedChapters = null;
      _fetchedEbookFile = null;
      _lastChapterIdx = -1;
      _lastSeenUpdatedAt =
          context.read<LibraryProvider>().itemUpdatedAt(_itemId) ??
          (widget.item['updatedAt'] as num?)?.toInt();
      _updatedAtBaselineKnown = _lastSeenUpdatedAt != null;
      _fetchChaptersIfNeeded();
      // The per-show speed is item state too - without this, a card recycled
      // for a different item shows times computed at the old item's speed.
      _loadSavedSpeed();
    }
    // Re-resolve the cover shape: the item (or its libraryId) may have changed,
    // or the player may now know the library for the item that just started.
    _reloadCoverShape();
    if (oldWidget.player != widget.player) _startChapterTracking();
  }

  @override
  void dispose() {
    PlayerSettings.settingsChanged.removeListener(_reloadButtonOrder);
    ChromecastService().removeListener(_onCastChanged);
    DownloadService().removeListener(_onDownloadChanged);
    widget.player.removeListener(_onSpeedMaybeChanged);
    _chapterTrackSub?.cancel();
    _blurLease?.release();
    _placeholderBlurLease?.release();
    _edgeBarExpanded.dispose();
    super.dispose();
  }

  void _onCoverLoaded(ImageProvider provider, String coverIdentity) {
    if (_currentCoverIdentity() != coverIdentity) return;
    if (_coverProviderIdentity != coverIdentity) {
      final brightness = Theme.of(context).brightness;
      final cachedScheme = CoverPaletteCache.instance.schemeFor(
        coverIdentity,
        brightness,
      );
      // Only a real replacement (we had a previous provider) needs the
      // outgoing blur parked for the crossfade; the first cover assignment is
      // not a change.
      if (_coverProviderIdentity != null) {
        _parkCurrentBlurForCrossfade();
      }
      _rawCoverScheme = cachedScheme;
      _coverBrightness = cachedScheme != null ? brightness : null;
      _coverAverageColor = CoverPaletteCache.instance.averageColorFor(
        coverIdentity,
      );
      _coverTopLuminance ??= CoverPaletteCache.instance.luminanceFor(
        coverIdentity,
      );
    }
    _coverProvider = provider;
    _coverProviderIdentity = coverIdentity;
    _rederiveCoverScheme();
    // Precache the blurred version of the cover, but only when the blurred
    // background is actually in use (skip the work for gradient / off modes).
    if (_cardBackground == 'blurred' &&
        _blurredCoverIdentity != coverIdentity &&
        _pendingBlurIdentity != coverIdentity) {
      _pendingBlurIdentity = coverIdentity;
      _precacheBlur(provider, coverIdentity);
    }
  }

  /// In gradient/off mode the cover image isn't painted, so resolve it directly
  /// to keep the extracted [_coverScheme] (accent + gradient colors) available.
  void _ensureCoverScheme(
    String? coverUrl,
    String? coverIdentity,
    LibraryProvider lib,
  ) {
    if (coverUrl == null || coverIdentity == null) return;
    if (_coverProvider != null && _coverProviderIdentity == coverIdentity) {
      return;
    }
    final headers = lib.mediaHeaders;
    final ImageProvider provider;
    if (coverUrl.startsWith('/')) {
      provider = FileImage(File(coverUrl));
    } else {
      provider = CachedNetworkImageProvider(
        coverUrl,
        headers: headers,
        cacheKey: coverIdentity,
      );
    }
    _onCoverLoaded(provider, coverIdentity);
  }

  /// 冷启动时先把上次落盘的配色和顶部亮度铺上，卡片第一帧就是正确色调。
  void _adoptCachedCoverPalette() {
    final lib = context.read<LibraryProvider>();
    final coverUrl = _resolveCoverUrl();
    final identity = _coverIdentity(coverUrl, lib);
    if (identity == null) return;
    final brightness = Theme.of(context).brightness;
    if (_rawCoverScheme == null) {
      final scheme = CoverPaletteCache.instance.schemeFor(identity, brightness);
      if (scheme != null) {
        _rawCoverScheme = scheme;
        _coverBrightness = brightness;
      }
    }
    _coverTopLuminance ??= CoverPaletteCache.instance.luminanceFor(identity);
    _coverAverageColor ??= CoverPaletteCache.instance.averageColorFor(identity);
  }

  /// 封面 URL 一确定就先起模糊图加载（磁盘缓存通常已有），不必等 1200px
  /// 封面解码完成；冷启动时背景和封面占位能更早用上模糊图。
  void _primeBlurFromCache() {
    // 背景设置是异步读的；设置还没回来时先按默认的 blurred 起加载，别让
    // 模糊图排在异步设置后面。如果最终是 gradient/off，模糊图仍会作为封面
    // 占位使用；设置确认后不再继续生成新的。
    if (_cardBackgroundReady && _cardBackground != 'blurred') return;
    final lib = context.read<LibraryProvider>();
    final coverUrl = _resolveCoverUrl();
    final identity = _coverIdentity(coverUrl, lib);
    if (coverUrl == null || identity == null) return;
    if (_blurredCoverIdentity == identity ||
        _pendingBlurIdentity == identity) {
      return;
    }
    _pendingBlurIdentity = identity;
    // 显式标注 ImageProvider：条件表达式的两个分支是不同实现类，直接让
    // 编译器推断会退化成 Object，导致参数类型不匹配。
    final ImageProvider provider = coverUrl.startsWith('/')
        ? FileImage(File(coverUrl))
        : CachedNetworkImageProvider(
            coverUrl,
            headers: lib.mediaHeaders,
            cacheKey: identity,
          );
    _precacheBlur(provider, identity);
  }

  void _rederiveCoverScheme() {
    final provider = _coverProvider;
    final coverIdentity = _coverProviderIdentity;
    if (provider == null || coverIdentity == null) return;
    final brightness = Theme.of(context).brightness;
    if (_rawCoverScheme != null && _coverBrightness == brightness) return;
    _coverBrightness = brightness;
    final cached = CoverPaletteCache.instance.schemeFor(
      coverIdentity,
      brightness,
    );
    if (cached != null) {
      // 缓存命中：跳过 ColorScheme.fromImageProvider 的解码 + 量化。
      _rawCoverScheme = cached;
      _coverTopLuminance ??= CoverPaletteCache.instance.luminanceFor(
        coverIdentity,
      );
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _coverProviderIdentity == coverIdentity) setState(() {});
        });
      }
      return;
    }
    ColorScheme.fromImageProvider(provider: provider, brightness: brightness)
        .then((s) {
          CoverPaletteCache.instance.storeScheme(coverIdentity, brightness, s);
          if (mounted &&
              _coverProviderIdentity == coverIdentity &&
              _coverBrightness == brightness) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted &&
                  _coverProviderIdentity == coverIdentity &&
                  _coverBrightness == brightness) {
                setState(() => _rawCoverScheme = s);
              }
            });
          }
        })
        .catchError((_) {});
  }

  /// Take the blurred background from the shared cache, generating it only if
  /// nobody has built this cover's blur yet.
  Future<void> _precacheBlur(
    ImageProvider provider,
    String coverIdentity,
  ) async {
    try {
      final lease = await CoverBlurCache.instance.acquire(
        provider,
        coverIdentity,
      );
      if (lease == null) return;
      if (!mounted || _currentCoverIdentity() != coverIdentity) {
        lease.release();
        return;
      }

      // The blurred bitmap is what the card paints, so put it up first. The
      // top-strip brightness only tunes the scrim gradient, and reading it back
      // is another image round-trip - it used to sit in front of the swap,
      // which is what read as a beat of lag before the blur appeared.
      final known = CoverBlurCache.instance.luminanceOf(coverIdentity) ??
          CoverPaletteCache.instance.luminanceFor(coverIdentity);
      final cachedAverage = CoverPaletteCache.instance.averageColorFor(
        coverIdentity,
      );
      final previous = _blurLease;
      setState(() {
        _blurLease = lease;
        _blurredCoverIdentity = coverIdentity;
        _coverTopLuminance = known;
        if (cachedAverage != null) _coverAverageColor = cachedAverage;
      });
      // Remember which item this blur belongs to, so the next cold start only
      // uses it as the first-frame base for the same card.
      unawaited(
        CoverBlurCache.instance.rememberLatest(_lyricsKey, coverIdentity),
      );
      previous?.release();
      // The first frame of the next cold start uses this average as the
      // background; derive it from the small blurred bitmap once.
      if (cachedAverage == null) {
        final average = await averageCoverColor(lease.image);
        if (average != null) {
          CoverPaletteCache.instance.storeAverageColor(coverIdentity, average);
          if (mounted && _currentCoverIdentity() == coverIdentity) {
            setState(() => _coverAverageColor = average);
          }
        }
      }
      if (known != null) return;

      final luminance = await topStripLuminance(lease.image);
      if (luminance == null) return;
      CoverBlurCache.instance.rememberLuminance(coverIdentity, luminance);
      CoverPaletteCache.instance.storeLuminance(coverIdentity, luminance);
      if (mounted && _currentCoverIdentity() == coverIdentity) {
        setState(() => _coverTopLuminance = luminance);
      }
    } catch (_) {
      // Fallback: card will show without blurred background, which is fine
    } finally {
      if (_pendingBlurIdentity == coverIdentity) {
        _pendingBlurIdentity = null;
      }
    }
  }

  /// The store key the live transcript runs under for this card.
  String get _lyricsKey =>
      _episodeId != null ? '$_itemId-$_episodeId' : _itemId;

  @override
  Widget build(BuildContext context) {
    super.build(context); // required for AutomaticKeepAliveClientMixin
    // E-ink mode: the cover-derived palette renders as washed-out grey, so
    // the card sticks to the monochrome app theme.
    final cs =
        (PlayerSettings.einkMode ? null : _coverScheme) ??
        Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 背景/占位用封面的平均色，而不是 Material tonal scheme 的
    // primaryContainer（淡黄封面常被映射成偏棕的容器色）。终点只混入少量
    // 主题 surface，避免渐变下半段又回到棕色。
    final coverBg = _coverAverageColor ?? cs.primaryContainer;
    final coverBgEnd = _coverAverageColor != null
        ? Color.lerp(
            _coverAverageColor!,
            isDark ? Colors.black : Colors.white,
            0.12,
          )!
        : cs.surface;
    final accent = cs.primary;
    final l = AppLocalizations.of(context)!;

    final lib = context.watch<LibraryProvider>();
    final coverUrl = _resolveCoverUrl();
    final coverIdentity = _coverIdentity(coverUrl, lib);
    final isLocalCover = coverUrl?.startsWith('/') ?? false;
    // 首帧还没有任何模糊图/封面时不要把主题色画进卡片；等模糊图/封面到了再显示
    // 边框、强调光和图片，避免“先闪一下主题色”。
    final hasCardVisual = _cardBackground != 'blurred' ||
        _blurLease != null ||
        _placeholderBlurLease != null ||
        _coverProvider != null;
    _maybeRefetchOnServerChange(lib);
    // For podcast episodes, look up progress by compound key (itemId-episodeId)
    final progress = (_episodeId != null)
        ? lib.getEpisodeProgress(_itemId, _episodeId!)
        : (_isPodcastEpisode
              ? lib.getEpisodeProgress(_itemId, widget.player.currentEpisodeId!)
              : lib.getProgress(_itemId));
    final chapterIdx = _currentChapterIndex();
    final cast = ChromecastService();
    final totalChapters = _isCastingThis
        ? cast.castingChapters.length
        : (_isActive ? widget.player.chapters.length : _chapters.length);
    final double bookProgress;
    if (widget.player.isParkedFinished) {
      // Finished book held on the card: engine stopped, freeze the bar at 100%.
      bookProgress = 1.0;
    } else if (_isCastingThis && cast.castingDuration > 0) {
      final castPos = cast.castPosition.inMilliseconds / 1000.0;
      bookProgress = (castPos / cast.castingDuration).clamp(0.0, 1.0);
    } else if (_isActive && widget.player.totalDuration > 0) {
      final playerPos = widget.player.position.inMilliseconds / 1000.0;
      if (playerPos < 1.0 && progress > 0.01) {
        bookProgress = progress;
      } else {
        bookProgress = (playerPos / widget.player.totalDuration).clamp(
          0.0,
          1.0,
        );
      }
    } else {
      bookProgress = progress;
    }

    // In gradient/off mode the cover image isn't painted, so derive its scheme separately.
    if (_cardBackground != 'blurred') {
      _ensureCoverScheme(coverUrl, coverIdentity, lib);
    }

    final tt = Theme.of(context).textTheme;
    final mediaHeaders = lib.mediaHeaders;
    // A chapterless book gets the same single-bar look as a chapterless
    // podcast: no top book bar, just the scrubber bar carrying the title.
    final showBookBar = _chapters.isNotEmpty;
    return GestureDetector(
      onVerticalDragEnd: (details) {
        final vy = details.primaryVelocity ?? 0;
        if (vy < -300) expandCard(context); // swipe up to expand
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: hasCardVisual
                ? accent.withValues(alpha: 0.15)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(23),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 模糊背景读盘/生成期间让页面透出来，不铺主题色块；模糊图到了
              // 再淡入。这样首帧不会出现“主题色卡片”。
              if (_cardBackground == 'off')
                ColoredBox(color: Theme.of(context).colorScheme.surface)
              else if (_cardBackground == 'gradient')
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [coverBg, coverBgEnd],
                    ),
                  ),
                )
              else if (_cardBackground == 'blurred') ...[
                // 上一次落盘的模糊封面先顶上；当前封面的模糊图就绪后淡入
                // 覆盖它。首帧因此是模糊封面/背景，而不是纯色或提取色。
                if (_placeholderBlurLease != null)
                  RepaintBoundary(
                    child: RawImage(
                      image: _placeholderBlurLease!.image,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                  ),
                if (_blurLease != null)
                  TweenAnimationBuilder<double>(
                    key: ValueKey(
                      'blur-bg-${_blurredCoverIdentity ?? _blurLease!.hashCode}',
                    ),
                    tween: Tween<double>(begin: 0, end: 1),
                    duration: _bgFadeDuration,
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) =>
                        Opacity(opacity: t, child: child),
                    child: RepaintBoundary(
                      child: RawImage(
                        image: _blurLease!.image,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                  ),
              ],
              // Layer 2: Scrim. 首帧图片/模糊图还没到时不铺 scrim，否则会在
              // 透明卡片上留下一条主题色/黑白的整卡渐变。
              if (hasCardVisual)
                Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      // Lighter scrim over the gradient/off backgrounds so the cover
                      // tint reads through; the blurred photo still needs the heavier one.
                      colors: _cardBackground == 'blurred'
                          ? (isDark
                                ? [
                                    Colors.black.withValues(alpha: 0.3),
                                    Colors.black.withValues(alpha: 0.6),
                                    Colors.black.withValues(alpha: 0.85),
                                  ]
                                : [
                                    Colors.white.withValues(alpha: 0.4),
                                    Colors.white.withValues(alpha: 0.7),
                                    Colors.white.withValues(alpha: 0.9),
                                  ])
                          : (isDark
                                ? [
                                    Colors.black.withValues(alpha: 0.15),
                                    Colors.black.withValues(alpha: 0.4),
                                    Colors.black.withValues(alpha: 0.68),
                                  ]
                                : [
                                    Colors.white.withValues(alpha: 0.25),
                                    Colors.white.withValues(alpha: 0.55),
                                    Colors.white.withValues(alpha: 0.8),
                                  ]),
                    ),
                  ),
                ),
              ),
              // Layer 3: Content
              LayoutBuilder(
                builder: (context, cardConstraints) {
                  final textScale = MediaQuery.textScalerOf(
                    context,
                  ).scale(1.0).clamp(1.0, 1.5);
                  final compact = cardConstraints.maxHeight < 600 * textScale;
                  // In landscape the card is wider than tall — switch to a two-pane
                  // layout with the cover on the left and everything else on the right.
                  final wide =
                      cardConstraints.maxWidth > cardConstraints.maxHeight;

                  final statsRow = ValueListenableBuilder<bool>(
                    valueListenable: _edgeBarExpanded,
                    builder: (_, expanded, child) => AnimatedOpacity(
                      opacity: expanded ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      child: child,
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(24, compact ? 6 : 10, 24, 0),
                      child: StreamBuilder<Duration>(
                        stream: _isCastingThis
                            ? cast.castPositionStream
                            : widget.player.absolutePositionStream,
                        builder: (_, snap) {
                          final double pos;
                          final double dur;
                          if (_isCastingThis) {
                            pos = cast.castPosition.inMilliseconds / 1000.0;
                            dur = cast.castingDuration;
                          } else if (_isActive) {
                            pos = (snap.data?.inMilliseconds ?? 0) / 1000.0;
                            dur = _effectiveDuration;
                          } else {
                            // Use exact currentTime from server progress if available,
                            // otherwise fall back to progress ratio * duration.
                            final pd = _episodeId != null
                                ? lib.getEpisodeProgressData(
                                    _itemId,
                                    _episodeId!,
                                  )
                                : lib.getProgressData(_itemId);
                            final ct = (pd?['currentTime'] as num?)?.toDouble();
                            pos = (ct != null && ct > 0)
                                ? ct
                                : bookProgress * _effectiveDuration;
                            dur = _effectiveDuration;
                          }
                          final speed = _speedAdjustedTime
                              ? (_isActive ? widget.player.speed : _savedSpeed)
                              : 1.0;
                          final liveBookProgress = dur > 0
                              ? (pos / dur).clamp(0.0, 1.0)
                              : bookProgress;
                          final elapsed = pos / speed;
                          final remaining = (dur - pos) / speed;
                          // This row sits on the cover, not on the theme surface.
                          // With a blurred background the scrim is at its thinnest
                          // right here (0.3 / 0.4), so a pale cover in dark mode
                          // used to leave white text on a near-white backdrop.
                          // Pick the ink from what is actually behind it; the other
                          // background modes follow the theme as before.
                          final coverLuminance = _cardBackground == 'blurred'
                              ? _coverTopLuminance
                              : null;
                          final ink = coverLuminance == null
                              ? null
                              : inkForLuminance(
                                  scrimmedLuminance(
                                    coverLuminance,
                                    isDark ? Colors.black : Colors.white,
                                    isDark ? 0.3 : 0.4,
                                  ),
                                );
                          final timeStyle = tt.labelSmall?.copyWith(
                            color:
                                ink?.ink ??
                                (isDark
                                    ? Colors.white.withValues(alpha: 0.55)
                                    : cs.onSurface),
                            fontWeight: FontWeight.w500,
                            fontSize: (compact ? 10 : 11) * _progressTextScale,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            shadows: [
                              Shadow(
                                color:
                                    ink?.shadow ??
                                    (isDark
                                        ? Colors.black.withValues(alpha: 0.6)
                                        : Colors.white.withValues(alpha: 0.6)),
                                blurRadius: 4,
                              ),
                            ],
                          );
                          return Stack(
                            alignment: Alignment.center,
                            children: [
                              Row(
                                children: [
                                  if (_effectiveDuration > 0 && showBookBar)
                                    Text(fmtTime(elapsed), style: timeStyle),
                                  const Spacer(),
                                  if (_effectiveDuration > 0 && showBookBar)
                                    Text(
                                      '-${fmtTime(remaining)}',
                                      style: timeStyle,
                                    ),
                                ],
                              ),
                              Text(
                                '${(liveBookProgress * 100).clamp(0, 100).toStringAsFixed(1)}%',
                                style: timeStyle,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  );

                  final coverArea = Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ListenableBuilder(
                      listenable: Listenable.merge([
                        ChromecastService(),
                        widget.player,
                      ]),
                      builder: (context, _) => LayoutBuilder(
                        builder: (context, constraints) {
                          final maxW = constraints.maxWidth * 0.85;
                          final rawH = constraints.maxHeight.isFinite
                              ? constraints.maxHeight
                              : maxW;
                          final maxH = rawH - 24;
                          double coverW, coverH;
                          if (_rectangleCovers) {
                            coverW = maxW;
                            coverH = coverW * 1.5;
                            if (coverH > maxH) {
                              coverH = maxH;
                              coverW = coverH / 1.5;
                            }
                          } else {
                            final s = maxW < maxH ? maxW : maxH;
                            coverW = s;
                            coverH = s;
                          }
                          final downloads = DownloadService();
                          final isDownloaded = downloads.isCurrentChapterSaved(
                            episodeId: _episodeId,
                            itemId: _itemId,
                            chapters: _chapters,
                            chapterIndex: chapterIdx,
                          );
                          final castService = ChromecastService();
                          final isCastingThis =
                              castService.isCasting &&
                              castService.castingItemId == _itemId;
                          final coverPlaying = isCastingThis
                              ? castService.isPlaying
                              : (_isActive && widget.player.isPlaying);
                          final coverLoading =
                              _isStarting ||
                              (_isActive &&
                                  widget.player.isLoadingOrBuffering &&
                                  !widget.player.isPlaying);
                          return Column(
                            mainAxisSize: MainAxisSize.max,
                            children: [
                              const Spacer(flex: 2),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: () {
                                  final showStreaming =
                                      !isDownloaded && _isActive;
                                  final showSaved = isDownloaded;
                                  final visible = showSaved || showStreaming;
                                  final streamColor = isDark
                                      ? Colors.white.withValues(alpha: 0.5)
                                      : cs.onSurface.withValues(alpha: 0.6);
                                  final savedColor = isDark
                                      ? Colors.greenAccent.withValues(
                                          alpha: 0.7,
                                        )
                                      : Colors.green.shade700.withValues(
                                          alpha: 0.7,
                                        );
                                  return Opacity(
                                    opacity: visible ? 1.0 : 0.0,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          showSaved
                                              ? Icons.download_done_rounded
                                              : Icons.cell_tower_rounded,
                                          size: 11,
                                          color: showSaved
                                              ? savedColor
                                              : streamColor,
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          showSaved
                                              ? l.saved
                                              : l.expandedCardStreaming,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w500,
                                            color: showSaved
                                                ? savedColor
                                                : streamColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }(),
                              ),
                              GestureDetector(
                                onTap: _coverPlayButton
                                    ? () {
                                        if (isCastingThis) {
                                          castService.togglePlayPause();
                                        } else if (_isActive) {
                                          widget.player.togglePlayPause(
                                            fromUi: true,
                                          );
                                        } else {
                                          _startPlayback();
                                        }
                                      }
                                    : null,
                                child: Container(
                                  width: coverW,
                                  height: coverH,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: [
                                      BoxShadow(
                                        color: hasCardVisual
                                            ? Colors.black.withValues(
                                                alpha: isDark ? 0.5 : 0.15,
                                              )
                                            : Colors.transparent,
                                        blurRadius: 20,
                                        spreadRadius: -2,
                                        offset: const Offset(0, 6),
                                      ),
                                      BoxShadow(
                                        color: hasCardVisual
                                            ? accent.withValues(alpha: 0.15)
                                            : Colors.transparent,
                                        blurRadius: 30,
                                        spreadRadius: -5,
                                      ),
                                    ],
                                  ),
                                  child: RepaintBoundary(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          // Cover image - hidden while the transcript
                                          // has the cover.
                                          AnimatedBuilder(
                                            animation: LyricsService.instance,
                                            builder: (context, child) =>
                                                LyricsService.instance
                                                    .coversArtFor(_lyricsKey)
                                                ? Offstage(child: child)
                                                : child!,
                                            child: EinkCoverTone(
                                              // 本地封面文件被原地替换时路径没变，只有
                                              // identity（含 mtime/size）会变；用 key 逼
                                              // Image.file 重新解析，否则会继续显示旧图。
                                              // 网络封面由 StableCachedNetworkImage 自己
                                              // 处理 URL 变化，所以不重挂。
                                              key:
                                                  isLocalCover &&
                                                      coverIdentity != null
                                                  ? ValueKey(
                                                      'local-cover-$coverIdentity',
                                                    )
                                                  : null,
                                              child: Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  // 常驻底图：CachedNetworkImage 从
                                                  // placeholder 切到解码图时，模糊图
                                                  // 不会先消失一瞬再重新出现。
                                                  _coverLoadingPlaceholder(cs),
                                                  (coverUrl != null &&
                                                          coverIdentity != null)
                                                      ? isLocalCover
                                                          ? BlurPaddedCover(
                                                            blurChild: Image.file(
                                                              File(coverUrl),
                                                              fit: BoxFit.cover,
                                                              gaplessPlayback:
                                                                  true,
                                                              errorBuilder:
                                                                  (
                                                                    _,
                                                                    __,
                                                                    ___,
                                                                  ) =>
                                                                      const SizedBox.shrink(),
                                                            ),
                                                            enabled:
                                                                !_rectangleCovers,
                                                            child: Image.file(
                                                              File(coverUrl),
                                                              fit:
                                                                  _rectangleCovers
                                                                  ? BoxFit.cover
                                                                  : BoxFit
                                                                        .contain,
                                                              gaplessPlayback:
                                                                  true,
                                                              errorBuilder:
                                                                  (
                                                                    _,
                                                                    __,
                                                                    ___,
                                                                  ) =>
                                                                      _coverLoadingPlaceholder(
                                                                        cs,
                                                                        showIcon:
                                                                            true,
                                                                      ),
                                                            ),
                                                          )
                                                        : BlurPaddedCover(
                                                            blurChild: StableCachedNetworkImage(
                                                              imageUrl:
                                                                  coverUrl,
                                                              cacheKey:
                                                                  coverIdentity,
                                                              fit: BoxFit.cover,
                                                              httpHeaders:
                                                                  mediaHeaders,
                                                              fadeInDuration:
                                                                  _coverFadeDuration,
                                                              errorWidget:
                                                                  (
                                                                    _,
                                                                    __,
                                                                    ___,
                                                                  ) =>
                                                                      const SizedBox.shrink(),
                                                            ),
                                                            enabled:
                                                                !_rectangleCovers,
                                                            child: StableCachedNetworkImage(
                                                              imageUrl:
                                                                  coverUrl,
                                                              cacheKey:
                                                                  coverIdentity,
                                                              fit:
                                                                  _rectangleCovers
                                                                  ? BoxFit.cover
                                                                  : BoxFit
                                                                        .contain,
                                                              httpHeaders:
                                                                  mediaHeaders,
                                                              fadeInDuration:
                                                                  _coverFadeDuration,
                                                              imageBuilder: (_, provider) {
                                                                _onCoverLoaded(
                                                                  provider,
                                                                  coverIdentity,
                                                                );
                                                                return Image(
                                                                  image:
                                                                      provider,
                                                                  fit:
                                                                      _rectangleCovers
                                                                      ? BoxFit
                                                                            .cover
                                                                      : BoxFit
                                                                            .contain,
                                                                );
                                                              },
                                                              placeholder: (_, __) =>
                                                                  const SizedBox.shrink(),
                                                              errorWidget:
                                                                  (
                                                                    _,
                                                                    __,
                                                                    ___,
                                                                  ) =>
                                                                      _coverLoadingPlaceholder(
                                                                        cs,
                                                                        showIcon:
                                                                            true,
                                                                      ),
                                                            ),
                                                          )
                                                      : _coverLoadingPlaceholder(
                                                          cs,
                                                          showIcon: true,
                                                        ),
                                                    ],
                                                  ),
                                            ),
                                          ),
                                          // Casting overlay
                                          if (isCastingThis) ...[
                                            Positioned.fill(
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.45),
                                                  borderRadius:
                                                      BorderRadius.circular(16),
                                                ),
                                              ),
                                            ),
                                            Positioned.fill(
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    Icons
                                                        .cast_connected_rounded,
                                                    size: 36,
                                                    color: accent.withValues(
                                                      alpha: 0.9,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    l.castingTo,
                                                    style: TextStyle(
                                                      color: Colors.white
                                                          .withValues(
                                                            alpha: 0.6,
                                                          ),
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 16,
                                                        ),
                                                    child: Text(
                                                      castService
                                                              .connectedDeviceName ??
                                                          l.expandedCardDeviceFallback,
                                                      style: TextStyle(
                                                        color: accent,
                                                        fontSize: 14,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                      textAlign:
                                                          TextAlign.center,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                          // Play/pause overlay - the tap still works
                                          // with the transcript up, but the button would
                                          // sit on the words.
                                          if (_coverPlayButton)
                                            Positioned.fill(
                                              child: AnimatedBuilder(
                                                animation:
                                                    LyricsService.instance,
                                                builder: (context, child) =>
                                                    LyricsService.instance
                                                        .coversArtFor(
                                                          _lyricsKey,
                                                        )
                                                    ? Offstage(child: child)
                                                    : child!,
                                                child: AnimatedContainer(
                                                  duration: const Duration(
                                                    milliseconds: 200,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: coverPlaying
                                                        ? Colors.transparent
                                                        : Colors.black
                                                              .withValues(
                                                                alpha: 0.25,
                                                              ),
                                                  ),
                                                  child: Center(
                                                    child: coverLoading
                                                        ? Container(
                                                            width: 65,
                                                            height: 65,
                                                            decoration:
                                                                BoxDecoration(
                                                                  shape: BoxShape
                                                                      .circle,
                                                                  color: Colors
                                                                      .black
                                                                      .withValues(
                                                                        alpha:
                                                                            0.5,
                                                                      ),
                                                                ),
                                                            child: Padding(
                                                              padding:
                                                                  const EdgeInsets.all(
                                                                    12,
                                                                  ),
                                                              child:
                                                                  CircularProgressIndicator(
                                                                    strokeWidth:
                                                                        3,
                                                                    color:
                                                                        accent,
                                                                  ),
                                                            ),
                                                          )
                                                        : AnimatedOpacity(
                                                            opacity:
                                                                coverPlaying
                                                                ? 0.2
                                                                : 0.9,
                                                            duration:
                                                                const Duration(
                                                                  milliseconds:
                                                                      200,
                                                                ),
                                                            child: Container(
                                                              width: 72,
                                                              height: 72,
                                                              decoration: BoxDecoration(
                                                                shape: BoxShape
                                                                    .circle,
                                                                color: Colors
                                                                    .black
                                                                    .withValues(
                                                                      alpha:
                                                                          0.45,
                                                                    ),
                                                              ),
                                                              child: Icon(
                                                                coverPlaying
                                                                    ? Icons
                                                                          .pause_rounded
                                                                    : Icons
                                                                          .play_arrow_rounded,
                                                                size: 42,
                                                                color: accent,
                                                              ),
                                                            ),
                                                          ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          // Live transcript (lyrics mode)
                                          LyricsOverlay(
                                            compact: true,
                                            forKey: _lyricsKey,
                                            surface: cs.surface,
                                            onSurface: cs.onSurface,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const Spacer(flex: 2),
                            ],
                          );
                        },
                      ),
                    ),
                  );

                  final scrubberBar = Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: CardDualProgressBar(
                      player: widget.player,
                      accent: accent,
                      isActive: _isActive,
                      staticProgress: (_isPodcastEpisode && _chapters.isEmpty)
                          ? 0.0
                          : progress,
                      staticDuration: (_isPodcastEpisode && _chapters.isEmpty)
                          ? widget.player.totalDuration
                          : _effectiveDuration,
                      chapters: _chapters,
                      showBookBar: false,
                      showChapterBar: true,
                      chapterName: (_isPodcastEpisode && _chapters.isEmpty)
                          ? (widget.player.currentEpisodeTitle ??
                                widget.player.currentTitle ??
                                _title)
                          : (_episodeId != null && !_isActive
                                ? (_recentEpisode?['title'] as String? ??
                                      _title)
                                : (_chapters.isEmpty
                                      ? _title
                                      : _chapterName(chapterIdx))),
                      chapterIndex: chapterIdx,
                      totalChapters: totalChapters,
                      itemId: _itemId,
                      compact: compact,
                    ),
                  );

                  final controlsRow = Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: CardPlaybackControls(
                      player: widget.player,
                      accent: accent,
                      isActive: _isActive,
                      isStarting: _isStarting,
                      onStart: _startPlayback,
                      itemId: _itemId,
                      showPlayButton: !_coverPlayButton,
                      libraryId: _resolveLibraryId(),
                    ),
                  );

                  final buttonGrid = MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.noScaling),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: LayoutBuilder(
                        builder: (context, buttonsConstraints) => FittedBox(
                          fit: BoxFit.scaleDown,
                          child: SizedBox(
                            width: buttonsConstraints.maxWidth - 40,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ..._buildButtonGrid(accent, tt),
                                if (!_moreInline) ...[
                                  const SizedBox(height: 6),
                                  Center(
                                    child: ListenableBuilder(
                                      listenable: ChromecastService(),
                                      builder: (context, _) {
                                        final castActive =
                                            ChromecastService().isCasting &&
                                            !_buttonOrder
                                                .take(_visibleButtonCount)
                                                .contains('cast');
                                        return Pressable(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => _showMoreMenu(
                                            context,
                                            accent,
                                            tt,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: castActive
                                                  ? accent.withValues(
                                                      alpha: 0.15,
                                                    )
                                                  : cs.onSurface.withValues(
                                                      alpha: 0.08,
                                                    ),
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: castActive
                                                  ? [
                                                      Icon(
                                                        Icons
                                                            .cast_connected_rounded,
                                                        size: 18,
                                                        color: accent,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        l.casting,
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                          color: accent,
                                                        ),
                                                      ),
                                                    ]
                                                  : [
                                                      Icon(
                                                        Icons
                                                            .more_horiz_rounded,
                                                        size: 18,
                                                        color: cs.onSurface
                                                            .withValues(
                                                              alpha: 0.54,
                                                            ),
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        l.more,
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.w500,
                                                          color: cs.onSurface
                                                              .withValues(
                                                                alpha: 0.54,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                                SizedBox(height: compact ? 4 : 8),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );

                  if (wide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: coverArea),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              statsRow,
                              SizedBox(height: compact ? 6 : 10),
                              scrubberBar,
                              SizedBox(height: compact ? 6 : 10),
                              controlsRow,
                              SizedBox(height: compact ? 6 : 12),
                              buttonGrid,
                            ],
                          ),
                        ),
                      ],
                    );
                  }

                  return Column(
                    children: [
                      statsRow,
                      Expanded(child: coverArea),
                      SizedBox(height: compact ? 6 : 10),
                      scrubberBar,
                      SizedBox(height: compact ? 6 : 10),
                      controlsRow,
                      SizedBox(height: compact ? 6 : 12),
                      buttonGrid,
                    ],
                  );
                },
              ),
              // Edge progress bar (thin strip at top of card)
              if (showBookBar)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: CardEdgeProgressBar(
                    player: widget.player,
                    accent: accent,
                    isActive: _isActive,
                    staticProgress: progress,
                    staticDuration: _effectiveDuration,
                    chapters: _chapters,
                    itemId: _itemId,
                    expandedNotifier: _edgeBarExpanded,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The freshest local version of this item's ebook for a read action.
  ///
  /// The minified shelf item's inline `media.ebookFile` goes stale when the
  /// server's default version is changed in the detail sheet, but that sheet
  /// writes the fresh full item to the disk cache as it reloads, so the cached
  /// copy is preferred here. Falls back to the inline / locally cached file
  /// when nothing has been fetched yet or offline.
  Future<Map<String, dynamic>?> _resolveEbookForAction() async {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api != null) {
      try {
        final fresh = await api.getCachedLibraryItem(_itemId);
        final ef = resolveEbookFile(fresh);
        if (ef != null) {
          if (mounted) setState(() => _fetchedEbookFile = ef);
          return ef;
        }
      } catch (_) {}
    }
    var ebookFile = _ebookFile;
    // A downloaded book's ebook may already sit in the reader cache - check
    // that before any network retry, so offline Read opens instantly instead
    // of waiting out a timeout. The reader opens from this same cached file
    // either way.
    ebookFile ??= await cachedEbookFileFor(_itemId);
    if (ebookFile == null) {
      // The initState fetch is one-shot and can fail silently (network blip),
      // so give it another chance before declaring there's no ebook.
      await _fetchChaptersIfNeeded();
      ebookFile = _ebookFile;
    }
    return ebookFile;
  }

  void _openEbookReader() async {
    final ebookFile = await _resolveEbookForAction();
    if (!mounted) return;
    if (ebookFile == null) {
      showOverlayToast(
        context,
        AppLocalizations.of(context)!.noEbookFileFound,
        icon: Icons.menu_book_outlined,
      );
      return;
    }
    openEbookReader(
      context,
      itemId: _itemId,
      title: _title,
      ebookFile: ebookFile,
    );
  }

  void _openReadAlong() async {
    final ebookFile = await _resolveEbookForAction();
    if (!mounted) return;
    if (ebookFile == null) {
      showOverlayToast(
        context,
        AppLocalizations.of(context)!.noEbookFileFound,
        icon: Icons.menu_book_outlined,
      );
      return;
    }
    openEbookReader(
      context,
      itemId: _itemId,
      title: _title,
      ebookFile: ebookFile,
      startReadAlong: true,
    );
  }

  void _findInEbook() async {
    final ebookFile = await _resolveEbookForAction();
    if (!mounted) return;
    if (ebookFile == null) {
      showOverlayToast(
        context,
        AppLocalizations.of(context)!.noEbookFileFound,
        icon: Icons.menu_book_outlined,
      );
      return;
    }
    launchFindInEbook(
      context,
      itemId: _itemId,
      title: _title,
      ebookFile: ebookFile,
    );
  }

  int _currentChapterIndex() {
    final cast = ChromecastService();
    final chapters = _isCastingThis
        ? cast.castingChapters
        : (_isActive ? widget.player.chapters : _chapters);
    if (chapters.isEmpty) return -1;
    double pos;
    if (_isCastingThis) {
      pos = cast.castPosition.inMilliseconds / 1000.0;
    } else if (_isActive) {
      // Latch-aware index (same source as the lock screen): while a jump is
      // settling the raw position sits in the previous chapter's tail (~0.3s
      // metadata-vs-boundary drift), so a plain containment lookup would flash
      // the PREVIOUS chapter at ~100%. Prefer the service's resolution of the
      // jumped-to chapter; fall back to its load-aware position only when the
      // service has no chapters of its own.
      final idx = widget.player.currentChapterIndex;
      if (idx != null && idx < chapters.length) return idx;
      // Use the player's load-aware chapter position so a slow next-episode
      // load resolves against the pending start instead of the stale
      // previous-book position (which map to the last chapter).
      pos = widget.player.chapterResolvePosSec;
    } else {
      // Use stored progress to calculate position when not actively playing
      final lib = context.read<LibraryProvider>();
      final progress = (_episodeId != null)
          ? lib.getEpisodeProgress(_itemId, _episodeId!)
          : lib.getProgress(_itemId);
      pos = progress * _effectiveDuration;
    }
    for (int i = 0; i < chapters.length; i++) {
      final ch = chapters[i] as Map<String, dynamic>;
      final start = (ch['start'] as num?)?.toDouble() ?? 0;
      final end = (ch['end'] as num?)?.toDouble() ?? 0;
      if (pos >= start && pos < end) return i;
    }
    // If past the last chapter end, return last chapter
    if (pos > 0 && chapters.isNotEmpty) return chapters.length - 1;
    return 0;
  }

  String? _chapterName(int chapterIdx) {
    if (_isCastingThis) {
      final ch = ChromecastService().currentChapter;
      return ch?['title'] as String?;
    }
    // currentChapter resolves through chapterResolvePosSec, which uses the
    // active seek target while a slow seek is still buffering - so the label
    // shows the chapter a jump is heading to immediately instead of staying on
    // the pre-seek chapter until the position catches up.
    if (_isActive && widget.player.currentChapter != null) {
      return widget.player.currentChapter!['title'] as String?;
    }
    if (chapterIdx >= 0 && chapterIdx < _chapters.length) {
      final ch = _chapters[chapterIdx] as Map<String, dynamic>;
      return ch['title'] as String?;
    }
    return null;
  }

  void expandCard(BuildContext context) {
    AppShell.setExpandedOpen(true);
    Navigator.of(context, rootNavigator: true)
        .push(
          ExpandedCardRoute(
            child: ExpandedCard(
              item: widget.item,
              player: widget.player,
              initialCoverScheme: _coverScheme,
              initialBlurIdentity: _blurredCoverIdentity,
              initialChapters: _fetchedChapters,
              initialEbookFile: _ebookFile,
              initialCardBackground: _cardBackground,
            ),
          ),
        )
        .then((_) => AppShell.setExpandedOpen(false));
  }

  Future<void> _startPlayback() async {
    if (_isStarting) return;
    // If we're casting this book, don't start local playback
    final cast = ChromecastService();
    if (cast.isCasting && cast.castingItemId == _itemId) return;
    setState(() => _isStarting = true);
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) {
      setState(() => _isStarting = false);
      return;
    }
    final error = await widget.player.playItem(
      api: api,
      itemId: _itemId,
      title: _title,
      author: _author,
      coverUrl: _coverUrl,
      totalDuration: _effectiveDuration,
      chapters: _chapters,
      episodeId: _episodeId,
      episodeTitle: _recentEpisode?['title'] as String?,
      libraryId: _resolveLibraryId(),
      seriesId: seriesIdFromItem(widget.item),
      fromUi: true,
    );
    if (mounted) {
      if (error != null) showErrorToast(context, error);
      setState(() => _isStarting = false);
    }
  }

  Future<void> _removeFromAbsorbing() async {
    if (widget.player.currentItemId == _itemId) {
      await widget.player.pause();
      await widget.player.stop();
    }
    if (mounted) {
      final lib = context.read<LibraryProvider>();
      // Use compound key for podcast episodes
      final key = _episodeId != null ? '$_itemId-$_episodeId' : _itemId;
      await lib.removeFromAbsorbing(key);
    }
  }

  // ── Dynamic button builders (delegated) ─────────────────────

  CardActionDelegate _makeActions() => CardActionDelegate(
    context: context,
    player: widget.player,
    item: widget.item,
    itemId: _itemId,
    episodeId: _episodeId,
    isPodcastEpisode: _isPodcastEpisode,
    title: _title,
    author: _author,
    coverUrl: _coverUrl,
    duration: _duration,
    effectiveDuration: _effectiveDuration,
    chapters: _chapters,
    recentEpisode: _recentEpisode,
    isActive: _isActive,
    isPlaybackActive: _isPlaybackActive,
    isCastingThis: _isCastingThis,
    speedAdjustedTime: _speedAdjustedTime,
    savedSpeed: _savedSpeed,
    visibleCount: _buttonVisibleCount,
    iconsOnly: _iconsOnly,
    moreInline: _moreInline,
    buttonOrder: _buttonOrder,
    removeFromAbsorbing: _removeFromAbsorbing,
    onReorder: (newOrder, newCount) {
      setState(() {
        _buttonOrder = newOrder;
        _buttonVisibleCount = newCount;
      });
      PlayerSettings.setCardButtonOrder(newOrder);
      PlayerSettings.setCardButtonVisibleCount(newCount);
    },
    isEbookPdf: _ebookExt == 'pdf',
    isEbookEpub: _ebookExt == 'epub',
    onEbookTap: _openEbookReader,
    onFindInEbookTap: _findInEbook,
    onReadAlongTap: _openReadAlong,
  );

  int get _visibleButtonCount => _buttonVisibleCount;

  List<Widget> _buildButtonGrid(Color accent, TextTheme tt) =>
      _makeActions().buildButtonGrid(accent, tt);

  void _showMoreMenu(BuildContext context, Color accent, TextTheme tt) =>
      _makeActions().showMoreMenu(accent, tt);
}
