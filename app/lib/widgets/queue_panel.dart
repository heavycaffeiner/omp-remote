import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';

/// Messages waiting for the agent to finish. None has reached the model, so
/// each can still be rewritten or dropped. Always visible while the queue is
/// non-empty: a prompt sent mid-turn is otherwise invisible until it runs.
class QueuePanel extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (queue.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.secondaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.schedule_send_outlined,
                  size: 18,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  queue.length == 1
                      ? '1 message queued'
                      : '${queue.length} messages queued',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ],
            ),
          ),
          for (final message in queue)
            _QueueRow(message: message, onEdit: onEdit, onRemove: onRemove),
          const SizedBox(height: AppSpacing.sm),
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
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                child: Text(
                  message.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Edit this message',
              icon: const Icon(Icons.edit_outlined, size: 18),
              color: scheme.onSecondaryContainer,
              onPressed: () => _promptForEdit(context),
            ),
            IconButton(
              tooltip: 'Remove this message',
              icon: const Icon(Icons.delete_outline, size: 18),
              color: scheme.onSecondaryContainer,
              onPressed: () => onRemove(message.id),
            ),
          ],
        ),
      ),
    );
  }
}
