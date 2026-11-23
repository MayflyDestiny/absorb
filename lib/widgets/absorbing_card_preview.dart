import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart' show flatNotifier;
import '../providers/library_provider.dart';
import '../services/audio_player_service.dart';
import '../services/chromecast_service.dart';
import '../services/player_settings.dart';
import '../utils/absorbing_list.dart';
import 'absorbing_card.dart';
import 'cover_glow.dart';

/// The real card of the book playing (or the first one on the Absorbing
/// page), shrunk to sit at the top of its settings. It is the card itself,
/// so every setting under it shows as it will really look; it just can't be
/// touched. Two cards move together, and changing the swipe or dismiss style
/// plays that motion once.
class AbsorbingCardPreview extends StatefulWidget {
  static const double height = 300;

  const AbsorbingCardPreview({super.key});

  @override
  State<AbsorbingCardPreview> createState() => _AbsorbingCardPreviewState();
}

class _AbsorbingCardPreviewState extends State<AbsorbingCardPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _demo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  String _swipeStyle = 'classic';
  String _dismissStyle = 'classic';
  String _mode = 'swipe';
  bool _stylesLoaded = false;
  final GlobalKey _frontCardKey = GlobalKey(debugLabel: 'preview-front');
  final GlobalKey _backCardKey = GlobalKey(debugLabel: 'preview-back');

  @override
  void initState() {
    super.initState();
    PlayerSettings.settingsChanged.addListener(_onSettingsChanged);
    _loadStyles();
  }

  @override
  void dispose() {
    PlayerSettings.settingsChanged.removeListener(_onSettingsChanged);
    _demo.dispose();
    super.dispose();
  }

  void _onSettingsChanged() => _loadStyles();

  Future<void> _loadStyles() async {
    final swipe = await PlayerSettings.getCardSwipeStyle();
    final dismiss = await PlayerSettings.getCardDismissStyle();
    if (!mounted) return;
    final swipeChanged = swipe != _swipeStyle;
    final dismissChanged = dismiss != _dismissStyle;
    if (!swipeChanged && !dismissChanged) {
      _stylesLoaded = true;
      return;
    }
    setState(() {
      _swipeStyle = swipe;
      _dismissStyle = dismiss;
    });
    if (!_stylesLoaded) {
      _stylesLoaded = true;
      return;
    }
    if (swipeChanged) {
      _play('swipe');
    } else if (dismissChanged) {
      _play('dismiss');
    }
  }

  void _play(String mode) {
    _mode = mode;
    _demo.stop();
    _demo.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      Future<void>.delayed(const Duration(milliseconds: 360), () {
        if (mounted && !_demo.isAnimating && _demo.value >= 1) {
          _demo.reverse();
        }
      });
    });
  }

  Widget _classicSlot(Widget card, double rawDist, double width) {
    final dist = rawDist.abs();
    final scaleX = dist >= 1.0
        ? 0.85
        : 0.85 + 0.15 * Curves.easeOut.transform(1.0 - dist);
    final freed = width - width * scaleX;
    final direction = rawDist > 0 ? 1.0 : (rawDist < 0 ? -1.0 : 0.0);
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..translate(direction * freed * 0.45, 0.0, 0.0)
        ..scale(scaleX, 1.0, 1.0),
      child: card,
    );
  }

  Widget _stackSlot(Widget card, double rawDist, double width) {
    final under = rawDist.clamp(0.0, 2.0);
    final sink = Curves.easeOut.transform(under.clamp(0.0, 1.0));
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..translate(under * width - sink * 10, sink * 6, 0.0)
        ..scale(1 - 0.07 * sink, 1 - 0.07 * sink, 1.0),
      child: Opacity(opacity: 1 - 0.35 * sink, child: card),
    );
  }

  Widget _slot(Widget card, int index, double page, double width, double height) {
    final rawDist = page - index;
    final styled = _swipeStyle == 'stack'
        ? _stackSlot(card, rawDist, width)
        : _classicSlot(card, rawDist, width);
    return Positioned(
      left: index * width,
      top: 0,
      width: width,
      height: height,
      child: styled,
    );
  }

  /// Carousel: the current card pinches into a sliver on the left while the
  /// next card is revealed behind it, instead of both cards sliding across.
  Widget _carouselSwipeStage(
    Widget front,
    Widget back,
    double width,
    double height,
    double t,
  ) {
    final ease = Curves.easeInOutCubic.transform(t);
    final shown = width * (1 - 0.78 * ease);
    return Stack(
      fit: StackFit.expand,
      children: [
        back,
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: shown,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: width,
                maxWidth: width,
                minHeight: height,
                maxHeight: height,
                child: front,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _swipeStage(
    Widget front,
    Widget back,
    double width,
    double height,
    double t,
  ) {
    final page = Curves.easeInOutCubic.transform(t);
    return SizedBox(
      width: width,
      height: height,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: width * 2,
          maxWidth: width * 2,
          minHeight: height,
          maxHeight: height,
          child: Transform.translate(
            offset: Offset(-page * width, 0),
            child: Builder(builder: (_) {
              final backOnTop = _swipeStyle == 'stack' && page > 0.5;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  if (!backOnTop) _slot(back, 1, page, width, height),
                  _slot(front, 0, page, width, height),
                  if (backOnTop) _slot(back, 1, page, width, height),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _carouselDismiss(
    Widget card,
    double width,
    double height,
    double ease,
  ) {
    final full = width;
    final sliver = full * 0.22;
    final shown = sliver + (full - sliver) * (1 - 0.85 * ease);
    return Transform.translate(
      offset: Offset(-width * 0.22 * ease, 0),
      child: Opacity(
        opacity: (1 - 0.85 * ease).clamp(0.0, 1.0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: shown,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: full,
                maxWidth: full,
                minHeight: height,
                maxHeight: height,
                child: card,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _frontDismiss(Widget card, double width, double height, double t) {
    final ease = Curves.easeInOutCubic.transform(t);
    switch (_dismissStyle) {
      case 'carousel':
        return _carouselDismiss(card, width, height, ease);
      case 'stack':
        return Transform.translate(
          offset: Offset(0, height * 0.32 * ease),
          child: Opacity(
            opacity: (1 - 0.55 * ease).clamp(0.0, 1.0),
            child: Transform.scale(scale: 1 - 0.14 * ease, child: card),
          ),
        );
      default:
        return Transform.translate(
          offset: Offset(-width * 0.6 * ease, height * 0.35 * ease),
          child: Opacity(
            opacity: (1 - 0.4 * ease).clamp(0.0, 1.0),
            child: Transform.rotate(angle: -0.07 * ease, child: card),
          ),
        );
    }
  }

  Widget _backDismiss(Widget card, double t) {
    final ease = Curves.easeInOutCubic.transform(t);
    final start = switch (_dismissStyle) {
      'stack' => 0.90,
      'carousel' => 1.0,
      _ => 0.96,
    };
    return Transform.scale(scale: start + (1 - start) * ease, child: card);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lib = context.watch<LibraryProvider>();
    final player = AudioPlayerService();
    final books = buildAbsorbingList(
      lib,
      player: player,
      cast: ChromecastService(),
      mergeLibraries: true,
    );
    final screen = MediaQuery.sizeOf(context);
    final cardWidth = math.min(screen.width, 440.0) - 40;
    final cardHeight =
        math.min(cardWidth * 1.8, math.max(screen.height * 0.74, 420.0));
    final frontItem = books.isEmpty ? null : books.first;
    final backItem =
        books.isEmpty ? null : (books.length > 1 ? books[1] : books.first);
    final front = frontItem == null
        ? null
        : AbsorbingCard(
            key: _frontCardKey,
            item: frontItem,
            player: player,
            preview: true,
          );
    final back = backItem == null
        ? null
        : AbsorbingCard(
            key: _backCardKey,
            item: backItem,
            player: player,
            preview: true,
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: flatNotifier,
              builder: (_, flat, __) => flat
                  ? const SizedBox.shrink()
                  : const CoverGlow(height: AbsorbingCardPreview.height - 18),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: front == null
                  ? Center(
                      child: Icon(Icons.headphones_rounded,
                          size: 40, color: cs.onSurfaceVariant))
                  : FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: cardWidth,
                        height: cardHeight,
                        child: IgnorePointer(
                          child: ExcludeSemantics(
                            child: AnimatedBuilder(
                              animation: _demo,
                              builder: (context, _) {
                                if (_mode == 'swipe' &&
                                    _swipeStyle == 'carousel' &&
                                    back != null) {
                                  return _carouselSwipeStage(front, back,
                                      cardWidth, cardHeight, _demo.value);
                                }
                                if (_mode == 'swipe' && back != null) {
                                  return _swipeStage(front, back, cardWidth,
                                      cardHeight, _demo.value);
                                }
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (back != null)
                                      _backDismiss(back, _demo.value),
                                    _frontDismiss(front, cardWidth, cardHeight,
                                        _demo.value),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}