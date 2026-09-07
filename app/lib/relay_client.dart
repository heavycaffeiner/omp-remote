// WebSocket client for the omp-remote v2 client-facing protocol. The same
// code path serves both transports (relayed and direct): the connection
// profile only carries a URL, a token, a role, and an optional agent id.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';

enum ConnectionPhase { disconnected, connecting, connected, reconnecting }

/// Everything needed to open one client connection, relayed or direct.
class ConnectionProfile {
  const ConnectionProfile({
    required this.url,
    required this.token,
    required this.role,
    this.agentId,
    this.name,
  });

  /// WebSocket origin, without the `/client` path, e.g. `ws://host:8788`.
  final Uri url;
  final String token;
  final ClientRole role;

  /// Selects which agent to subscribe to. Absent when pairing did not name
  /// one, in which case a lone roster entry is adopted on welcome.
  final String? agentId;

  /// Display name sent in `hello`.
  final String? name;
}

class ConnectionStatus {
  const ConnectionStatus({
    required this.phase,
    this.lastError,
    this.role,
    this.agents = const [],
    this.subscribedAgentId,
  });

  final ConnectionPhase phase;
  final String? lastError;
  final ClientRole? role;
  final List<AgentInfo> agents;
  final String? subscribedAgentId;

  ConnectionStatus copyWith({
    ConnectionPhase? phase,
    String? lastError,
    bool clearError = false,
    ClientRole? role,
    List<AgentInfo>? agents,
    String? subscribedAgentId,
    bool clearSubscribed = false,
  }) {
    return ConnectionStatus(
      phase: phase ?? this.phase,
      lastError: clearError ? null : (lastError ?? this.lastError),
      role: role ?? this.role,
      agents: agents ?? this.agents,
      subscribedAgentId: clearSubscribed
          ? null
          : (subscribedAgentId ?? this.subscribedAgentId),
    );
  }
}

/// Thrown when a command's reply never arrives within the timeout.
class CommandTimeoutException implements Exception {
  const CommandTimeoutException(this.cmd);
  final CommandName cmd;

  @override
  String toString() => 'command timed out: ${cmd.wire}';
}

/// Thrown when the relay reports a command failure.
class CommandFailedException implements Exception {
  const CommandFailedException(this.message);
  final String message;

  @override
  String toString() => message;
}

typedef FrameListener = void Function(ServerFrame frame);

/// Connects to `<url>/client`, authenticates, tracks the roster, subscribes
/// to one agent, and resolves outstanding commands. Reconnects with capped
/// exponential backoff and resumes from the last seen `seq`.
class RelayClient {
  RelayClient({required this.profile}) : _clientId = _generateId('client');

  ConnectionProfile profile;
  final String _clientId;

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Timer? _reconnectTimer;
  int _backoffSeconds = 1;
  static const int _maxBackoffSeconds = 30;
  bool _closed = false;
  int _generation = 0;

  int _highestSeq = 0;
  final Map<String, _PendingCommand> _pending = {};

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  ConnectionStatus _status = const ConnectionStatus(
    phase: ConnectionPhase.disconnected,
  );

  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  ConnectionStatus get status => _status;

  final _frameController = StreamController<ServerFrame>.broadcast();

  /// Frames other than `reply` (which is consumed internally to resolve
  /// pending commands). Consumers subscribe to build local session state.
  Stream<ServerFrame> get frames => _frameController.stream;

  static String _generateId(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$prefix-$hex';
  }

  void _setStatus(ConnectionStatus Function(ConnectionStatus) update) {
    _status = update(_status);
    if (!_statusController.isClosed) _statusController.add(_status);
  }

  /// Resets seq tracking, e.g. when switching agents. Call before `connect`
  /// if reusing this client for a different profile.
  void resetSeqTracking() {
    _highestSeq = 0;
  }

  Future<void> connect() async {
    _closed = false;
    _backoffSeconds = 1;
    await _connectOnce();
  }

