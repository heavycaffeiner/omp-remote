import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';
import '../theme.dart';

/// Shows model, thinking level, streaming/compacting, context usage, queued
/// count, and attached-viewer count. Every value is conveyed as text
/// (never color alone). A one-line compact summary keeps a phone-width app
/// bar from crowding; tapping it expands the full detail.
class StateHeader extends StatefulWidget {
  const StateHeader({
    required this.status,
    required this.state,
    this.activeSessionLabel,
    super.key,
  });

  final ConnectionStatus status;
  final StateSnapshot? state;

  /// Active session's name and agent id, already formatted as one line of
  /// text. Shown above the status summary so a multi-session user always
  /// knows which agent they are talking to.
  final String? activeSessionLabel;

  @override
  State<StateHeader> createState() => _StateHeaderState();
}

class _StateHeaderState extends State<StateHeader> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.status;
    final state = widget.state;

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
    final connectionColor = status.phase == ConnectionPhase.connected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    final activityText = state == null
        ? null
        : (state.compacting
              ? 'Compacting'
              : (state.streaming ? 'Streaming' : 'Idle'));
    final activityIcon = state == null
        ? null
        : (state.compacting
              ? Icons.compress
              : (state.streaming ? Icons.graphic_eq : Icons.check_circle_outline));

    final usage = state?.contextUsage;

    final summaryParts = <String>[
      connectionText,
      if (status.role == ClientRole.viewer) 'Read-only',
      if (state?.model != null) state!.model!.label,
      ?activityText,
      if (usage != null) '${usage.percent.toStringAsFixed(0)}% context',
    ];

    return Semantics(
      container: true,
      label:
          '${widget.activeSessionLabel != null ? 'Active session: ${widget.activeSessionLabel}. ' : ''}'
          'Session status: ${summaryParts.join(', ')}',
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.activeSessionLabel != null) ...[
                  Row(
                    children: [
                      Icon(
                        Icons.badge_outlined,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          widget.activeSessionLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Row(
                    children: [
                      Icon(connectionIcon, size: 16, color: connectionColor),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          summaryParts.join('  |  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
                if (_expanded) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: _buildDetailChips(theme, status, state, activityIcon, activityText),
                  ),
                  if (usage != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _ContextUsageBar(usage: usage),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildDetailChips(
    ThemeData theme,
    ConnectionStatus status,
    StateSnapshot? state,
    IconData? activityIcon,
    String? activityText,
  ) {
    final chips = <Widget>[
      _StatusChip(
        icon: switch (status.phase) {
          ConnectionPhase.disconnected => Icons.cloud_off,
          ConnectionPhase.connecting => Icons.cloud_sync,
          ConnectionPhase.connected => Icons.cloud_done,
          ConnectionPhase.reconnecting => Icons.cloud_sync,
        },
        label: switch (status.phase) {
          ConnectionPhase.disconnected => 'Disconnected',
          ConnectionPhase.connecting => 'Connecting...',
          ConnectionPhase.connected => 'Connected',
          ConnectionPhase.reconnecting => 'Reconnecting...',
        },
      ),
    ];

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
          _StatusChip(icon: Icons.smart_toy_outlined, label: state.model!.label),
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
      if (activityText != null && activityIcon != null) {
        chips.add(_StatusChip(icon: activityIcon, label: activityText));
      }
      if (state.queued > 0) {
        chips.add(
          _StatusChip(
            icon: Icons.playlist_add,
            label: 'Queued: ${state.queued}',
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

    return chips;
  }
}

/// Context usage read as a proportion: a labeled progress bar rather than a
/// raw token count, which is what the number is actually for.
class _ContextUsageBar extends StatelessWidget {
  const _ContextUsageBar({required this.usage});

  final ContextUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = (usage.percent / 100).clamp(0.0, 1.0);
    final label =
        'Context used: ${usage.percent.toStringAsFixed(1)}%, '
        '${usage.tokens} of ${usage.contextWindow} tokens';
    return Semantics(
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.data_usage,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                'Context: ${usage.percent.toStringAsFixed(1)}%',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.small),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: fraction >= 0.9
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
          ),
        ],
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
