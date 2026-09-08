// Command dispatch table (docs/protocol.md, "Commands"). Maps each wire
// command onto the real ExtensionAPI / ExtensionContext surface. Every
// command's args are validated at the boundary before use; nothing here
// throws out of executeCommand, and an invalid/unknown/unreachable command
// always resolves to { ok: false, error }.

import { SessionManager } from "@oh-my-pi/pi-coding-agent";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import type { Model } from "@oh-my-pi/pi-ai";
import { ThinkingLevel } from "@oh-my-pi/pi-agent-core";
import { DELIVER_AS_VALUES, THINKING_LEVELS } from "./protocol-types.js";
import { BTW_TASK, OMFG_TASK, runSideTask, type SideTask } from "./btw.js";
import { listModelRoles, setModelRole } from "./model-roles.js";
import type { RemoteConfig } from "./config.js";
import type { SessionBridge } from "./session-bridge.js";

// Wire level string -> real ThinkingLevel enum value. THINKING_LEVELS names
// every key; TypeScript's string enums are nominal, so a validated wire
// string still needs this lookup rather than a cast to reach the real type.
const THINKING_LEVEL_BY_WIRE: Record<(typeof THINKING_LEVELS)[number], ThinkingLevel> = {
	inherit: ThinkingLevel.Inherit,
	off: ThinkingLevel.Off,
	minimal: ThinkingLevel.Minimal,
	low: ThinkingLevel.Low,
	medium: ThinkingLevel.Medium,
	high: ThinkingLevel.High,
	xhigh: ThinkingLevel.XHigh,
	max: ThinkingLevel.Max,
};

export type CommandResult = { ok: true; data: unknown } | { ok: false; error: string };

function ok(data: unknown): CommandResult {
	return { ok: true, data };
}

function fail(error: string): CommandResult {
	return { ok: false, error };
}

// -----------------------------------------------------------------------
// Args validation helpers. `args` arrives as `unknown` off the wire; each
// helper narrows and reports precisely what is wrong.
// -----------------------------------------------------------------------

function asRecord(args: unknown): Record<string, unknown> | undefined {
	if (!args || typeof args !== "object" || Array.isArray(args)) return undefined;
	return args as Record<string, unknown>;
}

function requireString(record: Record<string, unknown>, field: string): string | { error: string } {
	const value = record[field];
	if (typeof value !== "string" || value.length === 0) {
		return { error: `"${field}" must be a non-empty string` };
	}
	return value;
}

function optionalString(record: Record<string, unknown>, field: string): string | undefined | { error: string } {
	const value = record[field];
	if (value === undefined) return undefined;
	if (typeof value !== "string") return { error: `"${field}" must be a string` };
	return value;
}

function requireBoolean(record: Record<string, unknown>, field: string): boolean | { error: string } {
	const value = record[field];
	if (typeof value !== "boolean") return { error: `"${field}" must be a boolean` };
	return value;
}

function optionalNumber(record: Record<string, unknown>, field: string): number | undefined | { error: string } {
	const value = record[field];
	if (value === undefined) return undefined;
	if (typeof value !== "number" || !Number.isFinite(value)) return { error: `"${field}" must be a number` };
	return value;
}

// Type guard preserving the narrowing between a validated value and the
// `{ error }` shape the require*/optional* helpers return on failure.
function isErrorResult<T>(value: T | { error: string }): value is { error: string } {
	return typeof value === "object" && value !== null && "error" in value;
}

// -----------------------------------------------------------------------
// Entry point.
// -----------------------------------------------------------------------

export async function executeCommand(
	bridge: SessionBridge,
	pi: ExtensionAPI,
	config: RemoteConfig,
	cmd: string,
	args: unknown,
): Promise<CommandResult> {
	try {
		return await dispatch(bridge, pi, config, cmd, args);
	} catch (err) {
		return fail(err instanceof Error ? err.message : String(err));
	}
}

