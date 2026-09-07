import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';

/// Read-only reference for the session's slash commands (from the
/// `commands` command). The extension API exposes no way to invoke a slash
/// command remotely, so this screen only lists what exists; it does not
/// offer to run anything. Any command must be typed at the workstation.
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
    final filtered = _filter.isEmpty
        ? _commands
        : _commands
              .where(
                (c) => c.name.toLowerCase().contains(_filter.toLowerCase()),
              )
              .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Slash commands')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  'These are the slash commands available in this session. '
                  'The app has no way to run one remotely: type it at the '
                  'workstation keyboard.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
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
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Could not load commands: $_error'),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _load,
                          child: const Text('Retry'),
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
                          return Semantics(
                            label:
                                '/${command.name}${command.description != null ? ', ${command.description}' : ''}. Run this at the workstation, not from the app.',
                            child: ListTile(
                              leading: const Icon(Icons.terminal),
                              title: Text('/${command.name}'),
                              subtitle: command.description != null
                                  ? Text(command.description!)
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
