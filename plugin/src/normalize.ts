// Pure mapping and truncation helpers. Kept dependency-free so the throwaway
// verification script can import and exercise them directly.

import type { AgentMessage } from "@oh-my-pi/pi-agent-core";
import type { Model, TextContent, ThinkingContent } from "@oh-my-pi/pi-ai";
import type { EvToolEnd, ModelRef, RemoteEvent } from "./protocol-types.js";

export const TOOL_INPUT_MAX_BYTES = 4096;
export const TEXT_MAX_BYTES = 16384;

// Truncates by UTF-16 code unit count (matches JSON string semantics closely
// enough for a KiB-scale budget) and appends "..." when the value is cut,
// per protocol.md's "ending with ... and the untruncated length is not
// reported" rule.
export function truncateText(value: string, maxLength: number): string {
	if (value.length <= maxLength) return value;
	if (maxLength <= 3) return "...".slice(0, maxLength);
	return `${value.slice(0, maxLength - 3)}...`;
}

export function safeStringifyInput(input: unknown): string {
	if (typeof input === "string") return input;
	try {
		return JSON.stringify(input) ?? "";
	} catch {
		return String(input);
	}
}

export function modelToRef(model: Model | undefined): ModelRef | undefined {
	if (!model) return undefined;
	return { provider: model.provider, id: model.id };
}

// The thinking levels a model accepts, in the order a picker should show
// them. The catalog lists provider efforts; `inherit` and `off` are
// agent-local selectors that exist for every model, so they are prepended
// rather than expected in the catalog's list.
//
// Undefined when the model has no controllable effort surface, which a
// client should render as a disabled control rather than a full list. One
// function because the model list and the state snapshot both report this
// and must not drift.
export function thinkingLevelsFor(model: Model | undefined): string[] | undefined {
	const efforts = model?.thinking?.efforts;
	if (!efforts || efforts.length === 0) return undefined;
	return ["inherit", "off", ...efforts];
}

// Extracts the visible text and thinking strings from a settled AgentMessage
// for the `message` event kind. Non-text/thinking content (tool calls, images)
// is ignored; the wire event only carries prose.
export function extractMessageParts(message: AgentMessage): { role: string; text: string; thinking?: string } {
	const role = (message as { role?: unknown }).role;
	const roleStr = typeof role === "string" ? role : "unknown";

	const content = (message as { content?: unknown }).content;
	if (typeof content === "string") {
		return { role: roleStr, text: content };
	}
	if (!Array.isArray(content)) {
		return { role: roleStr, text: "" };
	}

	const textParts: string[] = [];
	const thinkingParts: string[] = [];
	for (const block of content as Array<TextContent | ThinkingContent | Record<string, unknown>>) {
		if (!block || typeof block !== "object") continue;
		const type = (block as { type?: unknown }).type;
		if (type === "text") {
			const text = (block as TextContent).text;
			if (typeof text === "string") textParts.push(text);
		} else if (type === "thinking") {
			const thinking = (block as ThinkingContent).thinking;
			if (typeof thinking === "string") thinkingParts.push(thinking);
		}
	}

	const result: { role: string; text: string; thinking?: string } = {
		role: roleStr,
		text: textParts.join(""),
	};
	if (thinkingParts.length > 0) result.thinking = thinkingParts.join("");
	return result;
}

// Extracts a single text summary from an AgentToolResult-shaped value
// (`{ content: [{type:"text", text}] }`) for tool_end / tool_update events.
export function extractToolResultText(result: unknown): string {
	if (!result || typeof result !== "object") return "";
	const content = (result as { content?: unknown }).content;
	if (!Array.isArray(content)) return "";
	const parts: string[] = [];
	for (const block of content) {
		if (block && typeof block === "object" && (block as { type?: unknown }).type === "text") {
			const text = (block as { text?: unknown }).text;
			if (typeof text === "string") parts.push(text);
		}
	}
	return parts.join("");
}

export function buildMessageEvent(message: AgentMessage): RemoteEvent {
	const parts = extractMessageParts(message);
	return {
		k: "message",
		role: parts.role,
		text: truncateText(parts.text, TEXT_MAX_BYTES),
		...(parts.thinking !== undefined ? { thinking: truncateText(parts.thinking, TEXT_MAX_BYTES) } : {}),
	};
}

const DIFF_MAX_BYTES = 65536;

