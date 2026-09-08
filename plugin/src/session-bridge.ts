// Transport-agnostic seam: owns the sequence counter, the retained state
// snapshot, pending interactive requests, and the wiring from pi.on(...)
// handlers to normalized wire events. Both the relay uplink and the local
// server plug into this through the OutboundSink interface; neither knows
// about the other's transport details.

import * as os from "node:os";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import {
	TASK_SUBAGENT_LIFECYCLE_CHANNEL,
	TASK_SUBAGENT_PROGRESS_CHANNEL,
} from "@oh-my-pi/pi-coding-agent/task/types";
import {
	buildAutoCompactionEvent,
	buildAutoRetryEndEvent,
	buildAutoRetryStartEvent,
	buildHistoryEvents,
	buildMessageEvent,
	buildToolEndEvent,
	buildSubagentLifecycleEvent,
	buildTodosEventFromResult,
	buildSubagentProgressEvent,
	modelToRef,
	safeStringifyInput,
	truncateText,
	TEXT_MAX_BYTES,
	TOOL_INPUT_MAX_BYTES,
} from "./normalize.js";
import type {
	AgentInfo,
	CoreEvent,
	CoreRequest,
	CoreRequestCancel,
	CoreState,
	InteractiveRequest,
	PendingRequestSummary,
	RemoteEvent,
	RequestAnswer,
	RequestCancelReason,
	StateSnapshot,
	TodoSummary,
	ViewerCounts,
} from "./protocol-types.js";
import type { RemoteConfig } from "./config.js";

export interface OutboundSink {
	sendEvent(frame: CoreEvent): void;
	sendState(frame: CoreState): void;
	sendRequest(frame: CoreRequest): void;
	sendRequestCancel(frame: CoreRequestCancel): void;
}

interface PendingRequestEntry {
	request: InteractiveRequest;
	resolve: (answer: RequestAnswer | undefined) => void;
	timer?: Timer;
}

let requestCounter = 0;
function nextRequestId(): string {
	requestCounter += 1;
	return `req-${requestCounter}`;
}

// Validates a RequestAnswer against the shape its request kind requires.
// Returns the narrowed answer or undefined when the shape does not match.
export function validateAnswerForRequest(request: InteractiveRequest, response: unknown): RequestAnswer | undefined {
	if (!response || typeof response !== "object") return undefined;
	const r = response as Record<string, unknown>;
	switch (request.k) {
		case "select":
			return typeof r.index === "number" ? { index: r.index } : undefined;
		case "confirm":
			return typeof r.confirmed === "boolean" ? { confirmed: r.confirmed } : undefined;
		case "input":
		case "editor":
			return typeof r.value === "string" ? { value: r.value } : undefined;
		case "approval":
			return r.decision === "allow" || r.decision === "deny" || r.decision === "always"
				? { decision: r.decision }
				: undefined;
	}
}

export class SessionBridge {
	private readonly pi: ExtensionAPI;
	private readonly config: RemoteConfig;
	private readonly sinks = new Set<OutboundSink>();
	private seq = 0;
	private lastState: StateSnapshot | undefined;
	private readonly pendingRequests = new Map<string, PendingRequestEntry>();
	private latestCtx: ExtensionContext | undefined;
	private readonly viewers: ViewerCounts = { control: 0, viewer: 0 };
	private compacting = false;
	private historyReplayPending = false;

	/// True once a transcript has been replayed, so a late subscriber does not
	/// trigger a second pass over the same branch.
	historyReplayed = false;

	/// Write-tool arguments held between `tool_execution_start` and its end,
	/// because the result carries neither the content nor a diff.
	private readonly pendingWrites = new Map<string, { path: string; content: string }>();

	/// Latest todo list, so a client attaching mid-run sees it without
	/// waiting for the next todo mutation.
	private lastTodos: TodoSummary[] | undefined;
	private readonly connectedAt = Date.now();
	private readonly bashProcesses = new Map<string, AbortController>();
	private eventsSent = 0;
	private lastError: string | undefined;

