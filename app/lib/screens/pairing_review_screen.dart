import 'package:flutter/material.dart';

import '../pairing.dart';
import '../profile_store.dart';
import '../protocol.dart';
import '../relay_client.dart';
import '../theme.dart';
import 'session_screen.dart';

/// Shows the parsed pairing payload for confirmation before saving and
/// connecting. The token itself is never rendered; only its presence is.
class PairingReviewScreen extends StatefulWidget {
  const PairingReviewScreen({
    required this.payload,
    required this.profileStore,
    super.key,
  });

  final PairingPayload payload;
  final ProfileStore profileStore;

  @override
  State<PairingReviewScreen> createState() => _PairingReviewScreenState();
}

class _PairingReviewScreenState extends State<PairingReviewScreen> {
  late final TextEditingController _labelController = TextEditingController(
    text: widget.payload.name ?? widget.payload.url.host,
  );

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _saveAndConnect() async {
    final payload = widget.payload;
    final label = _labelController.text.trim().isEmpty
        ? payload.url.host
        : _labelController.text.trim();
    final saved = SavedProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      label: label,
      url: payload.url.toString(),
      token: payload.token,
      role: payload.role,
      agentId: payload.agentId,
      deviceName: payload.name,
      isDirect: payload.transport == PairingTransport.direct,
    );
    await widget.profileStore.upsert(saved);
    if (!mounted) return;

    final connection = ConnectionProfile(
      url: payload.url,
      token: payload.token,
      role: payload.role,
      agentId: payload.agentId,
      name: payload.name,
    );
    final client = RelayClient(profile: connection);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SessionScreen(
          relayClient: client,
          profileStore: widget.profileStore,
          savedProfileId: saved.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.payload;
    final transport = payload.transport == PairingTransport.direct
        ? 'Direct (local network)'
        : 'Relayed';
    final roleLabel = payload.role == ClientRole.control
        ? 'Control (can send prompts)'
        : 'Viewer (read-only)';
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm pairing')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            _InfoRow(label: 'Transport', value: transport),
            _InfoRow(label: 'URL', value: payload.url.toString()),
            _InfoRow(label: 'Role', value: roleLabel),
            _InfoRow(label: 'Session', value: payload.agentId),
            const _InfoRow(label: 'Token', value: 'Received (hidden)'),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Save this connection as',
              ),
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    label: 'Cancel pairing',
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Semantics(
                    button: true,
                    label: 'Save this connection and connect',
                    child: FilledButton(
                      onPressed: _saveAndConnect,
                      child: const Text('Save and connect'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label, style: theme.textTheme.labelSmall),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}