  Future<void> _connectOnce() async {
    if (_closed) return;
    final generation = ++_generation;
    _setStatus(
      (s) => s.copyWith(phase: ConnectionPhase.connecting, clearError: true),
    );

    final uri = profile.url.replace(
      path: '${profile.url.path}/client'.replaceAll('//', '/'),
    );

    WebSocketChannel channel;
    try {
      channel = IOWebSocketChannel.connect(
        uri,
        headers: {'Authorization': 'Bearer ${profile.token}'},
        connectTimeout: const Duration(seconds: 15),
        pingInterval: const Duration(seconds: 20),
      );
      await channel.ready;
    } catch (e) {
      if (generation != _generation) return;
      _handleDisconnect(_describeConnectError(e));
      return;
    }

    if (generation != _generation) {
      unawaited(channel.sink.close());
      return;
    }

    _channel = channel;
    channel.sink.add(
      jsonEncode(buildHelloFrame(clientId: _clientId, name: profile.name)),
    );

    _subscription = channel.stream.listen(
      (message) => _handleMessage(generation, message),
      onDone: () {
        if (generation == _generation) _handleDisconnect('connection closed');
      },
      onError: (Object error) {
        if (generation == _generation) _handleDisconnect(_describeError(error));
      },
      cancelOnError: true,
    );
  }

  /// Message for a stream error or close on an already-established
  /// connection (a lost connection, not a failed one).
  String _describeError(Object error) {
    if (error is WebSocketChannelException) {
      return error.message ?? 'websocket error';
    }
    return error.toString();
  }

  /// Classifies a failure from the initial connect attempt into the cause
  /// that needs its own fix: the host never answered, something answered
  /// but refused the port, or something answered and rejected the token.
  /// dart:io's `WebSocket.connect` reports a non-101 HTTP response as a
  /// `WebSocketException` carrying the status code, and reports a
  /// transport-level failure as the underlying `SocketException`'s message;
  /// both arrive here wrapped in `WebSocketChannelException.message`.
  String _describeConnectError(Object error) {
    if (error is TimeoutException) {
      return 'host unreachable: connection timed out';
    }
    final message = error is WebSocketChannelException
        ? (error.message ?? error.toString())
        : error.toString();
    if (message.contains('HTTP status code: 401')) {
      return 'token rejected: the server did not accept this token';
    }
    if (message.contains('Failed host lookup')) {
      return 'host unreachable: could not resolve the address';
    }
    if (message.contains('Connection refused')) {
      return 'port refused: nothing is listening on that port';
    }
    return 'connection failed: $message';
  }

  void _handleMessage(int generation, Object? raw) {
    if (generation != _generation) return;
    if (raw is! String) return;

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }

