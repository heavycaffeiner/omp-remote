// The thinking control has to offer exactly what the model in use accepts.
// `high` and `xhigh` exist on some models and not others, and a model with no
// controllable effort surface accepts none at all, so a fixed list offered
// levels the workstation would reject.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_omp/protocol.dart';
import 'package:remote_omp/relay_client.dart';
import 'package:remote_omp/screens/model_screen.dart';
import 'package:remote_omp/session_store.dart';

StateSnapshot _snapshot({
  required ModelInfo model,
  String? level,
  List<String>? levels,
}) => StateSnapshot(
  sessionId: 's',
  cwd: '/tmp',
  model: model,
  thinkingLevel: level,
  thinkingLevels: levels,
  streaming: false,
  compacting: false,
  queued: 0,
  pendingRequests: const [],
);

/// A store whose state is set directly: the screen reads `state` and listens
/// for changes, which is all these tests exercise.
class _Store extends SessionStore {
  _Store(this._state) : super(relayClient: _NullClient());

  StateSnapshot _state;

  @override
  StateSnapshot? get state => _state;

  void push(StateSnapshot next) {
    _state = next;
    notifyListeners();
  }
}

/// The screen calls `sendCommand` only in response to a tap; these tests read
/// what is offered, so every call throwing is correct and keeps the test from
/// reaching a socket.
class _NullClient extends RelayClient {
  _NullClient()
    : super(
        profile: ConnectionProfile(
          url: Uri.parse('ws://127.0.0.1:1'),
          token: 't',
          role: ClientRole.control,
        ),
      );

  @override
  Future<Object?> sendCommand(
    CommandName cmd, {
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 60),
  }) async => throw const CommandFailedException('not connected');
}

Future<void> _pump(WidgetTester tester, _Store store) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ModelScreen(
        relayClient: store.relayClient,
        canControl: true,
        sessionStore: store,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  const sonnet = ModelInfo(provider: 'kami-router', id: 'claude-sonnet-5');
  const legacy = ModelInfo(provider: 'anthropic', id: 'claude-3-haiku');

  testWidgets('offers exactly the levels the model accepts', (tester) async {
    final store = _Store(
      _snapshot(
        model: sonnet,
        level: 'high',
        levels: const ['inherit', 'off', 'minimal', 'low', 'medium', 'high'],
      ),
    );
    await _pump(tester, store);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pump(const Duration(milliseconds: 20));

    // A level the model does not accept must not be on offer, whatever the
    // agent's own enum contains.
    expect(find.text('xhigh'), findsNothing);
    expect(find.text('max'), findsNothing);
    for (final level in ['inherit', 'off', 'minimal', 'low', 'medium']) {
      expect(find.text(level), findsWidgets, reason: '$level should be listed');
    }
  });

  testWidgets('a model with no effort control disables the picker', (
    tester,
  ) async {
    final store = _Store(_snapshot(model: legacy));
    await _pump(tester, store);

    expect(find.text('This model has no thinking control'), findsOneWidget);
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(dropdown.onChanged, isNull);
  });

  testWidgets('a model change replaces the offered levels', (tester) async {
    final store = _Store(
      _snapshot(
        model: sonnet,
        level: 'high',
        levels: const ['inherit', 'off', 'minimal', 'high'],
      ),
    );
    await _pump(tester, store);

    store.push(
      _snapshot(
        model: const ModelInfo(provider: 'anthropic', id: 'claude-opus-4-6'),
        level: 'max',
        levels: const ['inherit', 'off', 'low', 'medium', 'high', 'max'],
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('max'), findsWidgets);
    // `minimal` belonged to the previous model.
    expect(find.text('minimal'), findsNothing);
  });
}
