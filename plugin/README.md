# omp-remote plugin

An omp extension that exposes a running session to the [OMPRemote](../README.md)
phone app over the wire protocol in `docs/protocol.md`. It never changes what
omp itself does; it observes the session and relays a bounded set of commands
and interactive requests to a remote client.

## Loading it

Point omp at the plugin directory directly:

```
omp --extension ./plugin
```

or register it in your omp config:

```yaml
extensions:
  - ./plugin
```

With neither `OMP_REMOTE_RELAY_URL` nor local serving enabled (see below),
the extension loads and stays completely dormant: no listener, no outbound
connection, no commands registered beyond the diagnostics one.

## Environment variables

All configuration is read once at load time from `process.env`; nothing
downstream re-reads the environment.

| Variable                     | Default                          | Meaning                                                                 |
| ----------------------------- | --------------------------------- | ------------------------------------------------------------------------ |
| `OMP_REMOTE_RELAY_URL`        | unset (relay disabled)            | `ws://` or `wss://` URL of the relay's `/agent` endpoint.                |
| `OMP_REMOTE_TOKEN`            | none                              | Agent token presented to the relay. Required when `OMP_REMOTE_RELAY_URL` is set. |
| `OMP_REMOTE_CONTROL_TOKEN`    | unset                             | Relay's `OMP_RELAY_CONTROL_TOKEN`. Only used to build a relay control pairing link. |
| `OMP_REMOTE_VIEWER_TOKEN`     | unset                             | Relay's `OMP_RELAY_VIEWER_TOKEN`. Only used to build a relay viewer pairing link. |
| `OMP_REMOTE_LOCAL`            | `1` (enabled)                     | Set to `0` to disable the plugin's own local WebSocket server.          |
| `OMP_REMOTE_LOCAL_PORT`       | `8788`                            | The port every session on this machine shares. The first to bind it serves the rest. |
| `OMP_REMOTE_LOCAL_BIND`       | `0.0.0.0`                         | Bind address for the local server.                                      |
| `OMP_REMOTE_AGENT_ID`         | `<hostname>/<cwd basename>#<pid>` | Agent id advertised in `hello`/roster entries and pairing links.        |
| `OMP_REMOTE_ALLOW_BASH`       | `0` (disabled)                    | Set to `1` or `true` to allow the `bash` command to run real shell commands on this workstation. |
| `OMP_REMOTE_REMOTE_APPROVAL`  | `0` (disabled)                    | Set to `1` or `true` to let an attached control client's `deny` answer block a tool call before it runs. |

A present-but-invalid value (a malformed relay URL, an out-of-range port, a
relay URL with no token) fails loudly once, through a notification on
`session_start`; the extension does not throw at load time and does not
retry silently with a guessed default.

Both transports may be active at once: a session started with both a relay
URL and local serving enabled is simultaneously relayed and directly
reachable, exactly as `docs/protocol.md`'s Topology section describes.

## Commands

### `/remote`

Prints the current transport status: agent id, whether the relay connection
is up and to which host, the local server's port and attached client
counts, and a running event counter. Diagnostic only; it registers
unconditionally, even when both transports are disabled, so `/remote` always
tells you why nothing is reachable.

### `/remote-omp`

Prints a terminal QR code, a six-character pairing code, and a link for the
OMPRemote app (`docs/protocol.md`, "Pairing").

The code is what makes pairing without a camera bearable: six characters typed
into the app instead of a 64-character token copied by hand. It is redeemed at
`GET /pair?code=...`, works once, and expires after five minutes. Relay
pairing has no code, since a relayed client cannot reach the local server.

- Bare (`/remote-omp`): a **control** link. Direct is preferred whenever the
  local server is up; falls back to relay otherwise.
- `/remote-omp viewer`: a **viewer** (read-only) link instead of control.
- `/remote-omp relay`: forces the relay form of the link even when the local
  server is up.

