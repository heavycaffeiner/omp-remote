// The workstation's own hub (docs/protocol.md, "Direct").
//
// The first omp session to bind the port serves it for every session on the
// machine: it answers apps on /client and accepts other sessions as agents on
// /agent, exactly as the relay does. A session that cannot bind dials this one
// instead. So one port carries every session, and an app sees the same roster
// whether it reached the workstation directly or through a relay.

import * as crypto from "node:crypto";
import * as os from "node:os";
import type { Server, ServerWebSocket } from "bun";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import type {
	AgentInfo,
	AgentToRelayFrame,
	ClientToServerFrame,
	CoreEvent,
	FrameCommand,
	FrameResponse,
	Role,
	ServerToClientFrame,
} from "./protocol-types.js";
import { PROTOCOL_VERSION } from "./protocol-types.js";
import type { OutboundSink, SessionBridge } from "./session-bridge.js";
import type { RemoteConfig } from "./config.js";
import { executeCommand, type CommandResult } from "./commands.js";
import { AgentRegistry, type AgentChannel, type AgentEntry } from "./agent-registry.js";

export interface LocalServerTokens {
	control: string;
	viewer: string;
	// Presented by another session on this workstation joining as an agent.
	agent: string;
}

const MAX_INBOUND_BYTES = 1024 * 1024;
const MAX_OUTBOUND_QUEUE = 256;
const PING_INTERVAL_MS = 20000;
const READ_TIMEOUT_SECONDS = 60;
const COMMAND_TIMEOUT_MS = 60000;
const PAIRING_CODE_TTL_MS = 5 * 60 * 1000;
// Crockford base32 without I, L, O, and U: no character pair a person can
// confuse while reading a code off one screen and typing it into another.
const PAIRING_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
// Guessing is bounded by expiry and single use, but not by anything else, so
// a burst of wrong codes stops redemption until the outstanding ones lapse.
const MAX_FAILED_REDEMPTIONS = 10;

function randomPairingCode(): string {
	const bytes = crypto.randomBytes(6);
	let out = "";
	for (const byte of bytes) out += PAIRING_CODE_ALPHABET[byte % PAIRING_CODE_ALPHABET.length];
	return out;
}

// A connection is either a client watching agents or a guest session offering
// itself as one. The kind is fixed at upgrade time by which endpoint was
// dialed, never by anything the peer sends.
interface ConnectionState {
	kind: "client" | "agent";
	role: Role;
	subscriptions: Set<string>;
	agentId: string | undefined;
	backpressureStreak: number;
	pingTimer: Timer | undefined;
}

type LocalWebSocket = ServerWebSocket<ConnectionState>;

// Compares a presented token against every known token without short-
// circuiting, so response timing does not reveal which one matched (or
// whether either did).
function constantTimeEquals(presented: Buffer, known: string): boolean {
	const knownBuf = Buffer.from(known, "utf8");
	return presented.length === knownBuf.length && crypto.timingSafeEqual(presented, knownBuf);
}

function matchClientToken(presented: string, tokens: LocalServerTokens): Role | undefined {
	const buf = Buffer.from(presented, "utf8");
	const control = constantTimeEquals(buf, tokens.control);
	const viewer = constantTimeEquals(buf, tokens.viewer);
	if (control) return "control";
	if (viewer) return "viewer";
	return undefined;
}

function extractToken(req: Request, url: URL): string | undefined {
	const auth = req.headers.get("authorization");
	if (auth) {
		const match = /^Bearer\s+(.+)$/i.exec(auth);
		if (match?.[1]) return match[1];
	}
	const queryToken = url.searchParams.get("token");
	return queryToken ?? undefined;
}

interface PendingCommand {
	client: LocalWebSocket;
	clientCommandId: string;
	timer: Timer;
}

