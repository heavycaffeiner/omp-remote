// Outbound uplink to an /agent endpoint (docs/protocol.md, "Relayed"). The
// endpoint is either a relay or another session's local server acting as the
// host for this workstation: the frames are identical, so one client serves
// both. Implements OutboundSink so SessionBridge can broadcast to it without
// knowing which it is.

import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import type {
	AgentToRelayFrame,
	CoreEvent,
	CoreRequest,
	CoreRequestCancel,
	CoreState,
	FrameCommand,
	FrameResponse,
	FrameViewers,
	FrameWelcomeAgent,
	RelayToAgentFrame,
} from "./protocol-types.js";
import { PROTOCOL_VERSION } from "./protocol-types.js";
import type { OutboundSink, SessionBridge } from "./session-bridge.js";
import type { RemoteConfig } from "./config.js";
import { executeCommand, type CommandResult } from "./commands.js";

const BACKOFF_INITIAL_MS = 1000;
const BACKOFF_MAX_MS = 30000;

function parseFrame(raw: string): RelayToAgentFrame | undefined {
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch {
		return undefined;
	}
	if (!parsed || typeof parsed !== "object") return undefined;
	const t = (parsed as { t?: unknown }).t;
	if (t === "welcome" || t === "command" || t === "response" || t === "viewers") {
		return parsed as RelayToAgentFrame;
	}
	return undefined;
}

// SessionBridge keeps its ExtensionAPI reference private (it is only needed
// to wire pi.on(...) handlers once), so commands.ts's executeCommand takes
// its own ExtensionAPI parameter and this sink is constructed with the same
// `pi` the extension factory received, beyond the bridge/config pair.
export class RelayClient implements OutboundSink {
	private readonly bridge: SessionBridge;
	private readonly config: RemoteConfig;
	private readonly pi: ExtensionAPI;
	private readonly url: string;
	private readonly token: string;
	private readonly label: string;
	private socket: WebSocket | undefined;
	private stopped = false;
	private welcomed = false;
	private backoffMs = BACKOFF_INITIAL_MS;
	private reconnectTimer: Timer | undefined;

	// Called when the connection drops, before a reconnect is scheduled.
	// A guest uses it to re-fetch the host's token: the session that takes over
	// the port mints its own, so the old one is rejected from then on.
	onDisconnect: (() => void) | undefined;

	// `endpoint` overrides config.relay, which is how a session that lost the
	// port race attaches to the session that won it.
	constructor(
		bridge: SessionBridge,
		config: RemoteConfig,
		pi: ExtensionAPI,
		endpoint?: { url: string; token: string; label: string },
	) {
		this.bridge = bridge;
		this.config = config;
		this.pi = pi;
		const source = endpoint ?? (config.relay ? { ...config.relay, label: "relay" } : undefined);
		if (!source) throw new Error("RelayClient requires a relay or an explicit endpoint");
		this.url = `${source.url.replace(/\/+$/, "")}/agent`;
		this.token = source.token;
		this.label = source.label;
	}

	get connected(): boolean {
		return this.welcomed && this.socket !== undefined && this.socket.readyState === WebSocket.OPEN;
	}

	start(): void {
		this.stopped = false;
		this.connect();
	}

	stop(): void {
		this.stopped = true;
		this.clearReconnectTimer();
		this.bridge.detachSink(this);
		if (this.socket) {
			try {
				this.socket.close(1000, "stopping");
			} catch {
				// socket already gone; nothing to clean up
			}
			this.socket = undefined;
		}
		this.welcomed = false;
	}

	private connect(): void {
		if (this.stopped) return;
		// Bun's WebSocket client sends the Authorization header on the upgrade
		// request. A query token would land in relay and proxy access logs.
		const socket = new WebSocket(this.url, { headers: { Authorization: `Bearer ${this.token}` } });
		this.socket = socket;
		this.welcomed = false;

		socket.onopen = () => {
			this.sendFrame(socket, {
				t: "hello",
				protocol: PROTOCOL_VERSION,
				agentId: this.bridge.agentId,
				info: this.bridge.info,
			});
		};
		socket.onmessage = (ev: MessageEvent) => {
			try {
				this.handleMessage(ev);
			} catch (err) {
				this.bridge.recordError(err instanceof Error ? err.message : String(err));
			}
		};
		socket.onerror = () => {
			// The close handler drives reconnection; onerror only needs to avoid
			// throwing so a socket-level failure never becomes an unhandled
			// rejection.
			this.bridge.recordError(`${this.label} connection error`);
		};
		socket.onclose = () => {
			this.welcomed = false;
			this.bridge.detachSink(this);
			if (this.socket === socket) this.socket = undefined;
			if (this.stopped) return;
			if (this.onDisconnect) {
				// The owner rebuilds this client against whoever holds the port
				// now, so this instance does not retry with a stale token.
				this.onDisconnect();
				return;
			}
			this.scheduleReconnect();
		};
	}