When more than one network address is plausibly reachable (for example a
Tailscale address and a LAN address on the same machine), every candidate is
printed, ranked Tailscale first, then private LAN ranges, then anything
else; the QR code always encodes the first (best-ranked) one.

A session that lost the race for the port asks the host for a code and a
client token over the loopback `/join` endpoint, so every session is pairable
and not just the one that started first. Its output names the session to pick
from the app's list.

Relay pairing needs a client-facing secret that the relay operator issues,
which is not the same credential the plugin dials the relay with. Set
`OMP_REMOTE_CONTROL_TOKEN` to the relay's `OMP_RELAY_CONTROL_TOKEN`, and
`OMP_REMOTE_VIEWER_TOKEN` to its `OMP_RELAY_VIEWER_TOKEN`, for the
corresponding link to be available. Without them `/remote-omp relay` fails
and says which variable to set.

The agent token is never substituted for either. It authenticates at
`/agent` and can claim any `agentId`, which is more power than any client
link should carry, and the relay rejects it at `/client` anyway, so a link
built from it would be both unsafe and broken. Direct pairing has no such
gap: the local server mints two independent tokens at startup.

The pairing link is a live credential: it carries a bearer token good for
whichever role it names. It is rendered to the terminal UI only. It is never
written to a log line, never persisted to disk, and never appended to the
session transcript or sent to the model.

## Transports

### Relay

The plugin dials out to a relay's `/agent` WebSocket endpoint
(`OMP_REMOTE_RELAY_URL`) and presents `OMP_REMOTE_TOKEN` as its agent
credential. Neither the workstation nor the phone needs an inbound port;
this is the transport to use across networks the workstation cannot expose a
port on. Reconnection uses the extension's own managed timers
(`ctx.setTimeout`), never a raw `setTimeout`, so a reconnect-loop bug cannot
take the whole session down with it.

### Direct

The plugin runs its own WebSocket server (`OMP_REMOTE_LOCAL_PORT`, default
`8788`) serving `/client`, `/agent`, `/pair`, `/join`, and `/healthz` as
`docs/protocol.md` specifies. Tokens are minted at startup and handed out only
through a redeemed pairing code or a `/remote-omp` link, never logged. Use this
on a LAN or over Tailscale, where the phone can already reach the workstation;
no relay or third party is involved.

Every session on the machine shares that one port. The first to bind it hosts
the rest, which attach over `/agent` and appear in the same roster the app
would see through a relay. `/agent` and `/join` accept loopback only, so a
peer on the network cannot publish itself as one of this machine's sessions.
When the host exits, a remaining session takes the port within seconds and the
others rejoin it.

## Interactive requests

This plugin can raise an interactive request (`select`, `confirm`, `input`,
`editor`, `approval`) only where the `ExtensionAPI` genuinely gives it a
channel to do so. The scope is exactly this and nothing more:

**Covered:**

- This plugin's own tools and commands (the shadowed `ask` tool below, and
  any request this plugin's own code raises through `bridge.raiseRequest`).
- The built-in `ask` tool, via shadowing: `ask-shadow.ts` registers its own
  `ask` that turns each question into a `select` request over the wire when
  a control client is attached, and delegates to the native tool
  (`ctx.invokeTool`) when nothing is attached or the remote answer times out
  or is cancelled. The terminal picker keeps working unchanged in both
  cases.
- `tool_call` **deny**, when `OMP_REMOTE_REMOTE_APPROVAL=1`: an attached
  control client's `deny` answer blocks the tool before it runs, using the
  `tool_call` event's block-decision return.

**Not covered, with no interception point:**

- Prompts raised by other extensions.
- Prompts raised by omp itself through the host UI (for example a
  destructive-action confirmation the core TUI shows directly).

These are answered at the workstation and never appear to a remote client as
a `request`. There is no hook in `ExtensionAPI` that fires before them, so
this is not a bug to fix later; it is the real shape of the extension
surface.

