// A streaming turn arrives a delta at a time and never touches the entry
// list, so it does not go through the coalescer. The row still has to repaint
// and the view still has to follow it, or a phone at the tail watches a
// frozen screen while the agent talks.

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

void main() {
  testWidgets('a delta reaches the screen without an entry-list mutation', (
    tester,
  ) async {
    final store = SessionStore(relayClient: _Client());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TranscriptView(sessionStore: store)),
      ),
    );

    store.applyEventForTest(TextDeltaEvent(text: 'first '));
    await tester.pump();
    expect(find.textContaining('first'), findsOneWidget);

    // Nothing but deltas from here: no MessageEvent, no new entry.
    for (final word in ['second ', 'third ', 'fourth ']) {
      store.applyEventForTest(TextDeltaEvent(text: word));
      await tester.pump();
      expect(
        find.textContaining(word.trim()),
        findsOneWidget,
        reason: '$word should be on screen the frame after it arrived',
      );
    }
  });

  testWidgets('the view stays at the tail as a streaming row grows', (
    tester,
  ) async {
    final store = SessionStore(relayClient: _Client());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TranscriptView(sessionStore: store)),
      ),
    );

    // Fill past a screen so there is somewhere to fall behind to.
    for (var i = 0; i < 40; i++) {
      store.applyEventForTest(
        MessageEvent(role: 'assistant', text: 'settled paragraph $i'),
      );
    }
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    // Now stream a long answer in, one delta at a time.
    for (var i = 0; i < 40; i++) {
      store.applyEventForTest(TextDeltaEvent(text: 'line $i of the answer\n'));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 200));

    // The newest text is what a phone at the tail should be looking at.
    expect(find.textContaining('line 39 of the answer'), findsOneWidget);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
  });
}
