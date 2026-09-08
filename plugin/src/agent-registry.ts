// Routing table for the local server once it serves more than its own session.
//
// The first omp session to bind the port becomes the host and serves every
// client on it. Later sessions cannot bind, so they dial the host as guests on
// the same /agent endpoint the relay exposes, and the host routes between them
// and the app. One port, every session, and the app sees a roster exactly as it
// does through a relay.
//
// The host's own session is an entry here too, so nothing downstream needs to
// know which agent is local and which arrived over a socket.

import type {
	AgentInfo,
	CoreEvent,
	CoreRequest,
	CoreRequestCancel,
	CoreState,
	InteractiveRequest,
	StateSnapshot,
} from "./protocol-types.js";

/// Ceiling on the retained frame count, to bound the array itself. Sized so
/// a long session's whole replayed transcript fits.
const EVENT_RING_MAX = 8000;

/// Ceiling on the retained frame payload. Text is already truncated per
/// event, so this is what actually bounds memory.
const RETAIN_MAX_BYTES = 8 * 1024 * 1024;

/// How long an exited session stays in the roster. Long enough for a client
/// to reconnect after a drop and still see what happened, short enough that
/// the app's session list is not a graveyard.
const OFFLINE_GRACE_MS = 120_000;

/// What the registry can send to one agent. The host's own session answers in
/// process; a guest answers over its socket.
export interface AgentChannel {
	sendCommand(id: string, cmd: string, args: unknown): void;
	sendResponse(id: string, response: unknown): void;
	sendViewers(counts: { control: number; viewer: number }): void;
	close(reason: string): void;
}

interface RetainedEvent {
	seq: number;
	event: CoreEvent["event"];
	bytes: number;
}

/// One registered agent: its identity, what it has emitted, and how to reach it.
export class AgentEntry {
	constructor(
		public info: AgentInfo,
		public channel: AgentChannel,
	) {}

	online = true;
	state: StateSnapshot | undefined;
	readonly events: RetainedEvent[] = [];
	readonly pendingRequests = new Map<string, InteractiveRequest>();
	private retainedBytes = 0;

	/// A hello starts a new epoch: the agent's seq counter restarts at 1, so
	/// retained frames from the previous run would replay out of order.
	resetForNewEpoch(): void {
		this.events.length = 0;
		this.retainedBytes = 0;
		this.state = undefined;
		this.pendingRequests.clear();
	}

	/// Retains the frame, evicting the oldest once either budget is spent.
	///
	/// A count alone was the wrong bound: replaying a resumed session's whole
	/// transcript is what fills this buffer, and one long conversation
	/// produces far more than a few hundred frames, so the start of it fell
	/// out before any client could read it. Bytes are what actually cost
	/// something, so that is what is capped, with a count ceiling to bound
	/// the array itself.
	recordEvent(frame: CoreEvent): void {
		const bytes = estimateEventBytes(frame.event);
		this.events.push({ seq: frame.seq, event: frame.event, bytes });
		this.retainedBytes += bytes;
		while (
			this.events.length > EVENT_RING_MAX &&
			this.events.length > 1
		) {
			this.retainedBytes -= (this.events.shift() as RetainedEvent).bytes;
		}
		while (this.retainedBytes > RETAIN_MAX_BYTES && this.events.length > 1) {
			this.retainedBytes -= (this.events.shift() as RetainedEvent).bytes;
		}
	}

	eventsSince(since: number): RetainedEvent[] {
		return this.events.filter((e) => e.seq > since);
	}
}

/// Rough on-the-wire size of one event. Only the text-bearing fields matter;
/// the rest is a handful of short keys.
function estimateEventBytes(event: CoreEvent["event"]): number {
	let total = 64;
	for (const value of Object.values(event as unknown as Record<string, unknown>)) {
		if (typeof value === "string") total += Buffer.byteLength(value, "utf8");
	}
	return total;
}

/// Tracks which agents exist and which clients are watching each one.
export class AgentRegistry {
	private readonly agents = new Map<string, AgentEntry>();
	private readonly reapTimers = new Map<string, Timer>();

	/// Called when an agent is dropped for staying offline, so the server can
	/// tell attached clients the roster changed.
	onReaped: ((agentId: string) => void) | undefined;

	get size(): number {
		return this.agents.size;
	}

	list(): AgentInfo[] {
		return Array.from(this.agents.values())
			.map((a) => ({ ...a.info, online: a.online }))
			.sort((a, b) => a.agentId.localeCompare(b.agentId));
	}

	get(agentId: string): AgentEntry | undefined {
		return this.agents.get(agentId);
	}

	/// Registers an agent, replacing any live entry under the same id. A
	/// workstation that reconnects after a drop must not be locked out by its
	/// own stale connection, so the previous channel is closed and the retained
	/// history dropped.
	register(info: AgentInfo, channel: AgentChannel): AgentEntry {
		const existing = this.agents.get(info.agentId);
		if (existing) {
			if (existing.online) existing.channel.close("replaced by a newer connection");
			existing.info = info;
			existing.channel = channel;
			existing.online = true;
			existing.resetForNewEpoch();
			return existing;
		}
		const entry = new AgentEntry(info, channel);
		this.agents.set(info.agentId, entry);
		return entry;
	}

	/// Marks an agent offline but keeps its history for a while, so a client
	/// reconnecting shortly after still sees what happened. The entry is
	/// dropped once the grace period passes: a session that exited is gone,
	/// and leaving it in the roster forever means the app's session list fills
	/// with dead entries nobody can connect to. Returns the entry when the
	/// call actually changed something.
	markOffline(agentId: string, channel: AgentChannel): AgentEntry | undefined {
		const entry = this.agents.get(agentId);
		if (!entry || entry.channel !== channel) return undefined;
		entry.online = false;
		entry.info = { ...entry.info, online: false };
		entry.pendingRequests.clear();

		clearTimeout(this.reapTimers.get(agentId));
		const timer = setTimeout(() => {
			this.reapTimers.delete(agentId);
			const current = this.agents.get(agentId);
			if (current && !current.online) {
				this.agents.delete(agentId);
				this.onReaped?.(agentId);
			}
		}, OFFLINE_GRACE_MS);
		// Never a reason to hold the process open.
		timer.unref?.();
		this.reapTimers.set(agentId, timer);
		return entry;
	}

	remove(agentId: string): void {
		clearTimeout(this.reapTimers.get(agentId));
		this.reapTimers.delete(agentId);
		this.agents.delete(agentId);
	}

	/// Cancels every pending reap. Called at shutdown so a timer cannot fire
	/// against a torn-down server.
	dispose(): void {
		for (const timer of this.reapTimers.values()) {
			clearTimeout(timer);
		}
		this.reapTimers.clear();
	}
}

export type { CoreRequest, CoreRequestCancel, CoreState };
