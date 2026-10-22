import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';

/// Custom open-source licenses page. An app-info header sits on top; below it,
/// third-party packages are grouped by name, and tapping a package opens its
/// full license text. This replaces the stock [showLicensePage] long list while
/// keeping every registered license reachable.
class OpenSourceLicensesScreen extends StatefulWidget {
  const OpenSourceLicensesScreen({super.key, required this.appVersion});

  final String appVersion;

  @override
  State<OpenSourceLicensesScreen> createState() =>
      _OpenSourceLicensesScreenState();
}

class _OpenSourceLicensesScreenState extends State<OpenSourceLicensesScreen> {
  late final Future<Map<String, List<LicenseEntry>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _collect();
  }

  Future<Map<String, List<LicenseEntry>>> _collect() async {
    final byPackage = <String, List<LicenseEntry>>{};
    await for (final LicenseEntry entry in LicenseRegistry.licenses) {
      for (final String package in entry.packages) {
        // The app's own license is already shown in the header card; don't
        // duplicate it in the third-party list.
        if (package == 'absorb') continue;
        byPackage.putIfAbsent(package, () => <LicenseEntry>[]).add(entry);
      }
    }
    return byPackage;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context)!.openSourceLicenses)),
      body: FutureBuilder<Map<String, List<LicenseEntry>>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final byPackage = snapshot.data ?? {};
          final packages = byPackage.keys.toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              // ── App info header ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Card(
                  elevation: 0,
                  color: cs.surfaceContainerHighest,
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Absorb',
                            style: tt.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(widget.appVersion,
                            style: tt.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                        const SizedBox(height: 12),
                        Text(AppLocalizations.of(context)!.licensesBasedOn,
                            style: tt.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () => launchUrl(
                            Uri.parse('https://github.com/MayflyDestiny/absorb'),
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.open_in_new_rounded, size: 16),
                          label:
                              Text(AppLocalizations.of(context)!.licensesViewRepository),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                child: Text(
                  AppLocalizations.of(context)!.licensesThirdParty,
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              for (final package in packages)
                _PackageRow(
                  packageName: package,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _PackageLicenseDetailPage(
                        packageName: package,
                        entries: byPackage[package]!,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}

class _PackageRow extends StatelessWidget {
  const _PackageRow({required this.packageName, required this.onTap});

  final String packageName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(packageName,
                      style:
                          const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full license text for a single package, rendered from its paragraphs.
class _PackageLicenseDetailPage extends StatefulWidget {
  const _PackageLicenseDetailPage({
    required this.packageName,
    required this.entries,
  });

  final String packageName;
  final List<LicenseEntry> entries;

  @override
  State<_PackageLicenseDetailPage> createState() =>
      _PackageLicenseDetailPageState();
}

class _PackageLicenseDetailPageState extends State<_PackageLicenseDetailPage> {
  final List<Widget> _blocks = <Widget>[];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    for (final LicenseEntry entry in widget.entries) {
      if (!mounted) return;
      final List<LicenseParagraph> paragraphs =
          entry.paragraphs.toList();
      if (!mounted) return;
      setState(() {
        _blocks.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1),
        ));
        for (final LicenseParagraph paragraph in paragraphs) {
          if (paragraph.indent == LicenseParagraph.centeredIndent) {
            _blocks.add(Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                paragraph.text,
                style: const TextStyle(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ));
          } else {
            _blocks.add(Padding(
              padding: EdgeInsetsDirectional.only(
                  top: 8.0, start: 16.0 * paragraph.indent),
              child: Text(paragraph.text),
            ));
          }
        }
      });
    }
    if (mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.packageName)),
      body: _loaded
          ? ListView(padding: const EdgeInsets.all(16), children: _blocks)
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
