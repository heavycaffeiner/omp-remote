// Persisted plugin settings. The relay lives here rather than in the
// environment so `/remote-omp config` can change it and the change survives a
// restart. The file is user-editable, so every field is validated on read and
// a bad value degrades to the default rather than failing the session.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export const DEFAULT_LOCAL_PORT = 8788;
export const DEFAULT_LOCAL_BIND = "0.0.0.0";

export interface StoredRelay {
	url: string;
	token: string;
	/// Client-facing secrets issued by the relay operator. Absent means relay
	/// pairing links cannot be built for that role.
	controlToken?: string;
	viewerToken?: string;
}

export interface StoredSettings {
	/// Absent means direct only, which is the default.
	relay?: StoredRelay;
	localEnabled: boolean;
	localPort: number;
	localBind: string;
	allowBash: boolean;
	remoteApproval: boolean;
}

export const DEFAULT_SETTINGS: StoredSettings = {
	localEnabled: true,
	localPort: DEFAULT_LOCAL_PORT,
	localBind: DEFAULT_LOCAL_BIND,
	allowBash: false,
	remoteApproval: false,
};

// Same directory the agent keeps its own config in, so the file sits next to
// config.yml rather than inventing a location.
export function settingsPath(env: NodeJS.ProcessEnv = process.env): string {
	const configured = env.OMP_REMOTE_CONFIG;
	if (configured) return configured;
	const agentDir = env.PI_CODING_AGENT_DIR ?? path.join(os.homedir(), ".omp", "agent");
	return path.join(agentDir, "omp-remote.json");
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
	return value as Record<string, unknown>;
}

function asNonEmptyString(value: unknown): string | undefined {
	return typeof value === "string" && value.trim().length > 0 ? value : undefined;
}

function asBool(value: unknown, fallback: boolean): boolean {
	return typeof value === "boolean" ? value : fallback;
}

function asPort(value: unknown, fallback: number): number {
	if (typeof value !== "number" || !Number.isInteger(value) || value <= 0 || value > 65535) {
		return fallback;
	}
	return value;
}

/// A relay entry is kept only when it carries both a usable ws/wss URL and a
/// token. Half a relay would fail at dial time with a less obvious message.
function parseRelay(value: unknown): StoredRelay | undefined {
	const record = asRecord(value);
	if (!record) return undefined;
	const url = asNonEmptyString(record.url);
	const token = asNonEmptyString(record.token);
	if (!url || !token) return undefined;
	if (!isRelayUrl(url)) return undefined;
	return {
		url,
		token,
		controlToken: asNonEmptyString(record.controlToken),
		viewerToken: asNonEmptyString(record.viewerToken),
	};
}

export function isRelayUrl(url: string): boolean {
	try {
		const parsed = new URL(url);
		return parsed.protocol === "ws:" || parsed.protocol === "wss:";
	} catch {
		return false;
	}
}

export function parseSettings(raw: unknown): StoredSettings {
	const record = asRecord(raw);
	if (!record) return { ...DEFAULT_SETTINGS };
	const local = asRecord(record.local) ?? {};
	return {
		relay: parseRelay(record.relay),
		localEnabled: asBool(local.enabled, DEFAULT_SETTINGS.localEnabled),
		localPort: asPort(local.port, DEFAULT_SETTINGS.localPort),
		localBind: asNonEmptyString(local.bind) ?? DEFAULT_SETTINGS.localBind,
		allowBash: asBool(record.allowBash, DEFAULT_SETTINGS.allowBash),
		remoteApproval: asBool(record.remoteApproval, DEFAULT_SETTINGS.remoteApproval),
	};
}

// A missing or unreadable file is the first run, not an error: the defaults
// are a working direct setup.
export function loadSettings(file: string = settingsPath()): StoredSettings {
	let text: string;
	try {
		text = fs.readFileSync(file, "utf8");
	} catch {
		return { ...DEFAULT_SETTINGS };
	}
	try {
		return parseSettings(JSON.parse(text));
	} catch {
		return { ...DEFAULT_SETTINGS };
	}
}

export function serializeSettings(settings: StoredSettings): string {
	const out: Record<string, unknown> = {
		local: {
			enabled: settings.localEnabled,
			port: settings.localPort,
			bind: settings.localBind,
		},
		allowBash: settings.allowBash,
		remoteApproval: settings.remoteApproval,
	};
	if (settings.relay) out.relay = settings.relay;
	return `${JSON.stringify(out, null, "\t")}\n`;
}

// Written through a temporary file in the same directory and renamed, so an
// interrupted write cannot leave a truncated file holding a relay token.
// Mode 0600: the file holds credentials.
export function saveSettings(settings: StoredSettings, file: string = settingsPath()): void {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const temp = `${file}.${process.pid.toString(36)}.tmp`;
	fs.writeFileSync(temp, serializeSettings(settings), { mode: 0o600 });
	fs.renameSync(temp, file);
}
