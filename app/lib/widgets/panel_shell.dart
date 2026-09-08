import 'package:flutter/material.dart';

import '../theme.dart';

/// Flat band chrome shared by every full-width panel that sits above or
/// below the transcript (state header, todo, subagent, queue): a
/// [surfaceContainerLow] background with a hairline bottom border and
/// padding `horizontal: AppSpacing.md, vertical: AppSpacing.sm`. Every
/// panel here is a tap-to-expand header row (icon, [title], optional
/// [trailing], expand chevron) plus an optional [expandedChild] shown only
/// while [expanded]. The padding is part of the tap target, not just the
/// text inside it. [semanticsLabel] must say what tapping it does. Every
/// panel contains only its own content: no border, background, or padding
/// of its own.
class PanelShell extends StatelessWidget {
  const PanelShell({
    required this.title,
    required this.onToggle,
    required this.semanticsLabel,
    this.leading,
    this.trailing,
    this.expanded = false,
    this.expandedChild,
    super.key,
  });

  /// Icon shown before [title].
  final Widget? leading;

  /// Header row content, e.g. the collapsed summary line.
  final Widget title;

  /// Optional widget shown after [title], before the expand chevron.
  final Widget? trailing;

  /// Whether [expandedChild] is currently shown.
  final bool expanded;

  /// Called when the header row is tapped.
  final VoidCallback onToggle;

  /// What tapping the header does, read to screen readers.
  final String semanticsLabel;

  /// Shown below the header only while [expanded].
  final Widget? expandedChild;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final header = Semantics(
      button: true,
      expanded: expanded,
      label: semanticsLabel,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(child: title),
                if (trailing != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  trailing!,
                ],
                const SizedBox(width: AppSpacing.xs),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          if (expanded && expandedChild != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: expandedChild,
            ),
        ],
      ),
    );
  }
}
