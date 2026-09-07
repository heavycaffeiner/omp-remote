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
  DiscoveredWorkstation? _found;
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
      _found = null;
      _searchedOnce = false;
    });
  }

  void _clearSelection() {
    setState(() {
      _found = null;
      _searchedOnce = false;
    });
  }

  /// Confirms a workstation is listening and shows what it serves. One session
  /// hosts the port for the whole machine, so this is a single request and the
  /// result is informational: the code decides which session is paired.
  Future<void> _findSessions() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      setState(() => _error = 'Enter a host to search first.');
      return;
    }
    setState(() {
      _discovering = true;
      _error = null;
      _found = null;
    });
    final result = await discoverWorkstation(host);
    if (!mounted) return;
    setState(() {
      _discovering = false;
      _found = result;
      _searchedOnce = true;
    });
  }

  Future<void> _connect() async {
    final codeInput = normalizePairingCode(_codeController.text);
    if (!codeInput.isValid) {
      setState(() => _error = codeInput.error);
      return;
    }
    final code = codeInput.code!;

    final host = _hostController.text.trim();
    if (host.isEmpty) {
      setState(() => _error = 'Enter the address shown on your workstation.');
      return;
    }

    setState(() {
      _connecting = true;
      _error = null;
    });

    final outcome = await redeemPairingCodeOnHost(address: host, code: code);

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
          // The code named one session out of the roster, so it is the
          // subscribe target and not merely a label.
          agentId: outcome.agent,
          // A code is redeemed against the workstation itself, never a relay.
          isDirect: true,
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
                  agentId: outcome.agent,
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
              'Type the address and the six-character code shown by '
              '/remote-omp on your workstation. The code decides which '
              'session you connect to.',
            ),
            const SizedBox(height: 16),
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
                labelText: 'Address',
                hintText: '100.64.0.3:8788',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 12),
            Semantics(
              button: true,
              label: 'Check this address for sessions',
              child: OutlinedButton.icon(
                onPressed: _discovering ? null : _findSessions,
                icon: _discovering
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                label: Text(_discovering ? 'Checking...' : 'Check address'),
              ),
            ),
            if (_searchedOnce && !_discovering && _found == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Nothing answered at ${_hostController.text.trim()}. Check '
                  'the address, and that omp is running there.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (_found != null) ...[
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle_outline),
                  title: Text(
                    _found!.sessions.length == 1
                        ? '1 session found'
                        : '${_found!.sessions.length} sessions found',
                  ),
                  subtitle: Text(
                    _found!.sessions.map((s) => s.name).join(', '),
                  ),
                  trailing: Semantics(
                    button: true,
                    label: 'Check a different address',
                    child: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _clearSelection,
                      tooltip: 'Check a different address',
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
