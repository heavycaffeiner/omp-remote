// A prompt sent while the agent is working goes into omp's queue and is
// invisible until it runs, so the panel is what tells the sender it exists.
// omp owns that queue and exposes only whether it is non-empty, so the panel
// shows what this client sent and says where editing happens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_omp/widgets/queue_panel.dart';

Future<void> _pump(
  WidgetTester tester, {
  required int queued,
  required List<String> sent,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: QueuePanel(queued: queued, sent: sent),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  testWidgets('nothing pending shows nothing', (tester) async {
    await _pump(tester, queued: 0, sent: const []);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('lists what this client sent, oldest first', (tester) async {
    await _pump(tester, queued: 1, sent: const ['first note', 'second note']);

    expect(find.text('2 messages waiting to be delivered'), findsOneWidget);
    expect(find.text('first note'), findsOneWidget);
    expect(find.text('second note'), findsOneWidget);

    final first = tester.getTopLeft(find.text('first note'));
    final second = tester.getTopLeft(find.text('second note'));
    expect(first.dy, lessThan(second.dy));
  });

  testWidgets('a queue this client did not fill names its origin', (
    tester,
  ) async {
    // The workstation typed it. Claiming a count here would be inventing one:
    // the wire reports presence, not contents.
    await _pump(tester, queued: 1, sent: const []);
    expect(
      find.text('A message is waiting, typed at the workstation'),
      findsOneWidget,
    );
  });

  testWidgets('says where a pending message is edited', (tester) async {
    await _pump(tester, queued: 1, sent: const ['note']);
    expect(find.textContaining('done at the workstation'), findsOneWidget);
  });
}