	constructor(pi: ExtensionAPI, config: RemoteConfig) {
		this.pi = pi;
		this.config = config;
	}

	get agentId(): string {
		return this.config.agentId;
	}

	/// The name a client shows for this session. The folder alone collides as
	/// soon as two sessions run in one project, so the session's own title is
	/// appended whenever it has one.
	get displayName(): string {
		const title = this.latestCtx?.sessionManager.getSessionName();
		const folder = this.config.agentName;
		if (typeof title !== "string") return folder;
		const trimmed = title.trim();
		if (trimmed.length === 0 || trimmed === folder) return folder;
		return `${folder} ${trimmed}`;
	}

	get info(): AgentInfo {
		return {
			agentId: this.config.agentId,
			name: this.displayName,
			host: os.hostname(),
			cwd: this.latestCtx?.cwd ?? process.cwd(),
			online: true,
			connectedAt: this.connectedAt,
		};
	}

	get eventCount(): number {
		return this.eventsSent;
	}

	get lastErrorMessage(): string | undefined {
		return this.lastError;
	}

	recordError(message: string): void {
		this.lastError = message;
	}

	setViewerCounts(counts: ViewerCounts): void {
		this.viewers.control = counts.control;
		this.viewers.viewer = counts.viewer;
		this.emitState();
	}

	attachSink(sink: OutboundSink): void {
		this.sinks.add(sink);
		// A newly attached transport (e.g. the local server accepting its first
		// client) should see the latest retained state and pending requests
		// immediately, mirroring the relay's own replay-on-subscribe behavior.
		if (this.lastState) sink.sendState({ t: "state", state: this.lastState });
		for (const [id, entry] of this.pendingRequests) {
			sink.sendRequest({ t: "request", id, request: entry.request });
		}
	}

	detachSink(sink: OutboundSink): void {
		this.sinks.delete(sink);
	}

	/// Publishes one event to every subscriber. Also used by the side-question
	/// session, which is not a `pi.on` source but reports through the same
	/// channel.
	broadcastEvent(event: RemoteEvent): void {
		this.seq += 1;
		this.eventsSent += 1;
		const frame: CoreEvent = { t: "event", seq: this.seq, event };
		for (const sink of this.sinks) sink.sendEvent(frame);
	}

	private updateCtx(ctx: ExtensionContext): void {
		this.latestCtx = ctx;
	}

	// -------------------------------------------------------------------
	// State snapshot.
	// -------------------------------------------------------------------

	getCurrentState(): StateSnapshot {
		return this.lastState ?? this.buildState();
	}

	private buildState(): StateSnapshot {
		const ctx = this.latestCtx;
		const sessionId = ctx?.sessionManager.getSessionId() ?? "";
		const sessionName = ctx?.sessionManager.getSessionName();
		const sessionFile = ctx?.sessionManager.getSessionFile();
		const cwd = ctx?.cwd ?? process.cwd();
		const modelRef = modelToRef(ctx?.model);
		const thinkingLevel = ctx ? this.pi.getThinkingLevel() : undefined;
		const streaming = ctx ? !ctx.isIdle() : false;
		// ExtensionContext has no queued-message count, only a boolean
		// (hasPendingMessages). This reports presence, not the real count
		// AgentSession.queuedMessageCount would give; see README's API gaps.
		const queued = ctx?.hasPendingMessages() ? 1 : 0;
		const contextUsageRaw = ctx?.getContextUsage();
		const contextUsage = contextUsageRaw
			? {
					tokens: contextUsageRaw.tokens,
					contextWindow: contextUsageRaw.contextWindow,
					percent: contextUsageRaw.percent,
				}
			: undefined;

		const pendingRequests: PendingRequestSummary[] = Array.from(this.pendingRequests.entries()).map(
			([id, entry]) => ({ id, request: entry.request }),
		);

		const snapshot: StateSnapshot = {
			sessionId,
			cwd,
			streaming,
			queued,
			pendingRequests,
			viewers: { ...this.viewers },
		};
		if (sessionName !== undefined) snapshot.sessionName = sessionName;
		if (sessionFile !== undefined) snapshot.sessionFile = sessionFile;
		if (modelRef !== undefined) snapshot.model = modelRef;
		if (thinkingLevel !== undefined) snapshot.thinkingLevel = thinkingLevel;
		snapshot.compacting = this.compacting;
		if (contextUsage !== undefined) snapshot.contextUsage = contextUsage;
		if (this.lastTodos !== undefined) snapshot.todos = this.lastTodos;
		return snapshot;
	}

