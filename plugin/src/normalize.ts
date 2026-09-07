// Pure mapping and truncation helpers. Kept dependency-free so the throwaway
// verification script can import and exercise them directly.

import type { AgentMessage } from "@oh-my-pi/pi-agent-core";
import type { Model, TextContent, ThinkingContent } from "@oh-my-pi/pi-ai";
import type { ModelRef, RemoteEvent } from "./protocol-types.js";

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

export function buildToolEndEvent(id: string, name: string, result: unknown, isError: boolean): RemoteEvent {
	return {
		k: "tool_end",
		id,
		name,
		ok: !isError,
		text: truncateText(extractToolResultText(result), TEXT_MAX_BYTES),
	};
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
