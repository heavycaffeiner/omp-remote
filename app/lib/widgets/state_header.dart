import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';
import '../theme.dart';
import 'panel_shell.dart';

/// Shows model, thinking level, streaming/compacting, context usage, queued
/// count, and attached-viewer count. Every value is conveyed as text
/// (never color alone). Collapsed, it is one 40dp line: connection icon,
/// then the session label and summary parts joined by a thin separator,
/// then the expand affordance. Tapping it expands a dense key/value grid
/// with every field the collapsed line elides.
class StateHeader extends StatefulWidget {
  const StateHeader({
    required this.status,
    required this.state,
    this.activeSessionLabel,
    this.onRetry,
    super.key,
  });

  final ConnectionStatus status;
  final StateSnapshot? state;

  /// Active session's name and agent id, already formatted as one line of
  /// text. Shown as the first summary part so a multi-session user always
  /// knows which agent they are talking to.
  final String? activeSessionLabel;

  /// Retries the connection now rather than waiting out the backoff. Shown
  /// as an affordance only while the connection is down.
  final VoidCallback? onRetry;

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

    final usage = state?.contextUsage;
    final error = status.lastError;
    final connected = status.phase == ConnectionPhase.connected;

    // While the connection is not up, the reason it is not up is the only
    // thing worth the collapsed line. Everything else is stale by then.
    final summaryParts = connected || error == null
        ? <String>[
            ?widget.activeSessionLabel,
            connectionText,
            if (status.role == ClientRole.viewer) 'Read-only',
            if (state?.model != null) state!.model!.label,
            ?activityText,
            if (usage != null) '${usage.percent.toStringAsFixed(0)}% context',
          ]
        : <String>[connectionText, error];

    return PanelShell(
      leading: Icon(connectionIcon, size: 16, color: connectionColor),
      title: Text(
        summaryParts.join('  |  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: connected || error == null
              ? theme.colorScheme.onSurface
              : theme.colorScheme.error,
        ),
      ),
      trailing: connected || widget.onRetry == null
          ? null
          : IconButton(
              onPressed: widget.onRetry,
              tooltip: 'Try connecting again',
              iconSize: 18,
              icon: const Icon(Icons.refresh),
            ),
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      semanticsLabel:
          '${_expanded ? 'Hide' : 'Show'} session details. '
          'Session status: ${summaryParts.join(', ')}',
      expandedChild: _DetailGrid(
        status: status,
        state: state,
        activityText: activityText,
      ),
    );
  }
}

/// Every field the collapsed line elides, as a dense two-column key/value
/// grid rather than a stack of colour-coded chips.
class _DetailGrid extends StatelessWidget {
  const _DetailGrid({
    required this.status,
    required this.state,
    required this.activityText,
  });

  final ConnectionStatus status;
  final StateSnapshot? state;
  final String? activityText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pairs = <(String, String)>[
      (
        'Connection',
        switch (status.phase) {
          ConnectionPhase.disconnected => 'Disconnected',
          ConnectionPhase.connecting => 'Connecting...',
          ConnectionPhase.connected => 'Connected',
          ConnectionPhase.reconnecting => 'Reconnecting...',
        },
      ),
      ('Access', status.role == ClientRole.viewer ? 'Read-only' : 'Control'),
    ];

    final state = this.state;
    if (state != null) {
      if (state.model != null) pairs.add(('Model', state.model!.label));
      if (state.thinkingLevel != null) {
        pairs.add(('Thinking', state.thinkingLevel!));
      }
      if (activityText != null) pairs.add(('Activity', activityText!));
      pairs.add(('Queued', '${state.queued}'));
      final viewers = state.viewers;
      if (viewers != null) {
        pairs.add(('Controllers', '${viewers.control}'));
        pairs.add(('Viewers', '${viewers.viewer}'));
      }
      if (state.sessionName != null) {
        pairs.add(('Session', state.sessionName!));
      }
      final usage = state.contextUsage;
      if (usage != null) {
        pairs.add((
          'Context',
          '${usage.percent.toStringAsFixed(1)}% '
              '(${usage.tokens}/${usage.contextWindow})',
        ));
      }
    }
    if (status.lastError != null) {
      pairs.add(('Last error', status.lastError!));
    }

    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final valueStyle = theme.textTheme.bodySmall;

    Widget cell(String text, TextStyle? style, {bool label = false}) => Padding(
      padding: EdgeInsets.only(
        right: AppSpacing.sm,
        bottom: AppSpacing.xs,
        left: label ? 0 : AppSpacing.sm,
      ),
      child: Text(text, style: style, overflow: TextOverflow.ellipsis),
    );

    final rows = <TableRow>[];
    for (var i = 0; i < pairs.length; i += 2) {
      final first = pairs[i];
      final second = i + 1 < pairs.length ? pairs[i + 1] : null;
      rows.add(
        TableRow(
          children: [
            cell(first.$1, labelStyle, label: true),
            cell(first.$2, valueStyle),
            cell(second?.$1 ?? '', labelStyle, label: true),
            cell(second?.$2 ?? '', valueStyle),
          ],
        ),
      );
    }

    return Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
        2: IntrinsicColumnWidth(),
        3: FlexColumnWidth(),
      },
      children: rows,
    );
  }
}
