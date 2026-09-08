// Turns the persisted settings file into the config the transports run on.
// Nothing downstream reads the file or the environment; everything flows
// through RemoteConfig.

import * as os from "node:os";
import * as path from "node:path";

import { loadSettings, type StoredSettings } from "./settings.js";

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
	/// Absent unless a relay was configured with `/remote config relay`.
	/// Direct serving is the default and needs no configuration at all.
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

/// Projects stored settings onto the running config. Every value is already
/// validated by `parseSettings`, so this cannot fail.
export function configFromSettings(settings: StoredSettings): RemoteConfig {
	return {
		agentId: defaultAgentId(),
		agentName: path.basename(process.cwd()),
		relay: settings.relay
			? {
					url: settings.relay.url,
					token: settings.relay.token,
					controlToken: settings.relay.controlToken,
					viewerToken: settings.relay.viewerToken,
				}
			: undefined,
		local: settings.localEnabled
			? { port: settings.localPort, bind: settings.localBind }
			: undefined,
		allowBash: settings.allowBash,
		remoteApproval: settings.remoteApproval,
	};
}

export function readRemoteConfig(): RemoteConfig {
	return configFromSettings(loadSettings());
}
