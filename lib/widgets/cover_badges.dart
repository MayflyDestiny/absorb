import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// State banner across the bottom of cover art: a finished check + "Finished"
/// (green) and a downloaded arrow + "Downloaded" (white), stacked, over a strong
/// dark scrim so they stay legible on any artwork. Place across the bottom of a
/// cover Stack:
///   Positioned(left: 0, right: 0, bottom: 0, child: CoverStateBadges(...))
class CoverStateBadges extends StatelessWidget {
  final bool isDownloaded;
  final bool isFinished;
  final double iconSize;

  /// Shows just the icons (no text labels), for covers too small to fit the
  /// full banner like the search result tiles.
  final bool iconOnly;

  /// Rounds the banner's bottom corners to match covers that aren't clipped by
  /// a parent ClipRRect (e.g. some cards).
  final BorderRadius? borderRadius;

  const CoverStateBadges({
    super.key,
    required this.isDownloaded,
    required this.isFinished,
    this.iconSize = 13,
    this.iconOnly = false,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    if (!isDownloaded && !isFinished) return const SizedBox.shrink();
    final l = AppLocalizations.of(context)!;
    final green = Colors.greenAccent.shade400;
    if (iconOnly) return _iconOnly(green);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.92),
            Colors.black.withValues(alpha: 0.55),
            Colors.black.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.6, 1.0],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isFinished) _row(Icons.check_circle_rounded, l.finished, green),
          if (isFinished && isDownloaded) const SizedBox(height: 2),
          if (isDownloaded) _row(Icons.download_rounded, l.saved, Colors.white),
        ],
      ),
    );
  }

  Widget _iconOnly(Color green) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.9),
            Colors.black.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isFinished) Icon(Icons.check_circle_rounded, size: iconSize, color: green),
          if (isFinished && isDownloaded) const SizedBox(width: 3),
          if (isDownloaded) Icon(Icons.download_rounded, size: iconSize, color: Colors.white),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String label, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: color),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }
}

/// Compact status chips for covers. When [surfaceTone] is true (default
/// false), the chips use theme surface colors instead of the dark/white
/// overlay palette, so they can sit *outside* the cover artwork (e.g. centered
/// below a grid cover).
class CoverStatusChips extends StatelessWidget {
  final bool isDownloaded;
  final bool isFinished;

  /// Downloaded chapters and the book's full chapter count. When [savedChapters]
  /// is 0 or below [totalChapters] is 0/unknown, the plain label is shown.
  final int savedChapters;
  final int totalChapters;

  /// Use muted surface-based tones instead of the dark/white overlay palette.
  final bool surfaceTone;

  const CoverStatusChips({
    super.key,
    required this.isDownloaded,
    required this.isFinished,
    this.savedChapters = 0,
    this.totalChapters = 0,
    this.surfaceTone = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!isDownloaded && !isFinished) return const SizedBox.shrink();
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final partial =
        isDownloaded && totalChapters > 0 && savedChapters < totalChapters;
    final savedLabel = partial
        ? l.coverSavedCount(savedChapters, totalChapters)
        : l.saved;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (isFinished)
          _chip(
            icon: Icons.check_circle_rounded,
            label: l.finished,
            background: surfaceTone
                ? Colors.green.withValues(alpha: dark ? 0.18 : 0.12)
                : Colors.green.shade700.withValues(alpha: 0.92),
            foreground: surfaceTone
                ? (dark ? Colors.greenAccent.shade100 : Colors.green.shade800)
                : Colors.white,
          ),
        if (isFinished && isDownloaded) const SizedBox(height: 3),
        if (isDownloaded)
          _chip(
            icon: Icons.download_rounded,
            label: savedLabel,
            background:
                surfaceTone ? cs.surfaceContainerHighest : Colors.black.withValues(alpha: 0.62),
            foreground: surfaceTone ? cs.onSurfaceVariant : Colors.white,
          ),
      ],
    );
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: foreground),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
