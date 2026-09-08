// Extension entry point. Wires SessionBridge to whichever transports are
// configured and owns their lifecycle: construction at load, start on
// session_start, stop on session_shutdown.

import type { ExtensionAPI, ExtensionContext, ToolCallEvent, ToolCallEventResult } from "@oh-my-pi/pi-coding-agent";
import { configFromSettings, type RemoteConfig } from "./config.js";
import { loadSettings, saveSettings, type StoredSettings } from "./settings.js";
import { SessionBridge } from "./session-bridge.js";
import { RelayClient } from "./relay-client.js";
import { LocalServer } from "./local-server.js";
import { registerAskShadow } from "./ask-shadow.js";
import { registerRemoteCommand } from "./pairing.js";
import { safeStringifyInput, truncateText, TOOL_INPUT_MAX_BYTES } from "./normalize.js";

const APPROVAL_TIMEOUT_MS = 120000;
// How often a guest checks whether the port has been freed, so the session
// holding it exiting does not leave the workstation unreachable.
const HOST_POLL_MS = 5000;

// Maps a tool name to the risk tier shown in the remote approval prompt.
// Mirrors pi-agent-core's ToolTier vocabulary ("read" | "write" | "exec") so
// the phone's wording matches what the workstation's own approval gate uses.
function toolRisk(toolName: string): string {
	if (toolName === "bash") return "exec";
	if (toolName === "write" || toolName === "edit") return "write";
	return "read";
}

// Set once the factory has run in this process. A directory named on the
// command line can be resolved both by its package manifest and by a scan of
// its contents, which loads this module twice: two servers on two ports, and
// a pairing code registered with whichever one the user is not talking to.
let loaded = false;

