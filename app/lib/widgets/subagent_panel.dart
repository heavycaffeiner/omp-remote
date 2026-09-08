import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';
import 'panel_shell.dart';

/// Spawned agents run in sessions of their own, so their work never reaches
/// the parent transcript. This panel is where it shows up: collapsed to one
/// line naming how many are running and the newest one's name, expanded to
/// one row per agent, replaced in place as progress arrives rather than
/// appended, so a fan-out of eight does not bury the conversation.
class SubagentPanel extends StatefulWidget {
  const SubagentPanel({required this.subagents, super.key});

  final List<SubagentEvent> subagents;

  @override
  State<SubagentPanel> createState() => _SubagentPanelState();
}

class _SubagentPanelState extends State<SubagentPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.subagents.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final running = widget.subagents.where((a) => !a.isTerminal).length;
    final newest = widget.subagents.last;
    final label = running > 0
        ? '$running subagent${running == 1 ? '' : 's'} running, '
              'newest: ${newest.name}'
        : '${widget.subagents.length} '
              'subagent${widget.subagents.length == 1 ? '' : 's'} finished, '
              'newest: ${newest.name}';

    return PanelShell(
      leading: Icon(
        running > 0 ? Icons.groups : Icons.groups_outlined,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: running > 0
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      semanticsLabel: _expanded ? 'Hide agent details' : 'Show agent details',
      expandedChild: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final agent in widget.subagents) _SubagentRow(agent: agent),
        ],
      ),
    );
  }
}

class _SubagentRow extends StatelessWidget {
  const _SubagentRow({required this.agent});

  final SubagentEvent agent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Status is never carried by colour alone: the icon shape differs too.
    final (IconData icon, Color color) = switch (agent.phase) {
      'completed' => (Icons.check_circle_outline, scheme.primary),
      'failed' => (Icons.error_outline, scheme.error),
      'aborted' => (Icons.cancel_outlined, scheme.error),
      'pending' => (Icons.schedule, scheme.onSurfaceVariant),
      _ => (Icons.play_circle_outline, scheme.tertiary),
    };

    final facts = <String>[
      if (agent.agentType != null && agent.agentType!.isNotEmpty)
        agent.agentType!,
      agent.phase,
      if (agent.tool != null && agent.tool!.isNotEmpty) 'in ${agent.tool}',
      if (agent.toolCount != null && agent.toolCount! > 0)
        '${agent.toolCount} tools',
      if (agent.tokens != null && agent.tokens! > 0)
        '${_compactCount(agent.tokens!)} tokens',
      if (agent.durationMs != null && agent.durationMs! > 0)
        _duration(agent.durationMs!),
    ];

    return Semantics(
      label: '${agent.name}, ${facts.join(", ")}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    agent.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    facts.join('  |  '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (agent.text != null && agent.text!.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xxs),
                    Text(agent.text!, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _compactCount(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
  return '$value';
}

String _duration(int ms) {
  if (ms < 1000) return '${ms}ms';
  final seconds = ms ~/ 1000;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  return '${minutes}m ${seconds % 60}s';
}
