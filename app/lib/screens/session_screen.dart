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
import '../widgets/queue_panel.dart';
import '../widgets/state_header.dart';
import '../widgets/subagent_panel.dart';
import '../widgets/todo_panel.dart';
import '../widgets/transcript_view.dart';
import 'command_sheet.dart';
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
    // The client falls back across every address the link carried; the one
    // that answered is where the next connect should start.
    final savedId = widget.savedProfileId;
    if (savedId != null) {
      widget.relayClient.onAddressChanged = (origin) => unawaited(
        widget.profileStore.recordWorkingAddress(savedId, origin.toString()),
      );
    }
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
    final resumed = state == AppLifecycleState.resumed;
    final returning = resumed && !_appInForeground;
    _appInForeground = resumed;
    _updateNotificationForeground();
    // Coming back to the app is when a stale connection has to be noticed,
    // not twenty seconds later when a ping finally fails.
    if (returning) widget.relayClient.resume();
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
    final busy = !(_sessionStore.state?.streaming == false);
    setState(() => _sending = true);
    try {
      await widget.relayClient.sendCommand(
        CommandName.prompt,
        args: {'text': text},
      );
      // Sent while the agent was working, so it went into omp's queue rather
      // than starting a turn. Remembering it here is the only way the panel
      // can show what is waiting: the queue's contents are not readable.
      if (busy) _sessionStore.noteQueuedPrompt(text);
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

  void _openCommands() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CommandSheet(
        relayClient: widget.relayClient,
        sessionStore: _sessionStore,
        canControl: _canControl,
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
              label: 'Open commands',
              child: IconButton(
                icon: const Icon(Icons.terminal),
                onPressed: _openCommands,
                tooltip: 'Commands',
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
              onRetry: () => unawaited(widget.relayClient.retryNow()),
            ),
            if (pending.isNotEmpty && _canControl)
              InteractiveRequestCard(
                pending: pending.last,
                onAnswer: (response) =>
                    _sessionStore.answerRequest(pending.last.id, response),
              ),
            if (_sessionStore.subagents.isNotEmpty)
              SubagentPanel(subagents: _sessionStore.subagents),
            TodoPanel(todos: _sessionStore.todos),
            Expanded(child: TranscriptView(sessionStore: _sessionStore)),
            QueuePanel(
              queued: _sessionStore.state?.queued ?? 0,
              sent: _sessionStore.sentQueue,
            ),
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
    // Why sending is blocked belongs in the field the user is looking at,
    // not on a row of its own above it.
    final hint = isViewer
        ? 'Read-only connection, sending is disabled'
        : (notConnected
              ? 'Not connected, sending is disabled'
              : 'Message the agent');
    final queued = _sessionStore.state?.queued ?? 0;

    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Semantics(
                    label: 'Prompt text. $hint',
                    textField: true,
                    child: TextField(
                      controller: _promptController,
                      enabled: _canControl && !_sending,
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(hintText: hint),
                      onSubmitted: (_) => _canControl ? _sendPrompt() : null,
                    ),
                  ),
                ),
                // Interrupting only exists while there is a turn to
                // interrupt; a permanently disabled stop button reads as a
                // control that does nothing.
                if (streaming && _canControl) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Semantics(
                    button: true,
                    label: 'Abort the current turn',
                    child: IconButton.filledTonal(
                      onPressed: _abort,
                      tooltip: 'Abort the current turn',
                      style: IconButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      icon: const Icon(Icons.stop),
                    ),
                  ),
                ],
                const SizedBox(width: AppSpacing.xs),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _promptController,
                  builder: (context, value, _) {
                    final ready =
                        _canControl &&
                        !_sending &&
                        value.text.trim().isNotEmpty;
                    // The queue depth rides the button that filled it rather
                    // than spending a whole row on one integer.
                    return Badge(
                      isLabelVisible: queued > 0,
                      label: Text('$queued'),
                      child: Semantics(
                        button: true,
                        label: queued > 0
                            ? 'Send prompt, $queued already queued'
                            : 'Send prompt. $hint',
                        enabled: ready,
                        child: IconButton.filled(
                          onPressed: ready ? _sendPrompt : null,
                          tooltip: 'Send prompt',
                          icon: _sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.arrow_upward),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
