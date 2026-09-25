import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import '../services/player_settings.dart';

class SettingsLayoutSheet extends StatefulWidget {
  final List<String> initialOrder;
  final Set<String> initialHidden;
  final ScrollController? scrollController;

  const SettingsLayoutSheet({
    super.key,
    required this.initialOrder,
    required this.initialHidden,
    this.scrollController,
  });

  static Future<void> show(
    BuildContext context, {
    required List<String> initialOrder,
    required Set<String> initialHidden,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.pop(context),
        behavior: HitTestBehavior.opaque,
        child: DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          builder: (context, scrollController) => GestureDetector(
            onTap: () {},
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).bottomSheetTheme.backgroundColor ??
                    Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SettingsLayoutSheet(
                initialOrder: initialOrder,
                initialHidden: initialHidden,
                scrollController: scrollController,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  State<SettingsLayoutSheet> createState() => _SettingsLayoutSheetState();
}

IconData settingsSectionIcon(String id) {
  switch (id) {
    case 'Playback':
      return Icons.play_circle_outline_rounded;
    case 'Appearance':
      return Icons.palette_outlined;
    case 'Customize Stats':
      return Icons.bar_chart_rounded;
    case 'Absorbing Cards':
      return Icons.style_rounded;
    case 'Media Controls':
      return Icons.dvr_rounded;
    case 'Sleep Timer':
      return Icons.bedtime_outlined;
    case 'Downloads & Storage':
      return Icons.storage_rounded;
    case 'Library':
      return Icons.auto_stories_outlined;
    case 'Permissions':
      return Icons.shield_outlined;
    case 'Issues & Support':
      return Icons.support_agent_rounded;
    case 'Advanced':
      return Icons.tune_rounded;
    case 'Backup & Sync':
      return Icons.cloud_sync_rounded;
    case 'All Bookmarks':
      return Icons.bookmarks_rounded;
    default:
      return Icons.tune_rounded;
  }
}

String settingsSectionTitle(String id, AppLocalizations l) {
  switch (id) {
    case 'Playback':
      return l.sectionPlayback;
    case 'Appearance':
      return l.sectionAppearance;
    case 'Customize Stats':
      return l.settingsCustomizeStats;
    case 'Absorbing Cards':
      return l.sectionAbsorbingCards;
    case 'Media Controls':
      return l.sectionMediaControls;
    case 'Sleep Timer':
      return l.sectionSleepTimer;
    case 'Downloads & Storage':
      return l.sectionDownloadsAndStorage;
    case 'Library':
      return l.sectionLibrary;
    case 'Permissions':
      return l.sectionPermissions;
    case 'Issues & Support':
      return l.sectionIssuesAndSupport;
    case 'Advanced':
      return l.sectionAdvanced;
    case 'Backup & Sync':
      return l.backupAndSync;
    case 'All Bookmarks':
      return l.allBookmarks;
    default:
      return id;
  }
}

class _SettingsLayoutSheetState extends State<SettingsLayoutSheet> {
  late List<String> _order;
  late Set<String> _hidden;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.initialOrder);
    _hidden = Set.of(widget.initialHidden);
  }

  void _reset() {
    setState(() {
      _order = List.of(PlayerSettings.defaultSettingsSectionOrder);
      _hidden = {};
    });
  }

  Future<void> _save() async {
    await PlayerSettings.setSettingsSectionOrder(_order);
    await PlayerSettings.setSettingsHiddenSections(_hidden.toList());
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;

    return Column(children: [
      const SizedBox(height: 8),
      Center(child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: cs.onSurface.withValues(alpha: 0.24),
          borderRadius: BorderRadius.circular(2),
        ),
      )),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(children: [
          GestureDetector(
            onTap: _reset,
            child: Text(l.reset, style: tt.labelMedium?.copyWith(
              color: cs.primary, fontWeight: FontWeight.w500,
            )),
          ),
          const Spacer(),
          Text(l.customizeSettings, style: tt.titleMedium?.copyWith(
            fontWeight: FontWeight.w600, color: cs.onSurface,
          )),
          const Spacer(),
          GestureDetector(
            onTap: _save,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(l.done, style: tt.labelLarge?.copyWith(
                color: cs.primary, fontWeight: FontWeight.w600,
              )),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(
          l.dragToReorderTapEye,
          style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 12),
      Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.3),
        indent: 20, endIndent: 20),
      Expanded(
        child: ReorderableListView.builder(
          scrollController: widget.scrollController,
          padding: EdgeInsets.only(top: 8, bottom: MediaQuery.of(context).padding.bottom + 8),
          itemCount: _order.length,
          onReorderStart: (_) => HapticFeedback.mediumImpact(),
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _order.removeAt(oldIndex);
              _order.insert(newIndex, item);
            });
          },
          itemBuilder: (context, index) {
            final id = _order[index];
            final isHidden = _hidden.contains(id);
            return Container(
              key: ValueKey(id),
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: isHidden ? 0.02 : 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
              ),
              child: ListTile(
                dense: true,
                leading: Icon(settingsSectionIcon(id), size: 18,
                  color: isHidden
                      ? cs.onSurfaceVariant.withValues(alpha: 0.3)
                      : cs.onSurfaceVariant),
                title: Text(settingsSectionTitle(id, l), style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500,
                  color: isHidden
                      ? cs.onSurface.withValues(alpha: 0.35)
                      : cs.onSurface,
                )),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        if (isHidden) {
                          _hidden.remove(id);
                        } else {
                          _hidden.add(id);
                        }
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        isHidden ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                        size: 18,
                        color: isHidden
                            ? cs.onSurfaceVariant.withValues(alpha: 0.3)
                            : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.drag_handle_rounded, size: 18,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}