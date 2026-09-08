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

Nothing else is needed. Out of the box the extension serves this workstation
directly on port 8788 and uses no relay: `/remote` prints a QR code the
app scans over your LAN or Tailscale.

## Configuration

Settings live in `~/.omp/agent/omp-remote.json` (or
`$PI_CODING_AGENT_DIR/omp-remote.json`, or the exact path in
`OMP_REMOTE_CONFIG`), written at mode 0600 because it holds relay
credentials. Change it with `/remote config` rather than by hand. No
setting is read from the environment.

```jsonc
{
  "local": { "enabled": true, "port": 8788, "bind": "0.0.0.0" },
  "allowBash": false,
  "remoteApproval": false
  // "relay": { "url": "wss://relay.example/agent", "token": "...",
  //            "controlToken": "...", "viewerToken": "..." }
}
```

| Setting          | Default     | Meaning                                                                 |
| ---------------- | ----------- | ------------------------------------------------------------------------ |
| `relay`          | absent      | Route through a relay as well as serving directly. Absent means direct only. |
| `local.enabled`  | `true`      | Serve this workstation directly.                                        |
| `local.port`     | `8788`      | The port every session on this machine shares. The first to bind it serves the rest. |
| `local.bind`     | `0.0.0.0`   | Bind address for the direct server.                                     |
| `allowBash`      | `false`     | Allow the `bash` command to run real shell commands on this workstation. |
| `remoteApproval` | `false`     | Let an attached control client's `deny` answer block a tool call before it runs. |

An unreadable file, a malformed value, or a relay entry missing its URL or
token falls back to that row's default: a corrupt settings file leaves you
with working direct serving rather than a failed session.

The agent id is always `<hostname>/<cwd basename>#<pid suffix>`. It is not
configurable: it has to stay unique across the sessions sharing one port.

Both transports may be active at once. A session with a relay configured is
simultaneously relayed and directly reachable, exactly as
`docs/protocol.md`'s Topology section describes.

## The `/remote` command

One command owns pairing, settings, and diagnostics: two names for one
plugin only made the user guess which.

Bare, it prints a terminal QR code, a six-character pairing code, and a link
for the OMPRemote app (`docs/protocol.md`, "Pairing"). The code is what makes
pairing without a camera bearable: six characters typed into the app instead
of a 64-character token copied by hand. It is redeemed at
`GET /pair?code=...`, works once, and expires after five minutes. Relay
pairing has no code, since a relayed client cannot reach the local server.

- Bare (`/remote`): a **control** link. Direct is preferred whenever the
  local server is up; falls back to relay otherwise.
- `/remote viewer`: a **viewer** (read-only) link instead of control.
- `/remote relay`: forces the relay form of the link even when the local
  server is up.
- `/remote status`: agent id, whether the relay connection is up and to which
  host, the local server's port and attached client counts, and a running
  event counter. Diagnostic only, and registered even when both transports
  are disabled, so it always tells you why nothing is reachable.
- `/remote config`: shows the current settings and how to change each of
  them. No token is ever echoed back, only whether one is set.
- `/remote config relay <url> <token>`: routes this session through a
  relay as well as serving directly, and connects immediately. Pointing at a
  different relay drops the role tokens, since those belong to whichever
  relay issued them.
- `/remote config relay off`: back to direct only.
- `/remote config port|bind|direct|bash|approval`: the remaining
  settings. The reply says when a change needs a restart, which is the case
  for anything the already-bound listening socket owns.

When more than one network address is plausibly reachable (for example a
Tailscale address and a LAN address on the same machine), every candidate is
printed, ranked Tailscale first, then private LAN ranges, then anything
else; the QR code always encodes the first (best-ranked) one.

A session that lost the race for the port asks the host for a code and a
client token over the loopback `/join` endpoint, so every session is pairable
and not just the one that started first. Its output names the session to pick
from the app's list.

Relay pairing needs a client-facing secret that the relay operator issues,
which is not the same credential the plugin dials the relay with. Run
`/remote config relay control <token>` with the relay's
`OMP_RELAY_CONTROL_TOKEN`, and `/remote config relay viewer <token>` with
its `OMP_RELAY_VIEWER_TOKEN`, for the corresponding link to be available.
Without them `/remote relay` fails and says which one to set.

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
(the `relay.url` setting) and presents `relay.token` as its agent
credential. Neither the workstation nor the phone needs an inbound port;
this is the transport to use across networks the workstation cannot expose a
port on. Reconnection uses the extension's own managed timers
(`ctx.setTimeout`), never a raw `setTimeout`, so a reconnect-loop bug cannot
take the whole session down with it.

### Direct

The plugin runs its own WebSocket server (the `local.port` setting, default
`8788`) serving `/client`, `/agent`, `/pair`, `/join`, and `/healthz` as
`docs/protocol.md` specifies. Tokens are minted at startup and handed out only
through a redeemed pairing code or a `/remote` link, never logged. Use this
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
- `tool_call` **deny**, when `remoteApproval` is on: an attached
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

`allowBash` defaults to false. A `bash` command is refused outright
while it is off, with an error naming exactly that. Turning it on is a
deliberate decision to let whoever holds the control token run arbitrary
shell commands on this workstation: the command runs through `Bun.spawn`
with an argument array (`/bin/sh -c <command>`, `<command>` as one opaque
argument, never concatenated into a larger shell line), its output streams
back as `bash_output` events coalesced to at most one emission per 100 ms,
and it can be cancelled with `abort_bash`. This is a remote shell, not a
sandboxed one; treat the control token as workstation-root-adjacent once
`allowBash` is turned on.

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
- `branch` (by `entryId`): needs `AgentSession`-level branch-by-entry
  tracking that no extension surface exposes.
- `run_command`: `ExtensionAPI` exposes no method to execute a slash
  command. Submitting `/name` through the prompt path was tried against a
  live session and does not work: the text reaches the model verbatim
  instead of being expanded, so the command never runs.

`new_session`, `end_session`, and `switch_session` do work, by a narrower
route: they need `ExtensionCommandContext`, which only a slash-command
handler receives, so the bridge keeps the one `/remote` was last invoked
with. `/remote` is how a session gets paired, so it is present whenever a
client can ask; a session paired some other way gets an error naming what to
run. `ctx.shutdown()` is not that route: it is documented as a request the
host may ignore, and it is ignored in both TUI and RPC mode, so ending a
session leaves it for a fresh one instead.

Role model assignments are reachable, by a different route: they are
settings, not session state, so `src/model-roles.ts` reaches the live
`Settings` singleton the host initialized at startup. Writing a second,
separately loaded copy would disagree with the running session; writing the
live one means the next turn resolves `@role` to the new model and the
workstation's own UI sees the same change. Core's built-in role list is not
exported from the package root and the deep path is not published, so that
list is named in `model-roles.ts` and unioned with whatever roles config.yml
already holds.

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

- `notice` has no dedicated `pi.on(...)` source; it is only emitted by this
  plugin's own diagnostics. `model_changed` and `thinking_changed` are
  emitted by the commands that make those changes, since a client watching
  the session should not have to wait for a turn boundary to see one.
- The `queued` field in the state snapshot reports presence
  (`ctx.hasPendingMessages()`, a boolean), not the real queued-message
  count: `ExtensionContext` has no counter, and
  `AgentSession.getQueuedMessages()` is not reachable, so the queue's
  contents cannot be read or edited from here. A mid-turn prompt is queued
  as `steer`, which keeps it in the queue the workstation renders and can
  edit while still delivering it at the agent's next step.
