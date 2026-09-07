// Builds the transcript and running session state from the event and state
// frame stream produced by a RelayClient. A ChangeNotifier so the UI can
// use ValueListenableBuilder/AnimatedBuilder without extra dependencies.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'protocol.dart';
import 'relay_client.dart';

enum TranscriptKind { message, tool, notice, status, system }

/// One rendered row in the transcript. Mutable in place for streaming text
/// so the list widget can rebuild only the changed row.
class TranscriptEntry {
  TranscriptEntry({
    required this.id,
    required this.kind,
    this.role = 'assistant',
    this.text = '',
    this.thinking = '',
    this.toolName,
    this.toolInput,
    this.toolOk,
    this.diff,
    this.path,
    this.open = false,
    this.level,
  });

  final String id;
  final TranscriptKind kind;
  final String role;
  String text;
  String thinking;
  final String? toolName;
  final Object? toolInput;
  bool? toolOk;

  /// Unified diff of the file this call changed, when it changed one.
  String? diff;
  String? path;

  /// True while a streaming block or a tool call has not yet finalized.
  bool open;

  /// For notice entries: info, warning, error.
  final String? level;

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void touch() {
    revision.value++;
  }
}

class PendingRequestState {
  const PendingRequestState({
    required this.id,
    required this.request,
    required this.receivedAt,
  });
  final String id;
  final InteractiveRequest request;
  final DateTime receivedAt;
}

/// Result of an already-superseded answer attempt, shown to the user
/// rather than silently dropped.
class LateAnswerError {
  const LateAnswerError({required this.requestId, required this.message});
  final String requestId;
  final String message;
}

class SessionStore extends ChangeNotifier {
  SessionStore({required this.relayClient}) {
    _subscription = relayClient.frames.listen(_handleFrame);
  }

  final RelayClient relayClient;
  StreamSubscription<ServerFrame>? _subscription;

  final List<TranscriptEntry> _entries = [];
  List<TranscriptEntry> get entries => List.unmodifiable(_entries);

  StateSnapshot? _state;
  StateSnapshot? get state => _state;

  final List<PendingRequestState> _pendingRequests = [];
  List<PendingRequestState> get pendingRequests =>
      List.unmodifiable(_pendingRequests);

  /// Live subagents keyed by id, in the order they first appeared. Progress
  /// frames arrive continuously, so the latest state per agent replaces the
  /// previous one instead of appending another transcript line.
  final Map<String, SubagentEvent> _subagents = {};
  List<SubagentEvent> get subagents => List.unmodifiable(_subagents.values);
  bool get hasActiveSubagents =>
      _subagents.values.any((a) => !a.isTerminal);

  /// Live todo list. Seeded from `state.todos` and replaced by every
  /// `todos` event, so the panel tracks edits without waiting for a turn
  /// to end.
  List<TodoItem> _todos = const [];
  List<TodoItem> get todos => _todos;

  LateAnswerError? lastLateAnswerError;

  int _lastAppliedSeq = 0;
  String? _openToolBlockId;
  bool _hasOpenTextBlock = false;

  /// Notified once per appended/updated entry list mutation (not per delta).
  final ValueNotifier<int> transcriptRevision = ValueNotifier<int>(0);

  void clearTranscript() {
    _entries.clear();
    _subagents.clear();
    _openToolBlockId = null;
    _hasOpenTextBlock = false;
    transcriptRevision.value++;
    notifyListeners();
  }

  /// Resets local seq tracking, pending requests, and the transcript.
  /// Called before subscribing to a different agent so stale state from
  /// the previous agent never bleeds into the new one.
  void resetForAgentSwitch() {
    _lastAppliedSeq = 0;
    _pendingRequests.clear();
    clearTranscript();
  }