	// Rebuilds and broadcasts the state snapshot. Called on session start,
	// turn boundaries, model/thinking changes, and todo updates.
	emitState(): void {
		this.lastState = this.buildState();
		const frame: CoreState = { t: "state", state: this.lastState };
		for (const sink of this.sinks) sink.sendState(frame);
	}

	// -------------------------------------------------------------------
	// Interactive requests.
	// -------------------------------------------------------------------

	// Raises a request to every attached control client and waits for the
	// first valid answer, a timeout, or explicit cancellation. Resolves to
	// `undefined` when cancelled or timed out without an answer.
	raiseRequest(request: InteractiveRequest): Promise<RequestAnswer | undefined> {
		const id = nextRequestId();
		return new Promise<RequestAnswer | undefined>((resolve) => {
			const entry: PendingRequestEntry = { request, resolve };
			this.pendingRequests.set(id, entry);
			if (request.timeout && this.latestCtx) {
				entry.timer = this.latestCtx.setTimeout(() => {
					this.settleRequest(id, "timed_out");
					resolve(undefined);
				}, request.timeout);
			}
			const frame: CoreRequest = { t: "request", id, request };
			for (const sink of this.sinks) sink.sendRequest(frame);
			this.emitState();
		});
	}

	// Called by a transport when a `response` frame arrives from a control
	// client. Returns whether the answer was accepted.
	submitResponse(id: string, response: unknown): { ok: true } | { ok: false; error: string } {
		const entry = this.pendingRequests.get(id);
		if (!entry) return { ok: false, error: "request already answered" };
		const answer = validateAnswerForRequest(entry.request, response);
		if (!answer) return { ok: false, error: "invalid response" };
		this.settleRequest(id, "answered_locally", answer);
		return { ok: true };
	}

	private settleRequest(id: string, reason: RequestCancelReason, answer?: RequestAnswer): void {
		const entry = this.pendingRequests.get(id);
		if (!entry) return;
		this.pendingRequests.delete(id);
		if (entry.timer) this.latestCtx?.clearTimer(entry.timer);
		if (!answer) {
			const frame: CoreRequestCancel = { t: "request_cancel", id, reason };
			for (const sink of this.sinks) sink.sendRequestCancel(frame);
		}
		this.emitState();
		if (answer) entry.resolve(answer);
	}

	// Cancels every pending request, used on session_shutdown.
	cancelAllRequests(reason: RequestCancelReason): void {
		for (const id of Array.from(this.pendingRequests.keys())) {
			const entry = this.pendingRequests.get(id);
			this.settleRequest(id, reason);
			entry?.resolve(undefined);
		}
	}

	// -------------------------------------------------------------------
	// bash tracking (used by commands.ts for abort_bash).
	// -------------------------------------------------------------------

	registerBashProcess(id: string, controller: AbortController): void {
		this.bashProcesses.set(id, controller);
	}

	unregisterBashProcess(id: string): void {
		this.bashProcesses.delete(id);
	}

	abortBashProcess(id: string): boolean {
		const controller = this.bashProcesses.get(id);
		if (!controller) return false;
		controller.abort();
		return true;
	}

	broadcastBashOutput(id: string, text: string): void {
		this.broadcastEvent({ k: "bash_output", id, text: truncateText(text, TEXT_MAX_BYTES) });
	}

