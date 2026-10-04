import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

String stableCoverCacheKey(String imageUrl, {int? updatedAt}) {
  final uri = Uri.tryParse(imageUrl);
  if (uri == null ||
      !uri.path.contains('/api/items/') ||
      !uri.path.endsWith('/cover')) {
    return imageUrl;
  }

  final query = Map<String, String>.from(uri.queryParameters);
  final revision = updatedAt?.toString() ?? query['ts'];
  query.remove('token');
  query.remove('ts');
  if (revision != null) query['ts'] = revision;

  return uri.replace(queryParameters: query.isEmpty ? null : query).toString();
}

class StableCachedNetworkImage extends StatefulWidget {
  const StableCachedNetworkImage({
    super.key,
    required this.imageUrl,
    required this.cacheKey,
    this.fit,
    this.httpHeaders,
    this.imageBuilder,
    this.placeholder,
    this.errorWidget,
  });

  final String imageUrl;
  final String cacheKey;
  final BoxFit? fit;
  final Map<String, String>? httpHeaders;
  final Widget Function(BuildContext, ImageProvider)? imageBuilder;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;

  @override
  State<StableCachedNetworkImage> createState() => _StableCachedNetworkImageState();
}

class _StableCachedNetworkImageState extends State<StableCachedNetworkImage> {
  late CachedNetworkImageProvider _currentProvider;
  late String _currentUrl;
  CachedNetworkImageProvider? _targetProvider;
  String? _targetUrl;
  bool _isPreloading = false;

  /// Bounded retries for a cover that failed to load, spaced out far enough to
  /// cover a Wi-Fi re-association after the screen wakes. An unlock makes the
  /// app dump every decoded image and re-request whatever is not on disk yet -
  /// which is exactly the set of books added most recently, since an older book
  /// already has a disk entry for the width being rendered. Requests fired
  /// before the network came back timed out, and see [_onError] for why that
  /// used to be permanent.
  static const _retryDelays = <Duration>[
    Duration(milliseconds: 600),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];
  int _errorAttempts = 0;

  @override
  void initState() {
    super.initState();
    _currentProvider = _makeProvider(widget.cacheKey);
    _currentUrl = widget.imageUrl;
  }

  @override
  void didUpdateWidget(StableCachedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey ||
        oldWidget.imageUrl != widget.imageUrl) {
      // A different cover gets its own retry budget.
      _errorAttempts = 0;
      _preloadNewProvider();
    }
  }

  Future<void> _preloadNewProvider() async {
    if (_isPreloading) return;
    _isPreloading = true;

    final provider = _makeProvider(widget.cacheKey);
    final url = widget.imageUrl;
    _targetProvider = provider;
    _targetUrl = url;

    try {
      final completer = Completer<void>();
      final stream = provider.resolve(const ImageConfiguration());

      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (_, __) {
          stream.removeListener(listener);
          if (!completer.isCompleted) completer.complete();
        },
        onError: (_, __) {
          stream.removeListener(listener);
          if (!completer.isCompleted) completer.completeError('preload failed');
        },
      );
      stream.addListener(listener);

      await completer.future;

      if (mounted && _targetProvider != null) {
        setState(() {
          _currentProvider = _targetProvider!;
          _currentUrl = _targetUrl!;
          _targetProvider = null;
          _targetUrl = null;
        });
      }
    } catch (_) {
      // Preload failed — keep showing the old image
    } finally {
      _isPreloading = false;
    }
  }

  CachedNetworkImageProvider _makeProvider(String cacheKey) {
    return CachedNetworkImageProvider(
      widget.imageUrl,
      headers: widget.httpHeaders,
      cacheKey: cacheKey,
    );
  }

  /// A failed resolve is remembered by [ImageCache] against that key, so every
  /// later build replays the same failure without touching the network - which
  /// is what made a cover that lost one race on wake-up look permanently
  /// missing, recoverable only by a manual refresh. Drop the poisoned entry so
  /// the rebuild genuinely retries, then fall back to the caller's error widget
  /// until it does.
  ///
  /// Past the retry budget the entry is left alone on purpose: a book that truly
  /// has no cover must not re-request on every parent rebuild, and the failed
  /// entry is cheaper to replay than to re-fetch. A changed cache key or URL
  /// resets the budget.
  Widget _onError(BuildContext context, String url, Object error) {
    if (_errorAttempts < _retryDelays.length) {
      PaintingBinding.instance.imageCache.evict(_currentProvider);
      final delay = _retryDelays[_errorAttempts];
      _errorAttempts++;
      Timer(delay, () {
        if (mounted) setState(() {});
      });
    }
    return widget.errorWidget?.call(context, url, error) ??
        const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    // The provider and the URL must come from the SAME snapshot. Pairing the
    // new imageUrl with the not-yet-swapped _currentProvider.cacheKey stored
    // the new bytes under the old key - so the previous cover's entry got
    // overwritten, and a failed fetch left the old entry holding nothing.
    return CachedNetworkImage(
      imageUrl: _currentUrl,
      httpHeaders: widget.httpHeaders,
      cacheKey: _currentProvider.cacheKey,
      useOldImageOnUrlChange: true,
      fit: widget.fit,
      imageBuilder: widget.imageBuilder,
      placeholder: widget.placeholder,
      errorWidget: _onError,
    );
  }
}