// The edit tool already produces a unified diff and reports the path it
// touched; `write` reports neither, so its added content is rendered as an
// all-additions diff instead of leaving the app with only a byte count.
export function buildToolEndEvent(
	id: string,
	name: string,
	result: unknown,
	isError: boolean,
	written?: { path: string; content: string },
): EvToolEnd {
	const event: EvToolEnd = {
		k: "tool_end",
		id,
		name,
		ok: !isError,
		text: truncateText(extractToolResultText(result), TEXT_MAX_BYTES),
	};

	const details = field(result, "details");
	const path = stringField(details, "path") || stringField(details, "resolvedPath");
	if (path.length > 0) event.path = path;
	const sourcePath = stringField(details, "sourcePath");
	if (sourcePath.length > 0) event.sourcePath = sourcePath;

	const diff = stringField(details, "diff");
	if (diff.length > 0) {
		event.diff = truncateText(diff, DIFF_MAX_BYTES);
		return event;
	}

	// A write reports no diff, so its content is rendered as all additions.
	// The content lives in the call's arguments, not the result.
	const newText = stringField(details, "newText") || written?.content;
	if (newText !== undefined && newText.length > 0) {
		event.diff = truncateText(asAdditions(newText), DIFF_MAX_BYTES);
		if (event.path === undefined && written !== undefined) event.path = written.path;
	}
	return event;
}

// The todo tool's result carries the whole list, so a `todos` event can be
// derived from it. `todo_reminder` alone is not enough: it fires only when
// the harness nags, not when the list actually changes.
export function buildTodosEventFromResult(result: unknown): RemoteEvent | undefined {
	const phases = field(field(result, "details"), "phases");
	if (!Array.isArray(phases)) return undefined;
	const todos: Array<{ phase: string; content: string; status: string }> = [];
	for (const phase of phases) {
		const name = stringField(phase, "name");
		const tasks = field(phase, "tasks");
		if (!Array.isArray(tasks)) continue;
		for (const task of tasks) {
			const content = stringField(task, "content");
			if (content.length === 0) continue;
			todos.push({
				phase: name,
				content: truncateText(content, 512),
				status: stringField(task, "status") || "pending",
			});
		}
	}
	return { k: "todos", todos };
}

function asAdditions(text: string): string {
	const lines = text.split("\n");
	return [`@@ -0,0 +1,${lines.length} @@`, ...lines.map((line) => `+${line}`)].join("\n");
}

// `notice`, `model_changed`, and `thinking_changed` wire events have no
// dedicated `ExtensionAPI.on(...)` source: `notice` is only emitted
// internally by the plugin's own diagnostics (see session-bridge.ts's
// `raiseNotice`), and model/thinking changes are derived by diffing
// `ctx.model` / `pi.getThinkingLevel()` against the last-sent value at turn
// boundaries and after `set_model`/`set_thinking` commands settle. This is a
// real API gap, documented in README.md.

export function buildAutoCompactionEvent(phase: "start" | "end"): RemoteEvent {
	return { k: "compaction", phase };
}

export function buildAutoRetryStartEvent(errorMessage: string): RemoteEvent {
	return { k: "retry", phase: "start", text: truncateText(errorMessage, TEXT_MAX_BYTES) };
}

export function buildAutoRetryEndEvent(success: boolean, finalError: string | undefined): RemoteEvent {
	return { k: "retry", phase: "end", text: truncateText(success ? "recovered" : (finalError ?? "failed"), TEXT_MAX_BYTES) };
}

// Field readers for persisted session entries. Session JSONL is outside data:
// narrow every read instead of asserting a shape onto it.
function field(value: unknown, key: string): unknown {
	if (!value || typeof value !== "object") return undefined;
	if (!(key in value)) return undefined;
	return (value as Record<string, unknown>)[key];
}

function stringField(value: unknown, key: string): string {
	const raw = field(value, key);
	return typeof raw === "string" ? raw : "";
}

