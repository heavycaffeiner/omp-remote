// A question the tool asked for several answers must not silently become a
// single-choice one: the agent reads `selectedOptions` back and would act on
// one pick where the user meant three.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_omp/protocol.dart';
import 'package:remote_omp/session_store.dart';
import 'package:remote_omp/widgets/interactive_request_card.dart';

const _options = [
  SelectOption(label: 'read'),
  SelectOption(label: 'write', description: 'and edit'),
  SelectOption(label: 'bash'),
];

Future<List<Map<String, Object?>>> _pump(
  WidgetTester tester, {
  required bool multi,
}) async {
  final answers = <Map<String, Object?>>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: InteractiveRequestCard(
          pending: PendingRequestState(
            id: 'r1',
            request: SelectRequest(
              title: 'Which tools?',
              message: '',
              options: _options,
              multi: multi,
            ),
            receivedAt: DateTime.now(),
          ),
          onAnswer: answers.add,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 20));
  return answers;
}

void main() {
  testWidgets('a single-choice question answers on tap', (tester) async {
    final answers = await _pump(tester, multi: false);

    await tester.tap(find.text('bash'));
    await tester.pump(const Duration(milliseconds: 20));

    expect(answers, [
      {'index': 2},
    ]);
  });

  testWidgets('a multi question collects picks and sends them together', (
    tester,
  ) async {
    final answers = await _pump(tester, multi: true);

    // Tapping must not answer yet: the point of a multi question is more
    // than one pick.
    await tester.tap(find.text('bash'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(answers, isEmpty);

    await tester.tap(find.text('read'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Send 2'), findsOneWidget);

    await tester.tap(find.text('Send 2'));
    await tester.pump(const Duration(milliseconds: 20));

    // Pick order, not option order: the agent reads them back in the order
    // the user chose.
    expect(answers, [
      {
        'indexes': [2, 0],
      },
    ]);
  });

  testWidgets('a multi question with nothing picked cannot be sent', (
    tester,
  ) async {
    await _pump(tester, multi: true);

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('tapping a picked option in a multi question unpicks it', (
    tester,
  ) async {
    final answers = await _pump(tester, multi: true);

    await tester.tap(find.text('write'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.text('write'));
    await tester.pump(const Duration(milliseconds: 20));

    expect(answers, isEmpty);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });
}