async function dispatch(
	bridge: SessionBridge,
	pi: ExtensionAPI,
	config: RemoteConfig,
	cmd: string,
	args: unknown,
): Promise<CommandResult> {
	switch (cmd) {
		case "prompt":
			return cmdPrompt(bridge, pi, args);
		case "steer":
			return cmdSteer(bridge, pi, args);
		case "follow_up":
			return cmdFollowUp(bridge, pi, args);
		case "abort":
			return cmdAbort(bridge);

		case "state":
			return cmdState(bridge);
		case "history":
			return cmdHistory(bridge, args);
		case "tools":
			return cmdTools(pi);
		case "commands":
			return cmdCommands();
		case "btw":
			return cmdSideTask(bridge, BTW_TASK, args);
		case "omfg":
			return cmdSideTask(bridge, OMFG_TASK, args);
		case "models":
			return cmdModels(bridge);
		case "system_prompt":
			return cmdSystemPrompt(bridge);
		case "jobs":
			return cmdJobs(bridge);

		case "set_model":
			return cmdSetModel(bridge, pi, args);
		case "set_model_role":
			return cmdSetModelRole(bridge, args);
		case "set_thinking":
			return cmdSetThinking(bridge, pi, args);
		case "set_active_tools":
			return cmdSetActiveTools(pi, args);
		case "set_todos":
			return cmdSetTodos(bridge, args);
		case "set_auto_compaction":
			return cmdSetAutoCompaction(bridge, args);

		case "new_session":
			return cmdNewSession(bridge);
		case "end_session":
			return cmdEndSession(bridge);
		case "switch_session":
			return cmdSwitchSession(bridge, args);
		case "list_sessions":
			return cmdListSessions(bridge, args);
		case "compact":
			return cmdCompact(bridge, args);
		case "set_session_name":
			return cmdSetSessionName(pi, args);

		case "bash":
			return cmdBash(bridge, config, args);
		case "abort_bash":
			return cmdAbortBash(bridge, args);

		// omp owns the pending queue now, and its editable surface belongs to
		// the workstation's own composer: `ExtensionContext` exposes only
		// `hasPendingMessages()`, with no way to list, edit, or drop an entry.
		case "queue_edit":
		case "queue_remove":
		case "queue_clear":
			return fail(
				"the pending queue belongs to omp; ExtensionContext exposes only hasPendingMessages(), so a queued message cannot be listed, edited, or removed from here",
			);

		// Verified gaps: AgentSession-only surface not reachable from an
		// extension (see docs/protocol.md's Known API gaps), or no invocation
		// path at all for run_command. Each fails explicitly and precisely.
		case "set_fast_mode":
			return fail("set_fast_mode requires AgentSession.setFastMode, which ExtensionContext does not expose");
		case "set_steering_mode":
			return fail("set_steering_mode requires AgentSession.setSteeringMode, which ExtensionContext does not expose");
		case "set_follow_up_mode":
			return fail(
				"set_follow_up_mode requires AgentSession.setFollowUpMode, which ExtensionContext does not expose",
			);
		case "set_interrupt_mode":
			return fail(
				"set_interrupt_mode requires AgentSession.setInterruptMode, which ExtensionContext does not expose",
			);
		case "cycle_model":
			return fail("cycle_model requires AgentSession.cycleModel, which ExtensionContext does not expose");
		case "stats":
			return fail("stats requires AgentSession.getSessionStats, which ExtensionContext does not expose");
		case "branch":
			return fail(
				"branch by entryId requires AgentSession-level branch-by-entry tracking not reachable from an extension's command context",
			);
		case "run_command":
			return fail(
				"run_command has no invocation path: ExtensionAPI exposes no way to execute a slash command, and the prompt path sends the text to the model verbatim instead of expanding it",
			);

		default:
			return fail(`unknown command: ${cmd}`);
	}
}

function requireCtx(bridge: SessionBridge): ExtensionContext | { error: string } {
	const ctx = bridge.getLatestCtx();
	if (!ctx) return { error: "no active session context" };
	return ctx;
}

// -----------------------------------------------------------------------
// Prompting and turn control.
// -----------------------------------------------------------------------

