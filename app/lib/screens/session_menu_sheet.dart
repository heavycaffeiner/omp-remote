import 'dart:async';

import 'package:flutter/material.dart';

import '../notifications.dart';
import '../protocol.dart';
import '../relay_client.dart';
import '../session_store.dart';
import '../theme.dart';

/// Frequently used session settings, reachable directly rather than through
/// the slash command reference: model picker, thinking level, compaction,
/// session lifecycle, and todos. Disabled entirely for a viewer connection.
class SessionMenuSheet extends StatefulWidget {
  const SessionMenuSheet({
    required this.relayClient,
    required this.sessionStore,
    required this.canControl,
    super.key,
  });

  final RelayClient relayClient;
  final SessionStore sessionStore;
  final bool canControl;

  @override
  State<SessionMenuSheet> createState() => _SessionMenuSheetState();
}

class _SessionMenuSheetState extends State<SessionMenuSheet> {
  bool _busy = false;

  Future<void> _run(
    Future<Object?> Function() action, {
    String? successMessage,
  }) async {
    if (!widget.canControl) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && successMessage != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(successMessage)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.sessionStore.state;
    final disabled = !widget.canControl || _busy;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Semantics(
                  header: true,
                  child: Text('Session', style: theme.textTheme.titleSmall),
                ),
                const Spacer(),
                if (_busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (!widget.canControl)
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.xs,
                  bottom: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.visibility,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        'Settings are disabled: read-only connection.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(),
            const SizedBox(height: AppSpacing.sm),
            Semantics(
              label:
                  'Thinking level, currently ${state?.thinkingLevel ?? 'unknown'}',
              child: DropdownButtonFormField<String>(
                initialValue:
                    state?.thinkingLevel != null &&
                        thinkingLevels.contains(state!.thinkingLevel)
                    ? state.thinkingLevel
                    : null,
                decoration: const InputDecoration(labelText: 'Thinking level'),
                items: [
                  for (final level in thinkingLevels)
                    DropdownMenuItem(value: level, child: Text(level)),
                ],
                onChanged: disabled
                    ? null
                    : (value) {
                        if (value == null) return;
                        _run(
                          () => widget.relayClient.sendCommand(
                            CommandName.setThinking,
                            args: {'level': value},
                          ),
                        );
                      },
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Semantics(
              button: true,
              label: 'Cycle model',
              child: OutlinedButton.icon(
                onPressed: disabled
                    ? null
                    : () => _run(
                        () => widget.relayClient.sendCommand(
                          CommandName.cycleModel,
                        ),
                      ),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Cycle model'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Semantics(
              button: true,
              label: 'Compact session',
              child: OutlinedButton.icon(
                onPressed: disabled
                    ? null
                    : () => _run(
                        () =>
                            widget.relayClient.sendCommand(CommandName.compact),
                      ),
                icon: const Icon(Icons.compress),
                label: const Text('Compact session'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Semantics(
              button: true,
              label: 'Start new session',
              child: OutlinedButton.icon(
                onPressed: disabled
                    ? null
                    : () => _run(
                        () => widget.relayClient.sendCommand(
                          CommandName.newSession,
                        ),
                        successMessage: 'New session started',
                      ),
                icon: const Icon(Icons.add_box_outlined),
                label: const Text('New session'),
              ),
            ),
            if (state?.todos != null && state!.todos!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text('Todos', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              for (final todo in state.todos!)
                Semantics(
                  label: '${todo.phase}: ${todo.content}, ${todo.status}',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      todo.status == 'completed'
                          ? Icons.check_circle
                          : (todo.status == 'in_progress'
                                ? Icons.play_circle_outline
                                : Icons.circle_outlined),
                      size: 18,
                    ),
                    title: Text(todo.content),
                    subtitle: Text('${todo.phase}: ${todo.status}'),
                  ),
                ),
            ],
            const SizedBox(height: AppSpacing.sm),
            const Divider(),
            const SizedBox(height: AppSpacing.sm),
            Text('Notifications', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Semantics(
              label:
                  'Notify me when the agent needs an answer or finishes a run, currently ${(NotificationService.instance.userEnabled ?? false) ? 'on' : 'off'}',
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Notify on requests and run status'),
                value: NotificationService.instance.userEnabled ?? false,
                onChanged: (value) {
                  setState(() {
                    unawaited(
                      NotificationService.instance.setUserEnabled(value),
                    );
                  });
                },
              ),
            ),
            if (NotificationService.instance.disabledReason != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.notifications_off_outlined,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        NotificationService.instance.disabledReason!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
