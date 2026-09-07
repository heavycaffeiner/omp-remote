// The relayless transport (docs/protocol.md, "Direct"). Serves exactly the
// client-facing half of the protocol on the plugin's own Bun.serve instance,
// so the app's single code path against /client works unchanged whether it
// talks to the relay or straight to the workstation.

import * as crypto from "node:crypto";
import * as os from "node:os";
import type { Server, ServerWebSocket } from "bun";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import type {
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

export interface LocalServerTokens {
	control: string;
	viewer: string;
}

const MAX_INBOUND_BYTES = 1024 * 1024;
const MAX_OUTBOUND_QUEUE = 256;
const PING_INTERVAL_MS = 20000;
const READ_TIMEOUT_SECONDS = 60;
const EVENT_RING_SIZE = 512;

interface ConnectionState {
	role: Role;
	subscribed: boolean;
	backpressureStreak: number;
	pingTimer: Timer | undefined;
}

type LocalWebSocket = ServerWebSocket<ConnectionState>;

// Compares a presented token against both known tokens without short-
// circuiting, so response timing does not reveal which one matched (or
// whether either did). Returns the matched role, or undefined.
function matchToken(presented: string, tokens: LocalServerTokens): Role | undefined {
	const presentedBuf = Buffer.from(presented, "utf8");
	const controlBuf = Buffer.from(tokens.control, "utf8");
	const viewerBuf = Buffer.from(tokens.viewer, "utf8");

	const controlMatches =
		presentedBuf.length === controlBuf.length && crypto.timingSafeEqual(presentedBuf, controlBuf);
	const viewerMatches = presentedBuf.length === viewerBuf.length && crypto.timingSafeEqual(presentedBuf, viewerBuf);

	if (controlMatches) return "control";
	if (viewerMatches) return "viewer";
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

export class LocalServer {
	private readonly bridge: SessionBridge;
	private readonly config: RemoteConfig;
	private readonly pi: ExtensionAPI;
	readonly tokens: LocalServerTokens;
	private server: Server<ConnectionState> | undefined;
	private readonly connections = new Set<LocalWebSocket>();
	private readonly sinksByConnection = new Map<LocalWebSocket, OutboundSink>();
	private readonly eventRing: CoreEvent[] = [];
	private controlCount = 0;
	private viewerCount = 0;

	constructor(bridge: SessionBridge, config: RemoteConfig, pi: ExtensionAPI) {
		this.bridge = bridge;
		this.config = config;
		this.pi = pi;
		this.tokens = {
			control: crypto.randomBytes(32).toString("hex"),
			viewer: crypto.randomBytes(32).toString("hex"),
		};
		// A permanently-attached internal sink records every broadcast event
		// into a bounded ring so a client's `subscribe` with `since` can replay
		// what it missed. SessionBridge itself only retains the latest state
		// snapshot and pending requests, not an event history.
		this.bridge.attachSink({
			sendEvent: (frame) => {
				this.eventRing.push(frame);
				if (this.eventRing.length > EVENT_RING_SIZE) this.eventRing.shift();
			},
			sendState: () => {},
			sendRequest: () => {},
			sendRequestCancel: () => {},
		});
	}

	get port(): number {
		return this.server?.port ?? this.config.local?.port ?? 0;
	}

	get clientCounts(): { control: number; viewer: number } {
		return { control: this.controlCount, viewer: this.viewerCount };
	}

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
			fetch: (req, server) => this.handleFetch(req, server),
			websocket: {
				maxPayloadLength: MAX_INBOUND_BYTES,
				idleTimeout: READ_TIMEOUT_SECONDS,
				open: (ws) => this.handleOpen(ws),
				message: (ws, message) => this.handleMessage(ws, message),
				close: (ws) => this.handleClose(ws),
				drain: (ws) => {
					// Backpressure has cleared: the client has caught up, so the
					// approximate too-slow counter resets.
					ws.data.backpressureStreak = 0;
				},
			},
		});
	}

	stop(): void {
		for (const ws of Array.from(this.connections)) {
			this.teardownConnection(ws);
			ws.close(1001, "server stopping");
		}
		this.server?.stop(true);
		this.server = undefined;
	}

	// The bind address is usually the wildcard 0.0.0.0, which is not a
	// dialable address for a phone on the same network. Prefer the first
	// non-internal IPv4 interface address in that case so the pairing link
	// actually reaches the workstation; an explicit non-wildcard bind is
	// used as-is.
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

		if (url.pathname === "/pair") {
			if (!this.config.local) return new Response("not found", { status: 404 });
			const payload = {
				v: PROTOCOL_VERSION,
				t: "direct" as const,
				url: `ws://${this.pairingHost()}:${this.port}`,
				role: "control" as const,
				name: this.config.agentName,
			};
			return Response.json(payload);
		}

		if (url.pathname === "/client") {
			const token = extractToken(req, url);
			if (!token) return new Response("unauthorized", { status: 401 });
			const role = matchToken(token, this.tokens);
			if (!role) return new Response("unauthorized", { status: 401 });

			const upgraded = server.upgrade(req, {
				data: { role, subscribed: false, backpressureStreak: 0, pingTimer: undefined },
			});
			if (!upgraded) return new Response("upgrade failed", { status: 400 });
			return undefined;
		}

		return new Response("not found", { status: 404 });
	}

	// -------------------------------------------------------------------
	// WebSocket connection lifecycle.
	// -------------------------------------------------------------------

	private handleOpen(ws: LocalWebSocket): void {
		this.connections.add(ws);
		if (ws.data.role === "control") this.controlCount += 1;
		else this.viewerCount += 1;
		this.bridge.setViewerCounts({ control: this.controlCount, viewer: this.viewerCount });

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
		const sink = this.sinksByConnection.get(ws);
		if (sink) {
			this.bridge.detachSink(sink);
			this.sinksByConnection.delete(ws);
		}
		if (ws.data.role === "control") this.controlCount = Math.max(0, this.controlCount - 1);
		else this.viewerCount = Math.max(0, this.viewerCount - 1);
		this.bridge.setViewerCounts({ control: this.controlCount, viewer: this.viewerCount });
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
		const frame = parsed as ClientToServerFrame;

		switch (frame.t) {
			case "hello":
				this.handleHello(ws, frame.protocol);
				return;
			case "subscribe":
				this.handleSubscribe(ws);
				return;
			case "unsubscribe":
				this.handleUnsubscribe(ws);
				return;
			case "command":
				this.handleCommand(ws, frame);
				return;
			case "response":
				this.handleResponse(ws, frame);
				return;
		}
	}

	private handleHello(ws: LocalWebSocket, protocol: number): void {
		if (protocol !== PROTOCOL_VERSION) {
			ws.close(1002, `protocol mismatch: server speaks ${PROTOCOL_VERSION}`);
			return;
		}
		this.send(ws, {
			t: "welcome",
			protocol: PROTOCOL_VERSION,
			clientId: crypto.randomBytes(8).toString("hex"),
			role: ws.data.role,
			agents: [this.bridge.info],
		});
	}

	private handleSubscribe(ws: LocalWebSocket): void {
		if (ws.data.subscribed) return;
		ws.data.subscribed = true;

		const sink: OutboundSink = {
			sendEvent: (frame) => this.send(ws, { ...frame, agentId: this.bridge.agentId }),
			sendState: (frame) => this.send(ws, { ...frame, agentId: this.bridge.agentId }),
			sendRequest: (frame) => this.send(ws, { ...frame, agentId: this.bridge.agentId }),
			sendRequestCancel: (frame) => this.send(ws, { ...frame, agentId: this.bridge.agentId }),
		};
		this.sinksByConnection.set(ws, sink);
		// attachSink replays retained state and pending requests immediately;
		// this ring replay covers events, which the bridge itself does not
		// retain beyond the single latest state snapshot.
		this.bridge.attachSink(sink);
		for (const event of this.eventRing) {
			this.send(ws, { ...event, agentId: this.bridge.agentId });
		}
	}

	private handleUnsubscribe(ws: LocalWebSocket): void {
		if (!ws.data.subscribed) return;
		ws.data.subscribed = false;
		const sink = this.sinksByConnection.get(ws);
		if (sink) {
			this.bridge.detachSink(sink);
			this.sinksByConnection.delete(ws);
		}
	}

	private handleCommand(ws: LocalWebSocket, frame: FrameCommand): void {
		if (ws.data.role !== "control") {
			this.send(ws, { t: "reply", id: frame.id, ok: false, error: "read-only connection" });
			return;
		}
		executeCommand(this.bridge, this.pi, this.config, frame.cmd, frame.args)
			.then((result: CommandResult) => {
				if (result.ok) this.send(ws, { t: "reply", id: frame.id, ok: true, data: result.data });
				else this.send(ws, { t: "reply", id: frame.id, ok: false, error: result.error });
			})
			.catch((err: unknown) => {
				this.send(ws, {
					t: "reply",
					id: frame.id,
					ok: false,
					error: err instanceof Error ? err.message : String(err),
				});
			});
	}

	private handleResponse(ws: LocalWebSocket, frame: FrameResponse): void {
		if (ws.data.role !== "control") {
			this.send(ws, { t: "reply", id: frame.id, ok: false, error: "read-only connection" });
			return;
		}
		const outcome = this.bridge.submitResponse(frame.id, frame.response);
		if (outcome.ok) this.send(ws, { t: "reply", id: frame.id, ok: true, data: { accepted: true } });
		else this.send(ws, { t: "reply", id: frame.id, ok: false, error: outcome.error });
	}

	// -------------------------------------------------------------------
	// Outbound framing. Every client-facing frame carries agentId (see
	// handleSubscribe's sink) so the app's parsing stays uniform across the
	// relay and direct transports; the reply frame family has no agentId in
	// the wire type and is sent as-is.
	// -------------------------------------------------------------------

	// Bun's send() returns 0 (dropped), -1 (queued under backpressure), or the
	// byte count sent immediately. There is no direct "frames queued" counter,
	// so a run of consecutive backpressured sends approximates the protocol's
	// "outbound queue exceeds 256 frames" limit: each -1 return means this
	// frame joined the client's unread buffer, and `drain` (above) means that
	// buffer emptied, so the streak resets there and on any immediate send.
	private send(ws: LocalWebSocket, frame: ServerToClientFrame): void {
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
