// Attaching to a session that already has history is the common case: the
// transcript arrives in one burst and the view has to be looking at the end
// of it. Landing at the top is worse than it sounds, because a lazy list
// never builds the last row from there, so the row that re-pins the tail as
// it streams is never built either: new output appends below the fold and the
// screen looks stopped.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_omp/protocol.dart';
import 'package:remote_omp/relay_client.dart';
import 'package:remote_omp/session_store.dart';
import 'package:remote_omp/widgets/transcript_view.dart';

class _Client extends RelayClient {
  _Client()
    : super(
        profile: ConnectionProfile(
          url: Uri.parse('ws://127.0.0.1:1'),
          token: 't',
          role: ClientRole.control,
        ),
      );
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  testWidgets('a replayed transcript opens at its end', (tester) async {
    final store = SessionStore(relayClient: _Client());
    addTearDown(store.dispose);

    // The burst lands before the view is mounted, which is what a resumed
    // session does: the history is already in the store when the screen opens.
    for (var i = 0; i < 60; i++) {
      store.applyEventForTest(
        MessageEvent(
          role: 'assistant',
          text: '## Section $i\n\nA paragraph of replayed history.\n',
        ),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TranscriptView(sessionStore: store)),
      ),
    );
    await tester.pumpAndSettle();

    final position = _position(tester);
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 1),
      reason: 'the newest output is what a reader opens the session for',
    );
  });

  testWidgets('streaming into a replayed session keeps the tail in view', (
    tester,
  ) async {
    final store = SessionStore(relayClient: _Client());
    addTearDown(store.dispose);
    for (var i = 0; i < 60; i++) {
      store.applyEventForTest(
        MessageEvent(
          role: 'assistant',
          text: '## Section $i\n\nA paragraph of replayed history.\n',
        ),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TranscriptView(sessionStore: store)),
      ),
    );
    await tester.pumpAndSettle();

    // Now the agent answers, one delta at a time and no entry-list mutation.
    for (var i = 0; i < 30; i++) {
      store.applyEventForTest(TextDeltaEvent(text: 'streamed line $i\n'));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.textContaining('streamed line 29'), findsOneWidget);
    final position = _position(tester);
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
  });
}
