import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';
import '../theme.dart';

/// Every slash command the session knows, from the `commands` command.
/// A command whose work the plugin can also do carries a `remote` wire
/// command; tapping it runs that instead of opening the workstation picker.
/// The rest are reference only: the extension API exposes no way to invoke a
/// slash command, so they have to be typed at the workstation.
class CommandReferenceScreen extends StatefulWidget {
  const CommandReferenceScreen({required this.relayClient, super.key});

  final RelayClient relayClient;

  @override
  State<CommandReferenceScreen> createState() => _CommandReferenceScreenState();
}

class _CommandReferenceScreenState extends State<CommandReferenceScreen> {
  List<SlashCommandInfo> _commands = const [];
  bool _loading = true;
  String? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.relayClient.sendCommand(
        CommandName.commandsList,
      );
      final map = asMap(data);
      setState(() {
        _commands = SlashCommandInfo.listFromJson(map['commands']);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _filter.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _commands
        : _commands
              .where(
                (c) =>
                    c.name.toLowerCase().contains(query) ||
                    (c.description?.toLowerCase().contains(query) ?? false),
              )
              .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Slash commands')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                0,
              ),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  'Every slash command this session knows: built-ins plus '
                  'extension, prompt, and skill commands. The app cannot run '
                  'any of them: type it at the workstation keyboard.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Filter commands',
                  prefixIcon: Icon(Icons.search),
                ),
                textCapitalization: TextCapitalization.none,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _filter = value),
              ),
            ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text('Could not load commands: $_error'),
                        const SizedBox(height: AppSpacing.md),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (!_loading && _error == null)
              Expanded(
                child: filtered.isEmpty
                    ? const Center(child: Text('No commands match.'))
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final command = filtered[index];
                          final runnable = command.remote != null;
                          final where = runnable
                              ? 'Runs from the app.'
                              : 'Runs at the workstation only.';
                          final label = command.description != null
                              ? '/${command.name}, ${command.description}'
                              : '/${command.name}';
                          return Semantics(
                            button: runnable,
                            label: '$label. From ${command.source}. $where',
                            child: ListTile(
                              leading: Icon(_iconFor(command.source)),
                              title: Text('/${command.name}'),
                              subtitle: command.description != null
                                  ? Text(command.description!)
                                  : null,
                              trailing: runnable
                                  ? const Icon(Icons.play_circle_outline)
                                  : Text(
                                      command.source,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                              onTap: runnable
                                  ? () => Navigator.of(
                                      context,
                                    ).pop(command.remote)
                                  : null,
                            ),
                          );
                        },
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

IconData _iconFor(String source) => switch (source) {
  'builtin' => Icons.terminal,
  'extension' => Icons.extension_outlined,
  'prompt' => Icons.description_outlined,
  'skill' => Icons.auto_awesome_outlined,
  _ => Icons.chevron_right,
};
