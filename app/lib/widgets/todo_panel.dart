import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';

/// The agent's todo list, always on screen while it has one. Collapsed it
/// shows the active task and a count; expanded it shows every task grouped
/// by phase. Driven by the live `todos` event, so it tracks edits within a
/// turn rather than only at turn boundaries.
class TodoPanel extends StatefulWidget {
  const TodoPanel({required this.todos, super.key});

  final List<TodoItem> todos;

  @override
  State<TodoPanel> createState() => _TodoPanelState();
}

class _TodoPanelState extends State<TodoPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.todos.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = widget.todos.where((t) => t.status == 'completed').length;
    final active = widget.todos.firstWhere(
      (t) => t.status == 'in_progress',
      orElse: () => widget.todos.firstWhere(
        (t) => t.status == 'pending',
        orElse: () => widget.todos.last,
      ),
    );

    return Material(
      color: scheme.surfaceContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            label: _expanded
                ? 'Hide the task list'
                : 'Show the task list, $done of ${widget.todos.length} done',
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.checklist_rtl,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      '$done/${widget.todos.length}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        active.content,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _rows(context),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _rows(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    String? lastPhase;
    for (final todo in widget.todos) {
      if (todo.phase.isNotEmpty && todo.phase != lastPhase) {
        lastPhase = todo.phase;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: Text(
              todo.phase,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      rows.add(_TodoRow(todo: todo));
    }
    return rows;
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.todo});

  final TodoItem todo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Status reads from the icon shape as well as its colour.
    final (IconData icon, Color color) = switch (todo.status) {
      'completed' => (Icons.check_circle, scheme.primary),
      'in_progress' => (Icons.radio_button_checked, scheme.tertiary),
      'blocked' => (Icons.pause_circle_outline, scheme.error),
      'abandoned' => (Icons.cancel_outlined, scheme.onSurfaceVariant),
      _ => (Icons.radio_button_unchecked, scheme.onSurfaceVariant),
    };
    final struck = todo.status == 'completed' || todo.status == 'abandoned';

    return Semantics(
      label: '${todo.content}, ${todo.status.replaceAll("_", " ")}',
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                todo.content,
                style: theme.textTheme.bodySmall?.copyWith(
                  decoration: struck ? TextDecoration.lineThrough : null,
                  color: struck ? scheme.onSurfaceVariant : scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
