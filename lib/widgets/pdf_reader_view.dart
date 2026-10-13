import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import '../services/api_service.dart';
import '../services/ebook_cache.dart';
import '../services/ebook_progress_store.dart';
import '../services/pdf_cache_manager.dart';
import '../services/progress_sync_service.dart';
import '../services/volume_key_service.dart';

/// Full-screen PDF reader. PDFs are fixed-layout, so this is deliberately
/// simpler than the EPUB reader (no font/margin/theme reflow): page scrolling,
/// an outline-as-chapters sheet, resume, and progress sync. Page number is
/// stored as the ebookLocation, the same field the EPUB reader uses for its CFI.
class PdfReaderView extends StatefulWidget {
  final String itemId;
  final String title;
  final Map<String, dynamic> ebookFile;

  const PdfReaderView({
    super.key,
    required this.itemId,
    required this.title,
    required this.ebookFile,
  });

  @override
  State<PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends State<PdfReaderView> with WidgetsBindingObserver {
  final _controller = PdfViewerController();
  ApiService? _api;
  LibraryProvider? _lib;
  File? _file;
  Uri? _uri;
  String? _error;
  bool _loading = true;

  int _initialPage = 1;
  int _page = 1;
  int _pageCount = 0;

  // The page indicator updates on every page change while scrolling; driving it
  // through notifiers (not setState) keeps those ticks from rebuilding the
  // whole Stack - including the PdfViewer - dozens of times a second.
  final _pageNotifier = ValueNotifier<int>(1);
  final _pageCountNotifier = ValueNotifier<int>(0);
  late final Listenable _pageInfo =
      Listenable.merge([_pageNotifier, _pageCountNotifier]);

  List<PdfOutlineNode> _outline = [];
  bool _showControls = true;
  int _attempt = 0;

  // Progress sync throttling - same gentle cadence as the EPUB reader.
  DateTime _lastSync = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSyncedPage = -1;
  int? _pendingPage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setFullscreen(true);
    _api = context.read<AuthProvider>().apiService;
    _lib = context.read<LibraryProvider>();
    _lib?.setReaderQuiet(true);
    _open();
    _volumeNav.attach();
  }

