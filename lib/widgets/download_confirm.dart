import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

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