export default function ompRemote(pi: ExtensionAPI): void {
	if (loaded) return;
	loaded = true;

	// Settings live in a file, not the environment, so a bad value degrades to
	// the default rather than failing the session. The default is direct
	// serving with no relay, which needs no configuration at all.
	let settings = loadSettings();
	let config = configFromSettings(settings);

	const bridge = new SessionBridge(pi, config);
	bridge.registerHandlers();
	registerAskShadow(pi, bridge);

	// Rebuilt whenever the relay is configured or cleared, so a change takes
	// effect without restarting omp.
	let relayClient: RelayClient | undefined;
	const localServer = config.local ? new LocalServer(bridge, config, pi) : undefined;
	const alwaysApprovedTools = new Set<string>();

	const applyRelay = (): void => {
		relayClient?.stop();
		relayClient = undefined;
		if (!config.relay) return;
		relayClient = new RelayClient(bridge, config, pi);
		relayClient.start();
	};

	// One port serves the whole workstation: the first session to bind it hosts
	// every other, and a session that cannot bind joins the host as a guest
	// instead of taking a port of its own. A transport that fails either way is
	// recorded and left dormant rather than thrown, which would surface as a
	// session error.
	let localStarted = false;
	let guestClient: RelayClient | undefined;
	let takeoverTimer: Timer | undefined;

	// Tries to become the host. Returns true once this session owns the port.
	const tryHost = (): boolean => {
		if (localStarted || !localServer) return localStarted;
		try {
			localServer.start();
			localStarted = true;
			return true;
		} catch {
			return false;
		}
	};

	const joinHost = async (ctx: ExtensionContext): Promise<void> => {
		const local = config.local;
		if (!local || localStarted) return;
		try {
			const response = await fetch(`http://127.0.0.1:${local.port}/join`, {
				signal: AbortSignal.timeout(2000),
			});
			if (!response.ok) throw new Error(`host refused the join: HTTP ${response.status}`);
			const payload = (await response.json()) as { token?: unknown };
			if (typeof payload.token !== "string") throw new Error("host returned no token");
			guestClient?.stop();
			guestClient = new RelayClient(bridge, config, pi, {
				url: `ws://127.0.0.1:${local.port}`,
				token: payload.token,
				label: "workstation hub",
			});
			// A dropped link means the host exited. The next poll either makes
			// this session the host or rejoins whoever took over; retrying with
			// the old token would just be refused, since the new host mints its
			// own.
			guestClient.onDisconnect = () => {
				guestClient?.stop();
				guestClient = undefined;
			};
			guestClient.start();
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err);
			bridge.recordError(`workstation hub: ${message}`);
		}
	};

	// One poll drives both halves of the handover: a guest first tries to
	// become the host, and failing that makes sure it is still attached to
	// whoever is. Without the second half a session stays alive but invisible
	// after the host it joined exits.
	const watchForTakeover = (ctx: ExtensionContext): void => {
		if (takeoverTimer || !localServer) return;
		const tick = () => {
			if (localStarted) return;
			if (tryHost()) {
				guestClient?.stop();
				guestClient = undefined;
				if (takeoverTimer) {
					ctx.clearTimer(takeoverTimer);
					takeoverTimer = undefined;
				}
				ctx.ui.notify("omp-remote is now hosting this workstation's port", "info");
				return;
			}
			if (!guestClient) void joinHost(ctx);
		};
		takeoverTimer = ctx.setInterval(tick, HOST_POLL_MS);
	};

	pi.on("session_start", async (_event, ctx) => {
		try {
			applyRelay();
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err);
			bridge.recordError(`relay: ${message}`);
			ctx.ui.notify(`omp-remote relay uplink failed: ${message}`, "warning");
		}
		if (localServer && !tryHost()) {
			// The port is taken, so another session hosts it. Join that one and
			// stand by to take over if it goes away.
			await joinHost(ctx);
			watchForTakeover(ctx);
		}
	});

	// `/remote config` hands back the settings it wants persisted. Saving and
	// re-deriving the config here keeps the file the single source of truth,
	// and the relay is rebuilt so the change takes effect at once.
	const updateSettings = (next: StoredSettings): void => {
		saveSettings(next);
		settings = next;
		config = configFromSettings(settings);
		applyRelay();
	};

	// The status text lives here because only the extension factory holds the
	// transports; `/remote status` renders it.
	const describeStatus = (): string => {
		const lines: string[] = [`agent: ${bridge.agentId}`];

		if (config.relay) {
			const relayHost = new URL(config.relay.url).host;
			lines.push(`relay: ${relayHost} (${relayClient?.connected ? "connected" : "disconnected"})`);
		} else {
			lines.push("relay: not configured, direct only (/remote config relay <url> <token>)");
		}

		if (!config.local) {
			lines.push("local: not configured");
		} else if (localStarted && localServer) {
			const counts = localServer.clientCounts;
			const others = localServer.agentCount - 1;
			const hosting = others > 0 ? `, hosting ${others} other session${others === 1 ? "" : "s"}` : "";
			lines.push(`local: hosting port ${localServer.port} (control ${counts.control}, viewer ${counts.viewer}${hosting})`);
		} else if (guestClient) {
			const state = guestClient.connected ? "connected" : "connecting";
			lines.push(`local: joined the session hosting port ${config.local.port} (${state})`);
		} else {
			lines.push("local: not running");
		}

		const attached = bridge.getCurrentState().viewers;
		lines.push(`attached: control ${attached.control}, viewer ${attached.viewer}`);
		lines.push(`events sent: ${bridge.eventCount}`);
		lines.push(`last error: ${bridge.lastErrorMessage ?? "none"}`);
		return lines.join("\n");
	};

	registerRemoteCommand(pi, bridge, {
		getConfig: () => config,
		getSettings: () => settings,
		updateSettings,
		getLocalServer: () => (localStarted ? localServer : undefined),
		relayConnected: () => relayClient?.connected ?? false,
		describeStatus,
	});

	if (config.remoteApproval) {
		pi.on("tool_call", async (event: ToolCallEvent, _ctx: ExtensionContext): Promise<ToolCallEventResult | undefined> => {
			if (alwaysApprovedTools.has(event.toolName)) return undefined;
			// Only bother a remote control when one is actually attached; a
			// hung phone with nobody watching must never stall the session.
			if (bridge.getCurrentState().viewers.control <= 0) return undefined;

			const { answer: pending } = bridge.raiseRequest({
				k: "approval",
				toolName: event.toolName,
				input: truncateText(safeStringifyInput(event.input), TOOL_INPUT_MAX_BYTES),
				risk: toolRisk(event.toolName),
				timeout: APPROVAL_TIMEOUT_MS,
			});
			const answer = await pending;
			// A timeout or cancellation resolves to undefined: fall through to
			// the local default, same as "allow".
			if (!answer || !("decision" in answer)) return undefined;

			switch (answer.decision) {
				case "deny":
					return { block: true, reason: "denied via omp-remote control connection" };
				case "always":
					alwaysApprovedTools.add(event.toolName);
					return undefined;
				default:
					return undefined;
			}
		});
	}

	pi.on("session_shutdown", async () => {
		relayClient?.stop();
		guestClient?.stop();
		localServer?.stop();
		if (takeoverTimer) {
			const ctx = bridge.getLatestCtx();
			if (ctx) ctx.clearTimer(takeoverTimer);
			takeoverTimer = undefined;
		}
		bridge.cancelAllRequests("shutdown");
	});
}