	// The prompt queue lives in omp, not here. A prompt sent mid-turn is
	// handed straight over with `deliverAs: "aside"`, which puts it in the
	// same pending queue a message typed at the workstation goes into and
	// delivers it at the next step boundary. Holding a second queue here made
	// the phone's messages wait for the whole turn and put them somewhere the
	// workstation could not see.

	// -------------------------------------------------------------------
	// History replay
	// -------------------------------------------------------------------

	// A resumed or switched-to session has a transcript on disk but emits no
	// events for it, so a client attaching to one would see nothing. Replaying
	// the persisted branch into the event stream puts that history in the
	// retained buffer, which is what every subscriber reads from.
	//
	// Deferred by a turn of the event loop: at `session_start` a resumed
	// session's branch is still empty, so reading it there yields nothing.
	scheduleHistoryReplay(ctx: ExtensionContext): void {
		if (this.historyReplayPending) return;
		this.historyReplayPending = true;
		ctx.setTimeout(() => {
			this.historyReplayPending = false;
			this.replayHistory(ctx);
		}, 0);
	}

	// Replays whatever the branch holds now. Safe to call more than once: a
	// second call re-sends the same transcript, which a client applies as a
	// duplicate seq and drops.
	replayHistory(ctx: ExtensionContext): void {
		let entries: readonly unknown[];
		try {
			entries = ctx.sessionManager.getBranch();
		} catch {
			return;
		}
		const events = buildHistoryEvents(entries);
		if (events.length === 0) return;
		this.historyReplayed = true;
		// The whole branch, not a window of it: the retained buffer is bounded
		// by bytes and sized to hold a full session, and trimming here is what
		// left a resumed conversation starting mid-sentence.
		for (const event of events) {
			this.broadcastEvent(event as RemoteEvent);
		}
	}

	// -------------------------------------------------------------------
	// Subagent observability
	// -------------------------------------------------------------------

	// Spawned agents run in their own sessions, so none of their work reaches
	// the parent's `pi.on` events. The task tool republishes lifecycle and
	// coalesced progress frames on the session bus; forwarding them is what
	// lets a client watch a fan-out from inside the parent session.
	private registerSubagentWatch(): void {
		this.pi.events.on(TASK_SUBAGENT_LIFECYCLE_CHANNEL, (data) => {
			const event = buildSubagentLifecycleEvent(data);
			if (event) this.broadcastEvent(event);
		});
		this.pi.events.on(TASK_SUBAGENT_PROGRESS_CHANNEL, (data) => {
			const event = buildSubagentProgressEvent(data);
			if (event) this.broadcastEvent(event);
		});
	}

	// -------------------------------------------------------------------
	// pi.on(...) wiring. Called once from the extension factory.
	// -------------------------------------------------------------------

