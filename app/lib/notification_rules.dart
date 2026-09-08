// Pure decision logic for local notifications: maps incoming server frames
// to notification actions (show, cancel, or nothing). No Flutter, plugin,
// or platform dependency, so this is fully unit-testable without a plugin
// binding; see notifications.dart for the plugin wiring that consumes it.

import 'dart:convert';

import 'protocol.dart';

/// Urgency tier for a notification. Mapped to Android importance/priority
/// and iOS interruption level by the delivery layer in notifications.dart.
enum NotificationPriority { high, normal }

/// What is currently visible in the app, used to suppress a notification
/// for something the user is already looking at. `foregroundAgentId` is
/// the agent whose session screen is on screen, if any; `foregroundRequestId`
/// is the pending request currently displayed there, if any.
class NotificationForegroundState {
  const NotificationForegroundState({
    required this.appInForeground,
    this.foregroundAgentId,
    this.foregroundRequestId,
  });

  final bool appInForeground;
  final String? foregroundAgentId;
  final String? foregroundRequestId;

  bool isSessionOnScreen(String agentId) =>
      appInForeground && foregroundAgentId == agentId;

  bool isRequestOnScreen(String agentId, String requestId) =>
      isSessionOnScreen(agentId) && foregroundRequestId == requestId;

  static const none = NotificationForegroundState(appInForeground: false);
}

/// Where a notification tap should take the user: a session, and,
/// when the notification was about one, the pending request open within
/// it. Encoded to a plain string for the plugin's string-only payload.
class NotificationPayload {
  const NotificationPayload({required this.agentId, this.requestId});

  final String agentId;
  final String? requestId;

  String encode() => jsonEncode({
    'agentId': agentId,
    if (requestId != null) 'requestId': requestId,
  });

  static NotificationPayload? decode(String? raw) {
    if (raw == null) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    final map = asMap(decoded);
    final agentId = asString(map['agentId']);
    if (agentId == null) return null;
    return NotificationPayload(
      agentId: agentId,
      requestId: asString(map['requestId']),
    );
  }
}

/// One thing the delivery layer should do in response to a decision.
sealed class NotificationAction {
  const NotificationAction();
}

/// Show a notification. `id` and `tag` together identify it on Android, so
/// notifications from different agent ids, or of different kinds for the
/// same agent, never collapse into one another.
class ShowNotification extends NotificationAction {
  const ShowNotification({
    required this.id,
    required this.tag,
    required this.title,
    required this.body,
    required this.priority,
    required this.payload,
  });

  final int id;
  final String tag;
  final String title;
  final String body;
  final NotificationPriority priority;
  final NotificationPayload payload;
}

/// Dismiss a previously shown notification, e.g. because its request was
/// answered or withdrawn.
class CancelNotification extends NotificationAction {
  const CancelNotification({required this.id, required this.tag});

  final int id;
  final String tag;
}

const int _maxBodyLength = 200;

/// Collapses to one line and caps length, so a notification body can never
/// dump multi-line tool output or blow past what a notification tray shows.
String _truncate(String text) {
  final singleLine = text.replaceAll('\n', ' ').trim();
  if (singleLine.length <= _maxBodyLength) return singleLine;
  return '${singleLine.substring(0, _maxBodyLength - 1)}...';
}

/// FNV-1a 32-bit hash, masked to a non-negative int. Android notification
/// ids are a 32-bit Java int and need to be stable and collision-resistant
/// across the life of the app; Dart's `String.hashCode` is not specified to
/// be stable across isolates or releases, so it is not used here.
int stableNotificationId(String key) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(key)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

String _requestKindLabel(InteractiveRequest request) => switch (request) {
  SelectRequest(:final title) => 'Select: $title',
  ConfirmRequest(:final title) => 'Confirm: $title',
  InputRequest(:final title) => 'Input: $title',
  EditorRequest(:final title) => 'Editor: $title',
  ApprovalRequest(:final toolName) => 'Approval: $toolName',
  UnknownRequest(:final kind) => 'Request: $kind',
};

