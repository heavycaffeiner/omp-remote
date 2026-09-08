// Wire protocol models for omp-remote v2. Every value here may originate
// from an untrusted network peer, so every parser validates types and
// falls back to a safe, explicit "unknown" representation instead of
// throwing. See docs/protocol.md for the authoritative contract.

const int protocolVersion = 2;

String? asString(Object? v) => v is String ? v : null;

int? asInt(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite) return v.toInt();
  return null;
}

double? asDouble(Object? v) {
  if (v is num) return v.toDouble();
  return null;
}

bool? asBool(Object? v) => v is bool ? v : null;

Map<String, Object?> asMap(Object? v) => v is Map
    ? v.map((key, value) => MapEntry(key.toString(), value))
    : const {};

List<Object?> asList(Object? v) => v is List ? v : const [];

// ---------------------------------------------------------------------------
// Roles
// ---------------------------------------------------------------------------

enum ClientRole { control, viewer }

ClientRole? clientRoleFromJson(Object? v) {
  switch (asString(v)) {
    case 'control':
      return ClientRole.control;
    case 'viewer':
      return ClientRole.viewer;
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Shared value objects
// ---------------------------------------------------------------------------

class AgentInfo {
  const AgentInfo({
    required this.agentId,
    required this.name,
    required this.host,
    required this.cwd,
    required this.online,
    required this.connectedAt,
  });

  final String agentId;
  final String name;
  final String host;
  final String cwd;
  final bool online;
  final int connectedAt;

  static AgentInfo? fromJson(Object? json) {
    final map = asMap(json);
    final agentId = asString(map['agentId']);
    if (agentId == null || agentId.isEmpty) return null;
    return AgentInfo(
      agentId: agentId,
      name: asString(map['name']) ?? agentId,
      host: asString(map['host']) ?? '',
      cwd: asString(map['cwd']) ?? '',
      online: asBool(map['online']) ?? false,
      connectedAt: asInt(map['connectedAt']) ?? 0,
    );
  }

  static List<AgentInfo> listFromJson(Object? json) {
    final result = <AgentInfo>[];
    for (final entry in asList(json)) {
      final info = AgentInfo.fromJson(entry);
      if (info != null) result.add(info);
    }
    return result;
  }
}

/// One authenticated model. `name` is what the workstation calls it; the rest
/// is what a person needs to choose between two rows that otherwise differ
/// only by an opaque id.
class ModelInfo {
  const ModelInfo({
    required this.provider,
    required this.id,
    this.name,
    this.reasoning = false,
    this.contextWindow,
    this.image = false,
    this.thinking,
  });

  final String provider;
  final String id;
  final String? name;
  final bool reasoning;
  final int? contextWindow;
  final bool image;

  /// The thinking levels this model accepts, least to most intensive. Null
  /// when it has no controllable effort surface, which is not the same as an
  /// empty list: `high` exists on some models and not others, so a fixed
  /// list offered levels the model would reject.
  final List<String>? thinking;

  static ModelInfo? fromJson(Object? json) {
    final map = asMap(json);
    final provider = asString(map['provider']);
    final id = asString(map['id']);
    if (provider == null || id == null) return null;
    final levels = map.containsKey('thinking')
        ? [for (final entry in asList(map['thinking'])) ?asString(entry)]
        : null;
    return ModelInfo(
      provider: provider,
      id: id,
      name: asString(map['name']),
      reasoning: asBool(map['reasoning']) ?? false,
      contextWindow: asInt(map['contextWindow']),
      image: asBool(map['image']) ?? false,
      thinking: (levels != null && levels.isNotEmpty) ? levels : null,
    );
  }

  String get label => '$provider/$id';

  /// What the row shows first: the workstation's own name for the model when
  /// it has one, since an id like `claude-3-5-sonnet-20240620` is a date, not
  /// a name.
  String get title => name ?? id;
}

/// A named model slot the workstation resolves through `@<role>`. An empty
/// slot still resolves, by falling through to `default`, so `configured` and
/// `resolved` are separate: one is the assignment, the other is what a turn
/// would actually use.
class ModelRoleInfo {
  const ModelRoleInfo({
    required this.role,
    this.purpose,
    this.configured,
    this.resolved,
    this.source,
  });

  final String role;
  final String? purpose;
  final String? configured;
  final ModelInfo? resolved;
  final String? source;

  static ModelRoleInfo? fromJson(Object? json) {
    final map = asMap(json);
    final role = asString(map['role']);
    if (role == null) return null;
    final provider = asString(map['resolvedProvider']);
    final id = asString(map['resolvedId']);
    return ModelRoleInfo(
      role: role,
      purpose: asString(map['purpose']),
      configured: asString(map['configured']),
      resolved: provider == null || id == null
          ? null
          : ModelInfo(provider: provider, id: id),
      source: asString(map['source']),
    );
  }

  static List<ModelRoleInfo> listFromJson(Object? json) {
    final result = <ModelRoleInfo>[];
    for (final entry in asList(json)) {
      final role = ModelRoleInfo.fromJson(entry);
      if (role != null) result.add(role);
    }
    return result;
  }

  bool get isAssigned => configured != null;
}

class ContextUsage {
  const ContextUsage({
    required this.tokens,
    required this.contextWindow,
    required this.percent,
  });

  final int tokens;
  final int contextWindow;
  final double percent;

  static ContextUsage? fromJson(Object? json) {
    final map = asMap(json);
    final tokens = asInt(map['tokens']);
    final contextWindow = asInt(map['contextWindow']);
    final percent = asDouble(map['percent']);
    if (tokens == null || contextWindow == null || percent == null) return null;
    return ContextUsage(
      tokens: tokens,
      contextWindow: contextWindow,
      percent: percent,
    );
  }
}

class TodoItem {
  const TodoItem({
    required this.phase,
    required this.content,
    required this.status,
  });

  final String phase;
  final String content;
  final String status;

  static TodoItem? fromJson(Object? json) {
    final map = asMap(json);
    final content = asString(map['content']);
    if (content == null) return null;
    return TodoItem(
      phase: asString(map['phase']) ?? '',
      content: content,
      status: asString(map['status']) ?? 'pending',
    );
  }

  static List<TodoItem> listFromJson(Object? json) {
    final result = <TodoItem>[];
    for (final entry in asList(json)) {
      final item = TodoItem.fromJson(entry);
      if (item != null) result.add(item);
    }
    return result;
  }
}

class ViewerCounts {
  const ViewerCounts({required this.control, required this.viewer});

  final int control;
  final int viewer;

  static ViewerCounts? fromJson(Object? json) {
    final map = asMap(json);
    if (map.isEmpty) return null;
    return ViewerCounts(
      control: asInt(map['control']) ?? 0,
      viewer: asInt(map['viewer']) ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// Interactive requests
// ---------------------------------------------------------------------------

class SelectOption {
  const SelectOption({required this.label, this.description});

  final String label;
  final String? description;

  static SelectOption? fromJson(Object? json) {
    final map = asMap(json);
    final label = asString(map['label']);
    if (label == null) return null;
    return SelectOption(
      label: label,
      description: asString(map['description']),
    );
  }
}

sealed class InteractiveRequest {
  const InteractiveRequest({this.timeoutMs});

  final int? timeoutMs;

  static InteractiveRequest fromJson(Object? json) {
    final map = asMap(json);
    final kind = asString(map['k']);
    final timeoutMs = asInt(map['timeout']);
    switch (kind) {
      case 'select':
        final options = <SelectOption>[];
        for (final entry in asList(map['options'])) {
          final option = SelectOption.fromJson(entry);
          if (option != null) options.add(option);
        }
        return SelectRequest(
          title: asString(map['title']) ?? '',
          message: asString(map['message']) ?? '',
          options: options,
          timeoutMs: timeoutMs,
        );
      case 'confirm':
        return ConfirmRequest(
          title: asString(map['title']) ?? '',
          message: asString(map['message']) ?? '',
          timeoutMs: timeoutMs,
        );
      case 'input':
        return InputRequest(
          title: asString(map['title']) ?? '',
          message: asString(map['message']) ?? '',
          placeholder: asString(map['placeholder']),
          initial: asString(map['initial']),
          timeoutMs: timeoutMs,
        );
      case 'editor':
        return EditorRequest(
          title: asString(map['title']) ?? '',
          initial: asString(map['initial']),
          language: asString(map['language']),
          timeoutMs: timeoutMs,
        );
      case 'approval':
        return ApprovalRequest(
          toolName: asString(map['toolName']) ?? '',
          input: map['input'],
          risk: asString(map['risk']),
          timeoutMs: timeoutMs,
        );
      default:
        return UnknownRequest(kind: kind ?? '(missing)', timeoutMs: timeoutMs);
    }
  }
}

class SelectRequest extends InteractiveRequest {
  const SelectRequest({
    required this.title,
    required this.message,
    required this.options,
    super.timeoutMs,
  });

  final String title;
  final String message;
  final List<SelectOption> options;
}

class ConfirmRequest extends InteractiveRequest {
  const ConfirmRequest({
    required this.title,
    required this.message,
    super.timeoutMs,
  });

  final String title;
  final String message;
}

class InputRequest extends InteractiveRequest {
  const InputRequest({
    required this.title,
    required this.message,
    this.placeholder,
    this.initial,
    super.timeoutMs,
  });

  final String title;
  final String message;
  final String? placeholder;
  final String? initial;
}

class EditorRequest extends InteractiveRequest {
  const EditorRequest({
    required this.title,
    this.initial,
    this.language,
    super.timeoutMs,
  });

  final String title;
  final String? initial;
  final String? language;
}

class ApprovalRequest extends InteractiveRequest {
  const ApprovalRequest({
    required this.toolName,
    this.input,
    this.risk,
    super.timeoutMs,
  });

  final String toolName;
  final Object? input;
  final String? risk;
}

class UnknownRequest extends InteractiveRequest {
  const UnknownRequest({required this.kind, super.timeoutMs});

  final String kind;
}

Map<String, Object?> selectResponse(int index) => {'index': index};

Map<String, Object?> confirmResponse(bool confirmed) => {
  'confirmed': confirmed,
};

Map<String, Object?> valueResponse(String value) => {'value': value};

Map<String, Object?> approvalResponse(String decision) => {
  'decision': decision,
};

class PendingRequest {
  const PendingRequest({required this.id, required this.request});

  final String id;
  final InteractiveRequest request;

  static PendingRequest? fromJson(Object? json) {
    final map = asMap(json);
    final id = asString(map['id']);
    if (id == null) return null;
    return PendingRequest(
      id: id,
      request: InteractiveRequest.fromJson(map['request']),
    );
  }

  static List<PendingRequest> listFromJson(Object? json) {
    final result = <PendingRequest>[];
    for (final entry in asList(json)) {
      final pending = PendingRequest.fromJson(entry);
      if (pending != null) result.add(pending);
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// State snapshot
// ---------------------------------------------------------------------------

class StateSnapshot {
  const StateSnapshot({
    this.sessionId,
    this.sessionName,
    this.sessionFile,
    this.cwd,
    this.model,
    this.thinkingLevel,
    this.thinkingLevels,
    required this.streaming,
    required this.compacting,
    required this.queued,
    this.autoCompaction,
    this.steeringMode,
    this.followUpMode,
    this.interruptMode,
    this.contextUsage,
    this.todos,
    this.pendingRequests,
    this.viewers,
  });

  final String? sessionId;
  final String? sessionName;
  final String? sessionFile;
  final String? cwd;
  final ModelInfo? model;
  final String? thinkingLevel;

  /// The levels the current model accepts. Null when the workstation did not
  /// say, or when the model has no effort control at all.
  final List<String>? thinkingLevels;
  final bool streaming;
  final bool compacting;
  final int queued;

  final bool? autoCompaction;
  final String? steeringMode;
  final String? followUpMode;
  final String? interruptMode;
  final ContextUsage? contextUsage;
  final List<TodoItem>? todos;
  final List<PendingRequest>? pendingRequests;
  final ViewerCounts? viewers;

  static StateSnapshot fromJson(Object? json) {
    final map = asMap(json);
    return StateSnapshot(
      sessionId: asString(map['sessionId']),
      sessionName: asString(map['sessionName']),
      sessionFile: asString(map['sessionFile']),
      cwd: asString(map['cwd']),
      model: ModelInfo.fromJson(map['model']),
      thinkingLevel: asString(map['thinkingLevel']),
      thinkingLevels: map.containsKey('thinkingLevels')
          ? [
              for (final entry in asList(map['thinkingLevels']))
                ?asString(entry),
            ]
          : null,
      streaming: asBool(map['streaming']) ?? false,
      compacting: asBool(map['compacting']) ?? false,
      queued: asInt(map['queued']) ?? 0,
      autoCompaction: asBool(map['autoCompaction']),
      steeringMode: asString(map['steeringMode']),
      followUpMode: asString(map['followUpMode']),
      interruptMode: asString(map['interruptMode']),
      contextUsage: ContextUsage.fromJson(map['contextUsage']),
      todos: map.containsKey('todos')
          ? TodoItem.listFromJson(map['todos'])
          : null,
      pendingRequests: map.containsKey('pendingRequests')
          ? PendingRequest.listFromJson(map['pendingRequests'])
          : null,
      viewers: ViewerCounts.fromJson(map['viewers']),
    );
  }
}

// ---------------------------------------------------------------------------
// Session events
// ---------------------------------------------------------------------------

sealed class SessionEvent {
  const SessionEvent();

  static SessionEvent fromJson(Object? json) {
    final map = asMap(json);
    final kind = asString(map['k']);
    switch (kind) {
      case 'agent_start':
        return const AgentStartEvent();
      case 'agent_end':
        return AgentEndEvent(terminal: asBool(map['terminal']) ?? false);
      case 'turn_start':
        return const TurnStartEvent();
      case 'turn_end':
        return const TurnEndEvent();
      case 'text_delta':
        return TextDeltaEvent(text: asString(map['text']) ?? '');
      case 'thinking_delta':
        return ThinkingDeltaEvent(text: asString(map['text']) ?? '');
      case 'message':
        return MessageEvent(
          role: asString(map['role']) ?? 'assistant',
          text: asString(map['text']) ?? '',
          thinking: asString(map['thinking']),
        );
      case 'tool_start':
        return ToolStartEvent(
          id: asString(map['id']) ?? '',
          name: asString(map['name']) ?? '',
          input: map['input'],
        );
      case 'tool_update':
        return ToolUpdateEvent(
          id: asString(map['id']) ?? '',
          text: asString(map['text']) ?? '',
        );
      case 'tool_end':
        return ToolEndEvent(
          id: asString(map['id']) ?? '',
          name: asString(map['name']) ?? '',
          ok: asBool(map['ok']) ?? false,
          text: asString(map['text']) ?? '',
          path: asString(map['path']),
          diff: asString(map['diff']),
          sourcePath: asString(map['sourcePath']),
        );
      case 'todos':
        return TodosEvent(todos: TodoItem.listFromJson(map['todos']));
      case 'notice':
        return NoticeEvent(
          level: asString(map['level']) ?? 'info',
          text: asString(map['text']) ?? '',
        );
      case 'status':
        return StatusEvent(
          key: asString(map['key']) ?? '',
          text: asString(map['text']) ?? '',
        );
      case 'model_changed':
        final model = ModelInfo.fromJson(map['model']);
        if (model == null) return const UnknownEvent(kind: 'model_changed');
        return ModelChangedEvent(model: model);
      case 'thinking_changed':
        return ThinkingChangedEvent(
          thinkingLevel: asString(map['thinkingLevel']) ?? '',
        );
      case 'compaction':
        return CompactionEvent(phase: asString(map['phase']) ?? '');
      case 'retry':
        return RetryEvent(
          phase: asString(map['phase']) ?? '',
          text: asString(map['text']),
        );
      case 'session_changed':
        return SessionChangedEvent(
          reason: asString(map['reason']) ?? '',
          sessionId: asString(map['sessionId']),
          sessionName: asString(map['sessionName']),
        );
      case 'subagent':
        return SubagentEvent(
          id: asString(map['id']) ?? '',
          name: asString(map['name']) ?? '',
          phase: asString(map['phase']) ?? '',
          text: asString(map['text']),
          agentType: asString(map['agentType']),
          tool: asString(map['tool']),
          toolCount: asInt(map['toolCount']),
          tokens: asInt(map['tokens']),
          durationMs: asInt(map['durationMs']),
        );
      case 'bash_output':
        return BashOutputEvent(
          id: asString(map['id']) ?? '',
          text: asString(map['text']) ?? '',
        );
      default:
        return UnknownEvent(kind: kind ?? '(missing)');
    }
  }
}

class AgentStartEvent extends SessionEvent {
  const AgentStartEvent();
}

class AgentEndEvent extends SessionEvent {
  const AgentEndEvent({required this.terminal});
  final bool terminal;
}

class TurnStartEvent extends SessionEvent {
  const TurnStartEvent();
}

class TurnEndEvent extends SessionEvent {
  const TurnEndEvent();
}

class TextDeltaEvent extends SessionEvent {
  const TextDeltaEvent({required this.text});
  final String text;
}

class ThinkingDeltaEvent extends SessionEvent {
  const ThinkingDeltaEvent({required this.text});
  final String text;
}

class MessageEvent extends SessionEvent {
  const MessageEvent({required this.role, required this.text, this.thinking});
  final String role;
  final String text;
  final String? thinking;
}

class ToolStartEvent extends SessionEvent {
  const ToolStartEvent({required this.id, required this.name, this.input});
  final String id;
  final String name;
  final Object? input;
}

class ToolUpdateEvent extends SessionEvent {
  const ToolUpdateEvent({required this.id, required this.text});
  final String id;
  final String text;
}

class ToolEndEvent extends SessionEvent {
  const ToolEndEvent({
    required this.id,
    required this.name,
    required this.ok,
    required this.text,
    this.path,
    this.diff,
    this.sourcePath,
  });
  final String id;
  final String name;
  final bool ok;
  final String text;

  /// File the call changed, when it changed exactly one.
  final String? path;

  /// Unified diff of that change.
  final String? diff;

  /// Pre-move path, set only when the edit renamed the file.
  final String? sourcePath;
}

class TodosEvent extends SessionEvent {
  const TodosEvent({required this.todos});
  final List<TodoItem> todos;
}

class NoticeEvent extends SessionEvent {
  const NoticeEvent({required this.level, required this.text});
  final String level;
  final String text;
}

class StatusEvent extends SessionEvent {
  const StatusEvent({required this.key, required this.text});
  final String key;
  final String text;
}

class ModelChangedEvent extends SessionEvent {
  const ModelChangedEvent({required this.model});
  final ModelInfo model;
}

class ThinkingChangedEvent extends SessionEvent {
  const ThinkingChangedEvent({required this.thinkingLevel});
  final String thinkingLevel;
}

class CompactionEvent extends SessionEvent {
  const CompactionEvent({required this.phase});
  final String phase;
}

class RetryEvent extends SessionEvent {
  const RetryEvent({required this.phase, this.text});
  final String phase;
  final String? text;
}

class SessionChangedEvent extends SessionEvent {
  const SessionChangedEvent({
    required this.reason,
    this.sessionId,
    this.sessionName,
  });
  final String reason;
  final String? sessionId;
  final String? sessionName;
}

class SubagentEvent extends SessionEvent {
  const SubagentEvent({
    required this.id,
    required this.name,
    required this.phase,
    this.text,
    this.agentType,
    this.tool,
    this.toolCount,
    this.tokens,
    this.durationMs,
  });
  final String id;
  final String name;

  /// Lifecycle or progress status: `started`, `running`, `completed`,
  /// `failed`, or `aborted`.
  final String phase;

  /// What the agent last said it was doing, or its assignment.
  final String? text;
  final String? agentType;
  final String? tool;
  final int? toolCount;
  final int? tokens;
  final int? durationMs;

  bool get isTerminal =>
      phase == 'completed' || phase == 'failed' || phase == 'aborted';
}

class BashOutputEvent extends SessionEvent {
  const BashOutputEvent({required this.id, required this.text});
  final String id;
  final String text;
}

class UnknownEvent extends SessionEvent {
  const UnknownEvent({required this.kind});
  final String kind;
}

// ---------------------------------------------------------------------------
// Commands (client to relay/plugin)
// ---------------------------------------------------------------------------

enum CommandName {
  prompt,
  steer,
  followUp,
  abort,
  state,
  history,
  stats,
  tools,
  commandsList,
  models,
  systemPrompt,
  setModel,
  setModelRole,
  cycleModel,
  setThinking,
  setAutoCompaction,
  setSteeringMode,
  setFollowUpMode,
  setInterruptMode,
  setActiveTools,
  setTodos,
  newSession,
  endSession,
  switchSession,
  listSessions,
  branch,
  compact,
  setSessionName,
  bash,
  abortBash,
  btw,
  omfg,
}

extension CommandNameWire on CommandName {
  String get wire {
    switch (this) {
      case CommandName.prompt:
        return 'prompt';
      case CommandName.steer:
        return 'steer';
      case CommandName.followUp:
        return 'follow_up';
      case CommandName.abort:
        return 'abort';
      case CommandName.state:
        return 'state';
      case CommandName.history:
        return 'history';
      case CommandName.stats:
        return 'stats';
      case CommandName.tools:
        return 'tools';
      case CommandName.commandsList:
        return 'commands';
      case CommandName.models:
        return 'models';
      case CommandName.systemPrompt:
        return 'system_prompt';
      case CommandName.setModel:
        return 'set_model';
      case CommandName.setModelRole:
        return 'set_model_role';
      case CommandName.cycleModel:
        return 'cycle_model';
      case CommandName.setThinking:
        return 'set_thinking';
      case CommandName.setAutoCompaction:
        return 'set_auto_compaction';
      case CommandName.setSteeringMode:
        return 'set_steering_mode';
      case CommandName.setFollowUpMode:
        return 'set_follow_up_mode';
      case CommandName.setInterruptMode:
        return 'set_interrupt_mode';
      case CommandName.setActiveTools:
        return 'set_active_tools';
      case CommandName.setTodos:
        return 'set_todos';
      case CommandName.newSession:
        return 'new_session';
      case CommandName.endSession:
        return 'end_session';
      case CommandName.switchSession:
        return 'switch_session';
      case CommandName.listSessions:
        return 'list_sessions';
      case CommandName.branch:
        return 'branch';
      case CommandName.compact:
        return 'compact';
      case CommandName.setSessionName:
        return 'set_session_name';
      case CommandName.bash:
        return 'bash';
      case CommandName.abortBash:
        return 'abort_bash';
      case CommandName.btw:
        return 'btw';
      case CommandName.omfg:
        return 'omfg';
    }
  }
}

class SlashCommandInfo {
  const SlashCommandInfo({
    required this.name,
    required this.source,
    this.description,
    this.remote,
  });

  final String name;

  /// Where the command comes from: `builtin`, `extension`, `prompt`, or
  /// `skill`. Shown so a long list is scannable by origin.
  final String source;
  final String? description;

  /// Wire command that does the same work from here, when one exists. Absent
  /// means the command only runs at the workstation.
  final String? remote;

  static SlashCommandInfo? fromJson(Object? json) {
    final map = asMap(json);
    final name = asString(map['name']);
    if (name == null || name.isEmpty) return null;
    return SlashCommandInfo(
      name: name,
      source: asString(map['source']) ?? 'unknown',
      description: asString(map['description']),
      remote: asString(map['remote']),
    );
  }

  static List<SlashCommandInfo> listFromJson(Object? json) {
    final result = <SlashCommandInfo>[];
    for (final entry in asList(json)) {
      final info = SlashCommandInfo.fromJson(entry);
      if (info != null) result.add(info);
    }
    return result;
  }
}

class SessionSummary {
  const SessionSummary({
    required this.sessionFile,
    this.sessionId,
    this.sessionName,
  });

  final String sessionFile;
  final String? sessionId;
  final String? sessionName;

  static SessionSummary? fromJson(Object? json) {
    final map = asMap(json);
    final sessionFile = asString(map['sessionFile']);
    if (sessionFile == null) return null;
    return SessionSummary(
      sessionFile: sessionFile,
      sessionId: asString(map['sessionId']),
      sessionName: asString(map['sessionName']),
    );
  }

  static List<SessionSummary> listFromJson(Object? json) {
    final result = <SessionSummary>[];
    for (final entry in asList(json)) {
      final summary = SessionSummary.fromJson(entry);
      if (summary != null) result.add(summary);
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// Outgoing client frames
// ---------------------------------------------------------------------------

Map<String, Object?> buildHelloFrame({
  required String clientId,
  String? name,
}) => {
  't': 'hello',
  'protocol': protocolVersion,
  'clientId': clientId,
  if (name != null && name.isNotEmpty) 'name': name,
};

Map<String, Object?> buildSubscribeFrame({
  required String agentId,
  required int since,
}) => {'t': 'subscribe', 'agentId': agentId, 'since': since};

Map<String, Object?> buildUnsubscribeFrame({required String agentId}) => {
  't': 'unsubscribe',
  'agentId': agentId,
};

Map<String, Object?> buildCommandFrame({
  required String id,
  required String agentId,
  required CommandName cmd,
  Map<String, Object?> args = const {},
}) => {
  't': 'command',
  'id': id,
  'agentId': agentId,
  'cmd': cmd.wire,
  'args': args,
};

Map<String, Object?> buildResponseFrame({
  required String id,
  required String agentId,
  required Map<String, Object?> response,
}) => {'t': 'response', 'id': id, 'agentId': agentId, 'response': response};

// ---------------------------------------------------------------------------
// Incoming server frames
// ---------------------------------------------------------------------------

sealed class ServerFrame {
  const ServerFrame();

  static ServerFrame fromJson(Object? json) {
    final map = asMap(json);
    final t = asString(map['t']);
    switch (t) {
      case 'welcome':
        final protocol = asInt(map['protocol']);
        final clientId = asString(map['clientId']);
        final role = clientRoleFromJson(map['role']);
        if (protocol == null || clientId == null || role == null) {
          return UnknownFrame(t: t);
        }
        return WelcomeFrame(
          protocol: protocol,
          clientId: clientId,
          role: role,
          agents: AgentInfo.listFromJson(map['agents']),
        );
      case 'agents':
        return AgentsFrame(agents: AgentInfo.listFromJson(map['agents']));
      case 'event':
        final agentId = asString(map['agentId']);
        final seq = asInt(map['seq']);
        if (agentId == null || seq == null) return UnknownFrame(t: t);
        return EventFrame(
          agentId: agentId,
          seq: seq,
          event: SessionEvent.fromJson(map['event']),
        );
      case 'state':
        final agentId = asString(map['agentId']);
        if (agentId == null) return UnknownFrame(t: t);
        return StateFrame(
          agentId: agentId,
          state: StateSnapshot.fromJson(map['state']),
        );
      case 'reply':
        final id = asString(map['id']);
        final ok = asBool(map['ok']);
        if (id == null || ok == null) return UnknownFrame(t: t);
        return ReplyFrame(
          id: id,
          ok: ok,
          data: map['data'],
          error: asString(map['error']),
        );
      case 'request':
        final agentId = asString(map['agentId']);
        final id = asString(map['id']);
        if (agentId == null || id == null) return UnknownFrame(t: t);
        return RequestFrame(
          agentId: agentId,
          id: id,
          request: InteractiveRequest.fromJson(map['request']),
        );
      case 'request_cancel':
        final agentId = asString(map['agentId']);
        final id = asString(map['id']);
        if (agentId == null || id == null) return UnknownFrame(t: t);
        return RequestCancelFrame(
          agentId: agentId,
          id: id,
          reason: asString(map['reason']) ?? 'shutdown',
        );
      default:
        return UnknownFrame(t: t);
    }
  }
}

class WelcomeFrame extends ServerFrame {
  const WelcomeFrame({
    required this.protocol,
    required this.clientId,
    required this.role,
    required this.agents,
  });

  final int protocol;
  final String clientId;
  final ClientRole role;
  final List<AgentInfo> agents;
}

class AgentsFrame extends ServerFrame {
  const AgentsFrame({required this.agents});
  final List<AgentInfo> agents;
}

class EventFrame extends ServerFrame {
  const EventFrame({
    required this.agentId,
    required this.seq,
    required this.event,
  });
  final String agentId;
  final int seq;
  final SessionEvent event;
}

class StateFrame extends ServerFrame {
  const StateFrame({required this.agentId, required this.state});
  final String agentId;
  final StateSnapshot state;
}

class ReplyFrame extends ServerFrame {
  const ReplyFrame({required this.id, required this.ok, this.data, this.error});
  final String id;
  final bool ok;
  final Object? data;
  final String? error;
}

class RequestFrame extends ServerFrame {
  const RequestFrame({
    required this.agentId,
    required this.id,
    required this.request,
  });
  final String agentId;
  final String id;
  final InteractiveRequest request;
}

class RequestCancelFrame extends ServerFrame {
  const RequestCancelFrame({
    required this.agentId,
    required this.id,
    required this.reason,
  });
  final String agentId;
  final String id;
  final String reason;
}

class UnknownFrame extends ServerFrame {
  const UnknownFrame({this.t});
  final String? t;
}
