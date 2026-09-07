// Shadows the built-in `ask` tool (docs/protocol.md, "Interactive requests":
// "`ask` is covered by shadowing the built-in tool of that name"). When a
// control client is attached, each question becomes a `select` request over
// the wire; the phone answers it like any other interactive request. When
// nothing is attached, or the remote answer times out or the request is
// cancelled, execution falls through to the native tool via
// `ctx.invokeTool`, so the terminal picker still works exactly as before.

import type { AgentToolResult, AgentToolUpdateCallback } from "@oh-my-pi/pi-agent-core";
import type { AskToolDetails, ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import type { InteractiveRequest } from "./protocol-types.js";
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
			const controlAttached = bridge.getCurrentState().viewers.control > 0;
			if (!controlAttached) return delegateToNative(ctx, params, signal);

			const results: RemoteQuestionResult[] = [];
			for (const question of params.questions) {
				if (signal?.aborted) return delegateToNative(ctx, params, signal);

				const request: InteractiveRequest = {
					k: "select",
					title: question.question,
					message: question.header ?? "",
					options: question.options.map((option) =>
						option.description !== undefined ? { label: option.label, description: option.description } : { label: option.label },
					),
				};

				const answerPromise = bridge.raiseRequest(request);
				const answer = signal ? await raceWithSignal(answerPromise, signal) : await answerPromise;
				if (answer === undefined) return delegateToNative(ctx, params, signal);
				if (!("index" in answer)) return delegateToNative(ctx, params, signal);

				const selected = question.options[answer.index];
				if (!selected) return delegateToNative(ctx, params, signal);

				results.push({
					id: question.id,
					question: question.question,
					options: question.options.map((o) => o.label),
					multi: question.multi ?? false,
					selectedOptions: [selected.label],
				});
			}

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
			const responseText = `User answers:\n${results.map(formatAnswerLine).join("\n")}`;
			return { content: [{ type: "text", text: responseText }], details };
		},
	});
}
