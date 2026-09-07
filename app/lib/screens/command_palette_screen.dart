import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';

/// Lists the session's real slash commands (from the `commands` command) and
/// invokes one via `run_command`. This is what makes the rest of omp's
/// surface reachable without the app hardcoding every feature.
class CommandPaletteScreen extends StatefulWidget {
  const CommandPaletteScreen({required this.relayClient, super.key});

  final RelayClient relayClient;

  @override
  State<CommandPaletteScreen> createState() => _CommandPaletteScreenState();
}

class _CommandPaletteScreenState extends State<CommandPaletteScreen> {
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

  Future<void> _runCommand(SlashCommandInfo command) async {
    try {
      await widget.relayClient.sendCommand(
        CommandName.runCommand,
        args: {'name': command.name},
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Command failed: $e')));
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
      appBar: AppBar(title: const Text('Command palette')),
      body: SafeArea(
        child: Column(
          children: [
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
                            button: true,
                            label:
                                'Run /${command.name}${command.description != null ? ', ${command.description}' : ''}',
                            child: ListTile(
                              leading: const Icon(Icons.terminal),
                              title: Text('/${command.name}'),
                              subtitle: command.description != null
                                  ? Text(command.description!)
                                  : null,
                              onTap: () => _runCommand(command),
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
