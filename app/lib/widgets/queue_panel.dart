import 'package:flutter/material.dart';

import '../theme.dart';
import 'panel_shell.dart';

/// Prompts this phone sent while the agent was busy, still waiting for it.
///
/// They sit in omp's own queue, which drains one message per agent step
/// boundary, so each arrives mid-turn rather than after it. The extension API
/// reports only whether that queue is non-empty, never its contents, so this
/// lists what this client put there and nothing typed at the workstation.
/// Editing a pending message is a workstation action for the same reason.
class QueuePanel extends StatefulWidget {
  const QueuePanel({required this.queued, required this.sent, super.key});

  /// What the workstation reports: whether anything is pending at all.
  final int queued;

  /// The prompts this client sent into that queue, oldest first.
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
    // The count is what this client knows it sent. When the workstation says
    // something is pending and this client sent nothing, the message came
    // from the workstation itself, so the label says so instead of naming a
    // number it cannot know.
    final label = sent.isEmpty
        ? 'A message is waiting, sent from the workstation'
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
