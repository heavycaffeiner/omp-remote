// Wire types for docs/protocol.md v2. Mirrors the frame envelope, event
// kinds, commands, and interactive requests exactly; no invented fields.

export const PROTOCOL_VERSION = 2;

export type Role = "control" | "viewer";

// ---------------------------------------------------------------------------
// Events (agent -> relay/client), discriminator `k`.
// ---------------------------------------------------------------------------

export interface EvAgentStart {
	k: "agent_start";
}
export interface EvAgentEnd {
	k: "agent_end";
	terminal: boolean;
}
export interface EvTurnStart {
	k: "turn_start";
}
export interface EvTurnEnd {
	k: "turn_end";
}
export interface EvTextDelta {
	k: "text_delta";
	text: string;
}
export interface EvThinkingDelta {
	k: "thinking_delta";
	text: string;
}
export interface EvMessage {
	k: "message";
	role: string;
	text: string;
	thinking?: string;
}
export interface EvToolStart {
	k: "tool_start";
	id: string;
	name: string;
	input: string;
}
export interface EvToolUpdate {
	k: "tool_update";
	id: string;
	text: string;
}
export interface EvToolEnd {
	k: "tool_end";
	id: string;
	name: string;
	ok: boolean;
	text: string;

	/// File the call changed, when it changed exactly one.
	path?: string;

	/// Unified diff of the change, as the edit tool itself produced it. A
	/// `write` has no prior text to diff against on create, so this carries
	/// the added lines instead.
	diff?: string;

	/// Set when the edit moved the file; `path` is the destination.
	sourcePath?: string;
}
export interface EvTodos {
	k: "todos";
	todos: TodoSummary[];
}
export interface EvNotice {
	k: "notice";
	level: "info" | "warning" | "error";
	text: string;
}
export interface EvStatus {
	k: "status";
	key: string;
	text: string;
}
export interface EvModelChanged {
	k: "model_changed";
	model: ModelRef;
}
export interface EvThinkingChanged {
	k: "thinking_changed";
	thinkingLevel: string;
}
export interface EvCompaction {
	k: "compaction";
	phase: "start" | "end";
}
export interface EvRetry {
	k: "retry";
	phase: "start" | "end";
	text: string;
}
export interface EvSessionChanged {
	k: "session_changed";
	reason: "start" | "switch" | "branch" | "tree";
	sessionId: string;
	sessionName?: string;
}
// One subagent's state as the parent sees it. `phase` is the lifecycle or
// progress status; the rest is what a reader needs to tell a working agent
// from a stuck one without opening its transcript.
export interface EvSubagent {
	k: "subagent";
	id: string;
	name: string;
	phase: string;
	text: string;
	agentType?: string;
	tool?: string;
	toolCount?: number;
	tokens?: number;
	durationMs?: number;
}
export interface EvBashOutput {
	k: "bash_output";
	id: string;
	text: string;
}

export type RemoteEvent =
	| EvAgentStart
	| EvAgentEnd
	| EvTurnStart
	| EvTurnEnd
	| EvTextDelta
	| EvThinkingDelta
	| EvMessage
	| EvToolStart
	| EvToolUpdate
	| EvToolEnd
	| EvTodos
	| EvNotice
	| EvStatus
	| EvModelChanged
	| EvThinkingChanged
	| EvCompaction
	| EvRetry
	| EvSessionChanged
	| EvSubagent
	| EvBashOutput;

// ---------------------------------------------------------------------------
// Shared value shapes.
// ---------------------------------------------------------------------------

export interface ModelRef {
	provider: string;
	id: string;
}

/// One named model slot core resolves through `@<role>`. `configured` is the
/// selector stored in config.yml, absent when the slot is empty; `resolved`
/// is what a turn would actually use, which for an empty slot is whatever
/// `default` resolves to.
export interface ModelRoleInfo {
	role: string;
	purpose?: string;
	configured?: string;
	resolvedProvider?: string;
	resolvedId?: string;
	source?: string;
}

export interface TodoSummary {
	phase: string;
	content: string;
	status: string;
}

export interface ContextUsageSummary {
	tokens: number;
	contextWindow: number;
	percent: number;
}

export interface ViewerCounts {
	control: number;
	viewer: number;
}

// ---------------------------------------------------------------------------
// Interactive requests, discriminator `k`.
// ---------------------------------------------------------------------------

