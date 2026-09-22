import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/player_settings.dart';

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
    this.isFinished = false,
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

/// Compact download-status chip for covers. When [surfaceTone] is true
/// (default false), the chip uses theme surface colors instead of the
/// dark/white overlay palette, so it can sit *outside* the cover artwork (e.g.
/// centered below a grid cover).
///
/// The "finished" check is no longer part of this chip — it lives in the
/// top-right corner via [CoverFinishedBadge].
class CoverStatusChips extends StatelessWidget {
  final bool isDownloaded;

  /// Downloaded chapters and the book's full chapter count. When [savedChapters]
  /// is 0 or below [totalChapters] is 0/unknown, the plain label is shown.
  final int savedChapters;
  final int totalChapters;

  /// Use muted surface-based tones instead of the dark/white overlay palette.
  final bool surfaceTone;

  const CoverStatusChips({
    super.key,
    required this.isDownloaded,
    this.savedChapters = 0,
    this.totalChapters = 0,
    this.surfaceTone = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!isDownloaded) return const SizedBox.shrink();
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final partial = totalChapters > 0 && savedChapters < totalChapters;
    final savedLabel = partial
        ? l.coverSavedCount(savedChapters, totalChapters)
        : l.saved;
    return _chip(
      icon: Icons.download_rounded,
      label: savedLabel,
      background:
          surfaceTone ? cs.surfaceContainerHighest : Colors.black.withValues(alpha: 0.62),
      foreground: surfaceTone ? cs.onSurfaceVariant : Colors.white,
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

/// Green "Finished" badge for the top-right corner of a cover. The display
/// style is controlled by the global `finishedBadgeMode` setting: with the
/// "Finished" label (default), icon-only, or hidden entirely. Rebuilds when
/// the setting changes.
class CoverFinishedBadge extends StatelessWidget {
  const CoverFinishedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PlayerSettings.settingsChanged,
      builder: (context, _) {
        final l = AppLocalizations.of(context)!;
        final background = Colors.green.shade700.withValues(alpha: 0.92);
        final mode = PlayerSettings.finishedBadgeMode;
        if (mode == 'off') return const SizedBox.shrink();
        if (mode == 'icon') {
          return Container(
            padding: const EdgeInsets.all(3),
            decoration:
                BoxDecoration(color: background, shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_rounded,
                size: 12, color: Colors.white),
          );
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_rounded,
                  size: 11, color: Colors.white),
              const SizedBox(width: 3),
              Text(
                l.finished,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