function cmdPrompt(bridge: SessionBridge, pi: ExtensionAPI, args: unknown): CommandResult {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "text" field');
	const text = requireString(record, "text");
	if (isErrorResult(text)) return fail(text.error);

	let deliverAs: "steer" | "followUp" | "aside" | undefined;
	const deliverAsRaw = record.deliverAs;
	if (deliverAsRaw !== undefined) {
		if (
			typeof deliverAsRaw !== "string" ||
			!DELIVER_AS_VALUES.includes(deliverAsRaw as (typeof DELIVER_AS_VALUES)[number])
		) {
			return fail(`"deliverAs" must be one of ${DELIVER_AS_VALUES.join(", ")}`);
		}
		deliverAs = deliverAsRaw as "steer" | "followUp" | "aside";
	}

	const imagesRaw = record.images;
	if (imagesRaw !== undefined) {
		if (!Array.isArray(imagesRaw) || !imagesRaw.every((entry) => typeof entry === "string")) {
			return fail('"images" must be an array of data URL strings');
		}
		if (imagesRaw.length > 4) return fail('"images" must contain at most 4 entries');
	}

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	const ctx = ctxResult;

	// A plain prompt sent mid-turn is queued as `steer`: it drains one message
	// per agent step boundary, so it still arrives mid-turn rather than after
	// it, and it sits in the queue the workstation renders and can edit until
	// then. `aside` arrives at the same boundary but never enters that queue,
	// which left a queued message invisible on both screens.
	const effective = deliverAs ?? (ctx.isIdle() ? undefined : ("steer" as const));
	pi.sendUserMessage(text, effective !== undefined ? { deliverAs: effective } : undefined);
	return ok({ accepted: true });
}

/// Runs one of the two side tasks in its own session.
///
/// The main session keeps going: neither the question nor the complaint
/// enters its transcript or takes a turn from it. The outcome arrives on the
/// subagent channel, which is what a client shows.
function cmdSideTask(
	bridge: SessionBridge,
	task: SideTask,
	args: unknown,
): CommandResult {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "text" field');
	const text = requireString(record, "text");
	if (isErrorResult(text)) return fail(text.error);
	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	// Not awaited: the outcome arrives as events, and a client should not
	// hold a command open for however long a model call takes.
	void runSideTask(bridge, ctxResult, task, text);
	return ok({ accepted: true, run: task.name });
}

function cmdSteer(bridge: SessionBridge, pi: ExtensionAPI, args: unknown): CommandResult {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "text" field');
	const text = requireString(record, "text");
	if (isErrorResult(text)) return fail(text.error);

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);

	pi.sendUserMessage(text, { deliverAs: "steer" });
	return ok({ accepted: true });
}

function cmdFollowUp(bridge: SessionBridge, pi: ExtensionAPI, args: unknown): CommandResult {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "text" field');
	const text = requireString(record, "text");
	if (isErrorResult(text)) return fail(text.error);

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);

	pi.sendUserMessage(text, { deliverAs: "followUp" });
	return ok({ accepted: true });
}

function cmdAbort(bridge: SessionBridge): CommandResult {
	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	ctxResult.abort();
	return ok({ aborted: true });
}

// -----------------------------------------------------------------------
// Reading the session.
// -----------------------------------------------------------------------

function cmdState(bridge: SessionBridge): CommandResult {
	return ok(bridge.getCurrentState());
}

const HISTORY_DEFAULT_LIMIT = 50;
const HISTORY_HARD_CAP = 200;

interface HistoryMessage {
	id: string;
	role: string;
	text: string;
}

function extractPlainText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	const parts: string[] = [];
	for (const block of content) {
		if (!block || typeof block !== "object") continue;
		const b = block as { type?: unknown; text?: unknown };
		if (b.type === "text" && typeof b.text === "string") parts.push(b.text);
	}
	return parts.join("");
}

