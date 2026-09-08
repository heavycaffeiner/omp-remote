// Pairing links and the /remote command (docs/protocol.md, "Pairing").
// The link is a live credential: it is rendered to the UI only, never
// logged, and never sent into the conversation as a message.

import * as os from "node:os";
import { toString as qrToString } from "qrcode";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import type { RemoteConfig } from "./config.js";
import type { SessionBridge } from "./session-bridge.js";
import type { LocalServer } from "./local-server.js";
import {
	DEFAULT_LOCAL_BIND,
	DEFAULT_LOCAL_PORT,
	isRelayUrl,
	settingsPath,
	type StoredSettings,
} from "./settings.js";

export interface PairingTarget {
	transport: "direct" | "relay";
	url: string;
	label: string;
}

const CGNAT_FIRST_OCTET = 100;
const CGNAT_SECOND_OCTET_MIN = 64;
const CGNAT_SECOND_OCTET_MAX = 127;

function isTailscaleAddress(address: string): boolean {
	const parts = address.split(".").map(Number);
	if (parts.length !== 4 || parts.some((n) => Number.isNaN(n))) return false;
	const [first, second] = parts as [number, number, number, number];
	return first === CGNAT_FIRST_OCTET && second >= CGNAT_SECOND_OCTET_MIN && second <= CGNAT_SECOND_OCTET_MAX;
}

function isPrivateLanAddress(address: string): boolean {
	const parts = address.split(".").map(Number);
	if (parts.length !== 4 || parts.some((n) => Number.isNaN(n))) return false;
	const [first, second] = parts as [number, number, number, number];
	if (first === 10) return true;
	if (first === 172 && second >= 16 && second <= 31) return true;
	if (first === 192 && second === 168) return true;
	return false;
}

// Sort key: Tailscale addresses first, then private LAN, then anything else
// plausible. Loopback and link-local are filtered out before this runs.
function addressRank(address: string): number {
	if (isTailscaleAddress(address)) return 0;
	if (isPrivateLanAddress(address)) return 1;
	return 2;
}

// Enumerates non-loopback, non-link-local IPv4 addresses reachable from
// another device: a Tailscale CGNAT address first, then private LAN ranges,
// then any other IPv4 address the interface reports. Every plausible
// candidate is returned so the caller can print several rather than
// guessing which one the phone can reach.
export function directPairingTargets(port: number): PairingTarget[] {
	const interfaces = os.networkInterfaces();
	const ranked: Array<{ rank: number; target: PairingTarget }> = [];

	for (const [name, infos] of Object.entries(interfaces)) {
		if (!infos) continue;
		for (const info of infos) {
			if (info.family !== "IPv4") continue;
			if (info.internal) continue;
			if (info.address.startsWith("169.254.")) continue; // link-local

			const label = isTailscaleAddress(info.address) ? "Tailscale" : `LAN (${name})`;
			ranked.push({
				rank: addressRank(info.address),
				target: { transport: "direct", url: `ws://${info.address}:${port}`, label },
			});
		}
	}

	ranked.sort((a, b) => a.rank - b.rank);
	return ranked.map((entry) => entry.target);
}

// Builds remote-omp://pair?v=2&t=...&url=...&alt=...&token=...&role=...&agent=...&name=...
// (docs/protocol.md, "Pairing"), matching the Flutter app's parser exactly.
// `agent` is sent on both transports: a workstation serves every session on
// one port, so without it a client cannot tell which one the link is for.
//
// Every remaining candidate rides along as a repeated `alt`. Ranking picks a
// best guess, but only the phone knows which of a workstation's interfaces it
// can actually reach, and a link naming one address strands it on a silent
// timeout when that guess is wrong.
export function buildPairingLink(
	target: PairingTarget,
	token: string,
	role: "control" | "viewer",
	agentId: string,
	name: string,
	alternates: readonly PairingTarget[] = [],
): string {
	const params = new URLSearchParams();
	params.set("v", "2");
	params.set("t", target.transport);
	params.set("url", target.url);
	for (const alternate of alternates) {
		if (alternate.url !== target.url) params.append("alt", alternate.url);
	}
	params.set("token", token);
	params.set("role", role);
	params.set("agent", agentId);
	params.set("name", name);
	return `remote-omp://pair?${params.toString()}`;
}

