import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/download_service.dart';

/// Shows a confirm dialog before starting a user-triggered download.
/// Returns true when the user confirms.
Future<bool> confirmDownload(BuildContext context, String title) async {
  final l = AppLocalizations.of(context)!;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.downloadConfirmTitle),
      content: Text(l.downloadConfirmContent(title)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(l.download),
        ),
      ],
    ),
  );
  return go == true;
}

/// What the user chose to do with a download that is already running.
enum _DownloadRunningAction { pause, cancel }

/// Asks whether to pause or cancel a running download. Returns null when the
/// dialog is dismissed, which leaves the transfer running.
///
/// A progress button must not throw the transfer away on a single tap - pause
/// and cancel are very different outcomes - so both are offered explicitly and
/// dismissing is the "keep going" answer. Deliberately only two actions:
/// [AppLocalizations.cancel] and [AppLocalizations.downloadsCancel] are the
/// same word in several locales, so a third dismiss button would be ambiguous.
Future<_DownloadRunningAction?> _showDownloadRunningDialog(
  BuildContext context, {
  required String title,
  required String itemId,
  Color? accent,
}) {
  return showDialog<_DownloadRunningAction>(
    context: context,
    builder: (_) =>
        _DownloadRunningDialog(title: title, itemId: itemId, accent: accent),
  );
}

/// Offers pause/cancel for a running download and carries the choice out.
/// Dismissing leaves the transfer alone.
///
/// Every "tap the progress button" entry point (wide card button, inline card
/// button, More menu) wants the same thing, so the sheet plus the apply step
/// live here instead of being spelled out three times.
Future<void> handleRunningDownloadTap(
  BuildContext context,
  DownloadService dl,
  String itemId, {
  required String title,
  Color? accent,
}) async {
  final action = await _showDownloadRunningDialog(
    context,
    title: title,
    itemId: itemId,
    accent: accent,
  );
  if (action == null || !context.mounted) return;
  if (action == _DownloadRunningAction.pause) {
    await dl.pauseDownload(itemId);
  } else {
    dl.cancelDownload(itemId);
  }
}

/// Live view of a running download. The card's own button already fills a bar
/// as bytes land, so the dialog shows the same bar instead of a frozen number -
/// a static percentage in a dialog the user is about to act on reads as stale
/// the moment it appears. Also closes itself when the transfer stops on its own
/// (finished, or paused/cancelled elsewhere), because pause/cancel are no longer
/// meaningful choices at that point.
class _DownloadRunningDialog extends StatefulWidget {
  final String title;
  final String itemId;
  final Color? accent;
  const _DownloadRunningDialog({
    required this.title,
    required this.itemId,
    this.accent,
  });
  @override
  State<_DownloadRunningDialog> createState() => _DownloadRunningDialogState();
}

class _DownloadRunningDialogState extends State<_DownloadRunningDialog> {
  final _dl = DownloadService();

  /// Set when the user picks an action, so the listener doesn't pop the route a
  /// second time behind the button's own pop.
  bool _chosen = false;

  /// Last progress this dialog painted. DownloadService ticks for the whole
  /// queue, so without this every other book downloading would rebuild this
  /// dialog several times a second to redraw the same number.
  double _painted = -1;

  @override
  void initState() {
    super.initState();
    _dl.addListener(_tick);
  }

  @override
  void dispose() {
    _dl.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    if (!mounted || _chosen) return;
    if (_dl.isDownloading(widget.itemId)) {
      final progress = _dl.downloadProgress(widget.itemId);
      if (progress == _painted) return;
      _painted = progress;
      setState(() {});
      return;
    }
    _chosen = true;
    Navigator.pop(context);
  }

  void _choose(_DownloadRunningAction action) {
    _chosen = true;
    Navigator.pop(context, action);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final progress = _dl.downloadProgress(widget.itemId).clamp(0.0, 1.0);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              color: widget.accent,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),
          Text('${l.downloadsDownloading} · ${(progress * 100).toStringAsFixed(0)}%'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _choose(_DownloadRunningAction.pause),
          child: Text(l.downloadsPause),
        ),
        TextButton(
          onPressed: () => _choose(_DownloadRunningAction.cancel),
          child: Text(
            l.downloadsCancel,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    );
  }
}