	registerHandlers(): void {
		const pi = this.pi;
		this.registerSubagentWatch();

		pi.on("session_start", async (_event, ctx) => {
			this.updateCtx(ctx);
			this.scheduleHistoryReplay(ctx);
			this.emitState();
		});

		pi.on("agent_start", async (_event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent({ k: "agent_start" });
		});
		pi.on("agent_end", async (event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent({ k: "agent_end", terminal: !event.willContinue });
			this.emitState();
		});
		pi.on("turn_start", async (_event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent({ k: "turn_start" });
			this.emitState();
		});
		pi.on("turn_end", async (_event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent({ k: "turn_end" });
			this.emitState();
		});

		pi.on("message_update", async (event, ctx) => {
			this.updateCtx(ctx);
			const e = event.assistantMessageEvent;
			if (e.type === "text_delta") {
				this.broadcastEvent({ k: "text_delta", text: truncateText(e.delta, TEXT_MAX_BYTES) });
			} else if (e.type === "thinking_delta") {
				this.broadcastEvent({ k: "thinking_delta", text: truncateText(e.delta, TEXT_MAX_BYTES) });
			}
		});
		pi.on("message_end", async (event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent(buildMessageEvent(event.message));
		});
		pi.on("tool_execution_start", async (event, ctx) => {
			this.updateCtx(ctx);
			// `write` reports no diff and no path in its result, so its
			// arguments are kept until the call ends and the diff is built
			// from them.
			if (event.toolName === "write") {
				const args = event.args;
				if (args && typeof args === "object" && "path" in args && "content" in args) {
					const path = args.path;
					const content = args.content;
					if (typeof path === "string" && typeof content === "string") {
						this.pendingWrites.set(event.toolCallId, { path, content });
					}
				}
			}
			this.broadcastEvent({
				k: "tool_start",
				id: event.toolCallId,
				name: event.toolName,
				input: truncateText(safeStringifyInput(event.args), TOOL_INPUT_MAX_BYTES),
			});
		});
		pi.on("tool_execution_update", async (event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent({
				k: "tool_update",
				id: event.toolCallId,
				text: truncateText(safeStringifyInput(event.partialResult), TEXT_MAX_BYTES),
			});
		});
		pi.on("tool_execution_end", async (event, ctx) => {
			this.updateCtx(ctx);
			const written = this.pendingWrites.get(event.toolCallId);
			this.pendingWrites.delete(event.toolCallId);
			this.broadcastEvent(
				buildToolEndEvent(
					event.toolCallId,
					event.toolName,
					event.result,
					event.isError,
					written,
				),
			);
			if (event.toolName === "todo" && !event.isError) {
				const todos = buildTodosEventFromResult(event.result);
				if (todos && todos.k === "todos") {
					this.lastTodos = todos.todos;
					this.broadcastEvent(todos);
					this.emitState();
				}
			}
		});

		pi.on("todo_reminder", async (event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent({
				k: "todos",
				todos: event.todos.map((t) => ({ phase: "", content: t.content, status: t.status })),
			});
		});

		pi.on("auto_compaction_start", async (_event, ctx) => {
			this.updateCtx(ctx);
			this.compacting = true;
			this.broadcastEvent(buildAutoCompactionEvent("start"));
			this.emitState();
		});
		pi.on("auto_compaction_end", async (_event, ctx) => {
			this.updateCtx(ctx);
			this.compacting = false;
			this.broadcastEvent(buildAutoCompactionEvent("end"));
			this.emitState();
		});
		pi.on("auto_retry_start", async (event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent(buildAutoRetryStartEvent(event.errorMessage));
		});
		pi.on("auto_retry_end", async (event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent(buildAutoRetryEndEvent(event.success, event.finalError));
		});

		pi.on("session_switch", async (_event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent({
				k: "session_changed",
				reason: "switch",
				sessionId: ctx.sessionManager.getSessionId(),
				...(ctx.sessionManager.getSessionName() !== undefined
					? { sessionName: ctx.sessionManager.getSessionName() as string }
					: {}),
			});
			this.scheduleHistoryReplay(ctx);
			this.emitState();
		});
		pi.on("session_branch", async (_event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent({
				k: "session_changed",
				reason: "branch",
				sessionId: ctx.sessionManager.getSessionId(),
			});
			this.scheduleHistoryReplay(ctx);
			this.emitState();
		});
		pi.on("session_tree", async (_event, ctx) => {
			this.updateCtx(ctx);
			this.broadcastEvent({
				k: "session_changed",
				reason: "tree",
				sessionId: ctx.sessionManager.getSessionId(),
			});
			this.scheduleHistoryReplay(ctx);
			this.emitState();
		});

		pi.on("session_shutdown", async () => {
			this.cancelAllRequests("shutdown");
		});
	}

	raiseNotice(level: "info" | "warning" | "error", text: string): void {
		this.broadcastEvent({ k: "notice", level, text: truncateText(text, TEXT_MAX_BYTES) });
	}

	getLatestCtx(): ExtensionContext | undefined {
		return this.latestCtx;
	}
}
