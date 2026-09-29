import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Process-wide store for the pre-blurred cover bitmaps the listening cards
/// paint as their background.
///
/// Producing one costs three image round-trips - resolve the cover, draw it
/// through a blur filter, then read the top strip back for its brightness - so
/// a card that generated its own on first paint showed an unblurred, dimmed
/// cover for a beat before the blurred one snapped in. The bitmaps are tiny
/// (200px wide) and keyed by the same cache identity the covers use, so keeping
/// the handful a session actually visits means the card nearly always paints a
/// background that is already there. [warm] moves that work into the launch
/// preload, where nothing is competing for the raster thread.
///
/// The cache owns every [ui.Image] it holds. Callers take a [CoverBlurLease]
/// and release it when they drop the image; only unleased entries are eviction
/// candidates, so a bitmap a card is still painting can never be disposed from
/// under it.
class CoverBlurCache {
  CoverBlurCache._();

  static final CoverBlurCache instance = CoverBlurCache._();

  /// How many blurred covers to keep. The listening screen shows one card at a
  /// time, so a couple of spares cover a swipe in either direction.
  static const _capacity = 6;

  static const _targetWidth = 200;
  static const _sigma = 30.0;

  /// Insertion order doubles as LRU: a hit re-inserts, eviction takes the head.
  final _entries = <String, _BlurEntry>{};
  final _inFlight = <String, Future<ui.Image?>>{};

  /// An extra lease on [identity]'s bitmap, or null when nothing is cached.
  CoverBlurLease? lease(String identity) {
    final entry = _entries.remove(identity);
    if (entry == null) return null;
    _entries[identity] = entry;
    entry.leases++;
    return CoverBlurLease._(this, entry);
  }

  /// Top-strip brightness of [identity]'s blur, when it has been measured.
  double? luminanceOf(String identity) => _entries[identity]?.luminance;

  /// Records the brightness measured by a lease holder, so the next holder of
  /// the same cover gets it without another read-back.
  void rememberLuminance(String identity, double luminance) {
    _entries[identity]?.luminance = luminance;
  }

  /// A leased bitmap for [identity], generating it on first use. Concurrent
  /// callers for the same cover share one generation.
  Future<CoverBlurLease?> acquire(
    ImageProvider provider,
    String identity,
  ) async {
    final held = lease(identity);
    if (held != null) return held;
    final image = await _inflight(provider, identity);
    if (image == null) return null;
    // Concurrent callers resolve to the same bitmap; the first to land is the
    // one that owns it and the rest simply take a lease on that entry, so no
    // caller ever disposes an image the cache is holding.
    _storeIfAbsent(identity, image);
    return lease(identity);
  }

  /// Generates and stores [identity]'s bitmap without keeping a lease. Used by
  /// the launch preload; a later eviction is harmless, the point is that the
  /// card usually finds it already there.
  Future<void> warm(ImageProvider provider, String identity) async {
    if (_entries.containsKey(identity)) return;
    final image = await _inflight(provider, identity);
    if (image == null) return;
    _storeIfAbsent(identity, image);
  }

  /// Drops every cached bitmap. Leased entries are disposed once their holders
  /// release them, so nothing a card still paints is freed here.
  void clear() {
    for (final entry in _entries.values) {
      entry.dropped = true;
      if (entry.leases == 0) entry.image.dispose();
    }
    _entries.clear();
  }

  void _release(_BlurEntry entry) {
    entry.leases--;
    if (entry.leases > 0) return;
    _trim();
    if (entry.dropped) entry.image.dispose();
  }

  void _storeIfAbsent(String identity, ui.Image image) {
    if (_entries.containsKey(identity)) return;
    _entries[identity] = _BlurEntry(image);
    _trim();
  }

  void _trim() {
    while (_entries.length > _capacity) {
      String? victim;
      for (final entry in _entries.entries) {
        if (entry.value.leases == 0) {
          victim = entry.key;
          break;
        }
      }
      // Everything left is on screen; growing beats dropping a live bitmap.
      if (victim == null) return;
      final entry = _entries.remove(victim)!;
      entry.dropped = true;
      entry.image.dispose();
    }
  }

  Future<ui.Image?> _inflight(ImageProvider provider, String identity) {
    final pending = _inFlight[identity];
    if (pending != null) return pending;
    final future = _render(provider);
    _inFlight[identity] = future;
    future.whenComplete(() => _inFlight.remove(identity));
    return future;
  }

  Future<ui.Image?> _render(ImageProvider provider) async {
    try {
      final completer = Completer<ui.Image>();
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (e, _) {
          if (!completer.isCompleted) completer.completeError(e);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      final source = await completer.future;
      return await blurToBitmap(source);
    } catch (_) {
      return null;
    }
  }

  /// Draws [source] scaled down and blurred to a small bitmap. The blur hides
  /// detail, so a 200px-wide target is enough and keeps the cost small.
  static Future<ui.Image> blurToBitmap(ui.Image source) async {
    final width = _targetWidth;
    final height = (width * (source.height / source.width)).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    final paint = Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: _sigma,
        sigmaY: _sigma,
        tileMode: TileMode.decal,
      );
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      paint,
    );
    final picture = recorder.endRecording();
    final blurred = await picture.toImage(width, height);
    picture.dispose();
    return blurred;
  }
}

class _BlurEntry {
  _BlurEntry(this.image);

  final ui.Image image;
  double? luminance;
  int leases = 0;
  bool dropped = false;
}

/// A claim on a cached blurred bitmap.
///
/// The lease - not the [ui.Image] - is what callers hold. Releasing it lets the
/// cache evict and dispose the bitmap; double-releasing is a no-op.
class CoverBlurLease {
  CoverBlurLease._(this._cache, this._entry);

  final CoverBlurCache _cache;
  final _BlurEntry _entry;
  bool _released = false;

  ui.Image get image => _entry.image;

  void release() {
    if (_released) return;
    _released = true;
    _cache._release(_entry);
  }
}
