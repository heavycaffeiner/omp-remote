// Pumps the session screen with a synthetic transcript (no live socket)
// and asserts it renders the expected content and controls.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_omp/protocol.dart';
import 'package:remote_omp/relay_client.dart';
import 'package:remote_omp/session_store.dart';
import 'package:remote_omp/widgets/state_header.dart';
import 'package:remote_omp/widgets/transcript_view.dart';

void main() {
  testWidgets('transcript view renders a streaming assistant block and a finalized tool call',
      (WidgetTester tester) async {
    final client = RelayClient(
      profile: ConnectionProfile(
        url: Uri.parse('ws://localhost:8788'),
        token: 'test-token',
        role: ClientRole.control,
        agentId: 'test-host/test-agent',
      ),
    );
    addTearDown(client.dispose);

    final store = SessionStore(relayClient: client);
    addTearDown(store.dispose);

    // Synthesize the same event sequence the wire protocol would deliver:
    // a streaming text delta, a tool call, and a final message that closes
    // the streaming block.
    store.applyEventForTest(const TextDeltaEvent(text: 'Reading '));
    store.applyEventForTest(const TextDeltaEvent(text: 'the file...'));
    store.applyEventForTest(const ToolStartEvent(id: 't1', name: 'read', input: 'foo.txt'));
    store.applyEventForTest(const ToolEndEvent(id: 't1', name: 'read', ok: true, text: 'done'));
    store.applyEventForTest(const MessageEvent(role: 'assistant', text: 'Reading the file...done.'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const StateHeader(
                status: ConnectionStatus(phase: ConnectionPhase.connected, role: ClientRole.control),
                state: null,
              ),
              Expanded(child: TranscriptView(sessionStore: store)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Reading the file...done.'), findsOneWidget);
    expect(find.textContaining('read'), findsWidgets);
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('unknown event kind and malformed frame do not crash parsing', (WidgetTester tester) async {
    final unknown = SessionEvent.fromJson({'k': 'something_new_from_the_future'});
    expect(unknown, isA<UnknownEvent>());

    final malformedFrame = ServerFrame.fromJson({'t': 'event', 'agentId': 'a'});
    expect(malformedFrame, isA<UnknownFrame>());

    final malformedState = StateSnapshot.fromJson({'streaming': 'not-a-bool', 'queued': 'also-not-int'});
    expect(malformedState.streaming, isFalse);
    expect(malformedState.queued, 0);
  });
}
