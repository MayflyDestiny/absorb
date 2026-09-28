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
      errorWidget: widget.errorWidget,
    );
  }
}