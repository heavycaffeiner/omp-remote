// Shadows the built-in `ask` tool (docs/protocol.md, "Interactive requests":
// "`ask` is covered by shadowing the built-in tool of that name"). When a
// control client is attached, each question becomes a `select` request over
// the wire; the phone answers it like any other interactive request. When
// nothing is attached, or the remote answer times out or the request is
// cancelled, execution falls through to the native tool via
// `ctx.invokeTool`, so the terminal picker still works exactly as before.

import type { AgentToolResult, AgentToolUpdateCallback } from "@oh-my-pi/pi-agent-core";
import type { AskToolDetails, ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import type { InteractiveRequest, RequestAnswer } from "./protocol-types.js";
import type { SessionBridge } from "./session-bridge.js";

interface AskShadowOption {
	label: string;
	description?: string;
	preview?: string;
}

interface AskShadowQuestion {
	id: string;
	question: string;
	header?: string;
	options: AskShadowOption[];
	multi?: boolean;
	recommended?: number;
}

interface AskShadowParams {
	questions: AskShadowQuestion[];
}

interface RemoteQuestionResult {
	id: string;
	question: string;
	options: string[];
	multi: boolean;
	selectedOptions: string[];
}

// Waits for `promise`, but resolves to `undefined` as soon as `signal`
// aborts (a tool-call-level abort, distinct from the wire-level
// `request_cancel` that bridge.raiseRequest already folds into its own
// `undefined` resolution). The bridge exposes no way to cancel a single
// pending request from outside, so an abort here abandons the wait and
// falls through to native delegation; the parked request itself is only
// cleaned up later by its own timeout or by session shutdown.
function raceWithSignal<T>(promise: Promise<T>, signal: AbortSignal): Promise<T | undefined> {
	if (signal.aborted) return Promise.resolve(undefined);
	const { promise: raced, resolve } = Promise.withResolvers<T | undefined>();
	const onAbort = () => resolve(undefined);
	signal.addEventListener("abort", onAbort, { once: true });
	void promise.then((value) => {
		signal.removeEventListener("abort", onAbort);
		resolve(value);
	});
	return raced;
}

async function delegateToNative(
	ctx: ExtensionContext,
	params: AskShadowParams,
	signal: AbortSignal | undefined,
): Promise<AgentToolResult<AskToolDetails>> {
	if (!ctx.invokeTool) {
		throw new Error("ask-shadow: native ask tool delegation is unavailable (ExtensionContext.invokeTool is absent)");
	}
	const nativeParams: Record<string, unknown> = { questions: params.questions };
	return ctx.invokeTool<AskToolDetails>(nativeParams, signal !== undefined ? { signal } : undefined);
}

function formatAnswerLine(result: RemoteQuestionResult): string {
	return `${result.question}: ${result.selectedOptions.join(", ") || "(no selection)"}`;
}

/// The wire form of one question. `multi` travels so the client can offer
/// several picks where the tool asked for several.
function buildRequest(question: AskShadowQuestion): InteractiveRequest {
	const request: InteractiveRequest = {
		k: "select",
		title: question.question,
		message: question.header ?? "",
		options: question.options.map((option) =>
			option.description !== undefined
				? { label: option.label, description: option.description }
				: { label: option.label },
		),
	};
	if (question.multi === true) request.multi = true;
	return request;
}

/// Reads an answer against the question it was raised for. Returns undefined
/// when the client answered with something the question cannot use, which is
/// the same as not answering: the other path gets its turn.
function selectionFrom(
	question: AskShadowQuestion,
	answer: RequestAnswer | undefined,
): RemoteQuestionResult | undefined {
	if (!answer) return undefined;
	const labels: string[] = [];
	if ("indexes" in answer) {
		for (const index of answer.indexes) {
			const option = question.options[index];
			if (option) labels.push(option.label);
		}
	} else if ("index" in answer) {
		const option = question.options[answer.index];
		if (option) labels.push(option.label);
	}
	if (labels.length === 0) return undefined;
	return {
		id: question.id,
		question: question.question,
		options: question.options.map((option) => option.label),
		multi: question.multi ?? false,
		selectedOptions: labels,
	};
}

/// One question answers in the shape the native tool uses for one; several
/// answer as a list. Matching that keeps the model's view identical whether
/// the phone or the terminal answered.
function buildToolResult(results: RemoteQuestionResult[]): AgentToolResult<AskToolDetails> {
	if (results.length === 1) {
		const result = results[0] as RemoteQuestionResult;
		const details: AskToolDetails = {
			question: result.question,
			options: result.options,
			multi: result.multi,
			selectedOptions: result.selectedOptions,
		};
		return { content: [{ type: "text", text: formatAnswerLine(result) }], details };
	}
	const details: AskToolDetails = { results };
	return {
		content: [{ type: "text", text: `User answers:\n${results.map(formatAnswerLine).join("\n")}` }],
		details,
	};
}

export function registerAskShadow(pi: ExtensionAPI, bridge: SessionBridge): void {
	const optionSchema = pi.zod.object({
		label: pi.zod.string(),
		description: pi.zod.string().optional(),
		preview: pi.zod.string().optional(),
	});
	const questionSchema = pi.zod.object({
		id: pi.zod.string(),
		question: pi.zod.string(),
		header: pi.zod.string().optional(),
		options: pi.zod.array(optionSchema),
		multi: pi.zod.boolean().optional(),
		recommended: pi.zod.number().optional(),
	});
	const askShadowSchema = pi.zod.object({
		questions: pi.zod.array(questionSchema),
	});

	pi.registerTool({
		name: "ask",
		label: "Ask",
		description:
			"Ask the user one or more clarifying questions. Answered from the phone when a control client is attached; otherwise the interactive terminal picker.",
		parameters: askShadowSchema,
		approval: "read",
		execute: async (
			_toolCallId: string,
			params: AskShadowParams,
			signal: AbortSignal | undefined,
			_onUpdate: AgentToolUpdateCallback<AskToolDetails> | undefined,
			ctx: ExtensionContext,
		): Promise<AgentToolResult<AskToolDetails>> => {
			// Both paths run at once, and the first answer wins.
			//
			// Checking for an attached client first and delegating when there
			// was none is what made a question unanswerable from a phone that
			// arrived a moment later: no wire request was ever raised, so
			// reconnecting found nothing to show. Raising it regardless means
			// a client that attaches mid-question still sees the card, while
			// the workstation's own picker keeps working exactly as before.
			const raised = new Set<string>();
			const nativeAbort = new AbortController();
			const abortNative = () => nativeAbort.abort();
			signal?.addEventListener("abort", abortNative, { once: true });

			const remote = (async (): Promise<AgentToolResult<AskToolDetails> | undefined> => {
				const results: RemoteQuestionResult[] = [];
				for (const question of params.questions) {
					if (signal?.aborted) return undefined;
					const handle = bridge.raiseRequest(buildRequest(question));
					raised.add(handle.id);
					const answer = signal ? await raceWithSignal(handle.answer, signal) : await handle.answer;
					raised.delete(handle.id);
					const picked = selectionFrom(question, answer);
					if (!picked) return undefined;
					results.push(picked);
				}
				return buildToolResult(results);
			})();

			const native = (async (): Promise<AgentToolResult<AskToolDetails> | undefined> => {
				try {
					return await delegateToNative(ctx, params, nativeAbort.signal);
				} catch {
					// No picker here, or it was abandoned. The remote side is
					// still waiting, so this is not the tool's outcome.
					return undefined;
				}
			})();

			const tagged = await Promise.race([
				remote.then((result) => ({ via: "remote" as const, result })),
				native.then((result) => ({ via: "native" as const, result })),
			]);

			// The loser is withdrawn so a card does not linger on a phone for
			// a question the terminal already answered, and the reverse.
			let outcome = tagged.result;
			if (tagged.via === "remote" && outcome) {
				nativeAbort.abort();
			} else if (tagged.via === "native" && outcome) {
				for (const id of raised) bridge.cancelRequest(id, "answered_locally");
			} else {
				// Whichever path settled first could not answer; the other one
				// is the only remaining chance.
				const other = tagged.via === "remote" ? native : remote;
				outcome = await other;
			}

			signal?.removeEventListener("abort", abortNative);
			if (!outcome) {
				throw new Error("ask: neither the attached client nor the workstation answered");
			}
			return outcome;
		},
	});
}
