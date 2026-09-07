import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';

/// Shows model, thinking level, streaming/compacting, context usage, queued
/// count, and attached-viewer count. Every value is conveyed as text so
/// nothing depends on color alone.
class StateHeader extends StatelessWidget {
  const StateHeader({required this.status, required this.state, super.key});

  final ConnectionStatus status;
  final StateSnapshot? state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connectionText = switch (status.phase) {
      ConnectionPhase.disconnected => 'Disconnected',
      ConnectionPhase.connecting => 'Connecting...',
      ConnectionPhase.connected => 'Connected',
      ConnectionPhase.reconnecting => 'Reconnecting...',
    };
    final connectionIcon = switch (status.phase) {
      ConnectionPhase.disconnected => Icons.cloud_off,
      ConnectionPhase.connecting => Icons.cloud_sync,
      ConnectionPhase.connected => Icons.cloud_done,
      ConnectionPhase.reconnecting => Icons.cloud_sync,
    };

    final state = this.state;
    final chips = <Widget>[];

    chips.add(_StatusChip(icon: connectionIcon, label: connectionText));

    if (status.role == ClientRole.viewer) {
      chips.add(
        const _StatusChip(
          icon: Icons.visibility,
          label: 'Read-only connection',
        ),
      );
    }

    if (state != null) {
      if (state.model != null) {
        chips.add(
          _StatusChip(
            icon: Icons.smart_toy_outlined,
            label: state.model!.label,
          ),
        );
      }
      if (state.thinkingLevel != null) {
        chips.add(
          _StatusChip(
            icon: Icons.psychology_outlined,
            label: 'Thinking: ${state.thinkingLevel}',
          ),
        );
      }
      if (state.compacting) {
        chips.add(const _StatusChip(icon: Icons.compress, label: 'Compacting'));
      } else if (state.streaming) {
        chips.add(
          const _StatusChip(icon: Icons.graphic_eq, label: 'Streaming'),
        );
      } else {
        chips.add(
          const _StatusChip(icon: Icons.check_circle_outline, label: 'Idle'),
        );
      }
      if (state.queued > 0) {
        chips.add(
          _StatusChip(
            icon: Icons.playlist_add,
            label: 'Queued: ${state.queued}',
          ),
        );
      }
      final usage = state.contextUsage;
      if (usage != null) {
        chips.add(
          _StatusChip(
            icon: Icons.data_usage,
            label:
                'Context: ${usage.percent.toStringAsFixed(1)}% (${usage.tokens}/${usage.contextWindow})',
          ),
        );
      }
      final viewers = state.viewers;
      if (viewers != null) {
        chips.add(
          _StatusChip(
            icon: Icons.groups_outlined,
            label: 'Controls: ${viewers.control}, Viewers: ${viewers.viewer}',
          ),
        );
      }
      if (state.sessionName != null) {
        chips.add(
          _StatusChip(icon: Icons.folder_outlined, label: state.sessionName!),
        );
      }
    }

    if (status.lastError != null) {
      chips.add(
        _StatusChip(
          icon: Icons.error_outline,
          label: 'Last error: ${status.lastError}',
          isError: true,
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Semantics(
        container: true,
        label:
            'Session status: ${chips.map((c) => c is _StatusChip ? c.label : '').join(', ')}',
        child: Wrap(spacing: 8, runSpacing: 4, children: chips),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    this.isError = false,
  });

  final IconData icon;
  final String label;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return ExcludeSemantics(
      child: Chip(
        avatar: Icon(icon, size: 16, color: color),
        label: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: color),
        ),
        visualDensity: VisualDensity.compact,
        backgroundColor: theme.colorScheme.surfaceContainerHigh,
        side: BorderSide.none,
      ),
    );
  }
}