	private handleMessage(ev: MessageEvent): void {
		if (typeof ev.data !== "string") return;
		const frame = parseFrame(ev.data);
		if (!frame) return;

		switch (frame.t) {
			case "welcome":
				this.handleWelcome(frame);
				return;
			case "command":
				this.handleCommand(frame);
				return;
			case "response": {
				const f = frame as FrameResponse;
				this.bridge.submitResponse(f.id, f.response);
				return;
			}
			case "viewers": {
				const f = frame as FrameViewers;
				this.bridge.setViewerCounts({ control: f.control, viewer: f.viewer });
				return;
			}
		}
	}

	private handleWelcome(frame: FrameWelcomeAgent): void {
		if (frame.protocol !== PROTOCOL_VERSION) {
			// A protocol mismatch is a fatal link error: the relay and this
			// plugin disagree on the wire contract, and retrying in a tight
			// loop cannot fix that. Record the error and stop trying.
			this.bridge.recordError(
				`${this.label} protocol mismatch: plugin speaks ${PROTOCOL_VERSION}, got ${frame.protocol}`,
			);
			this.stop();
			return;
		}
		this.welcomed = true;
		this.backoffMs = BACKOFF_INITIAL_MS;
		this.bridge.attachSink(this);
	}

	private handleCommand(frame: FrameCommand): void {
		const { id, cmd, args } = frame;
		executeCommand(this.bridge, this.pi, this.config, cmd, args)
			.then((result: CommandResult) => {
				const reply: AgentToRelayFrame = result.ok
					? { t: "reply", id, ok: true, data: result.data }
					: { t: "reply", id, ok: false, error: result.error };
				if (this.socket) this.sendFrame(this.socket, reply);
			})
			.catch((err: unknown) => {
				const reply: AgentToRelayFrame = {
					t: "reply",
					id,
					ok: false,
					error: err instanceof Error ? err.message : String(err),
				};
				if (this.socket) this.sendFrame(this.socket, reply);
			});
	}

	private sendFrame(socket: WebSocket, frame: AgentToRelayFrame): void {
		if (socket.readyState !== WebSocket.OPEN) return;
		try {
			socket.send(JSON.stringify(frame));
		} catch (err) {
			this.bridge.recordError(err instanceof Error ? err.message : String(err));
		}
	}

	// -------------------------------------------------------------------
	// OutboundSink. A send on a closed socket is silently dropped: the
	// bridge broadcasts to every attached sink regardless of transport
	// health, and a disconnected relay link simply misses frames until it
	// reconnects and replays retained state via attachSink.
	// -------------------------------------------------------------------

	sendEvent(frame: CoreEvent): void {
		if (this.socket) this.sendFrame(this.socket, frame);
	}

	sendState(frame: CoreState): void {
		if (this.socket) this.sendFrame(this.socket, frame);
	}

	sendRequest(frame: CoreRequest): void {
		if (this.socket) this.sendFrame(this.socket, frame);
	}

	sendRequestCancel(frame: CoreRequestCancel): void {
		if (this.socket) this.sendFrame(this.socket, frame);
	}

	// -------------------------------------------------------------------
	// Reconnect with exponential backoff, jittered, capped at 30s, forever
	// until stopped.
	// -------------------------------------------------------------------

	private clearReconnectTimer(): void {
		if (!this.reconnectTimer) return;
		const ctx = this.bridge.getLatestCtx();
		if (ctx) {
			ctx.clearTimer(this.reconnectTimer);
		} else {
			clearTimeout(this.reconnectTimer);
		}
		this.reconnectTimer = undefined;
	}

	private scheduleReconnect(): void {
		if (this.stopped) return;
		this.clearReconnectTimer();
		const jitter = Math.random() * this.backoffMs * 0.2;
		const delay = Math.min(this.backoffMs, BACKOFF_MAX_MS) + jitter;
		this.backoffMs = Math.min(this.backoffMs * 2, BACKOFF_MAX_MS);

		const fire = () => {
			this.reconnectTimer = undefined;
			if (!this.stopped) this.connect();
		};

		const ctx = this.bridge.getLatestCtx();
		if (ctx) {
			this.reconnectTimer = ctx.setTimeout(fire, delay);
			return;
		}
		// No ctx yet (e.g. reconnecting before session_start has fired): fall
		// back to a raw timer whose callback body is entirely wrapped in
		// try/catch so a throw here can never escape as an uncaught exception
		// and take down the whole session.
		this.reconnectTimer = setTimeout(() => {
			try {
				fire();
			} catch (err) {
				this.bridge.recordError(err instanceof Error ? err.message : String(err));
			}
		}, delay);
	}
}
