// A direct connection carries no agent id in its profile: the protocol says
// there is exactly one agent, so the client learns it from the welcome roster.
// Two bugs lived in that gap. The client never subscribed at all, so no events
// arrived; and once it did, the id was not stored, so commands and answers to
// interactive requests had no target and were dropped.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_omp/protocol.dart';
import 'package:remote_omp/relay_client.dart';

/// A stand-in for the plugin's local server: accepts one client, answers the
/// handshake, and records what the client sends.
class _FakeAgent {
  _FakeAgent(this._server);

  final HttpServer _server;
  final List<Map<String, Object?>> received = [];
  WebSocket? _socket;

  static const agentId = 'workstation/project#ab12';

  static Future<_FakeAgent> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final agent = _FakeAgent(server);
    unawaited(agent._accept());
    return agent;
  }

  Uri get url => Uri.parse('ws://127.0.0.1:${_server.port}');

  Future<void> _accept() async {
    await for (final request in _server) {
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, Object?>;
        received.add(frame);
        if (frame['t'] == 'hello') {
          socket.add(
            jsonEncode({
              't': 'welcome',
              'protocol': 2,
              'clientId': frame['clientId'],
              'role': 'control',
              'agents': [
                {
                  'agentId': agentId,
                  'name': 'project',
                  'host': 'workstation',
                  'cwd': '/home/kim/project',
                  'online': true,
                  'connectedAt': 1757203200000,
                },
              ],
            }),
          );
        }
      });
    }
  }

  void send(Map<String, Object?> frame) => _socket?.add(jsonEncode(frame));

  Future<void> close() async {
    await _socket?.close();
    await _server.close(force: true);
  }
}

/// Waits until [test] holds or the timeout lapses, so a test never hangs on a
/// frame that is not coming.
Future<void> _until(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never became true');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late _FakeAgent agent;
  late RelayClient client;

  setUp(() async {
    agent = await _FakeAgent.start();
    client = RelayClient(
      profile: ConnectionProfile(
        url: agent.url,
        token: 'token',
        role: ClientRole.control,
        name: 'phone',
      ),
    );
  });

  tearDown(() async {
    await client.close();
    await agent.close();
  });

  test('subscribes to the only agent when the profile names none', () async {
    await client.connect();
    await _until(() => agent.received.any((f) => f['t'] == 'subscribe'));

    final subscribe = agent.received.firstWhere((f) => f['t'] == 'subscribe');
    expect(subscribe['agentId'], _FakeAgent.agentId);
    expect(subscribe['since'], 0);
  });

  test('commands reach the agent after that implicit subscribe', () async {
    await client.connect();
    await _until(() => agent.received.any((f) => f['t'] == 'subscribe'));

    unawaited(
      client.sendCommand(CommandName.abort).catchError((Object _) => null),
    );
    await _until(() => agent.received.any((f) => f['t'] == 'command'));

    final command = agent.received.firstWhere((f) => f['t'] == 'command');
    expect(command['agentId'], _FakeAgent.agentId);
    expect(command['cmd'], 'abort');
  });

  test('an interactive request can be answered', () async {
    await client.connect();
    await _until(() => agent.received.any((f) => f['t'] == 'subscribe'));

    client.sendResponse(requestId: 'req-1', response: {'confirmed': true});
    await _until(() => agent.received.any((f) => f['t'] == 'response'));

    final response = agent.received.firstWhere((f) => f['t'] == 'response');
    expect(response['agentId'], _FakeAgent.agentId);
    expect(response['id'], 'req-1');
  });

  test('resubscribing after events resumes rather than replaying', () async {
    await client.connect();
    await _until(() => agent.received.any((f) => f['t'] == 'subscribe'));

    agent.send({
      't': 'event',
      'agentId': _FakeAgent.agentId,
      'seq': 7,
      'event': {'k': 'turn_start'},
    });
    await _until(() => client.highestSeq == 7);

    // Re-targeting the agent already subscribed to is what a reconnect does.
    // Starting over at zero would replay the whole retained buffer.
    client.subscribeToAgent(_FakeAgent.agentId);
    await _until(
      () => agent.received.where((f) => f['t'] == 'subscribe').length >= 2,
    );

    final resubscribe = agent.received.lastWhere((f) => f['t'] == 'subscribe');
    expect(resubscribe['since'], 7);
    expect(agent.received.any((f) => f['t'] == 'unsubscribe'), isFalse);
  });
}