export interface ReqSelectOption {
	label: string;
	description?: string;
}
export interface ReqSelect {
	k: "select";
	title: string;
	message: string;
	options: ReqSelectOption[];
	/// Whether the question takes several picks. A client that ignores this
	/// answers with one `index`, which the agent accepts as a single pick.
	multi?: boolean;
	timeout?: number;
}
export interface ReqConfirm {
	k: "confirm";
	title: string;
	message: string;
	timeout?: number;
}
export interface ReqInput {
	k: "input";
	title: string;
	message: string;
	placeholder?: string;
	initial?: string;
	timeout?: number;
}
export interface ReqEditor {
	k: "editor";
	title: string;
	initial?: string;
	language?: string;
	timeout?: number;
}
export interface ReqApproval {
	k: "approval";
	toolName: string;
	input: string;
	risk: string;
	timeout?: number;
}

export type InteractiveRequest = ReqSelect | ReqConfirm | ReqInput | ReqEditor | ReqApproval;

export interface AnsSelect {
	index: number;
}
/// Answer to a `select` whose `multi` is set. Indexes are into the request's
/// own `options`, in the order the client wants them read back.
export interface AnsSelectMulti {
	indexes: number[];
}
export interface AnsConfirm {
	confirmed: boolean;
}
export interface AnsValue {
	value: string;
}
export interface AnsApproval {
	decision: "allow" | "deny" | "always";
}

export type RequestAnswer = AnsSelect | AnsSelectMulti | AnsConfirm | AnsValue | AnsApproval;

export type RequestCancelReason = "answered_locally" | "timed_out" | "aborted" | "shutdown";

export interface PendingRequestSummary {
	id: string;
	request: InteractiveRequest;
}

// ---------------------------------------------------------------------------
// State snapshot.
// ---------------------------------------------------------------------------

export interface StateSnapshot {
	sessionId: string;
	sessionName?: string;
	sessionFile?: string;
	cwd: string;
	model?: ModelRef;
	thinkingLevel?: string;
	/// The thinking levels the current model accepts, least to most
	/// intensive, with `inherit` and `off` first. Absent when the model has
	/// no controllable effort surface, which a client should render as a
	/// disabled control rather than a full list.
	thinkingLevels?: string[];
	/// The prompts this plugin forwarded while the agent was busy, oldest
	/// first. omp owns the queue and does not expose its contents, so this is
	/// what a client can be shown: it never includes text typed at the
	/// workstation. Absent when nothing is waiting.
	queue?: string[];
	streaming: boolean;
	compacting?: boolean;
	/// Whether omp has a message pending behind the current turn.
	/// `hasPendingMessages` is a boolean, so this is presence, not a count.
	queued: number;
	autoCompaction?: boolean;
	steeringMode?: string;
	followUpMode?: string;
	interruptMode?: string;
	contextUsage?: ContextUsageSummary;
	todos?: TodoSummary[];
	pendingRequests: PendingRequestSummary[];
	viewers: ViewerCounts;
}

// ---------------------------------------------------------------------------
// Agent info.
// ---------------------------------------------------------------------------

export interface AgentInfo {
	agentId: string;
	name: string;
	host: string;
	cwd: string;
	online: boolean;
	connectedAt: number;
}

// ---------------------------------------------------------------------------
// Commands (client -> agent via relay, or client -> local server), and their
// reply data shapes. Args are validated at the boundary in commands.ts.
// ---------------------------------------------------------------------------

export type DeliverAs = "steer" | "followUp" | "aside";

export interface CmdPromptArgs {
	text: string;
	deliverAs?: DeliverAs;
	images?: string[];
}
export interface CmdSteerArgs {
	text: string;
}
export interface CmdFollowUpArgs {
	text: string;
}
export interface CmdHistoryArgs {
	limit?: number;
	before?: string;
}
export interface CmdSetModelArgs {
	provider: string;
	id: string;
}
export interface CmdSetThinkingArgs {
	level: string;
}
/// `model` is a `provider/id` selector, optionally with an effort suffix.
/// Omitted, the role is cleared and falls back to `default`.
export interface CmdSetModelRoleArgs {
	role: string;
	model?: string;
}
export interface CmdSetAutoCompactionArgs {
	enabled: boolean;
}
export interface CmdSetSteeringModeArgs {
	mode: string;
}
export interface CmdSetFollowUpModeArgs {
	mode: string;
}
export interface CmdSetInterruptModeArgs {
	mode: string;
}
export interface CmdSetActiveToolsArgs {
	names: string[];
}
export interface CmdSetTodosArgs {
	phases: unknown;
}
export interface CmdSwitchSessionArgs {
	sessionFile: string;
}
export interface CmdListSessionsArgs {
	limit?: number;
}
export interface CmdBranchArgs {
	entryId: string;
}
export interface CmdCompactArgs {
	instructions?: string;
}
export interface CmdSetSessionNameArgs {
	name: string;
}
export interface CmdRunCommandArgs {
	name: string;
	args?: string;
}
export interface CmdBashArgs {
	command: string;
}
export interface CmdAbortBashArgs {
	id: string;
}