export class LocalServer {
	private readonly bridge: SessionBridge;
	private readonly config: RemoteConfig;
	private readonly pi: ExtensionAPI;
	readonly tokens: LocalServerTokens;
	private server: Server<ConnectionState> | undefined;
	private readonly connections = new Set<LocalWebSocket>();
	private readonly registry = new AgentRegistry();
	private readonly agentSockets = new Map<string, LocalWebSocket>();
	private readonly pairingCodes = new Map<string, { role: Role; expiresAt: number }>();
	private failedRedemptions = 0;
	// Commands in flight to a guest agent, keyed by the id this hub assigned.
	private readonly pendingCommands = new Map<string, PendingCommand>();
	private commandSeq = 0;

	constructor(bridge: SessionBridge, config: RemoteConfig, pi: ExtensionAPI) {
		this.bridge = bridge;
		this.config = config;
		this.pi = pi;
		this.tokens = {
			control: crypto.randomBytes(32).toString("hex"),
			viewer: crypto.randomBytes(32).toString("hex"),
			agent: crypto.randomBytes(32).toString("hex"),
		};
		this.registerOwnSession();
	}

	// The host's own session is an ordinary registry entry, so routing never
	// special-cases it. Its channel runs in process instead of over a socket.
	private registerOwnSession(): void {
		const channel: AgentChannel = {
			sendCommand: (id, cmd, args) => {
				executeCommand(this.bridge, this.pi, this.config, cmd, args)
					.then((result: CommandResult) => this.deliverReply(id, result))
					.catch((err: unknown) =>
						this.deliverReply(id, {
							ok: false,
							error: err instanceof Error ? err.message : String(err),
						}),
					);
			},
			sendResponse: (id, response) => {
				this.bridge.submitResponse(id, response);
			},
			sendViewers: () => {},
			close: () => {},
		};
		const entry = this.registry.register(this.bridge.info, channel);

		// Everything the local session emits flows into the registry the same
		// way a guest's frames do.
		this.bridge.attachSink({
			sendEvent: (frame) => {
				entry.recordEvent(frame);
				this.fanOut(this.bridge.agentId, { ...frame, agentId: this.bridge.agentId });
			},
			sendState: (frame) => {
				entry.state = frame.state;
				entry.info = this.bridge.info;
				this.fanOut(this.bridge.agentId, { ...frame, agentId: this.bridge.agentId });
			},
			sendRequest: (frame) => {
				entry.pendingRequests.set(frame.id, frame.request);
				this.fanOut(this.bridge.agentId, { ...frame, agentId: this.bridge.agentId });
			},
			sendRequestCancel: (frame) => {
				entry.pendingRequests.delete(frame.id);
				this.fanOut(this.bridge.agentId, { ...frame, agentId: this.bridge.agentId });
			},
		});
	}

	get port(): number {
		return this.server?.port ?? this.config.local?.port ?? 0;
	}

	get agentCount(): number {
		return this.registry.size;
	}

	get clientCounts(): { control: number; viewer: number } {
		let control = 0;
		let viewer = 0;
		for (const ws of this.connections) {
			if (ws.data.kind !== "client") continue;
			if (ws.data.role === "control") control += 1;
			else viewer += 1;
		}
		return { control, viewer };
	}

	// Issues a short code standing for a token, so pairing without the QR is
	// six typed characters rather than sixty-four.
	issuePairingCode(role: Role): { code: string; expiresAt: number } {
		this.prunePairingCodes();
		let code = "";
		do {
			code = randomPairingCode();
		} while (this.pairingCodes.has(code));
		const expiresAt = Date.now() + PAIRING_CODE_TTL_MS;
		this.pairingCodes.set(code, { role, expiresAt });
		return { code, expiresAt };
	}

	private prunePairingCodes(): void {
		const now = Date.now();
		for (const [code, entry] of this.pairingCodes) {
			if (entry.expiresAt <= now) this.pairingCodes.delete(code);
		}
		// Once nothing is outstanding there is nothing left to guess at, so the
		// lockout lifts with the codes it was protecting.
		if (this.pairingCodes.size === 0) this.failedRedemptions = 0;
	}

