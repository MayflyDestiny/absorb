import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Material 3 Expressive look (Android): shapes that squash, stretch and
/// morph. Off by default; driven by the setting of the same name.
///
/// Scope: the player card's corners, the card buttons (chapters, speed, timer,
/// bookmarks, and the other buttons sharing their row), the app's loading
/// spinners, the switches in Settings and the card's chapter bar. The play
/// button deliberately keeps the plain look.
final ValueNotifier<bool> expressiveNotifier = ValueNotifier(false);

/// A round shape with soft bumps around its edge, the family the Material
/// "cookie", "clover" and "sunny" shapes come from. [lobes] is how many bumps
/// and [depth] how deep the dips between them go (0 is a plain circle).
class WavyShape {
  final int lobes;
  final double depth;
  const WavyShape(this.lobes, this.depth);

  static const circle = WavyShape(1, 0);
  static const cookie9 = WavyShape(9, 0.07);
  static const clover = WavyShape(4, 0.14);
  static const cookie6 = WavyShape(6, 0.1);
  static const sunny = WavyShape(12, 0.05);
  static const softSquare = WavyShape(4, 0.045);

  /// The shapes the nav highlight cycles through, one per tab change.
  static const rolling = [cookie9, clover, cookie6, sunny];

  double radiusAt(double angle) =>
      1 - depth + depth * math.cos(lobes * angle);
}

const int _samples = 144;

/// The outline of [a] morphed toward [b] by [t], centred on the origin with
/// a radius of 1 at its widest.
Path wavyPath(WavyShape a, [WavyShape? b, double t = 0]) {
  final path = Path();
  for (var i = 0; i < _samples; i++) {
    final angle = i / _samples * math.pi * 2;
    var r = a.radiusAt(angle);
    if (b != null) r += (b.radiusAt(angle) - r) * t;
    final x = r * math.cos(angle);
    final y = r * math.sin(angle);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return path..close();
}

double _span(double t, double from, double to) =>
    ((t - from) / (to - from)).clamp(0.0, 1.0);

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// The Expressive loading indicator: one filled shape that keeps turning
/// while it morphs from one outline to the next.
class ExpressiveLoader extends StatefulWidget {
  final Color? color;
  const ExpressiveLoader({super.key, this.color});

  @override
  State<ExpressiveLoader> createState() => _ExpressiveLoaderState();
}

class _ExpressiveLoaderState extends State<ExpressiveLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _LoaderPainter(progress: _controller, color: color),
        ),
      ),
    );
  }
}

class _LoaderPainter extends CustomPainter {
  final Animation<double> progress;
  final Color color;

  _LoaderPainter({required this.progress, required this.color})
      : super(repaint: progress);

  static const _shapes = [
    WavyShape.cookie9,
    WavyShape.softSquare,
    WavyShape.clover,
    WavyShape.cookie6,
    WavyShape.sunny,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value * _shapes.length;
    final index = t.floor() % _shapes.length;
    // Hold each shape for a beat, then morph quickly into the next.
    final morph = Curves.easeInOutCubic.transform(_span(t - t.floor(), 0.35, 1));
    final path = wavyPath(
      _shapes[index],
      _shapes[(index + 1) % _shapes.length],
      morph,
    );
    final radius = size.shortestSide / 2;
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(progress.value * math.pi * 2);
    canvas.scale(radius, radius);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_LoaderPainter old) => old.color != color;
}

/// The app's spinner: the usual ring, or the shape loader when the Expressive
/// look is on. Takes the same two settings the ring is given around the app.
class AdaptiveSpinner extends StatelessWidget {
  final double? strokeWidth;
  final Color? color;
  const AdaptiveSpinner({super.key, this.strokeWidth, this.color});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: expressiveNotifier,
      builder: (context, expressive, _) =>
          expressive && !MediaQuery.disableAnimationsOf(context)
              ? ExpressiveLoader(color: color)
              : CircularProgressIndicator(
                  strokeWidth: strokeWidth,
                  color: color,
                ),
    );
  }
}

/// A jelly squash-and-stretch when something becomes selected, so the change
/// reads without a color flash. Used by the settings switches.
class ExpressivePop extends StatefulWidget {
  final bool active;
  final Widget child;
  const ExpressivePop({super.key, required this.active, required this.child});