  void _handleFrame(ServerFrame frame) {
    switch (frame) {
      case EventFrame():
        // A restarted agent begins its epoch at seq 1, which is the only
        // case that invalidates local history. Any other seq at or below
        // what was already applied is a repeat: drop it rather than wipe
        // the transcript the user is reading.
        if (frame.seq == 1 && _lastAppliedSeq > 1) {
          clearTranscript();
          _pendingRequests.clear();
        } else if (frame.seq <= _lastAppliedSeq) {
          return;
        }
        _lastAppliedSeq = frame.seq;
        _applyEvent(frame.event);
      case StateFrame():
        _state = frame.state;
        final stateTodos = frame.state.todos;
        if (stateTodos != null) _todos = stateTodos;
        final incoming = frame.state.pendingRequests;
        if (incoming != null) {
          _pendingRequests
            ..clear()
            ..addAll(
              incoming.map(
                (p) => PendingRequestState(
                  id: p.id,
                  request: p.request,
                  receivedAt: DateTime.now(),
                ),
              ),
            );
        }
        notifyListeners();
      case RequestFrame():
        _pendingRequests.removeWhere((p) => p.id == frame.id);
        _pendingRequests.add(
          PendingRequestState(
            id: frame.id,
            request: frame.request,
            receivedAt: DateTime.now(),
          ),
        );
        notifyListeners();
      case RequestCancelFrame():
        _pendingRequests.removeWhere((p) => p.id == frame.id);
        notifyListeners();
      case ReplyFrame():
        if (!frame.ok) {
          lastLateAnswerError = LateAnswerError(
            requestId: frame.id,
            message: frame.error ?? 'error',
          );
          notifyListeners();
        }
      case WelcomeFrame():
      case AgentsFrame():
      case UnknownFrame():
        break;
    }
  }

  void _appendEntry(TranscriptEntry entry) {
    _entries.add(entry);
    transcriptRevision.value++;
    notifyListeners();
  }

  TranscriptEntry? _findOpenTextEntry() {
    if (!_hasOpenTextBlock || _entries.isEmpty) return null;
    final last = _entries.last;
    return (last.kind == TranscriptKind.message && last.open) ? last : null;
  }

  TranscriptEntry _ensureOpenTextEntry() {
    final existing = _findOpenTextEntry();
    if (existing != null) return existing;
    final entry = TranscriptEntry(
      id: 'msg-${_entries.length}-${DateTime.now().microsecondsSinceEpoch}',
      kind: TranscriptKind.message,
      role: 'assistant',
      open: true,
    );
    _hasOpenTextBlock = true;
    _appendEntry(entry);
    return entry;
  }

  /// Applies one event as if it had arrived over the wire. Exists so tests
  /// can exercise transcript rendering without a live socket.
  @visibleForTesting
  void applyEventForTest(SessionEvent event) => _applyEvent(event);