function cmdHistory(bridge: SessionBridge, args: unknown): CommandResult {
	const record = asRecord(args) ?? {};

	const limitRaw = optionalNumber(record, "limit");
	if (isErrorResult(limitRaw)) return fail(limitRaw.error);
	if (limitRaw !== undefined && (limitRaw < 1 || !Number.isInteger(limitRaw))) {
		return fail('"limit" must be a positive integer');
	}
	const limit = Math.min(limitRaw ?? HISTORY_DEFAULT_LIMIT, HISTORY_HARD_CAP);

	const before = optionalString(record, "before");
	if (isErrorResult(before)) return fail(before.error);

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	const ctx = ctxResult;

	// getBranch() walks root-to-leaf (oldest first). Only "message" entries
	// normalize into wire-shape {role, text}; every other entry type (model
	// changes, custom entries, labels, ...) carries no display text and is
	// skipped rather than guessed at.
	const branch = ctx.sessionManager.getBranch();
	const messages: HistoryMessage[] = [];
	for (const entry of branch) {
		if (entry.type !== "message") continue;
		const message = entry.message as { role?: unknown; content?: unknown };
		const role = typeof message.role === "string" ? message.role : "unknown";
		messages.push({ id: entry.id, role, text: extractPlainText(message.content) });
	}

	// `before` pages backwards by message id: keep only messages strictly
	// before the named id, then take the last `limit` of those.
	let windowed = messages;
	if (before !== undefined) {
		const cutIndex = messages.findIndex((m) => m.id === before);
		if (cutIndex === -1) return fail(`"before" does not name a known message id: ${before}`);
		windowed = messages.slice(0, cutIndex);
	}

	const hasMore = windowed.length > limit;
	const page = hasMore ? windowed.slice(windowed.length - limit) : windowed;
	return ok({ messages: page.map(({ role, text }) => ({ role, text })), hasMore });
}

function cmdTools(pi: ExtensionAPI): CommandResult {
	return ok({ active: pi.getActiveTools(), all: pi.getAllTools().map((t) => t.name) });
}

// Backs the app's equivalent of /jobs, /hub, and /agents: the same snapshot
// those dashboards read.
function cmdJobs(bridge: SessionBridge): CommandResult {
	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	const snapshot = ctxResult.getAsyncJobSnapshot();
	if (!snapshot) return ok({ running: [], recent: [] });
	const summarize = (item: { id: string; type: string; status: string; label?: string; startTime?: number; agentId?: string }) => ({
		id: item.id,
		type: item.type,
		status: item.status,
		...(item.label !== undefined ? { label: item.label } : {}),
		...(item.startTime !== undefined ? { startTime: item.startTime } : {}),
		...(item.agentId !== undefined ? { agentId: item.agentId } : {}),
	});
	return ok({
		running: snapshot.running.map(summarize),
		recent: snapshot.recent.map(summarize),
	});
}

/// The only slash commands the app offers, and the wire command each one
/// runs here.
///
/// The rest are workstation-only: the APIs they need (`AgentSession`,
/// `Settings`, `ExtensionCommandContext`) are not reachable from an
/// extension, and listing 84 commands a phone cannot run made the list a
/// catalogue of disappointments. Model selection is its own setting rather
/// than a command, since picking a model is a preference, not an action.
const APP_COMMANDS: Array<{ name: string; description: string; remote: string }> = [
	{
		name: "todo",
		description: "Read and edit the agent's todo list",
		remote: "set_todos",
	},
	{
		name: "compact",
		description: "Compact the conversation, optionally around a focus",
		remote: "compact",
	},
	{
		name: "btw",
		description: "Ask a side question against the current context",
		remote: "btw",
	},
	{
		name: "omfg",
		description: "Turn a complaint into a standing rule",
		remote: "omfg",
	},
];

function cmdCommands(): CommandResult {
	return ok({ commands: APP_COMMANDS.map((entry) => ({ ...entry, source: "builtin" })) });
}

/// The thinking levels a model accepts, in the order a picker should show
/// them. The catalog lists provider efforts; `inherit` and `off` are
/// agent-local selectors that exist for every model, so they are prepended
/// rather than expected in the catalog's list.
///
/// Undefined when the model has no controllable effort surface: a client
/// should disable the control rather than offer a list nothing accepts.
function thinkingLevelsFor(model: Model): string[] | undefined {
	const efforts = model.thinking?.efforts;
	if (!efforts || efforts.length === 0) return undefined;
	return ["inherit", "off", ...efforts];
}

// Every authenticated model, with enough of each row for a phone to choose
// one without guessing from an id: the display name, whether it reasons, and
// its context window. The role assignments ride along, so the settings
// screen renders both halves of "which model" from one round trip.
function cmdModels(bridge: SessionBridge): CommandResult {
	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	const ctx = ctxResult;
	const models = ctx.models.list().map((m) => ({
		provider: m.provider,
		id: m.id,
		name: m.name,
		reasoning: m.reasoning,
		contextWindow: m.contextWindow ?? undefined,
		image: m.input.includes("image"),
		// What this model actually accepts. `high` exists on some models and
		// not others, so a fixed list offered levels that would be rejected
		// or silently clamped. Absent means no effort control at all.
		thinking: thinkingLevelsFor(m),
	}));
	const current = ctx.models.current();
	return ok({
		models,
		current: current ? { provider: current.provider, id: current.id } : undefined,
		roles: listModelRoles(ctx),
	});
}

