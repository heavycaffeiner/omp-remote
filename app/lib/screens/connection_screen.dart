import 'package:flutter/material.dart';

import '../pairing.dart';
import '../profile_store.dart';
import '../protocol.dart';
import '../relay_client.dart';
import 'pairing_code_screen.dart';
import 'pairing_review_screen.dart';
import 'qr_scan_screen.dart';
import 'session_screen.dart';

/// Entry screen: pick a saved connection, scan a pairing QR code, enter a
/// short pairing code, or enter a relay/direct URL and token by hand. No
/// session content is ever shown here; there is nothing to display until a
/// connection is established.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({required this.profileStore, super.key});

  final ProfileStore profileStore;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  List<SavedProfile> _profiles = const [];
  bool _showManualForm = false;

  final _linkController = TextEditingController();

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
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _connectWithProfile(SavedProfile saved) async {
    final uri = Uri.tryParse(saved.url);
    if (uri == null) {
      _showError('Saved connection has an invalid URL.');
      return;
    }
    await widget.profileStore.recordUsed(saved.id);
    if (!mounted) return;
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

  /// Takes the whole `remote-omp://pair?...` link from `/remote-omp`. One
  /// paste carries the address, the token, and the role, so there is nothing
  /// left to fill in by hand.
  Future<void> _submitLink() async {
    final raw = _linkController.text.trim();
    if (raw.isEmpty) {
      _showError('Paste the link shown by /remote-omp.');
      return;
    }
    final result = PairingPayload.parse(raw);
    if (result is! PairingPayload) {
      _showError('Pairing link error: $result');
      return;
    }
    if (!mounted) return;
    _linkController.clear();
    setState(() => _showManualForm = false);
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PairingReviewScreen(
          payload: result,
          profileStore: widget.profileStore,
        ),
      ),
    );
    if (saved == true && mounted) _reloadProfiles();
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

  Future<void> _enterCode() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PairingCodeScreen(profileStore: widget.profileStore),
      ),
    );
    if (mounted) _reloadProfiles();
  }

  Future<void> _renameProfile(SavedProfile profile) async {
    final controller = TextEditingController(text: profile.label);
    final newLabel = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename connection'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = newLabel?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    await widget.profileStore.rename(profile.id, trimmed);
    _reloadProfiles();
  }

  Future<void> _deleteProfile(SavedProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove connection'),
        content: Text('Remove "${profile.label}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.profileStore.remove(profile.id);
    _reloadProfiles();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OMPRemote')),
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
                  'No saved connections yet. Pair with a QR code, enter a '
                  'code, or add one manually below.',
                ),
              ),
            for (final profile in _profiles)
              _ProfileTile(
                profile: profile,
                onTap: () => _connectWithProfile(profile),
                onRename: () => _renameProfile(profile),
                onDelete: () => _deleteProfile(profile),
              ),
            const SizedBox(height: 24),
            Semantics(
              button: true,
              label: 'Enter a pairing code',
              child: ElevatedButton.icon(
                onPressed: _enterCode,
                icon: const Icon(Icons.dialpad),
                label: const Text('Enter a code'),
              ),
            ),
            const SizedBox(height: 12),
            Semantics(
              button: true,
              label: 'Scan pairing QR code',
              child: OutlinedButton.icon(
                onPressed: _scanQr,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR to pair'),
              ),
            ),
            const SizedBox(height: 12),
            Semantics(
              button: true,
              label: _showManualForm
                  ? 'Hide the pairing link field'
                  : 'Paste a pairing link',
              child: OutlinedButton.icon(
                onPressed: () =>
                    setState(() => _showManualForm = !_showManualForm),
                icon: Icon(
                  _showManualForm ? Icons.expand_less : Icons.expand_more,
                ),
                label: const Text('Paste a link'),
              ),
            ),
            if (_showManualForm) _buildLinkForm(context),
          ],
        ),
      ),
    );
  }

  Widget _buildLinkForm(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Run /remote-omp on your workstation and paste the link it '
            'prints. It carries the address, the token, and the role.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Semantics(
            label: 'Pairing link',
            textField: true,
            child: TextField(
              controller: _linkController,
              decoration: const InputDecoration(
                labelText: 'Pairing link',
                hintText: 'remote-omp://pair?v=2&...',
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              maxLines: 2,
              minLines: 1,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitLink(),
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            button: true,
            label: 'Connect using this link',
            child: ElevatedButton(
              onPressed: _submitLink,
              child: const Text('Connect'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final SavedProfile profile;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final roleLabel = profile.role == ClientRole.control ? 'Control' : 'Viewer';
    final transportLabel = profile.isDirect ? 'Direct' : 'Relay';
    final agentLine = profile.remoteAgentId ?? profile.agentId;
    final subtitleLines = [
      '$transportLabel, role: $roleLabel',
      ?agentLine,
      ?profile.cwd,
    ];
    return Card(
      child: ListTile(
        leading: Icon(
          profile.role == ClientRole.control ? Icons.edit : Icons.visibility,
        ),
        title: Text(profile.label),
        subtitle: Text(subtitleLines.join('\n'), maxLines: 3),
        isThreeLine: true,
        onTap: onTap,
        trailing: Semantics(
          button: true,
          label: 'Connection options for ${profile.label}',
          child: PopupMenuButton<_ProfileAction>(
            tooltip: 'Connection options for ${profile.label}',
            onSelected: (action) {
              switch (action) {
                case _ProfileAction.rename:
                  onRename();
                case _ProfileAction.delete:
                  onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _ProfileAction.rename,
                child: Text('Rename'),
              ),
              PopupMenuItem(
                value: _ProfileAction.delete,
                child: Text('Remove'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _ProfileAction { rename, delete }