  @override
  State<ExpressivePop> createState() => _ExpressivePopState();
}

class _ExpressivePopState extends State<ExpressivePop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
    value: 1,
  );

  static final _wide = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.24)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 22,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.24, end: 0.93)
          .chain(CurveTween(curve: Curves.easeInOut)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.93, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 48,
    ),
  ]);
  static final _tall = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.8)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 22,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.8, end: 1.12)
          .chain(CurveTween(curve: Curves.easeInOut)),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.12, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 48,
    ),
  ]);

  @override
  void didUpdateWidget(ExpressivePop old) {
    super.didUpdateWidget(old);
    if (widget.active &&
        !old.active &&
        expressiveNotifier.value &&
        !MediaQuery.disableAnimationsOf(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(
            _wide.transform(_controller.value),
            _tall.transform(_controller.value),
            1,
          ),
          child: child,
        ),
        child: widget.child,
      );
}

/// Where a button sits in a connected row, so it can round its outer corners
/// and keep the ones facing its neighbours tight.
class ExpressiveGroupSlot extends InheritedWidget {
  final bool first;
  final bool last;
  final double outer;

  const ExpressiveGroupSlot({
    super.key,
    required this.first,
    required this.last,
    this.outer = 24,
    required super.child,
  });

  static ExpressiveGroupSlot? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ExpressiveGroupSlot>();

  @override
  bool updateShouldNotify(ExpressiveGroupSlot old) =>
      old.first != first || old.last != last || old.outer != outer;
}

/// A card button's corners. Outside a connected row this is the plain
/// [radius] all round. [round] is for a button
/// that is switched on, which goes fully round to stand out from the row.
BorderRadius cardButtonCorners(
  BuildContext context,
  double radius, {
  bool round = false,
}) {
  final slot = ExpressiveGroupSlot.maybeOf(context);
  if (slot == null) return BorderRadius.circular(radius);
  final outer = Radius.circular(slot.outer);
  const inner = Radius.circular(7);
  if (round) return BorderRadius.all(outer);
  return BorderRadiusDirectional.horizontal(
    start: slot.first ? outer : inner,
    end: slot.last ? outer : inner,
  ).resolve(Directionality.of(context));
}

/// A row of buttons that act as one group: a thin gap between them and,
/// with [widen], the one under the finger widens while its neighbours give
/// way.
class ExpressiveButtonRow extends StatefulWidget {
  final List<Widget> children;
  final bool widen;
  final double gap;
  final double outer;
  const ExpressiveButtonRow({
    super.key,
    required this.children,
    this.widen = true,
    this.gap = 3,
    this.outer = 24,
  });

  @override
  State<ExpressiveButtonRow> createState() => _ExpressiveButtonRowState();
}

class _ExpressiveButtonRowState extends State<ExpressiveButtonRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: 1,
  );
  List<double> _from = const [];
  List<double> _to = const [];
  int? _pressed;

  List<double> _targets(int? pressed) {
    final n = widget.children.length;
    if (pressed == null || n < 2 || !widget.widen) return List.filled(n, 1.0);
    const grow = 0.2;
    return [for (var i = 0; i < n; i++) i == pressed ? 1 + grow : 1 - grow / (n - 1)];
  }

  List<double> _current() {
    final n = widget.children.length;
    if (_from.length != n || _to.length != n) return _targets(_pressed);
    final t = Curves.easeOutBack.transform(_controller.value);
    return [for (var i = 0; i < n; i++) _lerp(_from[i], _to[i], t)];
  }

  void _setPressed(int? index) {
    if (index == _pressed) return;
    _from = _current();
    _pressed = index;
    _to = _targets(index);
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.children.length;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final weights = _current();
        return Row(
          children: [
            for (var i = 0; i < n; i++) ...[
              if (i > 0) SizedBox(width: widget.gap),
              Expanded(
                flex: (weights[i] * 1000).round().clamp(1, 100000),
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) => _setPressed(i),
                  onPointerUp: (_) => _setPressed(null),
                  onPointerCancel: (_) => _setPressed(null),
                  child: ExpressiveGroupSlot(
                    first: i == 0,
                    last: i == n - 1,
                    outer: widget.outer,
                    child: widget.children[i],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