  void _applyEvent(SessionEvent event) {
    switch (event) {
      case TextDeltaEvent():
        final entry = _ensureOpenTextEntry();
        entry.text += event.text;
        entry.touch();
      case ThinkingDeltaEvent():
        final entry = _ensureOpenTextEntry();
        entry.thinking += event.text;
        entry.touch();
      case MessageEvent():
        // A toolResult message repeats what the tool card already shows, and
        // an assistant message that only carried a tool call has no prose at
        // all. Rendering either produces a stray empty block.
        if (event.role == 'toolResult') {
          _hasOpenTextBlock = false;
          return;
        }
        final hasContent =
            event.text.trim().isNotEmpty ||
            (event.thinking?.trim().isNotEmpty ?? false);
        final existing = _findOpenTextEntry();
        if (existing != null) {
          if (!hasContent) {
            _entries.remove(existing);
            _hasOpenTextBlock = false;
            transcriptRevision.value++;
            notifyListeners();
            return;
          }
          existing.text = event.text;
          existing.thinking = event.thinking ?? existing.thinking;
          existing.open = false;
          existing.touch();
        } else if (hasContent) {
          _appendEntry(
            TranscriptEntry(
              id: 'msg-${_entries.length}-${DateTime.now().microsecondsSinceEpoch}',
              kind: TranscriptKind.message,
              role: event.role,
              text: event.text,
              thinking: event.thinking ?? '',
              open: false,
            ),
          );
        }
        _hasOpenTextBlock = false;
      case ToolStartEvent():
        _openToolBlockId = event.id;
        _appendEntry(
          TranscriptEntry(
            id: 'tool-${event.id}',
            kind: TranscriptKind.tool,
            toolName: event.name,
            toolInput: event.input,
            open: true,
          ),
        );
      case ToolUpdateEvent():
        final entry = _findEntryById('tool-${event.id}');
        if (entry != null) {
          entry.text += event.text;
          entry.touch();
        }
      case ToolEndEvent():
        final entry = _findEntryById('tool-${event.id}');
        if (entry != null) {
          entry.text = event.text;
          entry.toolOk = event.ok;
          entry.diff = event.diff;
          entry.path = event.path;
          entry.open = false;
          entry.touch();
        } else {
          _appendEntry(
            TranscriptEntry(
              id: 'tool-${event.id}',
              kind: TranscriptKind.tool,
              toolName: event.name,
              text: event.text,
              toolOk: event.ok,
              diff: event.diff,
              path: event.path,
              open: false,
            ),
          );
        }
        if (_openToolBlockId == event.id) _openToolBlockId = null;
      case NoticeEvent():
        _appendEntry(
          TranscriptEntry(
            id: 'notice-${_entries.length}-${DateTime.now().microsecondsSinceEpoch}',
            kind: TranscriptKind.notice,
            text: event.text,
            level: event.level,
          ),
        );
      case StatusEvent():
        _appendEntry(
          TranscriptEntry(
            id: 'status-${_entries.length}-${DateTime.now().microsecondsSinceEpoch}',
            kind: TranscriptKind.status,
            text: event.text,
          ),
        );
      case SubagentEvent():
        _subagents[event.id] = event;
        notifyListeners();
      case RetryEvent():
        _appendEntry(
          TranscriptEntry(
            id: 'retry-${_entries.length}-${DateTime.now().microsecondsSinceEpoch}',
            kind: TranscriptKind.system,
            text:
                'Retry ${event.phase}${event.text != null ? ': ${event.text}' : ''}',
          ),
        );
      case CompactionEvent():
        _appendEntry(
          TranscriptEntry(
            id: 'compaction-${_entries.length}-${DateTime.now().microsecondsSinceEpoch}',
            kind: TranscriptKind.system,
            text: 'Compaction ${event.phase}',
          ),
        );
      case SessionChangedEvent():
        // A switch, branch, or tree move replaces the conversation, and the
        // agent replays the new one right after. Keeping the old entries
        // would interleave two transcripts.
        if (event.reason != 'start') {
          clearTranscript();
        }
        _appendEntry(
          TranscriptEntry(
            id: 'session-${_entries.length}-${DateTime.now().microsecondsSinceEpoch}',
            kind: TranscriptKind.system,
            text:
                'Session ${event.reason}${event.sessionName != null ? ': ${event.sessionName}' : ''}',
          ),
        );
      case ModelChangedEvent():
        _appendEntry(
          TranscriptEntry(
            id: 'model-${_entries.length}-${DateTime.now().microsecondsSinceEpoch}',
            kind: TranscriptKind.system,
            text: 'Model changed to ${event.model.label}',
          ),
        );
      case ThinkingChangedEvent():
        _appendEntry(
          TranscriptEntry(
            id: 'thinking-${_entries.length}-${DateTime.now().microsecondsSinceEpoch}',
            kind: TranscriptKind.system,
            text: 'Thinking level changed to ${event.thinkingLevel}',
          ),
        );
      case BashOutputEvent():
        final entry = _findEntryById('bash-${event.id}');
        if (entry != null) {
          entry.text += event.text;
          entry.touch();
        } else {
          _appendEntry(
            TranscriptEntry(
              id: 'bash-${event.id}',
              kind: TranscriptKind.system,
              text: event.text,
            ),
          );
        }
      case TodosEvent():
        // The event is the live source: `state.todos` only refreshes at a
        // turn boundary, and the list must track edits as they happen.
        _todos = event.todos;
        notifyListeners();
      case AgentStartEvent():
      case AgentEndEvent():
      case TurnStartEvent():
      case TurnEndEvent():
      case UnknownEvent():
        break;
    }
  }

  TranscriptEntry? _findEntryById(String id) {
    for (var i = _entries.length - 1; i >= 0; i--) {
      if (_entries[i].id == id) return _entries[i];
    }
    return null;
  }

  /// Answers a pending request locally: removes it immediately (optimistic)
  /// and sends the response frame.
  void answerRequest(String requestId, Map<String, Object?> response) {
    _pendingRequests.removeWhere((p) => p.id == requestId);
    notifyListeners();
    relayClient.sendResponse(requestId: requestId, response: response);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    transcriptRevision.dispose();
    super.dispose();
  }
}
