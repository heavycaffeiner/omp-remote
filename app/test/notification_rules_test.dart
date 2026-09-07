// Exercises the pure notification decision logic with synthetic frame
// sequences, including a reconnect replay, without any plugin binding.

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_omp/notification_rules.dart';
import 'package:remote_omp/protocol.dart';

String _label(String agentId) => 'Agent $agentId';

void main() {
  group('interactive requests', () {
    test('a request notifies, high priority, keyed to the request', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const RequestFrame(
          agentId: 'a1',
          id: 'req-1',
          request: ConfirmRequest(title: 'Run the test suite?', message: ''),
        ),
        sessionLabel: _label,
      );

      expect(action, isA<ShowNotification>());
      final show = action as ShowNotification;
      expect(show.priority, NotificationPriority.high);
      expect(show.tag, 'a1');
      expect(show.body, contains('Run the test suite?'));
      expect(show.payload.agentId, 'a1');
      expect(show.payload.requestId, 'req-1');
    });

    test('the matching request_cancel cancels the same notification id', () {
      final decider = NotificationDecider();
      final shown =
          decider.decide(
                const RequestFrame(
                  agentId: 'a1',
                  id: 'req-1',
                  request: ConfirmRequest(title: 'Run tests?', message: ''),
                ),
                sessionLabel: _label,
              )
              as ShowNotification;

      final action = decider.decide(
        const RequestCancelFrame(
          agentId: 'a1',
          id: 'req-1',
          reason: 'answered_locally',
        ),
        sessionLabel: _label,
      );

      expect(action, isA<CancelNotification>());
      final cancel = action as CancelNotification;
      expect(cancel.id, shown.id);
      expect(cancel.tag, 'a1');
    });

    test('a cancel for an id never shown produces no action', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const RequestCancelFrame(
          agentId: 'a1',
          id: 'never-shown',
          reason: 'timed_out',
        ),
        sessionLabel: _label,
      );
      expect(action, isNull);
    });

    test('a second request frame for the same id (resubscribe replay) does not re-notify', () {
      final decider = NotificationDecider();
      const frame = RequestFrame(
        agentId: 'a1',
        id: 'req-1',
        request: ConfirmRequest(title: 'Run tests?', message: ''),
      );
      final first = decider.decide(frame, sessionLabel: _label);
      final second = decider.decide(frame, sessionLabel: _label);

      expect(first, isA<ShowNotification>());
      expect(second, isNull);
    });

    test('requests from different agents never share a notification tag', () {
      final decider = NotificationDecider();
      final a = decider.decide(
        const RequestFrame(
          agentId: 'agent-a',
          id: 'req-1',
          request: ConfirmRequest(title: 'Deploy?', message: ''),
        ),
        sessionLabel: _label,
      );
      final b = decider.decide(
        const RequestFrame(
          agentId: 'agent-b',
          id: 'req-1',
          request: ConfirmRequest(title: 'Deploy?', message: ''),
        ),
        sessionLabel: _label,
      );

      final showA = a as ShowNotification;
      final showB = b as ShowNotification;
      expect(showA.tag, isNot(showB.tag));
      expect(showA.id, isNot(showB.id));
    });

    test('a request already on screen in the foreground does not notify', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const RequestFrame(
          agentId: 'a1',
          id: 'req-1',
          request: ConfirmRequest(title: 'Run tests?', message: ''),
        ),
        sessionLabel: _label,
        foreground: const NotificationForegroundState(
          appInForeground: true,
          foregroundAgentId: 'a1',
          foregroundRequestId: 'req-1',
        ),
      );
      expect(action, isNull);
    });
  });

  group('session events', () {
    test('a replayed event after reconnect does not re-notify (dedup by agentId:seq)', () {
      final decider = NotificationDecider();
      const frame = EventFrame(
        agentId: 'a1',
        seq: 4,
        event: NoticeEvent(level: 'error', text: 'Something broke'),
      );

      final first = decider.decide(frame, sessionLabel: _label);
      // Simulates a reconnect's `subscribe` replaying the same retained
      // event again (docs/protocol.md: replay covers seq > since, and a
      // client resuming from its own last-seen seq will see this frame
      // again if it reconnects before advancing past it).
      final replay = decider.decide(frame, sessionLabel: _label);

      expect(first, isA<ShowNotification>());
      expect(replay, isNull);
    });

    test('an info notice does not notify', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const EventFrame(
          agentId: 'a1',
          seq: 1,
          event: NoticeEvent(level: 'info', text: 'Reading a file'),
        ),
        sessionLabel: _label,
      );
      expect(action, isNull);
    });

    test('a warning notice notifies at normal priority', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const EventFrame(
          agentId: 'a1',
          seq: 1,
          event: NoticeEvent(level: 'warning', text: 'Disk almost full'),
        ),
        sessionLabel: _label,
      );
      expect(action, isA<ShowNotification>());
      expect((action as ShowNotification).priority, NotificationPriority.normal);
    });

    test('an error notice notifies', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const EventFrame(
          agentId: 'a1',
          seq: 1,
          event: NoticeEvent(level: 'error', text: 'Build failed'),
        ),
        sessionLabel: _label,
      );
      expect(action, isA<ShowNotification>());
    });

    test('agent_end with terminal: false does not notify (more work is scheduled)', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const EventFrame(
          agentId: 'a1',
          seq: 1,
          event: AgentEndEvent(terminal: false),
        ),
        sessionLabel: _label,
      );
      expect(action, isNull);
    });

    test('agent_end with terminal: true notifies at normal priority, naming the session', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const EventFrame(agentId: 'a1', seq: 1, event: AgentEndEvent(terminal: true)),
        sessionLabel: _label,
      );
      expect(action, isA<ShowNotification>());
      final show = action as ShowNotification;
      expect(show.priority, NotificationPriority.normal);
      expect(show.body, contains('Agent a1'));
      expect(show.body, contains('idle'));
    });

    test('agent_end is suppressed when that session is on screen in the foreground', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const EventFrame(agentId: 'a1', seq: 1, event: AgentEndEvent(terminal: true)),
        sessionLabel: _label,
        foreground: const NotificationForegroundState(
          appInForeground: true,
          foregroundAgentId: 'a1',
        ),
      );
      expect(action, isNull);
    });

    test('a failed tool call notifies', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const EventFrame(
          agentId: 'a1',
          seq: 1,
          event: ToolEndEvent(id: 't1', name: 'bash', ok: false, text: 'exit 1'),
        ),
        sessionLabel: _label,
      );
      expect(action, isA<ShowNotification>());
    });

    test('a successful tool call does not notify', () {
      final decider = NotificationDecider();
      final action = decider.decide(
        const EventFrame(
          agentId: 'a1',
          seq: 1,
          event: ToolEndEvent(id: 't1', name: 'bash', ok: true, text: 'done'),
        ),
        sessionLabel: _label,
      );
      expect(action, isNull);
    });

    for (final ignored in [
      const TextDeltaEvent(text: 'partial'),
      const ThinkingDeltaEvent(text: 'thinking'),
      const TodosEvent(todos: []),
      const TurnStartEvent(),
      const TurnEndEvent(),
      const AgentStartEvent(),
    ]) {
      test('${ignored.runtimeType} never notifies', () {
        final decider = NotificationDecider();
        final action = decider.decide(
          EventFrame(agentId: 'a1', seq: 1, event: ignored),
          sessionLabel: _label,
        );
        expect(action, isNull);
      });
    }
  });

  group('non-actionable frames', () {
    test('welcome, agents, state, and reply frames never notify', () {
      final decider = NotificationDecider();
      for (final frame in [
        const WelcomeFrame(protocol: 2, clientId: 'c1', role: ClientRole.control, agents: []),
        const AgentsFrame(agents: []),
        StateFrame(agentId: 'a1', state: StateSnapshot.fromJson({'streaming': false, 'compacting': false, 'queued': 0})),
        const ReplyFrame(id: 'cmd-1', ok: true),
      ]) {
        expect(decider.decide(frame, sessionLabel: _label), isNull);
      }
    });
  });

  group('payload encoding', () {
    test('round trips agent id and request id through the string payload', () {
      const payload = NotificationPayload(agentId: 'a1', requestId: 'req-1');
      final decoded = NotificationPayload.decode(payload.encode());
      expect(decoded!.agentId, 'a1');
      expect(decoded.requestId, 'req-1');
    });

    test('round trips with no request id', () {
      const payload = NotificationPayload(agentId: 'a1');
      final decoded = NotificationPayload.decode(payload.encode());
      expect(decoded!.agentId, 'a1');
      expect(decoded.requestId, isNull);
    });

    test('malformed payload text decodes to null rather than throwing', () {
      expect(NotificationPayload.decode('not json'), isNull);
      expect(NotificationPayload.decode(null), isNull);
    });
  });

  group('resetForAgent', () {
    test('clears dedup state only for the given agent, letting it notify again', () {
      final decider = NotificationDecider();
      const frame = EventFrame(
        agentId: 'a1',
        seq: 1,
        event: NoticeEvent(level: 'error', text: 'boom'),
      );
      expect(decider.decide(frame, sessionLabel: _label), isA<ShowNotification>());
      expect(decider.decide(frame, sessionLabel: _label), isNull);

      decider.resetForAgent('a1');
      expect(decider.decide(frame, sessionLabel: _label), isA<ShowNotification>());
    });

    test('does not affect another agent\'s dedup state', () {
      final decider = NotificationDecider();
      const frameA = EventFrame(agentId: 'a1', seq: 1, event: NoticeEvent(level: 'error', text: 'boom'));
      const frameB = EventFrame(agentId: 'b1', seq: 1, event: NoticeEvent(level: 'error', text: 'boom'));
      decider.decide(frameA, sessionLabel: _label);
      decider.decide(frameB, sessionLabel: _label);

      decider.resetForAgent('a1');
      expect(decider.decide(frameB, sessionLabel: _label), isNull);
    });
  });
}
