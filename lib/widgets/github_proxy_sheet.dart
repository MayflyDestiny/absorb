import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/player_settings.dart';
import 'overlay_toast.dart';
import 'stackable_sheet.dart';

Future<void> showGithubProxySheet(BuildContext context) {
  return showStackableSheet<void>(
    context: context,
    initialChildSize: 0.55,
    maxChildSize: 0.9,
    showHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    useSafeArea: true,
    builder: (ctx, scrollController) => const _GithubProxySheet(),
  );
}

class _GithubProxySheet extends StatefulWidget {
  const _GithubProxySheet();

  @override
  State<_GithubProxySheet> createState() => _GithubProxySheetState();
}

class _GithubProxySheetState extends State<_GithubProxySheet> {
  final _urlController = TextEditingController();
  bool _loading = true;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await PlayerSettings.getGithubProxyEnabled();
    final url = await PlayerSettings.getGithubProxyUrl();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _urlController.text = PlayerSettings.defaultGithubProxyUrl;
      if (url.isNotEmpty) _urlController.text = url;
      _loading = false;
    });
  }

  Future<void> _saveEnabled(bool value) async {
    setState(() => _enabled = value);
    await PlayerSettings.setGithubProxyEnabled(value);
  }

  Future<void> _saveUrl(String value) async {
    await PlayerSettings.setGithubProxyUrl(value.trim());
  }

  Future<void> _reset() async {
    final l = AppLocalizations.of(context)!;
    setState(() => _urlController.text = PlayerSettings.defaultGithubProxyUrl);
    await PlayerSettings.setGithubProxyUrl(PlayerSettings.defaultGithubProxyUrl);
    showOverlayToast(context, l.githubProxyResetDone,
        icon: Icons.check_circle_outline_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;

    if (_loading) {
      return const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.rocket_launch_rounded, color: cs.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l.githubProxyTitle,
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Text(
              l.githubProxySubtitle,
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: _saveEnabled,
              title: Text(l.githubProxyEnabledLabel),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _urlController,
              enabled: _enabled,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l.githubProxyUrlLabel,
                hintText: l.githubProxyUrlHint,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: _saveUrl,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: Text(l.githubProxyReset),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    _saveUrl(_urlController.text);
                    Navigator.of(context).pop();
                  },
                  child: Text(l.done),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}