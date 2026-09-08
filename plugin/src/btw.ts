// A side question, answered in its own session.
//
// The workstation's `/btw` answers without touching the running turn: the
// question and its answer are a detour, not part of the conversation. An
// extension cannot invoke that command, and injecting the question into the
// main session would make it part of the transcript and take a turn from the
// agent. So this opens a second session instead, seeded with a digest of the
// current one, and streams its answer back to the client as its own thing.

import { createAgentSession, SessionManager } from "@oh-my-pi/pi-coding-agent";
import type { ExtensionContext } from "@oh-my-pi/pi-coding-agent";

import type { SessionBridge } from "./session-bridge.js";

/// How much of the parent conversation the side session is told about. Enough
/// for "what was that file again?" to work, small enough not to pay for the
/// whole transcript on every aside.
const CONTEXT_MAX_BYTES = 24 * 1024;

/// Read-only tools only. A side question is a question; it has no business
/// editing the project or running commands.
const SIDE_TOOLS = ["read", "grep", "glob"];

/// How long a side question may take before it reports a timeout. A row that
/// says "running" forever is worse than one that says it gave up.
const ANSWER_TIMEOUT_MS = 120_000;

const SYSTEM_PROMPT = [
	"You are answering a side question about a coding session that is already",
	"in progress. The conversation so far is quoted below as context. Answer",
	"the question directly and briefly. You are not driving the session: do",
	"not propose next steps, do not write files, and do not act on anything.",
].join(" ");

/// Plain text of the parent branch, newest last, trimmed to the budget.
function digestBranch(ctx: ExtensionContext): string {
	let entries: readonly unknown[];
	try {
		entries = ctx.sessionManager.getBranch();
	} catch {
		return "";
	}
	const lines: string[] = [];
	for (const entry of entries) {
		const record = entry as Record<string, unknown>;
		if (record.type !== "message") continue;
		const message = record.message as Record<string, unknown> | undefined;
		if (!message) continue;
		const role = typeof message.role === "string" ? message.role : "";
		if (role !== "user" && role !== "assistant") continue;
		const content = message.content;
		if (!Array.isArray(content)) continue;
		const text = content
			.filter(
				(block): block is { type: string; text: string } =>
					typeof block === "object" &&
					block !== null &&
					(block as { type?: unknown }).type === "text" &&
					typeof (block as { text?: unknown }).text === "string",
			)
			.map((block) => block.text)
			.join("");
		if (text.trim().length === 0) continue;
		lines.push(`${role}: ${text.trim()}`);
	}
	// Keep the tail: the newest exchanges are what a side question is about.
	let digest = "";
	for (let i = lines.length - 1; i >= 0; i--) {
		const candidate = `${lines[i]}\n${digest}`;
		if (Buffer.byteLength(candidate, "utf8") > CONTEXT_MAX_BYTES) break;
		digest = candidate;
	}
	return digest.trimEnd();
}

/// One kind of side task: what it is called and what it is allowed to touch.
export interface SideTask {
	name: "btw" | "omfg";
	label: string;
	tools: string[];
	system: string;
	/// Wraps the user's text into the prompt the side session receives.
	buildPrompt: (text: string, digest: string) => string;
}

export const BTW_TASK: SideTask = {
	name: "btw",
	label: "side question",
	tools: ["read", "grep", "glob"],
	system: SYSTEM_PROMPT,
	buildPrompt: (text, digest) =>
		digest.length > 0
			? `Conversation so far:\n\n${digest}\n\n---\n\nSide question: ${text}`
			: text,
};

export const OMFG_TASK: SideTask = {
	name: "omfg",
	label: "rule",
	// Writing the rule is the whole point, so this one needs the write tools.
	tools: ["read", "grep", "glob", "write", "edit"],
	system: [
		"You turn a complaint about an agent's behaviour into one standing rule",
		"that stops it recurring. Write the rule as a short markdown file under",
		"the agent rules directory, then reply with the path you wrote and the",
		"rule in one sentence. Do nothing else.",
	].join(" "),
	buildPrompt: (text, digest) =>
		digest.length > 0
			? `What went wrong:\n\n${text}\n\nRecent session, for context:\n\n${digest}`
			: `What went wrong:\n\n${text}`,
};

/// Runs one side task and streams its outcome to attached clients.
///
/// Reported through the subagent channel rather than the transcript: it is a
/// detour with its own lifecycle, and a client renders that channel as a row
/// per run.
export async function runSideTask(
	bridge: SessionBridge,
	ctx: ExtensionContext,
	task: SideTask,
	text: string,
): Promise<void> {
	const id = `${task.name}-${Date.now().toString(36)}`;
	bridge.broadcastEvent({
		k: "subagent",
		id,
		name: task.name,
		phase: "running",
		text,
		agentType: task.label,
	});

	const prompt = task.buildPrompt(text, digestBranch(ctx));

	try {
		const { session } = await createAgentSession({
			cwd: ctx.cwd,
			model: ctx.model,
			sessionManager: SessionManager.inMemory(ctx.cwd),
			systemPrompt: task.system,
			toolNames: task.tools,
			restrictToolNames: true,
			enableMCP: false,
			enableLsp: false,
			enableIrc: false,
			disableExtensionDiscovery: true,
			requireYieldTool: false,
			hasUI: false,
			deadline: Date.now() + ANSWER_TIMEOUT_MS,
		});
		try {
			// Raced against the clock: a provider that never answers would
			// otherwise leave the client watching a row that says "running"
			// forever, which is the one outcome worse than a failure.
			let timer: Timer | undefined;
			const timeout = new Promise<never>((_resolve, reject) => {
				timer = setTimeout(
					() => reject(new Error("timed out waiting for an answer")),
					ANSWER_TIMEOUT_MS,
				);
			});
			try {
				await Promise.race([session.prompt(prompt), timeout]);
			} finally {
				clearTimeout(timer);
			}
			const answer = session.messages
				.filter((message) => message.role === "assistant")
				.flatMap((message) => message.content)
				.map((block) =>
					"type" in block && block.type === "text" && "text" in block
						? String(block.text)
						: "",
				)
				.join("")
				.trim();
			bridge.broadcastEvent({
				k: "subagent",
				id,
				name: task.name,
				phase: "completed",
				text: answer.length > 0 ? answer : "(no answer)",
				agentType: task.label,
			});
		} finally {
			await session.dispose();
		}
	} catch (err) {
		const message = err instanceof Error ? err.message : String(err);
		bridge.recordError(`${task.name}: ${message}`);
		bridge.broadcastEvent({
			k: "subagent",
			id,
			name: task.name,
			phase: "failed",
			text: message,
			agentType: task.label,
		});
	}
}
