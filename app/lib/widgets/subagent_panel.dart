import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';

/// Spawned agents run in sessions of their own, so their work never reaches
/// the parent transcript. This panel is where it shows up: one row per agent,
/// replaced in place as progress arrives rather than appended, so a fan-out
/// of eight does not bury the conversation.
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
    final label = running > 0
        ? '$running of ${widget.subagents.length} agents running'
        : '${widget.subagents.length} agents finished';

    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            label: _expanded ? 'Hide agent details' : 'Show agent details',
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  children: [
                    Icon(
                      running > 0 ? Icons.groups : Icons.groups_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(label, style: theme.textTheme.titleSmall),
                    ),
                    if (running > 0)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const SizedBox(width: AppSpacing.sm),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
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
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: AppSpacing.md),
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
                    const SizedBox(height: AppSpacing.xs),
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