	private redeemPairingCode(code: string): { token: string; role: Role } | undefined {
		this.prunePairingCodes();
		if (this.failedRedemptions >= MAX_FAILED_REDEMPTIONS) return undefined;

		const normalized = code.trim().toUpperCase();
		const entry = this.pairingCodes.get(normalized);
		if (!entry) {
			this.failedRedemptions += 1;
			return undefined;
		}
		this.pairingCodes.delete(normalized);
		if (entry.expiresAt <= Date.now()) return undefined;
		return {
			token: entry.role === "control" ? this.tokens.control : this.tokens.viewer,
			role: entry.role,
		};
	}

	// Binds the configured port only. A second session must not land on a
	// different port: it joins this one as a guest instead, which is what keeps
	// every session reachable through a single address.
	start(): void {
		if (this.server) return;
		if (!this.config.local) throw new Error("LocalServer requires config.local");
		const localConfig = this.config.local;

		this.server = Bun.serve<ConnectionState>({
			hostname: localConfig.bind,
			port: localConfig.port,
			// Bun's own idle-timeout knob, in seconds; matches the protocol's
			// 60-second read timeout for HTTP connections (the WebSocket ping
			// interval below enforces the same budget on open sockets).
			idleTimeout: READ_TIMEOUT_SECONDS,
			fetch: (req: Request, server: Server<ConnectionState>) => this.handleFetch(req, server),
			websocket: {
				maxPayloadLength: MAX_INBOUND_BYTES,
				idleTimeout: READ_TIMEOUT_SECONDS,
				open: (ws: LocalWebSocket) => this.handleOpen(ws),
				message: (ws: LocalWebSocket, message: string | Buffer) => this.handleMessage(ws, message),
				close: (ws: LocalWebSocket) => this.handleClose(ws),
				drain: (ws: LocalWebSocket) => {
					ws.data.backpressureStreak = 0;
				},
			},
		});
	}

	stop(): void {
		for (const pending of this.pendingCommands.values()) clearTimeout(pending.timer);
		this.pendingCommands.clear();
		for (const ws of Array.from(this.connections)) {
			this.teardownConnection(ws);
			ws.close(1001, "server stopping");
		}
		this.server?.stop(true);
		this.server = undefined;
	}

	// The bind address is usually the wildcard 0.0.0.0, which is not a dialable
	// address for a phone. Prefer the first non-internal IPv4 interface in that
	// case; an explicit non-wildcard bind is used as-is.
	private pairingHost(): string {
		const bind = this.config.local?.bind ?? "0.0.0.0";
		if (bind !== "0.0.0.0") return bind;
		for (const addresses of Object.values(os.networkInterfaces())) {
			for (const addr of addresses ?? []) {
				if (addr.family === "IPv4" && !addr.internal) return addr.address;
			}
		}
		return "127.0.0.1";
	}

