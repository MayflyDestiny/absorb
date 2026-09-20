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
  CachedNetworkImageProvider? _targetProvider;
  bool _isPreloading = false;

  @override
  void initState() {
    super.initState();
    _currentProvider = _makeProvider(widget.cacheKey);
  }

  @override
  void didUpdateWidget(StableCachedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      _preloadNewProvider();
    }
  }

  Future<void> _preloadNewProvider() async {
    if (_isPreloading) return;
    _isPreloading = true;

    _targetProvider = _makeProvider(widget.cacheKey);

    try {
      final completer = Completer<void>();
      final stream = _targetProvider!.resolve(const ImageConfiguration());

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
          _targetProvider = null;
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
    return CachedNetworkImage(
      imageUrl: widget.imageUrl,
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