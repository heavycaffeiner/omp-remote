import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';
import 'panel_shell.dart';

/// Messages waiting for the agent to finish. None has reached the model, so
/// each can still be rewritten or dropped. Always visible while the queue is
/// non-empty: a prompt sent mid-turn is otherwise invisible until it runs.
/// Collapsed to one line with a count; expanded shows every queued message.
class QueuePanel extends StatefulWidget {
  const QueuePanel({
    required this.queue,
    required this.onEdit,
    required this.onRemove,
    super.key,
  });

  final List<QueuedMessage> queue;

  /// Called with the new text for a queued message.
  final void Function(String id, String text) onEdit;
  final void Function(String id) onRemove;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final queue = widget.queue;
    if (queue.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = queue.length == 1
        ? '1 message queued'
        : '${queue.length} messages queued';

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
          ? 'Hide queued messages'
          : 'Show queued messages, $label',
      expandedChild: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final message in queue)
            _QueueRow(
              message: message,
              onEdit: widget.onEdit,
              onRemove: widget.onRemove,
            ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.message,
    required this.onEdit,
    required this.onRemove,
  });

  final QueuedMessage message;
  final void Function(String id, String text) onEdit;
  final void Function(String id) onRemove;

  Future<void> _promptForEdit(BuildContext context) async {
    final controller = TextEditingController(text: message.text);
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit queued message'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 2,
          decoration: const InputDecoration(labelText: 'Message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (edited != null && edited.isNotEmpty && edited != message.text) {
      onEdit(message.id, edited);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      label: 'Queued: ${message.text}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                message.text,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: Semantics(
                button: true,
                label: 'Edit this message',
                child: IconButton(
                  tooltip: 'Edit this message',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  color: scheme.onSurfaceVariant,
                  onPressed: () => _promptForEdit(context),
                ),
              ),
            ),
            SizedBox(
              width: 48,
              height: 48,
              child: Semantics(
                button: true,
                label: 'Remove this message',
                child: IconButton(
                  tooltip: 'Remove this message',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  color: scheme.onSurfaceVariant,
                  onPressed: () => onRemove(message.id),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
