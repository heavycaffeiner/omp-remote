import 'dart:async';

import 'package:flutter/material.dart';

import '../notification_rules.dart';
import '../notifications.dart';
import '../profile_store.dart';
import '../protocol.dart';
import '../relay_client.dart';
import '../session_store.dart';
import '../theme.dart';
import '../widgets/interactive_request_card.dart';
import '../widgets/state_header.dart';
import '../widgets/transcript_view.dart';
import 'command_palette_screen.dart';
import 'session_menu_sheet.dart';
import 'session_switch_sheet.dart';

/// Live session view: transcript, state header, prompt composer, abort
/// button, and any pending interactive request. Every mutating affordance
/// is disabled (not hidden) with an explicit text reason for a viewer
/// connection.
class SessionScreen extends StatefulWidget {
  const SessionScreen({
    required this.relayClient,
    required this.profileStore,
    this.savedProfileId,
    super.key,
  });

  final RelayClient relayClient;
  final ProfileStore profileStore;
  final String? savedProfileId;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  late final SessionStore _sessionStore = SessionStore(
    relayClient: widget.relayClient,
  );
  final TextEditingController _promptController = TextEditingController();
  ConnectionStatus _status = const ConnectionStatus(
    phase: ConnectionPhase.disconnected,
  );
  bool _sending = false;
  bool _appInForeground = true;
  StreamSubscription<ServerFrame>? _notificationSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.relayClient.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _status = status);
      _updateNotificationForeground();
    });
    _sessionStore.addListener(_onStoreChanged);
    widget.relayClient.connect();
    // Ask for the notification permission once the user has actually
    // connected, not at cold start; fire-and-forget, the result only
    // affects whether notifications can show later.
    unawaited(NotificationService.instance.requestPermission());
    _notificationSubscription = NotificationService.instance.attachToClient(
      widget.relayClient,
      sessionLabel: _sessionLabelFor,
    );
    NotificationService.instance.onNotificationTap = _handleNotificationTap;
    _updateNotificationForeground();
  }

  String _sessionLabelFor(String agentId) {
    final agent = _status.agents.where((a) => a.agentId == agentId).firstOrNull;
    return _sessionStore.state?.sessionName ?? agent?.name ?? agentId;
  }

  /// Switches the session in place when a notification for a different
  /// agent (in this connection's roster) is tapped while this screen is
  /// already open. A tap that names an agent outside this roster is a
  /// cold-start case handled elsewhere.
  void _handleNotificationTap(NotificationPayload payload) {
    if (!mounted || payload.agentId == _status.subscribedAgentId) return;
    final agent = _status.agents
        .where((a) => a.agentId == payload.agentId)
        .firstOrNull;
    if (agent == null) return;
    _sessionStore.resetForAgentSwitch();
    widget.relayClient.subscribeToAgent(agent.agentId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    _updateNotificationForeground();
  }

  void _updateNotificationForeground() {
    final pending = _sessionStore.pendingRequests;
    NotificationService.instance.updateForeground(
      appInForeground: _appInForeground,
      agentId: _status.subscribedAgentId,
      requestId: pending.isEmpty ? null : pending.last.id,
    );
  }

  void _onStoreChanged() {
    final lateError = _sessionStore.lastLateAnswerError;
    if (lateError != null) {
      _sessionStore.lastLateAnswerError = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Answer not accepted: ${lateError.message}')),
      );
    }
    _updateNotificationForeground();
    setState(() {});
  }

  bool get _canControl =>
      _status.role == ClientRole.control &&
      _status.phase == ConnectionPhase.connected;

  /// Active session name and agent id, formatted as one line of text, for
  /// the state header. Found by `subscribedAgentId` on either transport; a
  /// direct connection reaches every session on the workstation too, so a
  /// lone agent is the only case that needs no subscription to name.
  String? get _activeSessionLabel {
    final agents = _status.agents;
    if (agents.isEmpty) return null;
    final subscribed = _status.subscribedAgentId;
    final AgentInfo? agent;
    if (subscribed != null) {
      agent = agents.where((a) => a.agentId == subscribed).firstOrNull;
    } else {
      agent = agents.length == 1 ? agents.first : null;
    }
    if (agent == null) return null;
    final sessionName = _sessionStore.state?.sessionName;
    return '${sessionName ?? agent.name} (${agent.agentId})';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.instance.onNotificationTap = null;
    unawaited(_notificationSubscription?.cancel());
    _sessionStore.removeListener(_onStoreChanged);
    _sessionStore.dispose();
    widget.relayClient.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _sendPrompt() async {
    final text = _promptController.text.trim();
    if (text.isEmpty || !_canControl) return;
    setState(() => _sending = true);
    try {
      await widget.relayClient.sendCommand(
        CommandName.prompt,
        args: {'text': text},
      );
      _promptController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _abort() async {
    try {
      await widget.relayClient.sendCommand(CommandName.abort);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Abort failed: $e')));
      }
    }
  }

  void _openMenu() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SessionMenuSheet(
        relayClient: widget.relayClient,
        sessionStore: _sessionStore,
        canControl: _canControl,
      ),
    );
  }

  void _openCommandReference() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CommandReferenceScreen(relayClient: widget.relayClient),
      ),
    );
  }

  void _openSwitcher() async {
    final target = await showModalBottomSheet<SavedProfile>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SessionSwitchSheet(
        relayClient: widget.relayClient,
        sessionStore: _sessionStore,
        profileStore: widget.profileStore,
        currentProfileId: widget.savedProfileId,
        status: _status,
      ),
    );
    if (target == null || !mounted) return;
    final uri = Uri.tryParse(target.url);
    if (uri == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SessionScreen(
          relayClient: RelayClient(
            profile: ConnectionProfile(
              url: uri,
              token: target.token,
              role: target.role,
              agentId: target.agentId,
              name: target.deviceName,
            ),
          ),
          profileStore: widget.profileStore,
          savedProfileId: target.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final streaming = _sessionStore.state?.streaming ?? false;
    final pending = _sessionStore.pendingRequests;

    return Scaffold(
      appBar: AppBar(
        title: const Text('OMPRemote'),
        actions: [
          if (_canControl)
            Semantics(
              button: true,
              label: 'View slash command reference',
              child: IconButton(
                icon: const Icon(Icons.terminal),
                onPressed: _openCommandReference,
                tooltip: 'Slash command reference',
              ),
            ),
          Semantics(
            button: true,
            label: 'Switch session',
            child: IconButton(
              icon: const Icon(Icons.swap_horiz),
              onPressed: _openSwitcher,
              tooltip: 'Switch session',
            ),
          ),
          Semantics(
            button: true,
            label: 'Open session menu',
            child: IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: _openMenu,
              tooltip: 'Session menu',
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            StateHeader(
              status: _status,
              state: _sessionStore.state,
              activeSessionLabel: _activeSessionLabel,
            ),
            if (pending.isNotEmpty && _canControl)
              InteractiveRequestCard(
                pending: pending.last,
                onAnswer: (response) =>
                    _sessionStore.answerRequest(pending.last.id, response),
              ),
            Expanded(child: TranscriptView(sessionStore: _sessionStore)),
            _buildComposer(context, streaming),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer(BuildContext context, bool streaming) {
    final theme = Theme.of(context);
    final isViewer = _status.role == ClientRole.viewer;
    final notConnected = _status.phase != ConnectionPhase.connected;
    final sendDisabledReason = isViewer
        ? 'Sending is disabled: read-only connection.'
        : (notConnected ? 'Sending is disabled: not connected.' : null);
    final abortDisabledReason = !_canControl
        ? null // covered by sendDisabledReason already
        : (!streaming ? 'Abort is disabled: nothing is currently streaming.' : null);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (sendDisabledReason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Row(
                children: [
                  Icon(
                    isViewer ? Icons.visibility : Icons.cloud_off,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      sendDisabledReason,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (abortDisabledReason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                abortDisabledReason,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Semantics(
                  label: 'Prompt text',
                  textField: true,
                  child: TextField(
                    controller: _promptController,
                    enabled: _canControl && !_sending,
                    minLines: 1,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Send a message to the agent',
                    ),
                    onSubmitted: (_) => _canControl ? _sendPrompt() : null,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Semantics(
                button: true,
                label: 'Send prompt',
                enabled: _canControl && !_sending,
                child: IconButton.filled(
                  onPressed: (_canControl && !_sending) ? _sendPrompt : null,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Semantics(
                button: true,
                label: streaming
                    ? 'Abort current turn'
                    : 'Abort, disabled: nothing streaming',
                enabled: _canControl && streaming,
                child: IconButton.filledTonal(
                  onPressed: (_canControl && streaming) ? _abort : null,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

