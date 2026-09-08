// The settings file is a trust boundary: a user edits it by hand and an
// interrupted write can truncate it. A bad value must leave a working direct
// setup rather than a failed session, so every degradation path is pinned.

import { describe, expect, test } from "bun:test";
import { mkdtempSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import {
	DEFAULT_SETTINGS,
	isRelayUrl,
	loadSettings,
	parseSettings,
	saveSettings,
	settingsPath,
} from "../src/settings.js";
import { configFromSettings } from "../src/config.js";

function scratch(): string {
	return join(mkdtempSync(join(tmpdir(), "omp-remote-settings-")), "omp-remote.json");
}

describe("parseSettings", () => {
	test("nothing configured means direct only", () => {
		const settings = parseSettings({});
		expect(settings.relay).toBeUndefined();
		expect(settings.localEnabled).toBe(true);
		expect(settings.localPort).toBe(8788);
		expect(settings.localBind).toBe("0.0.0.0");
		expect(settings.allowBash).toBe(false);
		expect(settings.remoteApproval).toBe(false);
	});

	test("a relay missing its token is dropped, not half-applied", () => {
		expect(parseSettings({ relay: { url: "wss://relay.example/agent" } }).relay).toBeUndefined();
		expect(parseSettings({ relay: { token: "t" } }).relay).toBeUndefined();
	});

	test("a relay URL that is not ws or wss is dropped", () => {
		for (const url of ["http://relay.example", "https://relay.example", "relay.example", ""]) {
			expect(parseSettings({ relay: { url, token: "t" } }).relay).toBeUndefined();
		}
	});

	test("a usable relay keeps its role tokens", () => {
		const settings = parseSettings({
			relay: {
				url: "wss://relay.example/agent",
				token: "agent",
				controlToken: "ctl",
				viewerToken: "view",
			},
		});
		expect(settings.relay).toEqual({
			url: "wss://relay.example/agent",
			token: "agent",
			controlToken: "ctl",
			viewerToken: "view",
		});
	});

	test("an out-of-range or non-integer port falls back to the default", () => {
		for (const port of [0, -1, 65536, 1.5, "8080", null]) {
			expect(parseSettings({ local: { port } }).localPort).toBe(8788);
		}
		expect(parseSettings({ local: { port: 19600 } }).localPort).toBe(19600);
	});

	test("a non-boolean flag falls back rather than being coerced", () => {
		expect(parseSettings({ allowBash: "yes" }).allowBash).toBe(false);
		expect(parseSettings({ allowBash: 1 }).allowBash).toBe(false);
		expect(parseSettings({ allowBash: true }).allowBash).toBe(true);
	});

	test("a payload that is not an object at all yields the defaults", () => {
		for (const raw of [null, undefined, 42, "text", []]) {
			expect(parseSettings(raw)).toEqual(DEFAULT_SETTINGS);
		}
	});
});

describe("isRelayUrl", () => {
	test("accepts ws and wss only", () => {
		expect(isRelayUrl("ws://host:8788/agent")).toBe(true);
		expect(isRelayUrl("wss://host/agent")).toBe(true);
		expect(isRelayUrl("http://host")).toBe(false);
		expect(isRelayUrl("host:8788")).toBe(false);
	});
});

describe("loadSettings", () => {
	test("a missing file is a first run, not an error", () => {
		expect(loadSettings(scratch())).toEqual(DEFAULT_SETTINGS);
	});

	test("a truncated file leaves direct serving working", () => {
		const file = scratch();
		writeFileSync(file, '{"relay": {"url": "wss://relay.exam');
		const settings = loadSettings(file);
		expect(settings.relay).toBeUndefined();
		expect(settings.localEnabled).toBe(true);
	});
});

describe("saveSettings", () => {
	test("round-trips through the file", () => {
		const file = scratch();
		const written = {
			...DEFAULT_SETTINGS,
			relay: { url: "wss://relay.example/agent", token: "agent", controlToken: "ctl" },
			localPort: 19600,
			allowBash: true,
		};
		saveSettings(written, file);
		expect(loadSettings(file)).toEqual(written);
	});

	test("the file holds credentials, so it is not world-readable", () => {
		const file = scratch();
		saveSettings(DEFAULT_SETTINGS, file);
		expect(statSync(file).mode & 0o077).toBe(0);
	});

	test("a save leaves no temp file behind", () => {
		const file = scratch();
		saveSettings({ ...DEFAULT_SETTINGS, allowBash: true }, file);
		saveSettings({ ...DEFAULT_SETTINGS, allowBash: false }, file);
		expect(readdirSync(dirname(file))).toEqual(["omp-remote.json"]);
		expect(loadSettings(file).allowBash).toBe(false);
	});
});

describe("settingsPath", () => {
	test("an explicit path wins over the agent directory", () => {
		expect(settingsPath({ OMP_REMOTE_CONFIG: "/tmp/x.json", PI_CODING_AGENT_DIR: "/agent" })).toBe(
			"/tmp/x.json",
		);
	});

	test("otherwise it sits next to the agent's own config", () => {
		expect(settingsPath({ PI_CODING_AGENT_DIR: "/agent" })).toBe("/agent/omp-remote.json");
	});
});

describe("configFromSettings", () => {
	test("direct only is the shape with no relay configured", () => {
		const config = configFromSettings(DEFAULT_SETTINGS);
		expect(config.relay).toBeUndefined();
		expect(config.local).toEqual({ port: 8788, bind: "0.0.0.0" });
	});

	test("turning direct off leaves no local server to start", () => {
		const config = configFromSettings({ ...DEFAULT_SETTINGS, localEnabled: false });
		expect(config.local).toBeUndefined();
	});

	test("the agent id stays unique per process so one port can host several", () => {
		const config = configFromSettings(DEFAULT_SETTINGS);
		expect(config.agentId).toContain("/");
		expect(config.agentId).toContain("#");
	});
});
