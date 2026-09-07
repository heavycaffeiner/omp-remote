import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';
import '../session_store.dart';

/// Frequently used session settings, reachable directly rather than through
/// the command palette: model picker, thinking level, compaction, session
/// lifecycle, and todos. Disabled entirely for a viewer connection.
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
    final state = widget.sessionStore.state;
    final disabled = !widget.canControl || _busy;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Session', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (_busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (!widget.canControl)
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 8),
                child: Text('Read-only connection: settings are disabled.'),
              ),
            const Divider(),
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
            const SizedBox(height: 12),
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
            const SizedBox(height: 8),
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
            const SizedBox(height: 8),
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
              const SizedBox(height: 16),
              Text('Todos', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
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
          ],
        ),
      ),
    );
  }
}