	private handleFetch(req: Request, server: Server<ConnectionState>): Response | undefined {
		const url = new URL(req.url);

		if (url.pathname === "/healthz") {
			return new Response("ok", { status: 200 });
		}

		// How another session on this machine gets what it needs from the host:
		// the agent token to attach with, and, when asked, a pairing code so a
		// guest can be paired to as readily as the host. Restricted to the
		// loopback peer address, since the Host header is whatever the client
		// chose to send and a LAN host could otherwise claim 127.0.0.1.
		if (url.pathname === "/join") {
			const peer = server.requestIP(req)?.address ?? "";
			const loopback = peer === "127.0.0.1" || peer === "::1" || peer === "::ffff:127.0.0.1";
			if (!loopback) return new Response("forbidden", { status: 403 });

			const wantCode = url.searchParams.get("code");
			if (wantCode === null) {
				return Response.json({ v: PROTOCOL_VERSION, token: this.tokens.agent });
			}
			const role: Role = wantCode === "viewer" ? "viewer" : "control";
			const issued = this.issuePairingCode(role);
			return Response.json({
				v: PROTOCOL_VERSION,
				token: this.tokens.agent,
				code: issued.code,
				expiresAt: issued.expiresAt,
				url: `ws://${this.pairingHost()}:${this.port}`,
				role,
				// The client token for that role, so a guest can print a QR that
				// works the same as the host's rather than one that cannot
				// authenticate. Loopback only, like the rest of this endpoint.
				clientToken: role === "control" ? this.tokens.control : this.tokens.viewer,
			});
		}

		// Doubles as the discovery endpoint: an app asking this one port learns
		// every session on the workstation. Without a code the payload holds no
		// secret; with one it returns the token that code stands for.
		if (url.pathname === "/pair") {
			if (!this.config.local) return new Response("not found", { status: 404 });
			const base = {
				v: PROTOCOL_VERSION,
				t: "direct" as const,
				url: `ws://${this.pairingHost()}:${this.port}`,
				name: this.config.agentName,
				agent: this.bridge.agentId,
				agents: this.registry.list().map((a) => ({ agentId: a.agentId, name: a.name })),
			};

			const code = url.searchParams.get("code");
			if (code === null) return Response.json({ ...base, role: "control" as const });

			const redeemed = this.redeemPairingCode(code);
			if (!redeemed) {
				return Response.json({ error: "unknown or expired pairing code" }, { status: 404 });
			}
			return Response.json({ ...base, role: redeemed.role, token: redeemed.token });
		}

		// Another session on this workstation joining as an agent. Loopback
		// only, like /join: a session is by definition local, and the token
		// alone should not let a remote host publish itself as one.
		if (url.pathname === "/agent") {
			const peer = server.requestIP(req)?.address ?? "";
			const loopback = peer === "127.0.0.1" || peer === "::1" || peer === "::ffff:127.0.0.1";
			if (!loopback) return new Response("forbidden", { status: 403 });
			const token = extractToken(req, url);
			if (!token || !constantTimeEquals(Buffer.from(token, "utf8"), this.tokens.agent)) {
				return new Response("unauthorized", { status: 401 });
			}
			const upgraded = server.upgrade(req, {
				data: {
					kind: "agent" as const,
					role: "control" as Role,
					subscriptions: new Set<string>(),
					agentId: undefined,
					backpressureStreak: 0,
					pingTimer: undefined,
				},
			});
			if (!upgraded) return new Response("upgrade failed", { status: 400 });
			return undefined;
		}

		if (url.pathname === "/client") {
			const token = extractToken(req, url);
			if (!token) return new Response("unauthorized", { status: 401 });
			const role = matchClientToken(token, this.tokens);
			if (!role) return new Response("unauthorized", { status: 401 });

			const upgraded = server.upgrade(req, {
				data: {
					kind: "client" as const,
					role,
					subscriptions: new Set<string>(),
					agentId: undefined,
					backpressureStreak: 0,
					pingTimer: undefined,
				},
			});
			if (!upgraded) return new Response("upgrade failed", { status: 400 });
			return undefined;
		}

		return new Response("not found", { status: 404 });
	}

	// -------------------------------------------------------------------
	// Connection lifecycle
	// -------------------------------------------------------------------

	private handleOpen(ws: LocalWebSocket): void {
		this.connections.add(ws);
		if (ws.data.kind === "client") this.broadcastViewerCounts();

		const pingCallback = () => {
			try {
				ws.ping();
			} catch {
				// connection already gone; the close handler cleans up state
			}
		};
		const ctx = this.bridge.getLatestCtx();
		ws.data.pingTimer = ctx
			? ctx.setInterval(pingCallback, PING_INTERVAL_MS)
			: setInterval(pingCallback, PING_INTERVAL_MS);
	}

	private handleClose(ws: LocalWebSocket): void {
		this.teardownConnection(ws);
	}

