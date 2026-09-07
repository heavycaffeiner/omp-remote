// Reads and validates OMP_REMOTE_* environment variables at the process boundary.
// Nothing downstream re-reads process.env; everything flows through RemoteConfig.

import * as os from "node:os";
import * as path from "node:path";

export interface RelayConfig {
	url: string;
	token: string;
	// Client-facing secrets, issued by the relay operator. They are not used to
	// dial the relay: they exist only so a pairing link can hand a phone a
	// credential of the right strength. The agent token must never take their
	// place, since it authenticates at /agent and can claim any agentId.
	controlToken: string | undefined;
	viewerToken: string | undefined;
}

export interface LocalServerConfig {
	port: number;
	bind: string;
}

export interface RemoteConfig {
	agentId: string;
	agentName: string;
	relay: RelayConfig | undefined;
	local: LocalServerConfig | undefined;
	allowBash: boolean;
	remoteApproval: boolean;
}

// Host and directory alone collide when two sessions run in the same project,
// and on a relay the second registration evicts the first. A short suffix from
// the process id keeps them distinct while staying readable in a roster.
function defaultAgentId(): string {
	const host = os.hostname();
	const base = path.basename(process.cwd());
	const suffix = process.pid.toString(36).slice(-4);
	return `${host}/${base}#${suffix}`;
}

function parseBoolEnv(value: string | undefined, defaultValue: boolean): boolean {
	if (value === undefined) return defaultValue;
	return value === "1" || value.toLowerCase() === "true";
}

// Returns undefined (dormant) when the relay URL is unset. Throws a descriptive
// error only for a present-but-invalid configuration, which the caller reports
// once through ctx.ui.notify rather than letting it surface as noise.
function readRelayConfig(env: NodeJS.ProcessEnv): RelayConfig | undefined {
	const url = env.OMP_REMOTE_RELAY_URL;
	if (!url) return undefined;

	let parsed: URL;
	try {
		parsed = new URL(url);
	} catch {
		throw new Error(`OMP_REMOTE_RELAY_URL is not a valid URL: ${url}`);
	}
	if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
		throw new Error(`OMP_REMOTE_RELAY_URL must be ws: or wss:, got ${parsed.protocol}`);
	}

	const token = env.OMP_REMOTE_TOKEN;
	if (!token) {
		throw new Error("OMP_REMOTE_TOKEN is required when OMP_REMOTE_RELAY_URL is set");
	}

	return {
		url,
		token,
		controlToken: env.OMP_REMOTE_CONTROL_TOKEN || undefined,
		viewerToken: env.OMP_REMOTE_VIEWER_TOKEN || undefined,
	};
}

function readLocalConfig(env: NodeJS.ProcessEnv): LocalServerConfig | undefined {
	if (env.OMP_REMOTE_LOCAL === "0") return undefined;

	const portRaw = env.OMP_REMOTE_LOCAL_PORT;
	let port = 8788;
	if (portRaw !== undefined) {
		const parsedPort = Number.parseInt(portRaw, 10);
		if (!Number.isFinite(parsedPort) || parsedPort <= 0 || parsedPort > 65535) {
			throw new Error(`OMP_REMOTE_LOCAL_PORT must be a valid port number, got ${portRaw}`);
		}
		port = parsedPort;
	}

	const bind = env.OMP_REMOTE_LOCAL_BIND ?? "0.0.0.0";
	return { port, bind };
}

export class ConfigError extends Error {}

export function readRemoteConfig(env: NodeJS.ProcessEnv = process.env): RemoteConfig {
	let relay: RelayConfig | undefined;
	try {
		relay = readRelayConfig(env);
	} catch (err) {
		throw new ConfigError(err instanceof Error ? err.message : String(err));
	}

	let local: LocalServerConfig | undefined;
	try {
		local = readLocalConfig(env);
	} catch (err) {
		throw new ConfigError(err instanceof Error ? err.message : String(err));
	}

	const agentId = env.OMP_REMOTE_AGENT_ID ?? defaultAgentId();
	const agentName = path.basename(process.cwd());

	return {
		agentId,
		agentName,
		relay,
		local,
		allowBash: parseBoolEnv(env.OMP_REMOTE_ALLOW_BASH, false),
		remoteApproval: parseBoolEnv(env.OMP_REMOTE_REMOTE_APPROVAL, false),
	};
}
