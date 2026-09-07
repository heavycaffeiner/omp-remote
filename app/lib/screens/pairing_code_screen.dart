import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../discovery/direct_discovery.dart';
import '../discovery/pairing_code.dart';
import '../pairing.dart';
import '../profile_store.dart';
import '../relay_client.dart';
import 'session_screen.dart';

/// Redeems a six-character pairing code (docs/protocol.md, "Pairing
/// codes"). The user either discovers live sessions on a host first and
/// picks one, pinning its host and port so only the code remains to type,
/// or types the host and code directly and lets every port on that host be
/// tried for the code.
class PairingCodeScreen extends StatefulWidget {
  const PairingCodeScreen({required this.profileStore, super.key});

  final ProfileStore profileStore;

  @override
  State<PairingCodeScreen> createState() => _PairingCodeScreenState();
}

class _PairingCodeScreenState extends State<PairingCodeScreen> {
  final _hostController = TextEditingController();
  final _codeController = TextEditingController();
  List<String> _recentHosts = const [];
  List<DiscoveredSession> _discovered = const [];
  DiscoveredSession? _selected;
  bool _discovering = false;
  bool _connecting = false;
  bool _searchedOnce = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _recentHosts = widget.profileStore.readRecentHosts();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _pickRecentHost(String host) {
    setState(() {
      _hostController.text = host;
      _selected = null;
      _discovered = const [];
      _searchedOnce = false;
    });
  }

  void _clearSelection() {
    setState(() {
      _selected = null;
      _discovered = const [];
      _searchedOnce = false;
    });
  }

  Future<void> _findSessions() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      setState(() => _error = 'Enter a host to search first.');
      return;
    }
    setState(() {
      _discovering = true;
      _error = null;
      _discovered = const [];
    });
    final results = await discoverSessions(host);
    if (!mounted) return;
    setState(() {
      _discovering = false;
      _discovered = results;
      _searchedOnce = true;
    });
  }

  void _selectSession(DiscoveredSession session) {
    setState(() => _selected = session);
  }

  Future<void> _connect() async {
    final codeInput = normalizePairingCode(_codeController.text);
    if (!codeInput.isValid) {
      setState(() => _error = codeInput.error);
      return;
    }
    final code = codeInput.code!;

    final selected = _selected;
    final host = selected?.host ?? _hostController.text.trim();
    if (selected == null && host.isEmpty) {
      setState(() => _error = 'Enter a host, or pick a discovered session.');
      return;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });

    final outcome = selected != null
        ? await redeemPairingCode(host: selected.host, port: selected.port, code: code)
        : await redeemPairingCodeOnHost(host: host, code: code);

    if (!mounted) return;
    setState(() => _connecting = false);

    switch (outcome) {
      case PairingCodeSuccess():
        await widget.profileStore.addRecentHost(host);
        final saved = SavedProfile(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          label: outcome.name,
          url: outcome.url.toString(),
          token: outcome.token,
          role: outcome.role,
          cwd: outcome.cwd,
          remoteAgentId: outcome.agent,
          lastUsedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await widget.profileStore.upsert(saved);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => SessionScreen(
              relayClient: RelayClient(
                profile: ConnectionProfile(
                  url: outcome.url,
                  token: outcome.token,
                  role: outcome.role,
                  name: outcome.name,
                ),
              ),
              profileStore: widget.profileStore,
              savedProfileId: saved.id,
            ),
          ),
        );
      case PairingCodeRejected():
        setState(() => _error = outcome.message);
      case PairingCodeNetworkError():
        setState(
          () => _error =
              'Could not reach ${outcome.host}:${outcome.port}: ${outcome.reason}',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Enter a code')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Type the host running the session, then the six-character '
              'code shown by /remote-omp. Or find sessions on the host '
              'first and pick one, so only the code remains to type.',
            ),
            const SizedBox(height: 16),
            if (_selected == null) ...[
              if (_recentHosts.isNotEmpty) ...[
                Text('Recent hosts', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final host in _recentHosts)
                      ActionChip(
                        label: Text(host),
                        onPressed: () => _pickRecentHost(host),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  hintText: '100.64.0.3 or my-laptop.local',
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 12),
              Semantics(
                button: true,
                label: 'Find sessions on this host',
                child: OutlinedButton.icon(
                  onPressed: _discovering ? null : _findSessions,
                  icon: _discovering
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(_discovering ? 'Searching...' : 'Find sessions'),
                ),
              ),
              if (_searchedOnce && !_discovering && _discovered.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'No sessions found on ${_hostController.text.trim()}.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (_discovered.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Found sessions', style: theme.textTheme.labelLarge),
                for (final session in _discovered)
                  Semantics(
                    button: true,
                    label:
                        '${session.name}, ${session.cwd}, port ${session.port}',
                    child: ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(session.name),
                      subtitle: Text('${session.cwd}\nPort ${session.port}'),
                      isThreeLine: true,
                      onTap: () => _selectSession(session),
                    ),
                  ),
              ],
            ] else ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(_selected!.name),
                  subtitle: Text(
                    '${_selected!.cwd}\n${_selected!.host}:${_selected!.port}',
                  ),
                  isThreeLine: true,
                  trailing: Semantics(
                    button: true,
                    label: 'Change host or session',
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _clearSelection,
                      tooltip: 'Change host or session',
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Semantics(
              label: 'Pairing code, six characters',
              textField: true,
              child: TextField(
                controller: _codeController,
                decoration: const InputDecoration(
                  labelText: 'Pairing code',
                  hintText: 'HZE6VD',
                ),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 4,
                ),
                textAlign: TextAlign.center,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 6,
                inputFormatters: [UpperCaseTextFormatter()],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _connecting ? null : _connect(),
              ),
            ),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ),
            Semantics(
              button: true,
              label: 'Connect with this code',
              child: ElevatedButton(
                onPressed: _connecting ? null : _connect,
                child: _connecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Forces pairing code entry to uppercase as the user types, matching the
/// alphabet the server issues codes from and what gets sent on submit.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
