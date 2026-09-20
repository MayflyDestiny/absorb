import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/download_service.dart';
import 'overlay_toast.dart';

/// One-time first-run prompt that guides new users to pick a public download
/// folder. Downloads default to app-private storage; clearing app data wipes
/// them, which surprises users. The prompt only shows on Android, when no
/// custom folder has been set and it hasn't been shown or skipped before.
/// Choosing "Pick folder" opens the Storage Access Framework picker; choosing
/// "Keep default" (or dismissing) marks the prompt as seen with no change.
class DownloadLocationPrompt {
  /// One-time first-run prompt that guides new users to pick a public download
  /// folder. Downloads default to app-private storage; clearing app data wipes
  /// them, which surprises users. The prompt only shows on Android, when no
  /// custom folder has been set and it hasn't been shown or skipped before.
  /// Choosing "Pick folder" opens the Storage Access Framework picker; choosing
  /// "Keep default" (or dismissing) marks the prompt as seen with no change.
  /// The future only completes once the dialog is dismissed (or immediately
  /// when it didn't need to show) - so callers can chain it after other
  /// on-boarding (e.g. the welcome dialog) without stacking dialogs.
  static Future<void> showIfNeeded(BuildContext context) async {
    if (!Platform.isAndroid) return;
    final dl = DownloadService();
    if (!await dl.shouldShowFirstRunLocationPrompt()) return;
    // Mark seen immediately so a dismissed/rejected picker never re-prompts.
    await dl.markFirstRunLocationPromptSeen();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => const _LocationPromptDialog(),
    );
  }
}

class _LocationPromptDialog extends StatefulWidget {
  const _LocationPromptDialog();

  @override
  State<_LocationPromptDialog> createState() => _LocationPromptDialogState();
}

class _LocationPromptDialogState extends State<_LocationPromptDialog> {
  bool _busy = false;

  Future<void> _pickFolder() async {
    if (_busy) return;
    final l = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      // Storage Access Framework: user grants a folder through the system
      // picker, no storage permission needed. Mirrors the Settings flow.
      Uri? treeUri;
      try {
        treeUri = await FileDownloader().uri.pickDirectory(
          startLocation: SharedStorage.downloads,
          persistedUriPermission: true,
        );
      } catch (_) {
        if (mounted) {
          showOverlayToast(context, l.cannotWriteToFolder,
              icon: Icons.error_outline_rounded);
        }
        return;
      }
      if (treeUri == null || !mounted) return; // user cancelled
      // Verify we can actually create files in the chosen folder.
      try {
        final probe = await FileDownloader()
            .uri
            .createDirectory(treeUri, '.absorb_write_test');
        await FileDownloader().uri.deleteFile(probe);
      } catch (_) {
        if (mounted) {
          showOverlayToast(context, l.cannotWriteToFolder,
              icon: Icons.error_outline_rounded);
        }
        return;
      }
      final dl = DownloadService();
      await dl.setCustomDownloadUri(treeUri);
      // Recognize any previously downloaded content already in this folder and
      // restore it into the downloads registry (offline, marker-based).
      final scan = await dl.scanAndRegisterExistingDownloads(treeUri.toString());
      if (!mounted) return;
      Navigator.of(context).pop();
      if (scan.recognized > 0 || scan.unknown > 0) {
        await _showExistingDownloadsResult(context, scan.recognized, scan.unknown);
      }
      if (!mounted) return;
      showOverlayToast(context, l.downloadLocationSetTo(
              await dl.downloadLocationLabel),
          icon: Icons.folder_outlined);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showExistingDownloadsResult(
      BuildContext context, int recognized, int unknown) async {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        icon: Icon(Icons.folder_shared_rounded,
            color: theme.colorScheme.primary, size: 28),
        title: Text(l.existingDownloadsFoundTitle,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.existingDownloadsRecognized(recognized),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (unknown > 0) ...[
              const SizedBox(height: 10),
              Text(l.existingDownloadsUnrecognized(unknown),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.ok),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;

    return AlertDialog(
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      title: Row(children: [
        Icon(Icons.download_for_offline_rounded, color: cs.primary, size: 26),
        const SizedBox(width: 10),
        Expanded(
          child: Text(l.downloadLocationPromptTitle,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
      ]),
      content: SingleChildScrollView(
        child: Text(l.downloadLocationPromptBody,
            style: tt.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.45,
            )),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).pop(),
          child: Text(l.keepDefaultDownloadLocation),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _pickFolder,
          icon: _busy
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.folder_open_rounded, size: 18),
          label: Text(l.chooseFolder),
        ),
      ],
    );
  }
}