	private teardownConnection(ws: LocalWebSocket): void {
		if (!this.connections.has(ws)) return;
		this.connections.delete(ws);
		if (ws.data.pingTimer) {
			const ctx = this.bridge.getLatestCtx();
			if (ctx) ctx.clearTimer(ws.data.pingTimer);
			else clearInterval(ws.data.pingTimer);
		}

		if (ws.data.kind === "agent" && ws.data.agentId) {
			const entry = this.registry.get(ws.data.agentId);
			if (entry) {
				// Withdraw anything that session was waiting on: nobody can
				// answer it now.
				for (const id of entry.pendingRequests.keys()) {
					this.fanOut(ws.data.agentId, {
						t: "request_cancel",
						agentId: ws.data.agentId,
						id,
						reason: "shutdown",
					});
				}
			}
			this.registry.markOffline(ws.data.agentId, this.agentChannelFor(ws));
			this.agentSockets.delete(ws.data.agentId);
			this.broadcastRoster();
		}

		// Drop any command this connection was waiting on or answering for.
		for (const [id, pending] of this.pendingCommands) {
			if (pending.client === ws) {
				clearTimeout(pending.timer);
				this.pendingCommands.delete(id);
			}
		}

		if (ws.data.kind === "client") this.broadcastViewerCounts();
	}

	private handleMessage(ws: LocalWebSocket, message: string | Buffer): void {
		if (typeof message !== "string") {
			ws.close(1009, "binary frames are not supported");
			return;
		}
		if (Buffer.byteLength(message, "utf8") > MAX_INBOUND_BYTES) {
			ws.close(1009, "message too large");
			return;
		}

		let parsed: unknown;
		try {
			parsed = JSON.parse(message);
		} catch {
			return;
		}
		if (!parsed || typeof parsed !== "object") return;

		if (ws.data.kind === "agent") this.handleAgentFrame(ws, parsed as AgentToRelayFrame);
		else this.handleClientFrame(ws, parsed as ClientToServerFrame);
	}

	// -------------------------------------------------------------------
	// Guest agents
	// -------------------------------------------------------------------

	private agentChannelFor(ws: LocalWebSocket): AgentChannel {
		return {
			sendCommand: (id, cmd, args) => this.sendRaw(ws, { t: "command", id, cmd, args }),
			sendResponse: (id, response) => this.sendRaw(ws, { t: "response", id, response }),
			sendViewers: (counts) => this.sendRaw(ws, { t: "viewers", ...counts }),
			close: (reason) => ws.close(1000, reason),
		};
	}

	private handleAgentFrame(ws: LocalWebSocket, frame: AgentToRelayFrame): void {
		switch (frame.t) {
			case "hello": {
				if (frame.protocol !== PROTOCOL_VERSION) {
					ws.close(1002, `protocol mismatch: hub speaks ${PROTOCOL_VERSION}`);
					return;
				}
				if (!frame.agentId) {
					ws.close(1002, "hello requires an agentId");
					return;
				}
				ws.data.agentId = frame.agentId;
				const info: AgentInfo = { ...frame.info, agentId: frame.agentId, online: true };
				this.registry.register(info, this.agentChannelFor(ws));
				this.agentSockets.set(frame.agentId, ws);
				this.sendRaw(ws, { t: "welcome", protocol: PROTOCOL_VERSION, agentId: frame.agentId });
				this.broadcastRoster();
				this.sendViewerCountsTo(frame.agentId);
				return;
			}
			case "event": {
				const entry = ws.data.agentId ? this.registry.get(ws.data.agentId) : undefined;
				if (!entry || !ws.data.agentId) return;
				entry.recordEvent(frame);
				this.fanOut(ws.data.agentId, { ...frame, agentId: ws.data.agentId });
				return;
			}
			case "state": {
				const entry = ws.data.agentId ? this.registry.get(ws.data.agentId) : undefined;
				if (!entry || !ws.data.agentId) return;
				entry.state = frame.state;
				this.fanOut(ws.data.agentId, { ...frame, agentId: ws.data.agentId });
				return;
			}
			case "request": {
				const entry = ws.data.agentId ? this.registry.get(ws.data.agentId) : undefined;
				if (!entry || !ws.data.agentId) return;
				entry.pendingRequests.set(frame.id, frame.request);
				this.fanOut(ws.data.agentId, { ...frame, agentId: ws.data.agentId });
				return;
			}
			case "request_cancel": {
				const entry = ws.data.agentId ? this.registry.get(ws.data.agentId) : undefined;
				if (!entry || !ws.data.agentId) return;
				entry.pendingRequests.delete(frame.id);
				this.fanOut(ws.data.agentId, { ...frame, agentId: ws.data.agentId });
				return;
			}
			case "reply": {
				this.deliverReply(
					frame.id,
					frame.ok ? { ok: true, data: frame.data } : { ok: false, error: frame.error ?? "failed" },
				);
				return;
			}
		}
	}

