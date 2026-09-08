import 'package:flutter/material.dart';

import '../theme.dart';
import 'panel_shell.dart';

/// Prompts the workstation is holding for this session, still waiting for the
/// agent.
///
/// They sit in omp's own queue, which drains one message per agent step
/// boundary, so each arrives mid-turn rather than after it. The plugin keeps
/// the list, so every attached client sees the same one; the queue's contents
/// are not readable from an extension, so text typed at the workstation is
/// not in it, and editing or dropping an entry is a workstation action.
class QueuePanel extends StatefulWidget {
  const QueuePanel({required this.queued, required this.sent, super.key});

  /// What the workstation reports as waiting, whether or not it can name it.
  final int queued;

  /// The prompts it can name, oldest first.
  final List<String> sent;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    if (widget.queued == 0 && widget.sent.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sent = widget.sent;
    // The workstation reports what is waiting, and names it when it can. A
    // message typed at the workstation itself is counted but not listed,
    // since the queue's contents are not readable from an extension.
    final label = sent.isEmpty
        ? 'A message is waiting, typed at the workstation'
        : (sent.length == 1
              ? '1 message waiting to be delivered'
              : '${sent.length} messages waiting to be delivered');

    return PanelShell(
      leading: Icon(
        Icons.schedule_send_outlined,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
      title: Text(label, style: theme.textTheme.bodySmall),
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      semanticsLabel: _expanded
          ? 'Hide waiting messages'
          : 'Show waiting messages, $label',
      expandedChild: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final text in sent) _QueueRow(text: text),
          Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.xs,
              left: AppSpacing.sm,
              right: AppSpacing.sm,
              bottom: AppSpacing.xs,
            ),
            child: Text(
              'Each one is delivered at the agent\'s next step, without '
              'waiting for the turn to finish. Editing or dropping one is '
              'done at the workstation.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: AppSpacing.sm),
            child: Icon(
              Icons.subdirectory_arrow_right,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
