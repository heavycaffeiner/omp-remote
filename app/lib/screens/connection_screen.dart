import 'package:flutter/material.dart';

import '../pairing.dart';
import '../profile_store.dart';
import '../protocol.dart';
import '../relay_client.dart';
import '../theme.dart';
import 'pairing_code_screen.dart';
import 'pairing_review_screen.dart';
import 'pairing_sheet.dart';
import 'qr_scan_screen.dart';
import 'session_screen.dart';

/// Entry screen: pick a saved connection, scan a pairing QR code, paste the
/// pairing link, or enter a short pairing code. No session content is ever
/// shown here; there is nothing to display until a connection is
/// established.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({required this.profileStore, super.key});

  final ProfileStore profileStore;

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  List<SavedProfile> _profiles = const [];

  /// Id of the saved profile currently being connected to, or null if none.
  /// Only one row can be mid-connect at a time; the row shows a spinner in
  /// place of its avatar and does not accept another tap.
  String? _connectingId;

  @override
  void initState() {
    super.initState();
    // Every write notifies, so the list is right however it changed: a deep
    // link pairs without this screen ever being on top.
    widget.profileStore.addListener(_reloadProfiles);
    _profiles = widget.profileStore.readAll();
  }

  void _reloadProfiles() {
    if (!mounted) return;
    setState(() => _profiles = widget.profileStore.readAll());
  }

  @override
  void dispose() {
    widget.profileStore.removeListener(_reloadProfiles);
    super.dispose();
  }

  Future<void> _connectWithProfile(SavedProfile saved) async {
    if (_connectingId != null) return;
    final uri = Uri.tryParse(saved.url);
    if (uri == null) {
      _showError('Saved connection has an invalid URL.');
      return;
    }
    setState(() => _connectingId = saved.id);
    await widget.profileStore.recordUsed(saved.id);
    if (!mounted) return;
    final profile = ConnectionProfile(
      url: uri,
      alternates: [
        for (final address in saved.alternates) ?Uri.tryParse(address),
      ],
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
        .then((_) {
          if (!mounted) return;
          setState(() => _connectingId = null);
          _reloadProfiles();
        });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Takes the whole `remote-omp://pair?...` link from `/remote`. One
  /// paste carries the address, the token, the role, and which session to
  /// open, so there is nothing left to fill in by hand.
  Future<void> _submitLink(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      _showError('Paste the link shown by /remote.');
      return;
    }
    final result = PairingPayload.parse(trimmed);
    if (result is! PairingPayload) {
      _showError('Pairing link error: $result');
      return;
    }
    if (!mounted) return;
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

  Future<void> _openPairingSheet() async {
    final choice = await PairingSheet.show(context);
    if (!mounted || choice == null) return;
    switch (choice) {
      case ScanQrChoice():
        await _scanQr();
      case EnterCodeChoice():
        await _enterCode();
      case PasteLinkChoice(link: final link):
        await _submitLink(link);
    }
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
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
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
      appBar: AppBar(
        title: Semantics(header: true, child: const Text('OMPRemote')),
      ),
      body: SafeArea(
        child: _profiles.isEmpty
            ? _buildEmptyState(context)
            : _buildProfileList(context),
      ),
      floatingActionButton: _profiles.isEmpty
          ? null
          : Semantics(
              button: true,
              label: 'Add a connection',
              child: FloatingActionButton.extended(
                onPressed: _openPairingSheet,
                icon: const Icon(Icons.add),
                label: const Text('Add a connection'),
              ),
            ),
    );
  }

  Widget _buildProfileList(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xxl,
      ),
      children: [
        for (final profile in _profiles)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _ProfileTile(
              profile: profile,
              connecting: _connectingId == profile.id,
              onTap: () => _connectWithProfile(profile),
              onRename: () => _renameProfile(profile),
              onDelete: () => _deleteProfile(profile),
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.phonelink_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'No connections yet',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Run /remote on your workstation. It prints a QR code '
              'and a link that pair this device with that session.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            Semantics(
              button: true,
              label: 'Add a connection',
              child: FilledButton.icon(
                onPressed: _openPairingSheet,
                icon: const Icon(Icons.add),
                label: const Text('Add a connection'),
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
    required this.connecting,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final SavedProfile profile;
  final bool connecting;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isControl = profile.role == ClientRole.control;
    final roleLabel = isControl ? 'Control' : 'Viewer';
    final transportLabel = profile.isDirect ? 'Direct' : 'Relay';
    final cwdParts = profile.cwd?.split('/').where((part) => part.isNotEmpty);
    final cwdBase = cwdParts == null || cwdParts.isEmpty ? null : cwdParts.last;

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          child: connecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  isControl ? Icons.edit_outlined : Icons.visibility_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
        ),
        title: Text(
          profile.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            _MetaChip(transportLabel),
            const SizedBox(width: AppSpacing.xs),
            _MetaChip(roleLabel),
            if (cwdBase != null) ...[
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  cwdBase,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
        onTap: connecting ? null : onTap,
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

/// One word of connection metadata. A chip rather than a separator-joined
/// string so the transport and the role stay legible when the row narrows.
class _MetaChip extends StatelessWidget {
  const _MetaChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.extraSmall),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

enum _ProfileAction { rename, delete }