// Renders a QR code as a terminal-scannable block string. `small: true`
// packs two QR rows per printed line (half-block characters), which is what
// actually scans reliably at typical terminal font aspect ratios.
export async function renderQr(text: string): Promise<string> {
	return qrToString(text, { type: "terminal", small: true });
}

interface PairingTokenResult {
	token: string;
}

// Resolves the token for a role over a transport. Direct mints two genuinely
// independent secrets at local-server startup (LocalServerTokens), so both
// roles are always distinct there. Relay pairing needs a client-facing secret
// issued by the relay operator, which is a different credential from the agent
// token this plugin dials /agent with. The agent token must never stand in for
// one: it authenticates as an agent and can claim any agentId, which is more
// power than any client link should carry, and the relay refuses it at /client
// anyway, so substituting it produces a link that is both unsafe and broken.
function resolvePairingToken(
	role: "control" | "viewer",
	transport: "direct" | "relay",
	config: RemoteConfig,
	local: LocalServer | undefined,
): PairingTokenResult | { error: string } {
	if (transport === "direct") {
		if (!local) return { error: "the local server is not running" };
		return { token: role === "control" ? local.tokens.control : local.tokens.viewer };
	}
	if (!config.relay) {
		return { error: "no relay is configured. Run /remote config relay <url> <token>" };
	}

	const field = role === "control" ? "control" : "viewer";
	const relayVar = role === "control" ? "OMP_RELAY_CONTROL_TOKEN" : "OMP_RELAY_VIEWER_TOKEN";
	const token = role === "control" ? config.relay.controlToken : config.relay.viewerToken;
	if (!token) {
		return {
			error: `no ${role} token is configured for relay pairing. Run /remote config relay ${field} <token> with the relay's ${relayVar}, or pair over direct instead. The agent token cannot be used here: it authenticates as an agent, not a client`,
		};
	}
	return { token };
}

interface HostedPairing {
	url: string;
	code: string;
	expiresAt: number;
	clientToken: string;
}

// Asks the session holding the port for a pairing code on this session's
// behalf, plus the client token that code stands for. A guest has no server
// of its own, so without this only the session that happened to start first
// could be paired to.
async function requestHostedPairing(port: number, role: "control" | "viewer"): Promise<HostedPairing | undefined> {
	try {
		const response = await fetch(`http://127.0.0.1:${port}/join?code=${role}`, {
			signal: AbortSignal.timeout(2000),
		});
		if (!response.ok) return undefined;
		const payload = (await response.json()) as Record<string, unknown>;
		const { url, code, expiresAt, clientToken } = payload;
		if (
			typeof url !== "string" ||
			typeof code !== "string" ||
			typeof expiresAt !== "number" ||
			typeof clientToken !== "string"
		) {
			return undefined;
		}
		return { url, code, expiresAt, clientToken };
	} catch {
		return undefined;
	}
}

/// What `/remote` needs from the extension: the live config, the settings
/// behind it, a way to persist a change, and the transports' current state.
export interface RemoteHost {
	getConfig: () => RemoteConfig;
	getSettings: () => StoredSettings;
	updateSettings: (next: StoredSettings) => void;
	getLocalServer: () => LocalServer | undefined;
	relayConnected: () => boolean;
	/// Rendered by `/remote status`; only the extension factory holds the
	/// transports it reports on.
	describeStatus: () => string;
}

const CONFIG_USAGE = [
	"Usage:",
	"  /remote config                       show the current settings",
	"  /remote config relay <url> <token>   route through a relay",
	"  /remote config relay control <token> client token for control links",
	"  /remote config relay viewer <token>  client token for viewer links",
	"  /remote config relay off             go back to direct only",
	"  /remote config port <number>         port the direct server binds",
	"  /remote config bind <address>        address the direct server binds",
	"  /remote config direct on|off         serve directly at all",
	"  /remote config bash on|off           allow remote shell commands",
	"  /remote config approval on|off       ask the phone to approve tools",
].join("\n");