	// -------------------------------------------------------------------
	// Clients
	// -------------------------------------------------------------------

	private handleClientFrame(ws: LocalWebSocket, frame: ClientToServerFrame): void {
		switch (frame.t) {
			case "hello":
				if (frame.protocol !== PROTOCOL_VERSION) {
					ws.close(1002, `protocol mismatch: server speaks ${PROTOCOL_VERSION}`);
					return;
				}
				this.send(ws, {
					t: "welcome",
					protocol: PROTOCOL_VERSION,
					clientId: crypto.randomBytes(8).toString("hex"),
					role: ws.data.role,
					agents: this.registry.list(),
				});
				return;
			case "subscribe":
				this.handleSubscribe(ws, frame.agentId, frame.since ?? 0);
				return;
			case "unsubscribe":
				ws.data.subscriptions.delete(frame.agentId);
				this.broadcastViewerCounts();
				return;
			case "command":
				this.handleCommand(ws, frame);
				return;
			case "response":
				this.handleResponse(ws, frame);
				return;
		}
	}

	private handleSubscribe(ws: LocalWebSocket, agentId: string, since: number): void {
		const entry = this.registry.get(agentId);
		if (!entry) return;
		ws.data.subscriptions.add(agentId);

		// A client attaching to a resumed session before the deferred replay
		// ran would see an empty transcript. Doing it here too costs one
		// branch walk and covers the race.
		if (agentId === this.bridge.agentId && !this.bridge.historyReplayed) {
			const ctx = this.bridge.getLatestCtx();
			if (ctx) this.bridge.replayHistory(ctx);
		}

		// State first, then anything still awaiting an answer, then the events
		// this client has not seen: the order the protocol specifies.
		if (entry.state) this.send(ws, { t: "state", agentId, state: entry.state });
		for (const [id, request] of entry.pendingRequests) {
			this.send(ws, { t: "request", agentId, id, request });
		}
		for (const retained of entry.eventsSince(since)) {
			this.send(ws, { t: "event", agentId, seq: retained.seq, event: retained.event });
		}
		this.broadcastViewerCounts();
	}

	// A client that named no agent is talking to a workstation it assumes has
	// one, which is true until a second session joins. Resolving to the sole
	// agent keeps that client working; naming one is required once there are
	// several, since guessing would route commands to the wrong session.
	private resolveTarget(ws: LocalWebSocket, id: string, agentId: string | undefined): AgentEntry | undefined {
		const roster = this.registry.list();
		const resolved = agentId ?? (roster.length === 1 ? roster[0]?.agentId : undefined);
		if (!resolved) {
			this.send(ws, { t: "reply", id, ok: false, error: "this workstation has several sessions, name one" });
			return undefined;
		}
		const entry = this.registry.get(resolved);
		if (!entry || !entry.online) {
			this.send(ws, { t: "reply", id, ok: false, error: "agent offline" });
			return undefined;
		}
		return entry;
	}

