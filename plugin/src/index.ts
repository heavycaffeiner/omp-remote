// Extension entry point. Wires SessionBridge to whichever transports are
// configured and owns their lifecycle: construction at load, start on
// session_start, stop on session_shutdown.

import type { ExtensionAPI, ExtensionContext, ToolCallEvent, ToolCallEventResult } from "@oh-my-pi/pi-coding-agent";
import { ConfigError, readRemoteConfig, type RemoteConfig } from "./config.js";
import { SessionBridge } from "./session-bridge.js";
import { RelayClient } from "./relay-client.js";
import { LocalServer } from "./local-server.js";
import { registerAskShadow } from "./ask-shadow.js";
import { registerRemoteOmpCommand } from "./pairing.js";
import { safeStringifyInput, truncateText, TOOL_INPUT_MAX_BYTES } from "./normalize.js";

const APPROVAL_TIMEOUT_MS = 120000;

// Maps a tool name to the risk tier shown in the remote approval prompt.
// Mirrors pi-agent-core's ToolTier vocabulary ("read" | "write" | "exec") so
// the phone's wording matches what the workstation's own approval gate uses.
function toolRisk(toolName: string): string {
	if (toolName === "bash") return "exec";
	if (toolName === "write" || toolName === "edit") return "write";
	return "read";
}

export default function ompRemote(pi: ExtensionAPI): void {
	let config: RemoteConfig;
	try {
		config = readRemoteConfig();
	} catch (err) {
		if (!(err instanceof ConfigError)) throw err;
		// Report once through ctx.ui.notify on session_start and leave the
		// extension dormant rather than spamming or throwing at load time.
		let notified = false;
		pi.on("session_start", async (_event, ctx) => {
			if (notified) return;
			notified = true;
			ctx.ui.notify(`omp-remote: ${err.message}`, "error");
		});
		return;
	}

	if (!config.relay && !config.local) {
		// No relay URL and local disabled: load and stay dormant, no error.
		return;
	}

	const bridge = new SessionBridge(pi, config);
	bridge.registerHandlers();
	registerAskShadow(pi, bridge);

	const relayClient = config.relay ? new RelayClient(bridge, config, pi) : undefined;
	const localServer = config.local ? new LocalServer(bridge, config, pi) : undefined;
	const alwaysApprovedTools = new Set<string>();

	// A transport that cannot start is this extension's problem, not the
	// session's. Record it and stay dormant on that transport instead of
	// throwing out of the handler, which would surface as a session error.
	let localStarted = false;
	pi.on("session_start", async (_event, ctx) => {
		try {
			relayClient?.start();
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err);
			bridge.recordError(`relay: ${message}`);
			ctx.ui.notify(`omp-remote relay uplink failed: ${message}`, "warning");
		}
		try {
			localServer?.start();
			localStarted = localServer !== undefined;
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err);
			bridge.recordError(`local server: ${message}`);
			ctx.ui.notify(`omp-remote local server failed: ${message}`, "warning");
		}
	});

	registerRemoteOmpCommand(pi, bridge, config, () => localServer);

	pi.registerCommand("remote", {
		description: "Show omp-remote transport status",
		handler: async (_args, ctx) => {
			const lines: string[] = [`agent: ${bridge.agentId}`];

			if (config.relay) {
				const relayHost = new URL(config.relay.url).host;
				lines.push(`relay: ${relayHost} (${relayClient?.connected ? "connected" : "disconnected"})`);
			} else {
				lines.push("relay: not configured");
			}

			if (!config.local) {
				lines.push("local: not configured");
			} else if (!localStarted) {
				lines.push("local: not running");
			} else {
				const counts = localServer?.clientCounts ?? { control: 0, viewer: 0 };
				lines.push(`local: port ${localServer?.port} (control ${counts.control}, viewer ${counts.viewer})`);
			}

			const attached = bridge.getCurrentState().viewers;
			lines.push(`attached: control ${attached.control}, viewer ${attached.viewer}`);
			lines.push(`events sent: ${bridge.eventCount}`);
			lines.push(`last error: ${bridge.lastErrorMessage ?? "none"}`);
			ctx.ui.notify(lines.join("\n"), "info");
		},
	});

	if (config.remoteApproval) {
		pi.on("tool_call", async (event: ToolCallEvent, _ctx: ExtensionContext): Promise<ToolCallEventResult | undefined> => {
			if (alwaysApprovedTools.has(event.toolName)) return undefined;
			// Only bother a remote control when one is actually attached; a
			// hung phone with nobody watching must never stall the session.
			if (bridge.getCurrentState().viewers.control <= 0) return undefined;

			const answer = await bridge.raiseRequest({
				k: "approval",
				toolName: event.toolName,
				input: truncateText(safeStringifyInput(event.input), TOOL_INPUT_MAX_BYTES),
				risk: toolRisk(event.toolName),
				timeout: APPROVAL_TIMEOUT_MS,
			});
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
		localServer?.stop();
		bridge.cancelAllRequests("shutdown");
	});
}