/// Renders the settings a user can change, plus where they are stored. A
/// token is never echoed: only whether one is set.
function describeSettings(host: RemoteHost): string {
	const settings = host.getSettings();
	const lines = ["omp-remote settings", ""];
	if (settings.relay) {
		lines.push(`  relay:     ${settings.relay.url} (${host.relayConnected() ? "connected" : "disconnected"})`);
		lines.push(`  agent token: set`);
		lines.push(`  control token: ${settings.relay.controlToken ? "set" : "not set"}`);
		lines.push(`  viewer token:  ${settings.relay.viewerToken ? "set" : "not set"}`);
	} else {
		lines.push("  relay:     not configured (direct only)");
	}
	lines.push(
		`  direct:    ${settings.localEnabled ? `on, ${settings.localBind}:${settings.localPort}` : "off"}`,
		`  bash:      ${settings.allowBash ? "allowed" : "blocked"}`,
		`  approval:  ${settings.remoteApproval ? "asked on the phone" : "workstation only"}`,
		"",
		`Stored in ${settingsPath()}`,
		"",
		CONFIG_USAGE,
	);
	return lines.join("\n");
}

function parseOnOff(word: string | undefined): boolean | undefined {
	if (word === "on" || word === "true" || word === "1") return true;
	if (word === "off" || word === "false" || word === "0") return false;
	return undefined;
}

/// Applies one config change and returns what to show the user. Changing the
/// port or the bind address only takes effect on the next start, since the
/// listening socket is already bound; the reply says so rather than leaving
/// the user to wonder.
function runConfig(words: string[], host: RemoteHost): string {
	if (words.length === 0) return describeSettings(host);

	const settings = host.getSettings();
	const next: StoredSettings = { ...settings, relay: settings.relay ? { ...settings.relay } : undefined };
	const key = (words[0] ?? "").toLowerCase();

	switch (key) {
		case "relay": {
			const sub = (words[1] ?? "").toLowerCase();
			if (sub === "off" || sub === "none") {
				if (!next.relay) return "No relay was configured; nothing changed.";
				next.relay = undefined;
				host.updateSettings(next);
				return "Relay cleared. This session serves directly only.";
			}
			if (sub === "control" || sub === "viewer") {
				const token = words[2];
				if (!next.relay) {
					return "Configure the relay first: /remote config relay <url> <token>";
				}
				if (!token) return `Missing token. ${CONFIG_USAGE}`;
				if (sub === "control") next.relay.controlToken = token;
				else next.relay.viewerToken = token;
				host.updateSettings(next);
				return `Relay ${sub} token saved. Pairing links for that role will now work.`;
			}
			const url = words[1];
			const token = words[2];
			if (!url || !token) return `Missing relay URL or token.\n\n${CONFIG_USAGE}`;
			if (!isRelayUrl(url)) {
				return `That is not a usable relay URL: ${url}. It must start with ws:// or wss://`;
			}
			// Role tokens belong to whichever relay issued them, so pointing at
			// a different relay drops them rather than carrying them over.
			const keepRoleTokens = next.relay?.url === url;
			next.relay = {
				url,
				token,
				controlToken: keepRoleTokens ? next.relay?.controlToken : undefined,
				viewerToken: keepRoleTokens ? next.relay?.viewerToken : undefined,
			};
			host.updateSettings(next);
			return [
				`Relay set to ${url}. Connecting now.`,
				"",
				"Relay pairing links also need the relay's own client tokens:",
				"  /remote config relay control <token>",
				"  /remote config relay viewer <token>",
			].join("\n");
		}
		case "port": {
			const raw = words[1];
			const port = Number.parseInt(raw ?? "", 10);
			if (!Number.isInteger(port) || port <= 0 || port > 65535) {
				return `Not a port number: ${raw ?? "(missing)"}. Give a number from 1 to 65535.`;
			}
			next.localPort = port;
			host.updateSettings(next);
			return `Direct port set to ${port}. Restart omp for it to take effect (default is ${DEFAULT_LOCAL_PORT}).`;
		}
		case "bind": {
			const address = words[1];
			if (!address) return `Missing address.\n\n${CONFIG_USAGE}`;
			next.localBind = address;
			host.updateSettings(next);
			return `Direct bind address set to ${address}. Restart omp for it to take effect (default is ${DEFAULT_LOCAL_BIND}).`;
		}
		case "direct": {
			const value = parseOnOff((words[1] ?? "").toLowerCase());
			if (value === undefined) return `Say on or off.\n\n${CONFIG_USAGE}`;
			next.localEnabled = value;
			host.updateSettings(next);
			return `Direct serving ${value ? "enabled" : "disabled"}. Restart omp for it to take effect.`;
		}
		case "bash": {
			const value = parseOnOff((words[1] ?? "").toLowerCase());
			if (value === undefined) return `Say on or off.\n\n${CONFIG_USAGE}`;
			next.allowBash = value;
			host.updateSettings(next);
			return value
				? "Remote shell commands are now allowed. Anyone holding a control token can run commands on this machine."
				: "Remote shell commands are now blocked.";
		}
		case "approval": {
			const value = parseOnOff((words[1] ?? "").toLowerCase());
			if (value === undefined) return `Say on or off.\n\n${CONFIG_USAGE}`;
			next.remoteApproval = value;
			host.updateSettings(next);
			return `Tool approval ${value ? "will be asked on the phone when one is attached" : "stays on the workstation"}. Restart omp for it to take effect.`;
		}
		default:
			return `Unknown setting "${key}".\n\n${CONFIG_USAGE}`;
	}
}

