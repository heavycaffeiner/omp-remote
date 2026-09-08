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
    this.alternates = const [],
    this.agentId,
    this.name,
  });

  /// WebSocket origin, without the `/client` path, e.g. `ws://host:8788`.
  final Uri url;

  /// Other addresses for the same session. A workstation cannot know which
  /// of its interfaces the phone can reach, so every candidate is tried.
  final List<Uri> alternates;

  final String token;
  final ClientRole role;

  /// Selects which agent to subscribe to. Absent when pairing did not name
  /// one, in which case a lone roster entry is adopted on welcome.
  final String? agentId;

  /// Display name sent in `hello`.
  final String? name;

  /// Every address to try, best guess first and duplicates removed.
  List<Uri> get candidates => <Uri>[
    url,
    for (final alternate in alternates)
      if (alternate != url) alternate,
  ];
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

  /// Called when a candidate other than [ConnectionProfile.url] is the one
  /// that answered, so a saved profile can start there next time instead of
  /// paying the timeout on a dead address again.
  void Function(Uri origin)? onAddressChanged;

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Timer? _reconnectTimer;
  int _backoffSeconds = 1;
  // A phone waiting on a workstation that is restarting should not sit out
  // half a minute; one TCP attempt every ten seconds costs nothing, and a
  // return to the foreground retries at once regardless.
  static const int _maxBackoffSeconds = 10;
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

  /// Retries now instead of waiting out the backoff. What a user does after
  /// fixing the thing that was blocking the connection, so waiting up to the
  /// backoff ceiling to find out would be the wrong answer.
  Future<void> retryNow() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _backoffSeconds = 1;
    _closed = false;
    await _connectOnce();
  }

  /// Called when the app returns to the foreground.
  ///
  /// Two separate delays used to be waited out on the phone rather than on
  /// the workstation. A socket that died while the process was suspended is
  /// not noticed until a ping fails, twenty seconds of staring at a screen
  /// that is no longer live; and a scheduled retry may be sitting on a
  /// backoff of up to thirty seconds that the user is now waiting out for no
  /// reason. Coming back to the app is evidence that waiting is over.
  void resume() {
    if (_closed) return;
    if (_status.phase != ConnectionPhase.connected) {
      unawaited(retryNow());
      return;
    }
    unawaited(_probe());
  }

  /// Asks the workstation for the state it already sends unprompted. The
  /// reply is discarded: what matters is whether one arrives, since a
  /// suspended socket answers nothing and needs replacing.
  Future<void> _probe() async {
    try {
      await sendCommand(CommandName.state, timeout: const Duration(seconds: 4));
    } catch (_) {
      if (_closed) return;
      await retryNow();
    }
  }

  Uri _clientUri(Uri origin) =>
      origin.replace(path: '${origin.path}/client'.replaceAll('//', '/'));

  static void _closeQuietly(WebSocketChannel channel) {
    // A channel whose connect never completed throws on close; there is
    // nothing to report about an attempt we are abandoning anyway.
    unawaited(channel.sink.close().catchError((Object _) {}));
  }

  /// Opens every candidate address at once and keeps the first that answers.
  ///
  /// Trying them one at a time would spend the 15 second connect timeout on
  /// each address the phone cannot reach, and the unreachable one tends to
  /// come first: the workstation ranks a Tailscale address ahead of its LAN
  /// address, which is the wrong guess whenever the phone is not on the
  /// tailnet.
  Future<void> _connectOnce() async {
    if (_closed) return;
    final generation = ++_generation;
    // A retry keeps the reason the previous attempt failed with and says it
    // is retrying. Clearing the error and dropping back to `connecting` on
    // every attempt is what turned an unreachable host into an endless
    // spinner with nothing on screen to explain it.
    final retrying = _status.lastError != null;
    _setStatus(
      (s) => s.copyWith(
        phase: retrying
            ? ConnectionPhase.reconnecting
            : ConnectionPhase.connecting,
      ),
    );

    final candidates = profile.candidates;
    final settled = Completer<(Uri, WebSocketChannel)>();
    final attempts = <WebSocketChannel>[];
    var outstanding = candidates.length;
    Object? firstError;

    for (final origin in candidates) {
      final channel = IOWebSocketChannel.connect(
        _clientUri(origin),
        headers: {'Authorization': 'Bearer ${profile.token}'},
        connectTimeout: const Duration(seconds: 15),
        pingInterval: const Duration(seconds: 20),
      );
      attempts.add(channel);
      unawaited(
        channel.ready.then(
          (_) {
            if (!settled.isCompleted) settled.complete((origin, channel));
          },
          onError: (Object error) {
            // The first failure is the one worth reporting: candidates are
            // in the workstation's preference order, so it names the address
            // the user was told to expect.
            firstError ??= error;
            outstanding -= 1;
            if (outstanding == 0 && !settled.isCompleted) {
              settled.completeError(firstError ?? error);
            }
          },
        ),
      );
    }

    (Uri, WebSocketChannel) winner;
    try {
      winner = await settled.future;
    } catch (e) {
      if (generation != _generation) return;
      for (final attempt in attempts) {
        _closeQuietly(attempt);
      }
      _handleDisconnect(_describeConnectError(e));
      return;
    }

    final origin = winner.$1;
    final channel = winner.$2;
    for (final attempt in attempts) {
      if (attempt != channel) _closeQuietly(attempt);
    }

    if (generation != _generation) {
      _closeQuietly(channel);
      return;
    }

    // Reconnects go straight to the address that worked.
    if (origin != profile.url) {
      profile = ConnectionProfile(
        url: origin,
        alternates: candidates,
        token: profile.token,
        role: profile.role,
        agentId: profile.agentId,
        name: profile.name,
      );
      onAddressChanged?.call(origin);
    }

    _channel = channel;
    channel.sink.add(
      jsonEncode(buildHelloFrame(clientId: _clientId, name: profile.name)),
    );

    // Subscribing in the same write as `hello` instead of waiting for
    // `welcome`: both transports read a client's frames in order, so the
    // round trip spent waiting bought nothing and delayed the replay that
    // fills the screen. The roster is still needed for a session switch,
    // but not for attaching to the session pairing already named.
    final known = profile.agentId;
    if (known != null) _sendSubscribe(known);

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
        // Pairing usually names the target, and the connect path already
        // subscribed to it. When it did not, a lone roster entry is the only
        // unambiguous choice; with several the user picks one from the
        // switch sheet. This goes through subscribeToAgent rather than
        // _sendSubscribe because commands and request answers read
        // profile.agentId, and leaving it null receives events but refuses
        // to send anything.
        final target =
            profile.agentId ??
            (frame.agents.length == 1 ? frame.agents.single.agentId : null);
        if (target != null && _status.subscribedAgentId != target) {
          subscribeToAgent(target);
        }
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
      // The candidate list has to survive a roster switch: dropping it left
      // a later reconnect with one address to try.
      alternates: profile.alternates,
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
