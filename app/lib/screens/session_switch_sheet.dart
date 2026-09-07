import 'package:flutter/material.dart';

import '../profile_store.dart';
import '../protocol.dart';
import '../relay_client.dart';
import '../session_store.dart';

/// Lets the user switch the active session without a cold start: pick a
/// different agent in the current connection's roster (relay mode, or any
/// direct connection that happens to expose more than one), or pick a
/// different saved connection entirely.
///
/// Roster switching happens in place: it unsubscribes the old agent,
/// subscribes the new one, and resets the transcript, then the sheet
/// closes with no return value. Picking a different saved connection pops
/// the sheet with that [SavedProfile]; the caller (session_screen.dart)
/// is responsible for closing this connection and opening the new one.
class SessionSwitchSheet extends StatefulWidget {
  const SessionSwitchSheet({
    required this.relayClient,
    required this.sessionStore,
    required this.profileStore,
    required this.status,
    this.currentProfileId,
    super.key,
  });

  final RelayClient relayClient;
  final SessionStore sessionStore;
  final ProfileStore profileStore;
  final ConnectionStatus status;
  final String? currentProfileId;

  @override
  State<SessionSwitchSheet> createState() => _SessionSwitchSheetState();
}

class _SessionSwitchSheetState extends State<SessionSwitchSheet> {
  late final List<SavedProfile> _otherProfiles = widget.profileStore
      .readAll()
      .where((p) => p.id != widget.currentProfileId)
      .toList();

  void _switchAgent(AgentInfo agent) {
    if (agent.agentId == widget.status.subscribedAgentId) {
      Navigator.of(context).pop();
      return;
    }
    widget.sessionStore.resetForAgentSwitch();
    widget.relayClient.subscribeToAgent(agent.agentId);
    Navigator.of(context).pop();
  }

  Future<void> _switchProfile(SavedProfile profile) async {
    await widget.profileStore.recordUsed(profile.id);
    if (!mounted) return;
    Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final agents = widget.status.agents;
    final showRoster = agents.length > 1;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text('Switch session', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 12),
            if (showRoster) ...[
              Text('Agents in this connection', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              for (final agent in agents)
                _AgentTile(
                  agent: agent,
                  isActive: agent.agentId == widget.status.subscribedAgentId,
                  onTap: () => _switchAgent(agent),
                ),
              const SizedBox(height: 16),
            ],
            Text('Other saved connections', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            if (_otherProfiles.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No other saved connections.'),
              )
            else
              for (final profile in _otherProfiles)
                _ProfileSwitchTile(
                  profile: profile,
                  onTap: () => _switchProfile(profile),
                ),
          ],
        ),
      ),
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({
    required this.agent,
    required this.isActive,
    required this.onTap,
  });

  final AgentInfo agent;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statusText = isActive
        ? 'Active'
        : (agent.online ? 'Online' : 'Offline');
    return Semantics(
      button: true,
      selected: isActive,
      label: '${agent.name}, ${agent.agentId}, $statusText',
      child: ListTile(
        leading: Icon(isActive ? Icons.radio_button_checked : Icons.circle_outlined),
        title: Text(agent.name),
        subtitle: Text('${agent.agentId}\n${agent.cwd}\n$statusText', maxLines: 3),
        isThreeLine: true,
        onTap: onTap,
      ),
    );
  }
}

class _ProfileSwitchTile extends StatelessWidget {
  const _ProfileSwitchTile({required this.profile, required this.onTap});

  final SavedProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final transport = profile.isDirect ? 'Direct' : 'Relay';
    final roleLabel = profile.role == ClientRole.control ? 'Control' : 'Viewer';
    final agentLine = profile.agentId;
    final subtitleParts = [
      transport,
      roleLabel,
      ?agentLine,
      ?profile.cwd,
    ];
    return Semantics(
      button: true,
      label: '${profile.label}, ${subtitleParts.join(", ")}',
      child: ListTile(
        leading: Icon(profile.role == ClientRole.control ? Icons.edit : Icons.visibility),
        title: Text(profile.label),
        subtitle: Text(subtitleParts.join('\n'), maxLines: 3),
        isThreeLine: true,
        onTap: onTap,
      ),
    );
  }
}