  // Flush on background so an OS kill can't lose the last pages read.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _flushProgress();
  }

  late final EreaderVolumeNav _volumeNav = EreaderVolumeNav(
    onPrev: () {
      if (_page > 1) _controller.goToPage(pageNumber: _page - 1);
    },
    onNext: () {
      if (_pageCount <= 0 || _page < _pageCount) {
        _controller.goToPage(pageNumber: _page + 1);
      }
    },
  );

  @override
  void dispose() {
    _lib?.setReaderQuiet(false);
    WidgetsBinding.instance.removeObserver(this);
    _volumeNav.detach();
    _setFullscreen(false);
    _flushProgress();
    // The viewer has stopped reading, so trim the streamed-PDF block cache now
    // that its files are no longer held open. Fire-and-forget: cache upkeep must
    // never delay teardown or block the exit animation.
    unawaited(enforcePdfStreamCacheLimits());
    _pageNotifier.dispose();
    _pageCountNotifier.dispose();
    super.dispose();
  }

  void _setFullscreen(bool fullscreen) {
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  Future<void> _loadInitialPage() async {
    final lib = context.read<LibraryProvider>();
    final data = lib.getProgressData(widget.itemId);
    // The item-level location is shared by every ebook version of this book;
    // resolve it per version so a PDF never resumes at another version's page.
    final resolved = await EbookProgressStore.instance.resolve(
      widget.itemId,
      ebookVersionKey(widget.ebookFile),
      itemLocation: data?['ebookLocation'] as String?,
      itemProgress: (data?['ebookProgress'] as num?)?.toDouble(),
    );
    if (!mounted) return;
    final p = int.tryParse(resolved.location?.trim() ?? '');
    if (p != null && p >= 1) {
      _initialPage = p;
      _page = p;
      _pageNotifier.value = p;
    }
  }

  Future<void> _open() async {
    try {
      final api = _api;
      if (api == null) {
        setState(() { _error = 'Not connected to server'; _loading = false; });
        return;
      }
      // Make sure pdfrx's cache root is known, then trim it before this session
      // adds to it (a no-op on the very first open).
      await ensurePdfStreamCacheConfigured();
      unawaited(enforcePdfStreamCacheLimits());
      await _loadInitialPage();
      if (!mounted) return;
      // A downloaded/kept ebook already sits in the reader cache; open it from
      // disk so it reads offline with no network round-trip.
      if (await isEbookCached(widget.itemId, widget.ebookFile)) {
        final f = await ebookCacheFileFor(widget.itemId, widget.ebookFile);
        if (mounted) setState(() { _file = f; _loading = false; });
        return;
      }
      // Otherwise stream the PDF straight from the server. pdfrx issues HTTP
      // range requests and only the blocks pdfium asks for are fetched, so the
      // whole file is never written to the persistent ebook cache - the same
      // on-demand model the audio player uses.
      final ino = widget.ebookFile['ino'] as String?;
      if (ino == null) {
        if (mounted) {
          setState(() { _error = 'No ebook file found'; _loading = false; });
        }
        return;
      }
      final uri = Uri.parse(api.buildEbookUrl(widget.itemId, ino));
      if (mounted) setState(() { _uri = uri; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _loading = false; });
    }
  }

  // Re-mount the viewer for a fresh attempt (a dead pdfrx banner can't recover
  // on its own): drop every piece of open state and re-run _open, which checks
  // the reader cache first and otherwise rebuilds the stream from scratch. The
  // bumping key forces pdfrx to treat the new viewer as a brand-new widget.
  void _retry() {
    setState(() {
      _attempt++;
      _file = null;
      _uri = null;
      _error = null;
      _loading = true;
    });
    _open();
  }

  void _onPageChanged(int? page) {
    if (page == null || !mounted) return;
    _page = page;
    _pageNotifier.value = page;
    _pendingPage = page;
    if (DateTime.now().difference(_lastSync).inSeconds >= 10) _flushProgress();
  }

  void _flushProgress() {
    final page = _pendingPage;
    final api = _api;
    if (page == null || api == null || _pageCount <= 0 || page == _lastSyncedPage) return;
    final frac = (page / _pageCount).clamp(0.0, 1.0);
    ProgressSyncService().pushEbookProgress(api, widget.itemId, location: '$page', progress: frac);
    _lib?.applyLocalEbookProgress(widget.itemId, location: '$page', progress: frac);
    unawaited(EbookProgressStore.instance.record(
        widget.itemId, ebookVersionKey(widget.ebookFile), '$page', frac));
    _lastSync = DateTime.now();
    _lastSyncedPage = page;
    _pendingPage = null;
  }

  void _toggleControls() => setState(() => _showControls = !_showControls);

  PdfViewerParams _viewerParams(ColorScheme cs) => PdfViewerParams(
        backgroundColor: cs.surface,
        // Pre-rasterize a taller band around the viewport (default is 1.0x) so
        // continuous scrolling doesn't outrun pdfium's on-demand rendering.
        verticalCacheExtent: 2.0,
        // The default 100MB decoded-image budget gets thrashed while scrolling a
        // large PDF; a bigger budget trades RAM for far fewer re-rasterizations.
        maxImageBytesCachedOnMemory: 256 * 1024 * 1024,
        // The per-page drop shadow is pure overdraw on a continuous list and
        // barely visible at full-screen page size.
        pageDropShadow: null,
        onViewerReady: (document, controller) async {
          _pageCount = controller.pageCount;
          _pageCountNotifier.value = controller.pageCount;
          try {
            final o = await document.loadOutline();
            if (mounted) setState(() => _outline = o);
          } catch (_) {}
        },
        onPageChanged: _onPageChanged,
        onGeneralTap: (ctx, controller, details) {
          if (details.type == PdfViewerGeneralTapType.tap) _toggleControls();
          return false;
        },
        // A streamed PDF that can't load (offline, server down) shows pdfrx's
        // default blue error strip; replace it with a friendly panel and a
        // retry so the failure reads as "no connection", not "broken app".
        errorBannerBuilder: (ctx, error, stackTrace, documentRef) {
          final l = AppLocalizations.of(ctx)!;
          final c = Theme.of(ctx).colorScheme;
          final t = Theme.of(ctx).textTheme;
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_rounded, size: 56,
                      color: c.onSurfaceVariant),
                  const SizedBox(height: 16),
                  Text(l.readerFailedToOpen,
                      textAlign: TextAlign.center,
                      style: t.titleMedium?.copyWith(color: c.onSurface)),
                  const SizedBox(height: 8),
                  Text(l.readerStreamHint,
                      textAlign: TextAlign.center,
                      style: t.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(l.retry),
                  ),
                ],
              ),
            ),
          );
        },
      );

  void _showOutline() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(AppLocalizations.of(ctx)!.readerChapters,
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600, color: cs.onSurface)),
            ),
            Flexible(child: ListView(shrinkWrap: true, children: _outlineTiles(_outline, ctx, 0))),
          ],
        ),
      ),
    );
  }

  List<Widget> _outlineTiles(List<PdfOutlineNode> nodes, BuildContext ctx, int depth) {
    final cs = Theme.of(ctx).colorScheme;
    final out = <Widget>[];
    for (final n in nodes) {
      final title = n.title.trim();
      if (title.isNotEmpty) {
        out.add(ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: 16.0 + depth * 16, right: 16),
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurface)),
          onTap: () {
            Navigator.pop(ctx);
            if (n.dest != null) _controller.goToDest(n.dest);
          },
        ));
      }
      if (n.children.isNotEmpty) out.addAll(_outlineTiles(n.children, ctx, depth + 1));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null || (_file == null && _uri == null)) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error ?? l.noEbookFileFound,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant)),
        ),
      );
    } else {
      body = Stack(
        children: [
          Positioned.fill(
            child: _file != null
                ? PdfViewer.file(
                    _file!.path,
                    key: ValueKey('file-$_attempt'),
                    controller: _controller,
                    initialPageNumber: _initialPage,
                    params: _viewerParams(cs),
                  )
                : PdfViewer.uri(
                    _uri!,
                    key: ValueKey('stream-$_attempt'),
                    controller: _controller,
                    initialPageNumber: _initialPage,
                    preferRangeAccess: true,
                    headers: _api?.mediaHeaders,
                    params: _viewerParams(cs),
                  ),
          ),

          // Top bar
          Positioned(
            top: 0, left: 0, right: 0,
            child: AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [cs.surface, cs.surface.withValues(alpha: 0)],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: Row(children: [
                        IconButton(
                          icon: Icon(Icons.arrow_back_rounded, color: cs.onSurface),
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: tt.titleSmall?.copyWith(color: cs.onSurface)),
                        ),
                        if (_outline.isNotEmpty)
                          IconButton(
                            icon: Icon(Icons.list_rounded, color: cs.onSurface),
                            onPressed: _showOutline,
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Bottom bar
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter, end: Alignment.topCenter,
                      colors: [cs.surface, cs.surface.withValues(alpha: 0)],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      child: AnimatedBuilder(
                        animation: _pageInfo,
                        builder: (context, _) {
                          final count = _pageCountNotifier.value;
                          final page = _pageNotifier.value;
                          final pct = count > 0 ? ((page / count) * 100).round() : 0;
                          return Row(children: [
                            Text('$page / ${count > 0 ? count : '-'}',
                                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                            const Spacer(),
                            Text('$pct%', style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                          ]);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Scaffold(backgroundColor: cs.surface, body: body);
  }
}