/// Maps incoming server frames to notification actions. Holds only the
/// bookkeeping needed to dedupe: which request ids have already produced a
/// notification (and under what numeric id, so a cancel can find it again),
/// and which event keys have already been acted on.
///
/// Dedup rationale: `subscribe` with `since` replays every retained event on
/// reconnect, and every pending request is resent in full on every
/// subscribe regardless of `since` (docs/protocol.md, "Relay to client").
/// Acting on a frame naively would therefore re-notify for things the user
/// already saw on every reconnect. The event key (`agentId:seq`) is stable
/// across a replay of the same run, since seq only advances or (on an agent
/// restart) resets to a new, distinct epoch that legitimately deserves its
/// own notifications. The request key (`agentId:id`) is stable because a
/// request keeps the same id for its whole lifetime, resent verbatim on
/// every subscribe until it is answered or cancelled.
class NotificationDecider {
  final Set<String> _shownEventKeys = {};
  final Map<String, int> _requestNotificationIds = {};

  /// Decides what to do for one incoming frame. `sessionLabel` resolves an
  /// agent id to the display name shown in the notification; the caller
  /// supplies it because that mapping lives in roster/session state that
  /// this class deliberately has no access to.
  NotificationAction? decide(
    ServerFrame frame, {
    required String Function(String agentId) sessionLabel,
    NotificationForegroundState foreground = NotificationForegroundState.none,
  }) {
    switch (frame) {
      case RequestFrame(:final agentId, :final id, :final request):
        return _decideRequest(agentId, id, request, sessionLabel, foreground);
      case RequestCancelFrame(:final agentId, :final id):
        return _decideRequestCancel(agentId, id);
      case EventFrame(:final agentId, :final seq, :final event):
        return _decideEvent(agentId, seq, event, sessionLabel, foreground);
      case WelcomeFrame():
      case AgentsFrame():
      case StateFrame():
      case ReplyFrame():
      case UnknownFrame():
        return null;
    }
  }

  NotificationAction? _decideRequest(
    String agentId,
    String id,
    InteractiveRequest request,
    String Function(String) sessionLabel,
    NotificationForegroundState foreground,
  ) {
    final key = '$agentId:$id';
    if (_requestNotificationIds.containsKey(key)) return null;
    if (foreground.isRequestOnScreen(agentId, id)) return null;
    final notificationId = stableNotificationId('request:$key');
    _requestNotificationIds[key] = notificationId;
    return ShowNotification(
      id: notificationId,
      tag: agentId,
      title: sessionLabel(agentId),
      body: _truncate(_requestKindLabel(request)),
      priority: NotificationPriority.high,
      payload: NotificationPayload(agentId: agentId, requestId: id),
    );
  }

  NotificationAction? _decideRequestCancel(String agentId, String id) {
    final notificationId = _requestNotificationIds.remove('$agentId:$id');
    if (notificationId == null) return null;
    return CancelNotification(id: notificationId, tag: agentId);
  }

  NotificationAction? _decideEvent(
    String agentId,
    int seq,
    SessionEvent event,
    String Function(String) sessionLabel,
    NotificationForegroundState foreground,
  ) {
    final String body;
    switch (event) {
      case AgentEndEvent(terminal: true):
        body = '${sessionLabel(agentId)} finished its run and is idle.';
      case NoticeEvent(level: 'warning', :final text):
        body = 'Warning: ${_truncate(text)}';
      case NoticeEvent(level: 'error', :final text):
        body = 'Error: ${_truncate(text)}';
      case ToolEndEvent(ok: false, :final name):
        body = 'Tool failed: $name';
      default:
        return null;
    }
    if (foreground.isSessionOnScreen(agentId)) return null;
    final key = '$agentId:$seq';
    if (_shownEventKeys.contains(key)) return null;
    _shownEventKeys.add(key);
    return ShowNotification(
      id: stableNotificationId('event:$key'),
      tag: agentId,
      title: sessionLabel(agentId),
      body: body,
      priority: NotificationPriority.normal,
      payload: NotificationPayload(agentId: agentId),
    );
  }

  /// Drops all dedup bookkeeping for one agent. Call when a session's
  /// history is discarded locally (agent restart detected, or switching
  /// away from and back to the same agent id), so a legitimately new run
  /// is free to notify again instead of being treated as a stale replay.
  void resetForAgent(String agentId) {
    _shownEventKeys.removeWhere((key) => key.startsWith('$agentId:'));
    _requestNotificationIds.removeWhere(
      (key, _) => key.startsWith('$agentId:'),
    );
  }
}
