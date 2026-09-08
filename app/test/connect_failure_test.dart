// A workstation that drops the port is the common failure: the listener is
// up, the phone's connect is filtered, and the app has to say so. It used to
// clear the reason and drop back to `connecting` on every retry, which read
// as an endless spinner with nothing on screen to explain it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_omp/protocol.dart';
import 'package:remote_omp/relay_client.dart';
import 'package:remote_omp/widgets/state_header.dart';

void main() {
  test(
    'a failed connect keeps its reason and reports it as retrying',
    () async {
      final client = RelayClient(
        profile: ConnectionProfile(
          // Nothing listens here, so the connect fails immediately.
          url: Uri.parse('ws://127.0.0.1:1'),
          token: 'test-token',
          role: ClientRole.control,
          agentId: 'host/agent',
        ),
      );
      addTearDown(client.dispose);

      final seen = <ConnectionStatus>[];
      final sub = client.statusStream.listen(seen.add);
      addTearDown(sub.cancel);

      await client.connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The first attempt announces itself as connecting, then fails.
      expect(
        seen.map((s) => s.phase),
        containsAllInOrder([
          ConnectionPhase.connecting,
          ConnectionPhase.reconnecting,
        ]),
      );
      expect(client.status.lastError, isNotNull);

      // The retry must not wipe the reason or claim to be a first attempt.
      final before = seen.length;
      await client.retryNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.status.lastError, isNotNull);
      expect(
        seen.skip(before).map((s) => s.phase),
        isNot(contains(ConnectionPhase.connecting)),
      );
    },
  );

  testWidgets('the status band names the failure and offers a retry', (
    WidgetTester tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StateHeader(
            status: const ConnectionStatus(
              phase: ConnectionPhase.reconnecting,
              lastError: 'host unreachable: connection timed out',
            ),
            state: null,
            activeSessionLabel: 'tmp (host/agent)',
            onRetry: () => retries++,
          ),
        ),
      ),
    );

    // Collapsed, the reason is the line. A spinner that says only
    // "Reconnecting" leaves the user with nothing to act on.
    expect(
      find.textContaining('host unreachable: connection timed out'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Try connecting again'));
    expect(retries, 1);
  });

  testWidgets('a connected band shows the session, not a stale error', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StateHeader(
            status: const ConnectionStatus(
              phase: ConnectionPhase.connected,
              role: ClientRole.control,
            ),
            state: null,
            activeSessionLabel: 'tmp (host/agent)',
            onRetry: () {},
          ),
        ),
      ),
    );

    expect(find.textContaining('tmp (host/agent)'), findsOneWidget);
    expect(find.byTooltip('Try connecting again'), findsNothing);
  });
}
