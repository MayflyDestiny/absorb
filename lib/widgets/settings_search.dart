import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/settings_search_index.dart';
import 'collapsible_section.dart';

/// Filter and rank the search index for [query]. Every whitespace-separated
/// word must appear somewhere in the entry (title, subtitles, or section
/// name); entries whose title matches rank above subtitle-only matches.
List<SettingSearchEntry> filterSettingEntries(
  List<SettingSearchEntry> entries,
  String query,
) {
  final words = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((w) => w.isEmpty);
  if (words.isEmpty) return const [];

  int rankOf(SettingSearchEntry e) {
    final title = e.title.toLowerCase();
    final extras = e.extras.map((s) => s.toLowerCase()).toList();
    final section = e.sectionTitle.toLowerCase();
    var best = 4;
    for (final w in words) {
      final int r;
      if (title.startsWith(w)) {
        r = 0;
      } else if (title.contains(w)) {
        r = 1;
      } else if (extras.any((s) => s.contains(w))) {
        r = 2;
      } else if (section.contains(w)) {
        r = 3;
      } else {
        return -1; // word not found anywhere - entry is out
      }
      if (r < best) best = r;
    }
    return best;
  }

  final ranked = <(int, int, SettingSearchEntry)>[];
  for (var i = 0; i < entries.length; i++) {
    final r = rankOf(entries[i]);
    if (r >= 0) ranked.add((r, i, entries[i]));
  }
  ranked.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    return a.$2.compareTo(b.$2); // stable: keep on-screen order within a rank
  });
  return ranked.map((e) => e.$3).toList();
}

class SettingsSearchResults extends StatelessWidget {
  final List<SettingSearchEntry> results;
  final void Function(SettingSearchEntry) onOpen;
  const SettingsSearchResults({
    super.key,
    required this.results,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context)!;
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Text(l.settingsSearchNoResults,
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        ),
      );
    }
    return Column(
      children: [
        for (final e in results)
          ListTile(
            dense: true,
            title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: e.extras.isEmpty
                ? Text(e.sectionTitle,
                    style: tt.bodySmall?.copyWith(color: cs.primary))
                : Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: '${e.sectionTitle}  ·  ',
                          style: TextStyle(color: cs.primary)),
                      TextSpan(text: e.extras.first),
                    ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tt.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
            trailing: Icon(Icons.chevron_right_rounded,
                size: 18, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
            onTap: () => onOpen(e),
          ),
      ],
    );
  }
}

/// Scroll the tile whose title text is [title] into view inside the expanded
/// section at [sectionContext], then pulse a highlight over it that stays glued
/// to the row while the list scrolls. The tile is located by its rendered title
/// text, so the 150+ settings tiles need no individual markers. No-op if the
/// text isn't found (e.g. the tile is hidden behind a feature flag).
Future<void> highlightSettingInSection({
  required BuildContext sectionContext,
  required String title,
}) async {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is Text && w.data == title) {
      found = e;
      return;
    }
    e.visitChildren(visit);
  }

  (sectionContext as Element).visitChildren(visit);
  final textElement = found;
  if (textElement == null || !textElement.mounted) return;

  await Scrollable.ensureVisible(
    textElement,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
    alignment: 0.35,
  );
  if (!textElement.mounted) return;

  // Prefer the enclosing tile's bounds over the bare text so the pulse
  // covers the whole row, toggle included.
  RenderObject? target = textElement.renderObject;
  var tileFound = false;
  textElement.visitAncestorElements((a) {
    final w = a.widget;
    if (w is SwitchListTile ||
        w is ListTile ||
        w is CheckboxListTile ||
        w is RadioListTile) {
      target = a.renderObject ?? target;
      tileFound = true;
      return false;
    }
    // Stop climbing once we leave the section - keeps a missing tile
    // ancestor from selecting something huge.
    return w is! CollapsibleSection;
  });
  final box = target;
  if (box is! RenderBox || !box.attached) return;

  final overlay = Overlay.maybeOf(sectionContext);
  if (overlay == null) return;
  final accent = Theme.of(sectionContext).colorScheme.primary;

  final sectionRender = sectionContext.findRenderObject();
  final sectionBox =
      sectionRender is RenderBox && sectionRender.attached ? sectionRender : null;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _SettingHighlightPulse(
      target: box,
      sectionBox: sectionBox,
      tileFound: tileFound,
      accent: accent,
      onDone: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );
  overlay.insert(entry);
}

/// A short-lived highlight glued to its target row. The rectangle is re-read
/// from the target's [RenderObject] on every animation frame, so the box keeps
/// covering the row while the list scrolls under it (the settings rows stay
/// mounted in the eager sliver, so the target remains attached). Fades in,
/// holds, fades out, then removes itself via [onDone].
class _SettingHighlightPulse extends StatefulWidget {
  final RenderBox target;
  final RenderBox? sectionBox;
  final bool tileFound;
  final Color accent;
  final VoidCallback onDone;

  const _SettingHighlightPulse({
    required this.target,
    required this.sectionBox,
    required this.tileFound,
    required this.accent,
    required this.onDone,
  });

  @override
  State<_SettingHighlightPulse> createState() => _SettingHighlightPulseState();
}

class _SettingHighlightPulseState extends State<_SettingHighlightPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )
      // Rebuilding each frame re-measures the target, so the box tracks the
      // row as it scrolls instead of staying where it was first painted.
      ..addListener(() => setState(() {}))
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onDone();
      })
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Rect? _currentRect() {
    final target = widget.target;
    if (!target.attached) return null;
    var rect = target.localToGlobal(Offset.zero) & target.size;
    if (!widget.tileFound) {
      // Custom rows (segmented pickers, sliders) have no ListTile ancestor -
      // span the section's width at the title's line instead.
      final section = widget.sectionBox;
      if (section != null && section.attached) {
        final s = section.localToGlobal(Offset.zero) & section.size;
        rect = Rect.fromLTRB(
            s.left + 8, rect.top - 10, s.right - 8, rect.bottom + 10);
      } else {
        rect = rect.inflate(10);
      }
    }
    return rect.inflate(2);
  }

  @override
  Widget build(BuildContext context) {
    final rect = _currentRect();
    if (rect == null) return const SizedBox.shrink();

    final t = _controller.value;
    // Quick fade in, hold, slow fade out.
    final opacity = t < 0.12
        ? t / 0.12
        : t > 0.55
            ? ((1 - t) / 0.45).clamp(0.0, 1.0)
            : 1.0;

    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Container(
            decoration: BoxDecoration(
              color: widget.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: widget.accent.withValues(alpha: 0.55), width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}