// Rebuilds a transcript from persisted session entries. A resumed session
// replays no `pi.on` events, so without this a client that attaches to one
// sees an empty conversation. Tool calls live inside assistant messages and
// their results arrive as separate `toolResult` messages, so both are folded
// back into the tool_start/tool_end pair a live turn would have produced.
//
// Every entry type that carries context is emitted. Dropping the ones that
// are not plain messages left a replayed session missing its compactions,
// branch summaries, and model changes, so the history read as if those
// boundaries had never happened.
export function buildHistoryEvents(entries: readonly unknown[]): RemoteEvent[] {
	const events: RemoteEvent[] = [];
	for (const entry of entries) {
		const type = field(entry, "type");

		if (type === "compaction") {
			const summary = stringField(entry, "summary");
			events.push({ k: "compaction", phase: "end" });
			if (summary.length > 0) {
				events.push({ k: "message", role: "system", text: truncateText(summary, TEXT_MAX_BYTES) });
			}
			continue;
		}

		if (type === "branch_summary") {
			const summary = stringField(entry, "summary");
			events.push({
				k: "message",
				role: "system",
				text: truncateText(
					summary.length > 0 ? `Branched from here. ${summary}` : "Branched from here.",
					TEXT_MAX_BYTES,
				),
			});
			continue;
		}

		if (type === "model_change") {
			const model = stringField(entry, "model") || stringField(entry, "modelId");
			if (model.length > 0) {
				events.push({ k: "message", role: "system", text: `Model changed to ${model}` });
			}
			continue;
		}

		if (type === "thinking_level_change") {
			const level = stringField(entry, "thinkingLevel") || stringField(entry, "level");
			if (level.length > 0) {
				events.push({ k: "message", role: "system", text: `Thinking level set to ${level}` });
			}
			continue;
		}

		if (type === "custom_message") {
			const content = field(entry, "content");
			const text = typeof content === "string" ? content : extractContentText(content);
			if (text.length > 0) {
				events.push({ k: "message", role: "system", text: truncateText(text, TEXT_MAX_BYTES) });
			}
			continue;
		}

		if (type !== "message") continue;
		const message = field(entry, "message");
		if (!message || typeof message !== "object") continue;

		if (field(message, "role") === "toolResult") {
			events.push(
				buildToolEndEvent(
					stringField(message, "toolCallId"),
					stringField(message, "toolName"),
					message,
					field(message, "isError") === true,
				),
			);
			continue;
		}

		// The shape checks above are what `extractMessageParts` itself narrows
		// against, so handing it the same value is safe.
		const asMessage = message as AgentMessage;
		const parts = extractMessageParts(asMessage);
		if (parts.text.length > 0 || parts.thinking !== undefined) {
			events.push(buildMessageEvent(asMessage));
		}
		for (const call of extractToolCalls(message)) events.push(call);
	}
	return events;
}

// Text out of a content-block array, ignoring images and other block kinds.
function extractContentText(content: unknown): string {
	if (!Array.isArray(content)) return "";
	const parts: string[] = [];
	for (const block of content) {
		if (field(block, "type") === "text") {
			const text = field(block, "text");
			if (typeof text === "string") parts.push(text);
		}
	}
	return parts.join("");
}

function extractToolCalls(message: unknown): RemoteEvent[] {
	const content = field(message, "content");
	if (!Array.isArray(content)) return [];
	const calls: RemoteEvent[] = [];
	for (const block of content) {
		if (field(block, "type") !== "toolCall") continue;
		calls.push({
			k: "tool_start",
			id: stringField(block, "id"),
			name: stringField(block, "name"),
			input: truncateText(safeStringifyInput(field(block, "arguments")), TOOL_INPUT_MAX_BYTES),
		});
	}
	return calls;
}

const SUBAGENT_TEXT_MAX_BYTES = 2048;

// A lifecycle frame names a spawn and its outcome. `detached` spawns are the
// ones a parent keeps working alongside, but a blocking spawn is just as
// worth watching from a phone, so both are forwarded.
export function buildSubagentLifecycleEvent(data: unknown): RemoteEvent | undefined {
	const id = stringField(data, "id");
	if (id.length === 0) return undefined;
	const status = stringField(data, "status");
	const agentType = stringField(data, "agent");
	const description = stringField(data, "description");
	return {
		k: "subagent",
		id,
		name: id,
		phase: status.length > 0 ? status : "started",
		text: truncateText(description, SUBAGENT_TEXT_MAX_BYTES),
		...(agentType.length > 0 ? { agentType } : {}),
	};
}

// Progress frames are already coalesced upstream, so each one is forwarded as
// it arrives. The text is the agent's own last stated intent when it has one,
// falling back to its assignment, so a reader sees what it is doing rather
// than just that it is alive.
export function buildSubagentProgressEvent(data: unknown): RemoteEvent | undefined {
	const progress = field(data, "progress");
	if (!progress || typeof progress !== "object") return undefined;
	const id = stringField(progress, "id");
	if (id.length === 0) return undefined;

	const intent = stringField(progress, "lastIntent");
	const description = stringField(progress, "description");
	const assignment = stringField(progress, "assignment");
	const task = stringField(progress, "task");
	const text = intent || description || assignment || task;

	const tool = stringField(progress, "currentTool");
	const toolCount = numberField(progress, "toolCount");
	const tokens = numberField(progress, "tokens");
	const durationMs = numberField(progress, "durationMs");
	const agentType = stringField(progress, "agent");

	return {
		k: "subagent",
		id,
		name: id,
		phase: stringField(progress, "status") || "running",
		text: truncateText(text, SUBAGENT_TEXT_MAX_BYTES),
		...(agentType.length > 0 ? { agentType } : {}),
		...(tool.length > 0 ? { tool } : {}),
		...(toolCount !== undefined ? { toolCount } : {}),
		...(tokens !== undefined ? { tokens } : {}),
		...(durationMs !== undefined ? { durationMs } : {}),
	};
}

function numberField(value: unknown, key: string): number | undefined {
	const raw = field(value, key);
	return typeof raw === "number" && Number.isFinite(raw) ? raw : undefined;
}