// A role assignment is settings, not session state: it lands in config.yml
// through the live singleton the running session reads, so the next turn
// resolves `@<role>` to the new model and the workstation's own UI sees the
// same change.
function cmdSetModelRole(bridge: SessionBridge, args: unknown): CommandResult {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "role" field');
	const role = requireString(record, "role");
	if (isErrorResult(role)) return fail(role.error);

	const rawModel = record.model;
	if (rawModel !== undefined && rawModel !== null && typeof rawModel !== "string") {
		return fail('"model" must be a string or omitted to clear the role');
	}
	const model = typeof rawModel === "string" && rawModel.length > 0 ? rawModel : undefined;

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	const ctx = ctxResult;

	const outcome = setModelRole(ctx, role, model);
	if ("error" in outcome) return fail(outcome.error);

	// A role assignment can change what the current turn's `default` resolves
	// to, so the state snapshot is refreshed for every attached client, not
	// only the one that made the change.
	bridge.emitState();
	return ok({ ...outcome, roles: listModelRoles(ctx) });
}

function cmdSystemPrompt(bridge: SessionBridge): CommandResult {
	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	return ok({ sections: ctxResult.getSystemPrompt() });
}

// -----------------------------------------------------------------------
// Changing session settings.
// -----------------------------------------------------------------------

async function cmdSetModel(bridge: SessionBridge, pi: ExtensionAPI, args: unknown): Promise<CommandResult> {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with "provider" and "id" fields');
	const provider = requireString(record, "provider");
	if (isErrorResult(provider)) return fail(provider.error);
	const id = requireString(record, "id");
	if (isErrorResult(id)) return fail(id.error);

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	const ctx = ctxResult;

	const resolved = ctx.models.resolve(`${provider}/${id}`);
	if (!resolved) return fail(`could not resolve model ${provider}/${id}`);

	const success = await pi.setModel(resolved);
	if (!success) return fail(`no API key available for ${provider}/${id}`);

	// The change takes hold on the next turn, so the clients watching this
	// session are told now rather than at the next turn boundary, which could
	// be minutes away. Without this a phone keeps showing the old model and
	// the user cannot tell whether the tap did anything.
	const model = { provider: resolved.provider, id: resolved.id };
	bridge.broadcastEvent({ k: "model_changed", model });
	bridge.emitState();
	return ok({ model });
}

function cmdSetThinking(bridge: SessionBridge, pi: ExtensionAPI, args: unknown): CommandResult {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "level" field');
	const level = requireString(record, "level");
	if (isErrorResult(level)) return fail(level.error);
	if (!THINKING_LEVELS.includes(level as (typeof THINKING_LEVELS)[number])) {
		return fail(`"level" must be one of ${THINKING_LEVELS.join(", ")}`);
	}

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);

	pi.setThinkingLevel(THINKING_LEVEL_BY_WIRE[level as (typeof THINKING_LEVELS)[number]]);
	bridge.broadcastEvent({ k: "thinking_changed", thinkingLevel: level });
	bridge.emitState();
	return ok({ thinkingLevel: level });
}

async function cmdSetActiveTools(pi: ExtensionAPI, args: unknown): Promise<CommandResult> {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "names" field');
	const namesRaw = record.names;
	if (!Array.isArray(namesRaw) || !namesRaw.every((n) => typeof n === "string")) {
		return fail('"names" must be an array of strings');
	}
	const names = namesRaw as string[];

	const known: Record<string, true> = {};
	for (const tool of pi.getAllTools()) known[tool.name] = true;
	const unknownNames = names.filter((n) => !known[n]);
	if (unknownNames.length > 0) return fail(`unknown tool names: ${unknownNames.join(", ")}`);

	await pi.setActiveTools(names);
	return ok({ active: pi.getActiveTools() });
}

