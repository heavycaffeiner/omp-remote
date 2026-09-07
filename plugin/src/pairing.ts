// Pairing links and the /remote-omp command (docs/protocol.md, "Pairing").
// The link is a live credential: it is rendered to the UI only, never
// logged, and never sent into the conversation as a message.

import * as os from "node:os";
import { toString as qrToString } from "qrcode";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import type { RemoteConfig } from "./config.js";
import type { SessionBridge } from "./session-bridge.js";
import type { LocalServer } from "./local-server.js";

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

// Builds remote-omp://pair?v=2&t=...&url=...&token=...&role=...&agent=...&name=...
// (docs/protocol.md, "Pairing"), matching the Flutter app's parser exactly.
// `agent` is present only for relay targets, per the Pairing table ("relay" required, absent for direct).
export function buildPairingLink(
	target: PairingTarget,
	token: string,
	role: "control" | "viewer",
	agentId: string,
	name: string,
): string {
	const params = new URLSearchParams();
	params.set("v", "2");
	params.set("t", target.transport);
	params.set("url", target.url);
	params.set("token", token);
	params.set("role", role);
	if (target.transport === "relay") params.set("agent", agentId);
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
	if (!config.relay) return { error: "no relay is configured (OMP_REMOTE_RELAY_URL is unset)" };

	const envVar = role === "control" ? "OMP_REMOTE_CONTROL_TOKEN" : "OMP_REMOTE_VIEWER_TOKEN";
	const relayVar = role === "control" ? "OMP_RELAY_CONTROL_TOKEN" : "OMP_RELAY_VIEWER_TOKEN";
	const token = role === "control" ? config.relay.controlToken : config.relay.viewerToken;
	if (!token) {
		return {
			error: `no ${role} token is configured for relay pairing. Set ${envVar} to the relay's ${relayVar}, or pair over direct instead. The agent token cannot be used here: it authenticates as an agent, not a client`,
		};
	}
	return { token };
}

interface HostedPairing {
	url: string;
	code: string;
	expiresAt: number;
}

// Asks the session holding the port for a pairing code on this session's
// behalf. A guest has no server of its own, so without this only the session
// that happened to start first could be paired to.
async function requestHostedPairing(port: number, role: "control" | "viewer"): Promise<HostedPairing | undefined> {
	try {
		const response = await fetch(`http://127.0.0.1:${port}/join?code=${role}`, {
			signal: AbortSignal.timeout(2000),
		});
		if (!response.ok) return undefined;
		const payload = (await response.json()) as Record<string, unknown>;
		const url = payload.url;
		const code = payload.code;
		const expiresAt = payload.expiresAt;
		if (typeof url !== "string" || typeof code !== "string" || typeof expiresAt !== "number") {
			return undefined;
		}
		return { url, code, expiresAt };
	} catch {
		return undefined;
	}
}

// Registers the /remote-omp command (docs/protocol.md, "Pairing"):
//   bare    -> control link, direct preferred when the local server is up, relay fallback
//   viewer  -> viewer link instead of control
//   relay   -> force the relay form even when the local server is up
export function registerRemoteOmpCommand(
	pi: ExtensionAPI,
	_bridge: SessionBridge,
	config: RemoteConfig,
	getLocalServer: () => LocalServer | undefined,
): void {
	const bridge = _bridge;
	pi.registerCommand("remote-omp", {
		description: "Pair the OMPRemote app with this session",
		handler: async (argsText, ctx) => {
			const arg = argsText.trim().split(/\s+/)[0]?.toLowerCase() ?? "";
			const role: "control" | "viewer" = arg === "viewer" ? "viewer" : "control";
			const forceRelay = arg === "relay";
			const local = getLocalServer();

			// A guest session has no server of its own: the host holds the port
			// for the whole workstation. Ask it for a code naming this session,
			// so pairing works the same from any session rather than only the
			// one that happened to start first.
			if (!forceRelay && !local && config.local) {
				const hosted = await requestHostedPairing(config.local.port, role);
				if (hosted) {
					const link = buildPairingLink(
						{ transport: "direct", url: hosted.url, label: "Workstation" },
						"",
						role,
						bridge.agentId,
						bridge.info.name,
					);
					const minutes = Math.round((hosted.expiresAt - Date.now()) / 60000);
					const roleLabel = role === "viewer" ? "Viewer, read-only" : "Control";
					// The host reports the address it picked, which is loopback when
					// it bound loopback. Offer the reachable interfaces too, since a
					// phone cannot dial 127.0.0.1.
					const port = Number(new URL(hosted.url.replace(/^ws:/, "http:")).port);
					const reachable = directPairingTargets(port);
					const lines = [
						`${roleLabel} pairing for ${bridge.agentId}`,
						"",
						"This session is served by another one on this machine, so",
						"pair against the shared address and pick it in the app:",
						"",
						`    Address:  ${(reachable[0]?.url ?? hosted.url).replace(/^ws:\/\//, "")}`,
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
					lines.push("", await renderQr(link));
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
				buildPairingLink(candidate, tokenResult.token, role, bridge.agentId, bridge.info.name),
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
				);
			} else {
				lines.push("Cannot scan? Open this link on the device:", "", primaryLink);
			}

			if (links.length > 1) {
				lines.push("", "Other addresses for this workstation:");
				for (let i = 1; i < links.length; i++) {
					const target = candidates[i] as PairingTarget;
					lines.push(`  ${target.label}: ${target.url.replace(/^ws:\/\//, "")}`);
				}
			}

			// UI notification only: never appended to the session transcript and
			// never sent to the model, unlike pi.sendMessage/sendUserMessage. The
			// token therefore never enters the conversation or a log line.
			ctx.ui.notify(lines.join("\n"), "info");
		},
	});
}