    final frame = ServerFrame.fromJson(decoded);
    switch (frame) {
      case WelcomeFrame():
        _backoffSeconds = 1;
        _setStatus(
          (s) => s.copyWith(
            phase: ConnectionPhase.connected,
            role: frame.role,
            agents: frame.agents,
            clearError: true,
          ),
        );
        // Pairing usually names the target. When it did not, a lone roster
        // entry is the only unambiguous choice; with several the user picks
        // one from the switch sheet. This goes through subscribeToAgent
        // rather than _sendSubscribe because commands and request answers
        // read profile.agentId, and leaving it null receives events but
        // refuses to send anything.
        final target =
            profile.agentId ??
            (frame.agents.length == 1 ? frame.agents.single.agentId : null);
        if (target != null) subscribeToAgent(target);
      case AgentsFrame():
        _setStatus((s) => s.copyWith(agents: frame.agents));
      case EventFrame():
        _highestSeq = frame.seq;
        _frameController.add(frame);
      case ReplyFrame():
        final pending = _pending.remove(frame.id);
        if (pending != null) {
          pending.timeoutTimer.cancel();
          if (frame.ok) {
            pending.completer.complete(frame.data);
          } else {
            pending.completer.completeError(
              CommandFailedException(frame.error ?? 'unknown error'),
            );
          }
        } else {
          _frameController.add(frame);
        }
      case StateFrame():
      case RequestFrame():
      case RequestCancelFrame():
        _frameController.add(frame);
      case UnknownFrame():
        break;
    }
  }

  void _sendSubscribe(String agentId) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(
      jsonEncode(buildSubscribeFrame(agentId: agentId, since: _highestSeq)),
    );
    _setStatus((s) => s.copyWith(subscribedAgentId: agentId));
  }

  void _sendUnsubscribe(String agentId) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(buildUnsubscribeFrame(agentId: agentId)));
  }

  /// Switches the target agent: unsubscribes the previous one (if any and
  /// if different), subscribes to the new one, and resets local seq
  /// tracking so the new agent's history replays from the start. Used for a
  /// roster switch on either transport.
  void subscribeToAgent(String agentId) {
    final previous = _status.subscribedAgentId;
    final changed = previous != agentId;
    profile = ConnectionProfile(
      url: profile.url,
      token: profile.token,
      role: profile.role,
      agentId: agentId,
      name: profile.name,
    );
    // Only a genuine switch starts from scratch. Resetting on a reconnect to
    // the same agent would replay the whole retained buffer as if it were new.
    if (changed) _highestSeq = 0;
    if (_status.phase == ConnectionPhase.connected) {
      if (previous != null && changed) {
        _sendUnsubscribe(previous);
      }
      _sendSubscribe(agentId);
    }
  }

  int get highestSeq => _highestSeq;

  void _handleDisconnect(String reason) {
    _channel = null;
    _subscription?.cancel();
    _subscription = null;

    for (final pending in _pending.values) {
      pending.timeoutTimer.cancel();
      pending.completer.completeError(
        CommandFailedException('connection lost'),
      );
    }
    _pending.clear();

    if (_closed) {
      _setStatus(
        (s) =>
            s.copyWith(phase: ConnectionPhase.disconnected, lastError: reason),
      );
      return;
    }

    _setStatus(
      (s) => s.copyWith(phase: ConnectionPhase.reconnecting, lastError: reason),
    );
    _reconnectTimer?.cancel();
    final delay = Duration(seconds: _backoffSeconds);
    _backoffSeconds = min(_backoffSeconds * 2, _maxBackoffSeconds);
    _reconnectTimer = Timer(delay, () {
      if (!_closed) _connectOnce();
    });
  }

  /// Issues a command and resolves once the matching `reply` arrives, or
  /// throws [CommandTimeoutException] after 60 seconds, matching the
  /// protocol's server-side command timeout.
  Future<Object?> sendCommand(
    CommandName cmd, {
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 60),
  }) {
    final channel = _channel;
    final agentId = profile.agentId;
    if (channel == null || _status.phase != ConnectionPhase.connected) {
      return Future.error(const CommandFailedException('not connected'));
    }
    if (agentId == null) {
      return Future.error(const CommandFailedException('no agent selected'));
    }

    final id = _generateId('cmd');
    final completer = Completer<Object?>();
    final timer = Timer(timeout, () {
      final pending = _pending.remove(id);
      if (pending != null) {
        pending.completer.completeError(CommandTimeoutException(cmd));
      }
    });
    _pending[id] = _PendingCommand(completer: completer, timeoutTimer: timer);

    channel.sink.add(
      jsonEncode(
        buildCommandFrame(id: id, agentId: agentId, cmd: cmd, args: args),
      ),
    );
    return completer.future;
  }

  /// Answers a pending interactive request.
  void sendResponse({
    required String requestId,
    required Map<String, Object?> response,
  }) {
    final channel = _channel;
    final agentId = profile.agentId;
    if (channel == null || agentId == null) return;
    channel.sink.add(
      jsonEncode(
        buildResponseFrame(id: requestId, agentId: agentId, response: response),
      ),
    );
  }

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _generation++;
    for (final pending in _pending.values) {
      pending.timeoutTimer.cancel();
      pending.completer.completeError(
        const CommandFailedException('connection closed'),
      );
    }
    _pending.clear();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _setStatus(
      (s) => s.copyWith(phase: ConnectionPhase.disconnected, clearError: true),
    );
  }

  Future<void> dispose() async {
    await close();
    await _statusController.close();
    await _frameController.close();
  }
}

class _PendingCommand {
  _PendingCommand({required this.completer, required this.timeoutTimer});
  final Completer<Object?> completer;
  final Timer timeoutTimer;
}