function cmdSetTodos(bridge: SessionBridge, args: unknown): CommandResult {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "phases" field');
	const phasesRaw = record.phases;
	if (!Array.isArray(phasesRaw)) return fail('"phases" must be an array');
	for (const phase of phasesRaw) {
		if (!phase || typeof phase !== "object") return fail("each phase must be an object");
		const p = phase as Record<string, unknown>;
		if (typeof p.name !== "string") return fail('each phase must have a string "name"');
		if (!Array.isArray(p.tasks)) return fail('each phase must have a "tasks" array');
		for (const task of p.tasks) {
			if (!task || typeof task !== "object") return fail("each task must be an object");
			const t = task as Record<string, unknown>;
			if (typeof t.content !== "string") return fail('each task must have a string "content"');
			if (typeof t.status !== "string") return fail('each task must have a string "status"');
		}
	}

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);

	// No dedicated ExtensionContext setter for todos: AgentSession.setTodoPhases
	// is the only mutator and it is not part of the ExtensionContext surface.
	return fail("set_todos requires AgentSession.setTodoPhases, which ExtensionContext does not expose");
}

function cmdSetAutoCompaction(bridge: SessionBridge, args: unknown): CommandResult {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with an "enabled" field');
	const enabled = requireBoolean(record, "enabled");
	if (isErrorResult(enabled)) return fail(enabled.error);

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);

	// ExtensionContext exposes compact() (run one now) but no toggle for the
	// automatic-compaction setting itself; that lives on AgentSession.
	return fail(
		"set_auto_compaction requires AgentSession.setAutoCompactionEnabled, which ExtensionContext does not expose",
	);
}

// -----------------------------------------------------------------------
// Session lifecycle. ExtensionCommandContext (newSession/switchSession/
// branch/compact/reload/waitForIdle) is documented as reachable only from a
// slash-command handler, not the ExtensionContext an event handler or a
// command dispatched from a transport's own message loop receives.
// executeCommand runs off a `command` wire frame handled outside any
// registered slash-command handler, so none of that extended surface is
// available here; every lifecycle command that would need it fails
// explicitly instead of risking a runtime throw against a context that does
// not carry those methods. `compact` is the one exception: ExtensionContext
// itself exposes `compact()` directly (see ExtensionContextActions).
// -----------------------------------------------------------------------

// Both need `ExtensionCommandContext`, which only a slash-command handler
// receives; the bridge keeps the one `/remote` was last invoked with. A
// session paired by typing a code has never run it, so this can genuinely be
// missing, and the error says what to do rather than blaming the API.
async function cmdNewSession(bridge: SessionBridge): Promise<CommandResult> {
	const ctx = bridge.getCommandCtx();
	if (!ctx) {
		return fail(
			"starting a new session needs a command context, which only a slash command carries: run /remote once at the workstation, or use end_session to close this one",
		);
	}
	const outcome = await ctx.newSession();
	if (outcome.cancelled) return fail("the workstation cancelled the new session");
	return ok({ started: true });
}

async function cmdSwitchSession(bridge: SessionBridge, args: unknown): Promise<CommandResult> {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "sessionFile" field');
	const sessionFile = requireString(record, "sessionFile");
	if (isErrorResult(sessionFile)) return fail(sessionFile.error);

	const ctx = bridge.getCommandCtx();
	if (!ctx) {
		return fail("run /remote once in this session first: switching sessions needs a command context, and only a slash command carries one");
	}
	const outcome = await ctx.switchSession(sessionFile);
	if (outcome.cancelled) return fail("the workstation cancelled the switch");
	return ok({ switched: true, sessionFile });
}

// Ends this session by leaving it for a fresh one, which is the only route
// that works: `ctx.shutdown()` is documented as a request, and the host
// honours it in neither TUI nor RPC mode, so a command built on it returned
// success and did nothing.
//
// The transcript is untouched on disk either way, so ending is reversible by
// reopening it at the workstation.
async function cmdEndSession(bridge: SessionBridge): Promise<CommandResult> {
	const ctx = bridge.getCommandCtx();
	if (!ctx) {
		return fail(
			"ending a session needs a command context, which only a slash command carries: run /remote once at the workstation first",
		);
	}
	const outcome = await ctx.newSession();
	if (outcome.cancelled) return fail("the workstation cancelled ending the session");
	return ok({ ended: true });
}