	private handleCommand(ws: LocalWebSocket, frame: FrameCommand): void {
		if (ws.data.role !== "control") {
			this.send(ws, { t: "reply", id: frame.id, ok: false, error: "read-only connection" });
			return;
		}
		const entry = this.resolveTarget(ws, frame.id, frame.agentId);
		if (!entry) return;

		// A hub-scoped id keeps two clients' identical ids apart, and lets a
		// late reply find the client that asked.
		this.commandSeq += 1;
		const hubId = `h${this.commandSeq}`;
		const timer = setTimeout(() => {
			this.pendingCommands.delete(hubId);
			this.send(ws, { t: "reply", id: frame.id, ok: false, error: "command timed out" });
		}, COMMAND_TIMEOUT_MS);
		this.pendingCommands.set(hubId, { client: ws, clientCommandId: frame.id, timer });
		entry.channel.sendCommand(hubId, frame.cmd, frame.args);
	}

	private handleResponse(ws: LocalWebSocket, frame: FrameResponse): void {
		if (ws.data.role !== "control") {
			this.send(ws, { t: "reply", id: frame.id, ok: false, error: "read-only connection" });
			return;
		}
		const entry = this.resolveTarget(ws, frame.id, frame.agentId);
		if (!entry) return;
		if (!entry.pendingRequests.has(frame.id)) {
			this.send(ws, { t: "reply", id: frame.id, ok: false, error: "request already answered" });
			return;
		}
		entry.pendingRequests.delete(frame.id);
		entry.channel.sendResponse(frame.id, frame.response);
		this.send(ws, { t: "reply", id: frame.id, ok: true, data: { accepted: true } });
	}

	private deliverReply(hubId: string, result: CommandResult): void {
		const pending = this.pendingCommands.get(hubId);
		if (!pending) return;
		clearTimeout(pending.timer);
		this.pendingCommands.delete(hubId);
		if (result.ok) {
			this.send(pending.client, { t: "reply", id: pending.clientCommandId, ok: true, data: result.data });
		} else {
			this.send(pending.client, { t: "reply", id: pending.clientCommandId, ok: false, error: result.error });
		}
	}

	// -------------------------------------------------------------------
	// Fan-out
	// -------------------------------------------------------------------

	private fanOut(agentId: string, frame: ServerToClientFrame): void {
		for (const ws of this.connections) {
			if (ws.data.kind !== "client") continue;
			if (!ws.data.subscriptions.has(agentId)) continue;
			this.send(ws, frame);
		}
	}

	private broadcastRoster(): void {
		const agents = this.registry.list();
		for (const ws of this.connections) {
			if (ws.data.kind !== "client") continue;
			this.send(ws, { t: "agents", agents });
		}
	}

	// Every agent hears how many clients are watching it, including the host's
	// own session, which reports through the bridge instead of a socket.
	private broadcastViewerCounts(): void {
		for (const info of this.registry.list()) {
			this.sendViewerCountsTo(info.agentId);
		}
	}

	private sendViewerCountsTo(agentId: string): void {
		let control = 0;
		let viewer = 0;
		for (const ws of this.connections) {
			if (ws.data.kind !== "client") continue;
			if (!ws.data.subscriptions.has(agentId)) continue;
			if (ws.data.role === "control") control += 1;
			else viewer += 1;
		}
		if (agentId === this.bridge.agentId) {
			this.bridge.setViewerCounts({ control, viewer });
			return;
		}
		this.registry.get(agentId)?.channel.sendViewers({ control, viewer });
	}

	// Bun's send() returns 0 (dropped), -1 (queued under backpressure), or the
	// byte count sent immediately. A run of consecutive backpressured sends
	// approximates the protocol's outbound queue limit.
	private send(ws: LocalWebSocket, frame: ServerToClientFrame): void {
		this.sendRaw(ws, frame);
	}

	private sendRaw(ws: LocalWebSocket, frame: unknown): void {
		if (ws.readyState !== 1) return;
		const status = ws.send(JSON.stringify(frame));
		if (status > 0) {
			ws.data.backpressureStreak = 0;
			return;
		}
		if (status === -1) {
			ws.data.backpressureStreak += 1;
			if (ws.data.backpressureStreak >= MAX_OUTBOUND_QUEUE) {
				ws.close(1013, "too slow");
			}
		}
	}
}

export type { AgentEntry };
