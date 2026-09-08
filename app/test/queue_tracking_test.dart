// omp owns the prompt queue and reports only whether it is non-empty, so the
// only way a client can name what is waiting is to remember what it sent.
// That memory has to be dropped the moment the workstation says the queue is
// empty, or the panel keeps claiming messages that already ran.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_omp/protocol.dart';
import 'package:remote_omp/relay_client.dart';
import 'package:remote_omp/session_store.dart';

StateSnapshot _snapshot({required bool streaming, required int queued}) =>
    StateSnapshot(
      sessionId: 's',
      cwd: '/tmp',
      streaming: streaming,
      compacting: false,
      queued: queued,
      pendingRequests: const [],
    );

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
  test('tracks what it sent and forgets it once the queue drains', () async {
    final store = SessionStore(relayClient: _Client());
    addTearDown(store.dispose);

    expect(store.sentQueue, isEmpty);

    store.noteQueuedPrompt('first');
    store.noteQueuedPrompt('second');
    expect(store.sentQueue, ['first', 'second']);

    // Still pending: the panel keeps showing both.
    store.applyFrameForTest(
      StateFrame(agentId: 'a', state: _snapshot(streaming: true, queued: 1)),
    );
    expect(store.sentQueue, ['first', 'second']);

    // The workstation says nothing is pending, so nothing is.
    store.applyFrameForTest(
      StateFrame(agentId: 'a', state: _snapshot(streaming: true, queued: 0)),
    );
    expect(store.sentQueue, isEmpty);
  });

  test('an idle session reports no queue', () async {
    final store = SessionStore(relayClient: _Client());
    addTearDown(store.dispose);

    store.noteQueuedPrompt('note');
    store.applyFrameForTest(
      StateFrame(agentId: 'a', state: _snapshot(streaming: false, queued: 0)),
    );
    expect(store.sentQueue, isEmpty);
  });
}
