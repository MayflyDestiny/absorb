import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../build_info.dart';
import '../l10n/app_localizations.dart';
import '../services/player_settings.dart';
import '../services/update_checker_service.dart';
import 'welcome_sheet.dart';

/// After an update, shows the release notes pulled from this build's GitHub
/// release, with a link to the full notes. If the notes can't be fetched
/// (offline, release/tag missing) it falls back to a generic version line and
/// the same "see full notes" link, so the prompt never looks broken.
class WhatsNewPrompt {
  static const _lastBuildKey = 'whats_new_last_build';
  static const _isDevBuild = bool.fromEnvironment('DEV_BUILD');

  static Future<void> showIfUpdated(BuildContext context) async {
    if (kIsWeb || _isDevBuild) return;
    final prefs = await SharedPreferences.getInstance();
    final freshInstall = prefs.getBool(WelcomeSheet.prefKey) != true;
    final info = await PackageInfo.fromPlatform();
    final build = int.tryParse(info.buildNumber);
    if (build == null) return;

    // Always advance the stored build, even when the prompt is disabled, so
    // re-enabling it later doesn't re-prompt for the versions missed meanwhile.
    final lastBuild = prefs.getInt(_lastBuildKey);
    await prefs.setInt(_lastBuildKey, build);
    if (!await PlayerSettings.getShowWhatsNew()) return;
    if (freshInstall || (lastBuild != null && build <= lastBuild)) return;

    final beta = betaNumberFor(info.version);
    final tag = beta == null ? 'v${info.version}' : 'v${info.version}-$build';

    // Let launch settle so this doesn't land on top of the first frames.
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!context.mounted) return;
    final l = AppLocalizations.of(context)!;
    final version =
        beta == null ? info.version : '${info.version} (${l.betaLabel(beta)})';

    await showDialog<void>(
      context: context,
      builder: (_) => _WhatsNewDialog(version: version, tag: tag),
    );
  }
}

class _WhatsNewDialog extends StatefulWidget {
  final String version;
  final String tag;

  const _WhatsNewDialog({required this.version, required this.tag});

  @override
  State<_WhatsNewDialog> createState() => _WhatsNewDialogState();
}

class _WhatsNewDialogState extends State<_WhatsNewDialog> {
  /// Fetched release notes, or null while loading / when the fetch failed.
  String? _notes;

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    final notes = await UpdateCheckerService.fetchReleaseNotes(widget.tag);
    if (!mounted) return;
    setState(() => _notes = notes);
  }

  void _openFullLog() {
    launchUrl(
      Uri.parse(UpdateCheckerService.releasePageUrl(widget.tag)),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final notes = _notes;
    return AlertDialog(
      scrollable: true,
      title: Text(l.whatsNewTitle),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l.whatsNewContent(widget.version),
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (notes != null) ...[
            const SizedBox(height: 12),
            MarkdownBody(
              data: notes,
              shrinkWrap: true,
              selectable: true,
              onTapLink: (_, href, __) {
                if (href != null) {
                  launchUrl(Uri.parse(href),
                      mode: LaunchMode.externalApplication);
                }
              },
              styleSheet: _styleSheet(context),
            ),
          ],
        ],
      ),
      actions: [
        // Full (formatted) notes open in the browser; the primary action is
        // just dismissing, so it carries the filled style.
        TextButton(
          onPressed: _openFullLog,
          child: Text(l.whatsNewSeeFull),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.done),
        ),
      ],
    );
  }

  MarkdownStyleSheet _styleSheet(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return MarkdownStyleSheet(
      p: tt.bodyMedium?.copyWith(height: 1.5),
      strong: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
      listBullet: tt.bodyMedium?.copyWith(height: 1.5),
      a: tt.bodyMedium?.copyWith(color: cs.primary),
      h1: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      h2: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      h3: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}
