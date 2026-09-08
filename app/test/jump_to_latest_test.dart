// The jump button is the only way back to following once a reader has
// scrolled up. A lazy list revises its scroll extent while rows lay out, so
// animating to the extent sampled at the start of the gesture can land short
// of the real bottom, which reads as the button doing nothing.

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
  testWidgets('the jump button lands at the bottom and stays following', (
    tester,
  ) async {
    final store = SessionStore(relayClient: _Client());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TranscriptView(sessionStore: store)),
      ),
    );

    // Rows of very uneven height: what makes a lazy list's extent estimate
    // wrong until the tail has actually been laid out.
    for (var i = 0; i < 60; i++) {
      store.applyEventForTest(
        MessageEvent(
          role: 'assistant',
          text: i.isEven
              ? 'short $i'
              : List.generate(
                  14,
                  (line) => '## Section $i line $line with **bold** text',
                ).join('\n\n'),
        ),
      );
    }
    await tester.pump(const Duration(milliseconds: 300));

    // Scroll well away from the tail so the button appears.
    await tester.drag(find.byType(ListView), const Offset(0, 3000));
    await tester.pump();
    expect(
      find.byTooltip('Jump to the latest output'),
      findsOneWidget,
      reason: 'scrolled up, so the view is no longer following',
    );

    await tester.tap(find.byTooltip('Jump to the latest output'));
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 1),
      reason: 'the jump has to reach the real bottom, not an early estimate',
    );
    expect(
      find.byTooltip('Jump to the latest output'),
      findsNothing,
      reason: 'at the bottom the view follows again, so the button is gone',
    );
  });

  testWidgets('the jump button catches up with a tail that is still growing', (
    tester,
  ) async {
    final store = SessionStore(relayClient: _Client());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TranscriptView(sessionStore: store)),
      ),
    );

    for (var i = 0; i < 40; i++) {
      store.applyEventForTest(
        MessageEvent(role: 'assistant', text: 'settled paragraph $i'),
      );
    }
    await tester.pump(const Duration(milliseconds: 300));

    await tester.drag(find.byType(ListView), const Offset(0, 2000));
    await tester.pump();
    expect(find.byTooltip('Jump to the latest output'), findsOneWidget);

    // Tap, then keep the agent talking through the animation: this is what a
    // reader does mid-turn, and the bottom moves while the view travels to it.
    await tester.tap(find.byTooltip('Jump to the latest output'));
    for (var i = 0; i < 12; i++) {
      store.applyEventForTest(TextDeltaEvent(text: 'streamed line $i\n'));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 1),
      reason: 'the tail moved during the jump, and the view has to follow it',
    );
    expect(find.byTooltip('Jump to the latest output'), findsNothing);
  });
}
