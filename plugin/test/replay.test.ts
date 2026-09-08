// Replaying a transcript is what lets a client attach to a resumed session
// and see it. Doing it twice is what made a phone re-download the whole
// conversation on every reconnect: each replayed entry goes out under a
// fresh, higher seq, so a client cannot recognize the second copy as one it
// already has, and the retained ring evicts the live events to hold it.

import { describe, expect, test } from "bun:test";

import { SessionBridge } from "../src/session-bridge.js";
import type { RemoteConfig } from "../src/config.js";

const config: RemoteConfig = {
	agentId: "host/project#test",
	agentName: "project",
	allowBash: false,
	remoteApproval: false,
};

/// The slice of `ExtensionAPI` the bridge touches while replaying. The real
/// one needs a live session; replay reads the branch and broadcasts, so
/// nothing else has to exist for this.
function stubPi(): unknown {
	return {
		on: () => {},
		events: { on: () => {} },
		getThinkingLevel: () => undefined,
		sendUserMessage: () => {},
	};
}

/// A context whose branch holds `count` user messages under the entry shape
/// `buildHistoryEvents` reads.
function stubCtx(sessionId: string, count: number): unknown {
	const entries = Array.from({ length: count }, (_, i) => ({
		type: "message",
		message: { role: "user", content: `message ${i}` },
	}));
	return {
		cwd: "/tmp",
		isIdle: () => true,
		hasPendingMessages: () => false,
		getContextUsage: () => undefined,
		sessionManager: {
			getSessionId: () => sessionId,
			getSessionName: () => undefined,
			getSessionFile: () => undefined,
			getBranch: () => entries,
		},
	};
}

describe("replayHistory", () => {
	test("replays the branch once for one session", () => {
		const bridge = new SessionBridge(stubPi() as never, config);
		let events = 0;
		bridge.attachSink({
			sendEvent: () => {
				events += 1;
			},
			sendState: () => {},
			sendRequest: () => {},
			sendRequestCancel: () => {},
			sendReply: () => {},
		} as never);

		const ctx = stubCtx("session-a", 3);
		bridge.replayHistory(ctx as never);
		const afterFirst = events;
		expect(afterFirst).toBeGreaterThan(0);

		// `session_start` fires more than once for a resumed session.
		bridge.replayHistory(ctx as never);
		bridge.replayHistory(ctx as never);
		expect(events).toBe(afterFirst);
	});

	test("replays again when the transcript is a different one", () => {
		const bridge = new SessionBridge(stubPi() as never, config);
		let events = 0;
		bridge.attachSink({
			sendEvent: () => {
				events += 1;
			},
			sendState: () => {},
			sendRequest: () => {},
			sendRequestCancel: () => {},
			sendReply: () => {},
		} as never);

		bridge.replayHistory(stubCtx("session-a", 2) as never);
		const afterFirst = events;
		// A switch, branch, or tree move lands on a transcript the client has
		// never seen, and suppressing that leaves the previous session's
		// history on screen.
		bridge.replayHistory(stubCtx("session-b", 2) as never);
		expect(events).toBeGreaterThan(afterFirst);
	});

	test("every replayed event carries a distinct rising seq", () => {
		const bridge = new SessionBridge(stubPi() as never, config);
		const seqs: number[] = [];
		bridge.attachSink({
			sendEvent: (frame: { seq: number }) => {
				seqs.push(frame.seq);
			},
			sendState: () => {},
			sendRequest: () => {},
			sendRequestCancel: () => {},
			sendReply: () => {},
		} as never);

		bridge.replayHistory(stubCtx("session-a", 4) as never);
		expect(seqs.length).toBeGreaterThan(0);
		expect(new Set(seqs).size).toBe(seqs.length);
		// Rising seqs are why a duplicate replay cannot be deduplicated by a
		// client, which is what the gate above exists to prevent.
		for (let i = 1; i < seqs.length; i++) {
			expect(seqs[i]).toBeGreaterThan(seqs[i - 1] as number);
		}
	});
});