/// What to try when the app sits on "Connecting". The listener binds every
/// interface, so a phone that cannot reach it is almost always being dropped
/// by the workstation's own firewall, and that is invisible from here: a
/// connect from this machine to its own address never traverses the input
/// chain, so the plugin cannot test it for the user.
function firewallHint(port: number): string {
	return [
		`If the app stays on "Connecting", this machine is dropping port ${port}.`,
		"Open it for your local network, for example:",
		`    sudo firewall-cmd --add-port=${port}/tcp        # firewalld, this boot only`,
		`    sudo ufw allow ${port}/tcp                      # ufw`,
		"Tailscale traffic usually arrives on a trusted interface and needs nothing.",
	].join("\n");
}

// Registers the /remote command (docs/protocol.md, "Pairing"):
//   bare    -> control link, direct preferred when the local server is up, relay fallback
//   viewer  -> viewer link instead of control
//   relay   -> force the relay form even when the local server is up
//   config  -> show or change the persisted settings
//   status  -> transport diagnostics
//
// One command, because pairing and the settings behind it are the same
// subject: two names for one plugin only made the user guess which.
export function registerRemoteCommand(
	pi: ExtensionAPI,
	bridge: SessionBridge,
	host: RemoteHost,
): void {
	pi.registerCommand("remote", {
		description: "Pair the OMPRemote app with this session, or configure it",
		handler: async (argsText, ctx) => {
			const words = argsText.trim().split(/\s+/).filter((word) => word.length > 0);
			const first = words[0]?.toLowerCase() ?? "";

			if (first === "config") {
				ctx.ui.notify(runConfig(words.slice(1), host), "info");
				return;
			}

			if (first === "status") {
				ctx.ui.notify(host.describeStatus(), "info");
				return;
			}

			const config = host.getConfig();
			const role: "control" | "viewer" = first === "viewer" ? "viewer" : "control";
			const forceRelay = first === "relay";
			const local = host.getLocalServer();

			// A guest session has no server of its own: the host holds the port
			// for the whole workstation. Ask it for a code naming this session,
			// so pairing works the same from any session rather than only the
			// one that happened to start first.
			if (!forceRelay && !local && config.local) {
				const hosted = await requestHostedPairing(config.local.port, role);
				if (hosted) {
					const minutes = Math.round((hosted.expiresAt - Date.now()) / 60000);
					const roleLabel = role === "viewer" ? "Viewer, read-only" : "Control";
					// The host reports the address it bound, which is loopback when
					// it bound loopback. A phone cannot dial that, so the link and
					// the printed address both use a reachable interface.
					const port = Number(new URL(hosted.url.replace(/^ws:/, "http:")).port);
					const reachable = directPairingTargets(port);
					const primary: PairingTarget = reachable[0] ?? {
						transport: "direct",
						url: hosted.url,
						label: "Workstation",
					};
					const link = buildPairingLink(
						primary,
						hosted.clientToken,
						role,
						bridge.agentId,
						bridge.info.name,
						reachable,
					);
					const lines = [
						`${roleLabel} pairing for ${bridge.agentId}`,
						"",
						"This session is served by another one on this machine, so",
						"pair against the shared address and pick it in the app:",
						"",
						`    Address:  ${primary.url.replace(/^ws:\/\//, "")}`,
						`    Code:     ${hosted.code}`,
						"",
						`The code works once and expires in ${minutes} minutes.`,
						`Then choose ${bridge.agentId} from the session list.`,
					];
					if (reachable.length > 1) {
						lines.push("", "Other addresses for this workstation:");
						for (let i = 1; i < reachable.length; i++) {
							const target = reachable[i] as PairingTarget;
							lines.push(`  ${target.label}: ${target.url.replace(/^ws:\/\//, "")}`);
						}
					}
					lines.push("", "Or paste this link into the app:", "", link);
					lines.push("", await renderQr(link));
					lines.push(firewallHint(port));
					ctx.ui.notify(lines.join("\n"), "info");
					return;
				}
			}

			const transport: "direct" | "relay" = !forceRelay && local ? "direct" : "relay";

			const tokenResult = resolvePairingToken(role, transport, config, local);
			if ("error" in tokenResult) {
				ctx.ui.notify(`Cannot pair: ${tokenResult.error}`, "error");
				return;
			}

			const candidates: PairingTarget[] =
				transport === "direct"
					? directPairingTargets(local!.port)
					: [{ transport: "relay", url: config.relay!.url, label: "Relay" }];

			if (candidates.length === 0) {
				ctx.ui.notify(
					"Cannot pair: no reachable network address found (only loopback and link-local interfaces present)",
					"error",
				);
				return;
			}

			const primary = candidates[0] as PairingTarget;
			const links = candidates.map((candidate) =>
				buildPairingLink(
					candidate,
					tokenResult.token,
					role,
					bridge.agentId,
					bridge.info.name,
					candidates,
				),
			);
			const primaryLink = links[0] as string;
			const qr = await renderQr(primaryLink);

			const roleLabel = role === "viewer" ? "Viewer, read-only" : "Control";
			const lines = [`${roleLabel} pairing for ${bridge.agentId}`, "", qr];

			// Typing six characters beats copying a 64-character token by hand,
			// which is the only other option when the QR cannot be scanned.
			// Relay pairing has no code: the code is redeemed from the local
			// server, which a relayed client cannot reach.
			if (transport === "direct" && local) {
				const issued = local.issuePairingCode(role);
				const minutes = Math.round((issued.expiresAt - Date.now()) / 60000);
				lines.push(
					"Cannot scan? In the app choose Enter a code, then type:",
					"",
					`    Address:  ${primary.url.replace(/^ws:\/\//, "")}`,
					`    Code:     ${issued.code}`,
					"",
					`The code works once and expires in ${minutes} minutes.`,
					"",
					"Or paste this link into the app:",
					"",
					primaryLink,
				);
			} else {
				lines.push("Cannot scan? Paste this link into the app:", "", primaryLink);
			}

			if (links.length > 1) {
				lines.push("", "Other addresses for this workstation:");
				for (let i = 1; i < links.length; i++) {
					const target = candidates[i] as PairingTarget;
					lines.push(`  ${target.label}: ${target.url.replace(/^ws:\/\//, "")}`);
				}
			}

			if (transport === "direct" && local) {
				lines.push("", firewallHint(local.port));
			}

			// UI notification only: never appended to the session transcript and
			// never sent to the model, unlike pi.sendMessage/sendUserMessage. The
			// token therefore never enters the conversation or a log line.
			ctx.ui.notify(lines.join("\n"), "info");
		},
	});
}
