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

const EVENT_RING_SIZE = 512;

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

	/// A hello starts a new epoch: the agent's seq counter restarts at 1, so
	/// retained frames from the previous run would replay out of order.
	resetForNewEpoch(): void {
		this.events.length = 0;
		this.state = undefined;
		this.pendingRequests.clear();
	}

	recordEvent(frame: CoreEvent): void {
		this.events.push({ seq: frame.seq, event: frame.event });
		if (this.events.length > EVENT_RING_SIZE) this.events.shift();
	}

	eventsSince(since: number): RetainedEvent[] {
		return this.events.filter((e) => e.seq > since);
	}
}

/// Tracks which agents exist and which clients are watching each one.
export class AgentRegistry {
	private readonly agents = new Map<string, AgentEntry>();

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

	/// Marks an agent offline but keeps its history, so a client reconnecting
	/// shortly after still sees what happened. Returns the entry when the call
	/// actually changed something.
	markOffline(agentId: string, channel: AgentChannel): AgentEntry | undefined {
		const entry = this.agents.get(agentId);
		if (!entry || entry.channel !== channel) return undefined;
		entry.online = false;
		entry.info = { ...entry.info, online: false };
		entry.pendingRequests.clear();
		return entry;
	}

	remove(agentId: string): void {
		this.agents.delete(agentId);
	}
}

export type { CoreRequest, CoreRequestCancel, CoreState };
