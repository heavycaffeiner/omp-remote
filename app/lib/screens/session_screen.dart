import 'package:flutter/material.dart';

import '../profile_store.dart';
import '../protocol.dart';
import '../relay_client.dart';
import '../session_store.dart';
import '../widgets/interactive_request_card.dart';
import '../widgets/state_header.dart';
import '../widgets/transcript_view.dart';
import 'command_palette_screen.dart';
import 'session_menu_sheet.dart';

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

class _SessionScreenState extends State<SessionScreen> {
  late final SessionStore _sessionStore = SessionStore(
    relayClient: widget.relayClient,
  );
  final TextEditingController _promptController = TextEditingController();
  ConnectionStatus _status = const ConnectionStatus(
    phase: ConnectionPhase.disconnected,
  );
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.relayClient.statusStream.listen((status) {
      if (mounted) setState(() => _status = status);
    });
    _sessionStore.addListener(_onStoreChanged);
    widget.relayClient.connect();
  }

  void _onStoreChanged() {
    final lateError = _sessionStore.lastLateAnswerError;
    if (lateError != null) {
      _sessionStore.lastLateAnswerError = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Answer not accepted: ${lateError.message}')),
      );
    }
    setState(() {});
  }

  bool get _canControl =>
      _status.role == ClientRole.control &&
      _status.phase == ConnectionPhase.connected;

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final streaming = _sessionStore.state?.streaming ?? false;
    final pending = _sessionStore.pendingRequests;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote-OMP'),
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
            StateHeader(status: _status, state: _sessionStore.state),
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
    final disabledReason = _status.role == ClientRole.viewer
        ? 'Read-only connection: sending is disabled.'
        : (_status.phase != ConnectionPhase.connected
              ? 'Not connected.'
              : null);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (disabledReason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(disabledReason, style: theme.textTheme.bodySmall),
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
                    maxLines: 5,
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
              const SizedBox(width: 8),
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
              const SizedBox(width: 4),
              Semantics(
                button: true,
                label: streaming
                    ? 'Abort current turn'
                    : 'Abort (nothing streaming)',
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
