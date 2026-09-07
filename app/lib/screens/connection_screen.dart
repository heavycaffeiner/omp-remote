import 'package:flutter/material.dart';

import '../pairing.dart';
import '../profile_store.dart';
import '../protocol.dart';
import '../relay_client.dart';
import 'pairing_review_screen.dart';
import 'qr_scan_screen.dart';
import 'session_screen.dart';

/// Entry screen: pick a saved connection, scan a pairing QR code, or enter a
/// relay/direct URL and token by hand. No session content is ever shown
/// here; there is nothing to display until a connection is established.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({required this.profileStore, super.key});

  final ProfileStore profileStore;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  List<SavedProfile> _profiles = const [];
  bool _showManualForm = false;

  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  ClientRole _manualRole = ClientRole.control;

  @override
  void initState() {
    super.initState();
    _reloadProfiles();
  }

  void _reloadProfiles() {
    setState(() => _profiles = widget.profileStore.readAll());
  }

  @override
  void dispose() {
    _labelController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _connectWithProfile(SavedProfile saved) {
    final uri = Uri.tryParse(saved.url);
    if (uri == null) {
      _showError('Saved connection has an invalid URL.');
      return;
    }
    final profile = ConnectionProfile(
      url: uri,
      token: saved.token,
      role: saved.role,
      agentId: saved.agentId,
      name: saved.deviceName,
    );
    _openSession(profile: profile, savedProfileId: saved.id);
  }

  void _openSession({
    required ConnectionProfile profile,
    String? savedProfileId,
  }) {
    final client = RelayClient(profile: profile);
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => SessionScreen(
              relayClient: client,
              profileStore: widget.profileStore,
              savedProfileId: savedProfileId,
            ),
          ),
        )
        .then((_) => _reloadProfiles());
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submitManualForm() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      _showError('URL must be a valid ws:// or wss:// address.');
      return;
    }
    final label = _labelController.text.trim().isEmpty
        ? uri.host
        : _labelController.text.trim();
    final saved = SavedProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      label: label,
      url: uri.toString(),
      token: _tokenController.text,
      role: _manualRole,
    );
    await widget.profileStore.upsert(saved);
    if (!mounted) return;
    _labelController.clear();
    _urlController.clear();
    _tokenController.clear();
    setState(() => _showManualForm = false);
    _reloadProfiles();
    _connectWithProfile(saved);
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QrScanScreen()),
    );
    if (raw == null || !mounted) return;
    final result = PairingPayload.parse(raw);
    if (result is PairingPayload) {
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => PairingReviewScreen(
            payload: result,
            profileStore: widget.profileStore,
          ),
        ),
      );
      if (saved == true) _reloadProfiles();
    } else {
      _showError('Pairing link error: $result');
    }
  }

  Future<void> _deleteProfile(SavedProfile profile) async {
    await widget.profileStore.remove(profile.id);
    _reloadProfiles();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Remote-OMP')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Semantics(
              header: true,
              child: Text(
                'Saved connections',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            if (_profiles.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No saved connections yet. Pair with a QR code or add one manually below.',
                ),
              ),
            for (final profile in _profiles)
              _ProfileTile(
                profile: profile,
                onTap: () => _connectWithProfile(profile),
                onDelete: () => _deleteProfile(profile),
              ),
            const SizedBox(height: 24),
            Semantics(
              button: true,
              label: 'Scan pairing QR code',
              child: ElevatedButton.icon(
                onPressed: _scanQr,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR to pair'),
              ),
            ),
            const SizedBox(height: 12),
            Semantics(
              button: true,
              label: _showManualForm
                  ? 'Hide manual connection form'
                  : 'Enter connection details manually',
              child: OutlinedButton.icon(
                onPressed: () =>
                    setState(() => _showManualForm = !_showManualForm),
                icon: Icon(
                  _showManualForm ? Icons.expand_less : Icons.expand_more,
                ),
                label: const Text('Enter manually'),
              ),
            ),
            if (_showManualForm) _buildManualForm(context),
          ],
        ),
      ),
    );
  }

  Widget _buildManualForm(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _labelController,
              decoration: const InputDecoration(labelText: 'Name (optional)'),
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'Relay or direct URL',
                hintText: 'wss://relay.example.com or ws://100.64.0.3:8788',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'URL is required'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _tokenController,
              decoration: const InputDecoration(labelText: 'Client token'),
              obscureText: true,
              keyboardType: TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              validator: (value) =>
                  (value == null || value.isEmpty) ? 'Token is required' : null,
            ),
            const SizedBox(height: 12),
            Semantics(
              label: 'Expected connection role',
              child: SegmentedButton<ClientRole>(
                segments: const [
                  ButtonSegment(
                    value: ClientRole.control,
                    label: Text('Control'),
                    icon: Icon(Icons.edit),
                  ),
                  ButtonSegment(
                    value: ClientRole.viewer,
                    label: Text('Viewer'),
                    icon: Icon(Icons.visibility),
                  ),
                ],
                selected: {_manualRole},
                onSelectionChanged: (selection) =>
                    setState(() => _manualRole = selection.first),
              ),
            ),
            const SizedBox(height: 16),
            Semantics(
              button: true,
              label: 'Save and connect',
              child: ElevatedButton(
                onPressed: _submitManualForm,
                child: const Text('Save and connect'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.onTap,
    required this.onDelete,
  });

  final SavedProfile profile;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final roleLabel = profile.role == ClientRole.control ? 'Control' : 'Viewer';
    return Card(
      child: ListTile(
        leading: Icon(
          profile.role == ClientRole.control ? Icons.edit : Icons.visibility,
        ),
        title: Text(profile.label),
        subtitle: Text(
          '${profile.url}\nExpected role: $roleLabel',
          maxLines: 2,
        ),
        isThreeLine: true,
        onTap: onTap,
        trailing: Semantics(
          button: true,
          label: 'Remove ${profile.label}',
          child: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
            tooltip: 'Remove ${profile.label}',
          ),
        ),
      ),
    );
  }
}