interface SessionSummary {
	path: string;
	id: string;
	title?: string;
	modified: string;
}

async function cmdListSessions(bridge: SessionBridge, args: unknown): Promise<CommandResult> {
	const record = asRecord(args) ?? {};
	const limit = optionalNumber(record, "limit");
	if (isErrorResult(limit)) return fail(limit.error);
	if (limit !== undefined && (limit < 1 || !Number.isInteger(limit))) {
		return fail('"limit" must be a positive integer');
	}

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	const ctx = ctxResult;

	const sessions = await SessionManager.list(ctx.cwd);
	const sliced = limit !== undefined ? sessions.slice(0, limit) : sessions;
	const summaries: SessionSummary[] = sliced.map((s) => ({
		path: s.path,
		id: s.id,
		...(s.title !== undefined ? { title: s.title } : {}),
		modified: s.modified.toISOString(),
	}));
	return ok({ sessions: summaries });
}

async function cmdCompact(bridge: SessionBridge, args: unknown): Promise<CommandResult> {
	const record = asRecord(args) ?? {};
	const instructions = optionalString(record, "instructions");
	if (isErrorResult(instructions)) return fail(instructions.error);

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	const ctx = ctxResult;

	try {
		await ctx.compact(instructions);
		return ok({ compacted: true });
	} catch (err) {
		return fail(err instanceof Error ? err.message : String(err));
	}
}

async function cmdSetSessionName(pi: ExtensionAPI, args: unknown): Promise<CommandResult> {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "name" field');
	const name = requireString(record, "name");
	if (isErrorResult(name)) return fail(name.error);

	await pi.setSessionName(name);
	return ok({ sessionName: name });
}

// -----------------------------------------------------------------------
// Running things.
// -----------------------------------------------------------------------

const BASH_OUTPUT_COALESCE_MS = 100;

function cmdBash(bridge: SessionBridge, config: RemoteConfig, args: unknown): CommandResult {
	if (!config.allowBash) {
		return fail(
			"bash is disabled on this workstation. Run /remote config bash on there to allow it",
		);
	}
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with a "command" field');
	const command = requireString(record, "command");
	if (isErrorResult(command)) return fail(command.error);

	const ctxResult = requireCtx(bridge);
	if (isErrorResult(ctxResult)) return fail(ctxResult.error);
	const ctx = ctxResult;

	const id = `bash-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
	const controller = new AbortController();
	bridge.registerBashProcess(id, controller);

	// Argument array only: `command` travels as ONE opaque argument to
	// `sh -c`, never concatenated into a larger shell line.
	const proc = Bun.spawn(["/bin/sh", "-c", command], {
		cwd: ctx.cwd,
		stdout: "pipe",
		stderr: "pipe",
		signal: controller.signal,
	});

	let buffered = "";
	let flushTimer: Timer | undefined;
	const flush = () => {
		flushTimer = undefined;
		if (buffered.length === 0) return;
		const text = buffered;
		buffered = "";
		bridge.broadcastBashOutput(id, text);
	};
	const feed = (chunk: string) => {
		buffered += chunk;
		if (flushTimer === undefined) flushTimer = setTimeout(flush, BASH_OUTPUT_COALESCE_MS);
	};

	const decoder = new TextDecoder();
	const pump = async (stream: ReadableStream<Uint8Array>) => {
		for await (const chunk of stream) feed(decoder.decode(chunk, { stream: true }));
	};

	void Promise.allSettled([pump(proc.stdout), pump(proc.stderr)]).then(async () => {
		await proc.exited;
		if (flushTimer !== undefined) clearTimeout(flushTimer);
		flush();
		bridge.unregisterBashProcess(id);
	});

	return ok({ id });
}

function cmdAbortBash(bridge: SessionBridge, args: unknown): CommandResult {
	const record = asRecord(args);
	if (!record) return fail('"args" must be an object with an "id" field');
	const id = requireString(record, "id");
	if (isErrorResult(id)) return fail(id.error);

	const aborted = bridge.abortBashProcess(id);
	if (!aborted) return fail(`no running bash process with id ${id}`);
	return ok({ aborted: true });
}