### Approval is deny-only

The `tool_call` event that fires before a tool runs accepts a block decision
and nothing else. There is no corresponding channel to *approve* a tool past
the workstation's own gate. Consequently:

- `deny` from a remote control genuinely stops the tool. It never runs.
- `allow` and `always` mean only "this extension does not object". They do
  not approve anything by themselves. If the workstation's own approval
  gate would otherwise prompt for that tool call, it still prompts, and
  still has to be answered locally, regardless of what the phone sent.
  `always` only remembers, for the remainder of this session, not to ask the
  remote control again for that tool name; it has no effect on the local
  gate either.

A client integrating against this protocol must present `deny` and
`allow`/`always` differently, and must never claim that `allow` approved
anything.

## The `bash` gate

`OMP_REMOTE_ALLOW_BASH` defaults to `0`. A `bash` command is refused outright
while it is off, with an error naming exactly that. Turning it on is a
deliberate decision to let whoever holds the control token run arbitrary
shell commands on this workstation: the command runs through `Bun.spawn`
with an argument array (`/bin/sh -c <command>`, `<command>` as one opaque
argument, never concatenated into a larger shell line), its output streams
back as `bash_output` events coalesced to at most one emission per 100 ms,
and it can be cancelled with `abort_bash`. This is a remote shell, not a
sandboxed one; treat the control token as workstation-root-adjacent once
`OMP_REMOTE_ALLOW_BASH=1` is set.

## Known API gaps

A handful of wire commands name behavior that the real `ExtensionAPI` /
`ExtensionContext` surface cannot reach from where this plugin's command
dispatcher runs (`src/commands.ts`). Each fails explicitly with
`{ ok: false, error }` naming the missing method, rather than silently
no-op'ing or calling something that would throw at runtime:

- `set_fast_mode`, `set_steering_mode`, `set_follow_up_mode`,
  `set_interrupt_mode`, `cycle_model`, `stats`: these all live on
  `AgentSession`, which extensions never receive; `ExtensionContext` has no
  equivalent.
- `set_todos`, `set_auto_compaction`: same shape of gap. `AgentSession`
  exposes `setTodoPhases` / `setAutoCompactionEnabled`; `ExtensionContext`
  does not.
- `branch` (by `entryId`): the extended lifecycle surface
  (`ExtensionCommandContext.branch`, along with `newSession` and
  `switchSession`) is documented as valid only from inside a slash-command
  handler's own context, not the `ExtensionContext` a command dispatched off
  a `command` wire frame runs with. `new_session` and `switch_session` fail
  the same way and for the same reason.

- `run_command`: `ExtensionAPI` exposes no method to execute a slash
  command. Submitting `/name` through the prompt path was tried against a
  live session and does not work: the text reaches the model verbatim
  instead of being expanded, so the command never runs.

`commands` still works, but read its result for what it is: `getCommands()`
returns only extension, prompt, and skill commands. Built-ins such as
`/rename`, `/model`, and `/compact` are absent from it even though the
session has them, so the list is a subset and not an inventory of what the
session can do.

`compact` and reading commands (`state`, `history`, `tools`, `commands`,
`models`, `system_prompt`) are unaffected: `ExtensionContext` exposes
`compact()` directly, and the read-only surface is complete.

Two more gaps worth knowing about, both already reflected in the code
without changing wire behavior:

- `notice`, `model_changed`, and `thinking_changed` wire events have no
  dedicated `pi.on(...)` source; `notice` is only emitted by this plugin's
  own diagnostics, and model/thinking-change events would need to be
  synthesized by diffing state at turn boundaries (not yet wired, since
  nothing currently emits them).
- The `queued` field in the state snapshot reports presence
  (`ctx.hasPendingMessages()`, a boolean), not the real queued-message
  count: `ExtensionContext` has no counter, only a boolean.