// Mirrors `ThinkingLevel` in @oh-my-pi/pi-agent-core exactly. `inherit` is a
// real selection, not an absence: it defers to the higher-level setting.
export const THINKING_LEVELS = ["inherit", "off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
export const STEERING_FOLLOWUP_MODES = ["all", "one-at-a-time"] as const;
export const INTERRUPT_MODES = ["immediate", "wait"] as const;
export const DELIVER_AS_VALUES = ["steer", "followUp", "aside"] as const;

// Frame envelopes.
// ---------------------------------------------------------------------------
//
// Two families: the "core" frames the session-bridge produces, which never
// carry `agentId` (the protocol's agent-to-relay direction omits it); and the
// client-facing frames the local server sends to its own directly-connected
// clients, which add `agentId` so client-side parsing is uniform across the
// relay and direct transports (protocol.md, "Frame envelope").

export interface FrameHello {
	t: "hello";
	protocol: number;
	agentId: string;
	info: AgentInfo;
}
export interface CoreEvent {
	t: "event";
	seq: number;
	event: RemoteEvent;
}
export interface CoreState {
	t: "state";
	state: StateSnapshot;
}
export interface FrameReply {
	t: "reply";
	id: string;
	ok: boolean;
	data?: unknown;
	error?: string;
}
export interface CoreRequest {
	t: "request";
	id: string;
	request: InteractiveRequest;
}
export interface CoreRequestCancel {
	t: "request_cancel";
	id: string;
	reason: RequestCancelReason;
}
export interface FrameWelcomeAgent {
	t: "welcome";
	protocol: number;
	agentId: string;
}
export interface FrameCommand {
	t: "command";
	id: string;
	agentId?: string;
	cmd: string;
	args: unknown;
}
export interface FrameResponse {
	t: "response";
	id: string;
	agentId?: string;
	response: unknown;
}
export interface FrameViewers {
	t: "viewers";
	control: number;
	viewer: number;
}
export interface FrameWelcomeClient {
	t: "welcome";
	protocol: number;
	clientId: string;
	role: Role;
	agents: AgentInfo[];
}
export interface FrameAgents {
	t: "agents";
	agents: AgentInfo[];
}
export interface FrameSubscribe {
	t: "subscribe";
	agentId: string;
	since: number;
}
export interface FrameUnsubscribe {
	t: "unsubscribe";
	agentId: string;
}
export interface FrameClientHello {
	t: "hello";
	protocol: number;
	clientId: string;
	name?: string;
}

// Client-facing variants of the core frames, with `agentId` attached.
export interface FrameEventForClient extends CoreEvent {
	agentId: string;
}
export interface FrameStateForClient extends CoreState {
	agentId: string;
}
export interface FrameRequestForClient extends CoreRequest {
	agentId: string;
}
export interface FrameRequestCancelForClient extends CoreRequestCancel {
	agentId: string;
}

// Frames the plugin SENDS to a relay (agent role). None carry `agentId`; the
// relay already knows which connection they came from.
export type AgentToRelayFrame = FrameHello | CoreEvent | CoreState | FrameReply | CoreRequest | CoreRequestCancel;
// Frames the plugin RECEIVES from a relay (agent role).
export type RelayToAgentFrame = FrameWelcomeAgent | FrameCommand | FrameResponse | FrameViewers;

// Frames the plugin SENDS to a directly-connected client (local server, client-facing side).
export type ServerToClientFrame =
	| FrameWelcomeClient
	| FrameAgents
	| FrameEventForClient
	| FrameStateForClient
	| FrameReply
	| FrameRequestForClient
	| FrameRequestCancelForClient;
// Frames the plugin RECEIVES from a directly-connected client.
export type ClientToServerFrame = FrameClientHello | FrameSubscribe | FrameUnsubscribe | FrameCommand | FrameResponse;
