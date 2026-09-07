# omp-remote wire protocol

Version `2`. Transport is WebSocket with one JSON object per message. UTF-8, no
binary frames.

Version 1 is gone. Nothing shipped on it, so there is no compatibility path.

## Topology

The same client-facing protocol runs over two transports. A client speaks one
wire format and does not care which one it is on.

### Relayed

```
omp process                     relay (docker)                 phone
+------------------+            +---------------+            +-------------+
| omp-remote       | ---- WS -> | /agent        |            |             |
| plugin (agent)   |            |     hub       | <- WS ---- | OMPRemote   |
+------------------+            | /client       |            |  (client)   |
                                +---------------+            +-------------+
```

Both sides dial out, so neither the workstation nor the phone needs an inbound
port. Use this across networks.

### Direct

```
omp process (host)                               phone
+-------------------------------+              +-------------+
| omp-remote plugin             | <-- WS ----- | OMPRemote   |
|   server on :8788             |              |  (client)   |
|   /client  /agent  /pair      |              +-------------+
+-------------------------------+
        ^
        | WS /agent
+-------------------------------+
| omp-remote plugin (guest)     |
|   another session, same box   |
+-------------------------------+
```

The plugin listens itself and the client dials it. No relay, no third party.
Use this on a LAN or over Tailscale, where the phone can already reach the
workstation. The plugin serves exactly the client-facing half of the protocol,
so the app's code path is identical: only the URL differs.

Both transports may run at once. A session can be relayed and directly
reachable at the same time.

### Several sessions on one workstation

One port carries them all. The first session to bind it becomes the host and
serves every client on the machine; a session that finds the port taken dials
the host on `/agent` instead, exactly as it would dial a relay. So the app
asks one address and sees every session, and the frames are the same either
way.

The host is whoever holds the port, and nothing else. When it exits, the
remaining sessions race to bind, one wins, and the others rejoin it. A guest
polls for that every few seconds, so a lost host costs seconds of visibility
rather than requiring a restart.

`/agent` and `/join` are loopback only. A session is by definition local, and
a peer on the network must not be able to publish itself as one.

Agent ids are distinct per session, since a repeated id reads as a reconnect
and evicts the older connection. The default appends a short process-derived
suffix to host and directory, as in `kim-thinkpad/omp-remote#k69j`.

## Endpoints

Relay:

| Path       | Method | Purpose                                |
| ---------- | ------ | -------------------------------------- |
| `/agent`   | GET    | WebSocket upgrade for a plugin         |
| `/client`  | GET    | WebSocket upgrade for an OMPRemote app |
| `/healthz` | GET    | Liveness probe, returns `ok`           |

Plugin, whichever session holds the port:

| Path       | Method | Purpose                                       |
| ---------- | ------ | --------------------------------------------- |
| `/client`  | GET    | WebSocket upgrade for an OMPRemote app        |
| `/agent`   | GET    | Another session on this machine, loopback only |
| `/pair`    | GET    | Pairing payload and roster, see Pairing       |
| `/join`    | GET    | Tokens for a local session, loopback only     |
| `/healthz` | GET    | Liveness probe, returns `ok`                  |

## Roles

Every client connection has a role, fixed at handshake time.

| Role      | Reads stream | Sends commands | Answers requests |
| --------- | ------------ | -------------- | ---------------- |
| `control` | yes          | yes            | yes              |
| `viewer`  | yes          | no             | no               |

A viewer is a spectator. Its `command` and `response` frames are rejected with
`error: "read-only connection"` and never reach the agent. The role is derived
from which token authenticated the connection, never from anything the client
claims, so a viewer cannot promote itself by sending a different `role` value.

Multiple controls may connect at once. They all see the same stream and any of
them may answer an interactive request; the first answer wins and the others
are told the request is gone.

## Authentication

Three secrets, each granting a different thing.

| Secret         | Relay env                 | Grants                          |
| -------------- | ------------------------- | ------------------------------- |
| agent token    | `OMP_RELAY_AGENT_TOKEN`   | registering as an agent         |
| control token  | `OMP_RELAY_CONTROL_TOKEN` | a `control` client connection   |
| viewer token   | `OMP_RELAY_VIEWER_TOKEN`  | a `viewer` client connection    |

`OMP_RELAY_VIEWER_TOKEN` is optional. When it is empty, viewer connections are
refused entirely and only control clients can attach.

A connection presents its token as `Authorization: Bearer <token>`, or as a
`token` query parameter when the client stack cannot set headers on an upgrade
request. Comparison is constant time and every token is compared, so response
timing does not reveal which one matched. A missing or unrecognized token gets
`401` before the upgrade.

The plugin's local server uses its own pair of tokens, generated at startup and
handed out by the pairing payload. It has no agent token because there is no
agent connection to authenticate: the agent is the server.

The relay trusts the `agentId` an agent claims. Anyone holding the agent token
can therefore impersonate an agent id; treat it as a workstation credential and
run a separate deployment per trust domain.

## Pairing

`/remote-omp` in an omp session prints a QR code and a link. Scanning or opening
it configures the app with no typing.

The link is a URI in the app's scheme:

```
remote-omp://pair?v=2&t=direct&url=ws%3A%2F%2F100.64.0.3%3A8788&token=<token>&role=control&agent=kim-thinkpad%2Fomp-remote&name=omp-remote
```

| Parameter | Required | Meaning                                             |
| --------- | -------- | --------------------------------------------------- |
| `v`       | yes      | Protocol version, `2`                                |
| `t`       | yes      | `direct` or `relay`                                  |
| `url`     | yes      | WebSocket origin, without the `/client` path         |
| `token`   | yes      | The token for the requested role                     |
| `role`    | yes      | `control` or `viewer`                                |
| `agent`   | relay    | Agent id to subscribe to; absent for direct          |
| `name`    | no       | Display name for the connection                      |

The token is in the link, so the link is a credential. It is shown on the
workstation's own screen and is not logged, and the QR is not written to disk.
`/remote-omp viewer` emits a viewer link instead of a control link, which is the
one to hand to someone who should only watch.

### Pairing codes

Copying a 64-character token by hand is the fallback nobody wants, so the local
server also issues a short code standing for one. `/remote-omp` prints it
alongside the QR.

A code is six characters from `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, Crockford
base32 without `I`, `L`, `O`, and `U`, so no two characters are confusable when
read off one screen and typed into another. It is single use and expires five
minutes after being issued. Those two properties are what make six characters
enough: an attacker gets one guess per issued code out of 32^6.

```
GET /pair?code=HZE6VD
```

```jsonc
{ "v": 2, "t": "direct", "url": "ws://100.64.0.3:8788", "name": "omp-remote",
  "agent": "kim-thinkpad/omp-remote#k69j",
  "agents": [
    { "agentId": "kim-thinkpad/omp-remote#k69j", "name": "omp-remote" },
    { "agentId": "kim-thinkpad/api#m2rx", "name": "api" }
  ],
  "role": "control", "token": "0266e40e..." }
```

A redeemed payload is the discovery payload plus the token, so the client
that redeems a code learns every session on the workstation and picks the one
it was pointed at. Working directories are absent here for the same reason
they are absent from discovery.

An unknown, reused, or expired code gets `404` with
`{"error": "unknown or expired pairing code"}`. Codes are direct-only: a
relayed client cannot reach the local server to redeem one.

### Pairing from a guest session

A session that lost the race for the port has no server, so it cannot issue a
code or a token of its own. It asks the host for both over `/join`, and prints
them as if it had. Without this only the session that happened to start first
would be pairable.

```
GET /join?code=control
```

```jsonc
{ "v": 2, "token": "<agent token>", "code": "HZE6VD",
  "expiresAt": 1788546521000, "url": "ws://100.64.0.3:8788",
  "role": "control", "clientToken": "0266e40e..." }
```

`token` is the agent token, which is what a guest dials `/agent` with.
`clientToken` is the client token for the requested role, so the guest can
print a working QR rather than one that cannot authenticate. Both are secrets
the host already holds, and the endpoint is loopback only, so a guest learns
nothing a process on the same machine could not read from the config.

The guest builds its link against a reachable interface, not the address the
host reports. A host that bound loopback reports `127.0.0.1`, which no phone
can dial.

### Discovery

`GET /pair` without a code returns the payload minus `token`, plus the roster
of every session the host serves. One request to one port is the whole of
discovery: there is no scan and no second listener.

```jsonc
{ "v": 2, "t": "direct", "url": "ws://100.64.0.3:8788", "name": "omp-remote",
  "agent": "kim-thinkpad/omp-remote#k69j",
  "agents": [
    { "agentId": "kim-thinkpad/omp-remote#k69j", "name": "omp-remote" },
    { "agentId": "kim-thinkpad/api#m2rx", "name": "api" }
  ],
  "role": "control" }
```

`agent` names the host's own session. Working directories are deliberately
absent: this endpoint answers anyone who can reach the port, and a
filesystem path names a project and a user to the whole network. The agent
id already carries a project basename and a unique suffix, which is enough
to tell two sessions apart.

No token appears in a codeless response. The token travels only in the QR, the
link, or a redeemed code.

## Frame envelope

Every message is a flat object with a `t` discriminator. Fields not listed for a
type are absent.

```jsonc
{
  "t": "event",
  "agentId": "kim-thinkpad/omp-remote",
  "seq": 41,
  "event": { "k": "text_delta", "text": "Reading " }
}
```

`agentId` appears on relay-to-client frames. On the direct transport there is
exactly one agent, and the plugin still sets `agentId` so the client's parsing is
uniform.

### Agent to relay

| `t`              | Fields                        | Meaning                                    |
| ---------------- | ----------------------------- | ------------------------------------------ |
| `hello`          | `protocol`, `agentId`, `info` | First frame; registers or re-attaches      |
| `event`          | `seq`, `event`                | One normalized session event               |
| `state`          | `state`                       | Full state snapshot, replaces the last one |
| `reply`          | `id`, `ok`, `data` \| `error` | Result of a routed command                 |
| `request`        | `id`, `request`               | Interactive request needing a human answer |
| `request_cancel` | `id`, `reason`                | That request no longer needs an answer     |

`seq` is a per-agent counter starting at 1 and increasing by one per event. It
resets when the agent restarts, which a client detects as a `seq` at or below
what it already holds.

A `hello` therefore starts a new epoch. On every agent `hello`, including a
reconnect under an id the relay already knows, the relay discards that agent's
retained event ring and state snapshot, cancels its pending interactive
requests with reason `shutdown`, and closes any live connection still holding
that id. Without this, a `subscribe` with a `since` cursor would replay the
previous run's higher-numbered frames after the new run's `seq` 1, and a client
resuming normally would misread its own cursor as a restart.

### Relay to agent

| `t`         | Fields                | Meaning                                   |
| ----------- | --------------------- | ----------------------------------------- |
| `welcome`   | `protocol`, `agentId` | Registration accepted                     |
| `command`   | `id`, `cmd`, `args`   | Command from a control client             |
| `response`  | `id`, `response`      | Answer to an interactive request          |
| `viewers`   | `control`, `viewer`   | Connected client counts, on every change  |

The `id` an agent sees on a `command` is relay-scoped and opaque; echo it back
verbatim. The `id` on a `response` is the agent's own request id.

### Client to relay

| `t`           | Fields                         | Meaning                                   |
| ------------- | ------------------------------ | ----------------------------------------- |
| `hello`       | `protocol`, `clientId`, `name` | First frame                               |
| `subscribe`   | `agentId`, `since`             | Stream one agent, replaying after `since` |
| `unsubscribe` | `agentId`                      | Stop streaming that agent                 |
| `command`     | `id`, `agentId`, `cmd`, `args` | Command routed to the agent               |
| `response`    | `id`, `agentId`, `response`    | Answer to an interactive request          |

`since` of `0` requests the whole retained buffer. `name` is a display string
the workstation shows so a human knows who attached; it is untrusted and is
truncated to 64 characters.

### Relay to client

| `t`              | Fields                              | Meaning                             |
| ---------------- | ----------------------------------- | ----------------------------------- |
| `welcome`        | `protocol`, `clientId`, `role`, `agents` | Accepted, with role and roster |
| `agents`         | `agents`                            | Roster changed                      |
| `event`          | `agentId`, `seq`, `event`           | Forwarded or replayed event         |
| `state`          | `agentId`, `state`                  | Forwarded or replayed snapshot      |
| `reply`          | `id`, `ok`, `data` \| `error`       | Result for a command this client sent |
| `request`        | `agentId`, `id`, `request`          | Interactive request, needs an answer |
| `request_cancel` | `agentId`, `id`, `reason`           | That request is resolved or gone    |

Pending requests are part of an agent's retained state, so a client that
subscribes while a request is open receives it immediately after the state
snapshot. A late answer to an already-resolved request gets
`error: "request already answered"`.

## Agent info

Carried in `hello` and in every roster entry.

```jsonc
{
  "agentId": "kim-thinkpad/omp-remote",
  "name": "omp-remote",
  "host": "kim-thinkpad",
  "cwd": "/home/hyun/Projects/omp-remote",
  "online": true,
  "connectedAt": 1757203200000
}
```

## State snapshot

Sent whenever the session summary changes, and retained for replay. Optional
fields are omitted, never guessed.

```jsonc
{
  "sessionId": "0193...",
  "sessionName": "bootstrap remote control",
  "sessionFile": "/home/hyun/.omp/agent/sessions/....jsonl",
  "cwd": "/home/hyun/Projects/omp-remote",
  "model": { "provider": "anthropic", "id": "claude-sonnet-4-5" },
  "thinkingLevel": "medium",
  "streaming": false,
  "compacting": false,
  "queued": 0,
  "fastMode": { "enabled": false, "active": false },
  "autoCompaction": true,
  "steeringMode": "one-at-a-time",
  "followUpMode": "one-at-a-time",
  "interruptMode": "immediate",
  "contextUsage": { "tokens": 18422, "contextWindow": 200000, "percent": 9.2 },
  "todos": [{ "phase": "Scaffold", "content": "Write relay", "status": "pending" }],
  "pendingRequests": [{ "id": "req-3", "request": { "k": "confirm", "title": "Run tests?" } }],
  "viewers": { "control": 1, "viewer": 0 }
}
```

## Events

Session events are normalized by the plugin so the app never parses omp
internals. Every event is `{ "k": <kind>, ... }`.

| `k`                | Fields                                   | Source                          |
| ------------------ | ---------------------------------------- | ------------------------------- |
| `agent_start`      | none                                     | `agent_start`                   |
| `agent_end`        | `terminal`                               | `agent_end`                     |
| `turn_start`       | none                                     | `turn_start`                    |
| `turn_end`         | none                                     | `turn_end`                      |
| `text_delta`       | `text`                                   | `message_update` text delta     |
| `thinking_delta`   | `text`                                   | `message_update` thinking delta |
| `message`          | `role`, `text`, `thinking`               | `message_end`                   |
| `tool_start`       | `id`, `name`, `input`                    | `tool_execution_start`          |
| `tool_update`      | `id`, `text`                             | `tool_execution_update`         |
| `tool_end`         | `id`, `name`, `ok`, `text`               | `tool_execution_end`            |
| `todos`            | `todos`                                  | todo state change               |
| `notice`           | `level`, `text`                          | `notice`, UI notifications      |
| `status`           | `key`, `text`                            | `setStatus` from an extension   |
| `model_changed`    | `model`                                  | `model_changed`                 |
| `thinking_changed` | `thinkingLevel`                          | `thinking_level_changed`        |
| `compaction`       | `phase`                                  | auto-compaction start and end   |
| `retry`            | `phase`, `text`                          | auto-retry start and end        |
| `session_changed`  | `reason`, `sessionId`, `sessionName`     | start, switch, branch, tree     |
| `subagent`         | `id`, `name`, `phase`, `text`            | subagent lifecycle and progress |
| `bash_output`      | `id`, `text`                             | output of a client `bash` command |

`input` is truncated to 4 KiB and every `text` field to 16 KiB before it leaves
the plugin, so a large payload cannot blow the frame budget. Truncated values
end with `...` and the untruncated length is not reported.

## Interactive requests

This is how the phone answers what the terminal would have asked.

An agent raises a request, one or more controls see it, and the first valid
answer resolves it. If the workstation resolves it locally first, or the session
moves on, the agent sends `request_cancel`.

Request object:

```jsonc
{ "k": "select", "title": "Which branch?", "message": "...", "options": [
    { "label": "main", "description": "default branch" },
    { "label": "dev" }
  ], "timeout": 30000 }
```

| `k`        | Extra fields                                       | Answer shape            |
| ---------- | -------------------------------------------------- | ----------------------- |
| `select`   | `title`, `message`, `options[]`                    | `{ "index": 0 }`        |
| `confirm`  | `title`, `message`                                 | `{ "confirmed": true }` |
| `input`    | `title`, `message`, `placeholder`, `initial`       | `{ "value": "..." }`    |
| `editor`   | `title`, `initial`, `language`                     | `{ "value": "..." }`    |
| `approval` | `toolName`, `input`, `risk`                        | `{ "decision": "allow" \| "deny" \| "always" }` |

### What the plugin can actually raise

The extension API bounds this, and the bound is not obvious, so it is stated
here rather than discovered later.

- **Its own tools and commands** raise any kind freely.
- **`ask`** is covered by shadowing the built-in tool of that name. The plugin
  registers its own `ask`, serves the questions remotely, and delegates to the
  native tool when no control is attached or the remote answer times out.
- **`approval` is deny-only.** The extension surface that fires before a tool
  runs accepts a block decision and nothing else; the events that report an
  approval carry no channel to answer one. So `deny` genuinely stops the tool,
  while `allow` and `always` mean only that the plugin does not object. The
  workstation's own approval gate still runs and still has to be answered
  locally. A client MUST present these two decisions differently, and MUST NOT
  tell the user that `allow` approved anything.
- **Prompts raised by other extensions or by omp itself** through the host UI
  are not reachable. There is no interception point for them, so they are
  answered at the workstation and never appear as a `request`.

Every request carries `timeout` in milliseconds when one applies. A cancel
frame's `reason` is `answered_locally`, `timed_out`, `aborted`, or `shutdown`.

A `response` frame's `response` object must match the request kind's answer
shape. A mismatched answer is rejected with `error: "invalid response"` and the
request stays open.

## Commands

Issued by a control client, executed by the plugin in the live session. Every
command gets exactly one `reply`.

### Prompting and turn control

| `cmd`        | `args`                              | Reply `data`             |
| ------------ | ----------------------------------- | ------------------------ |
| `prompt`     | `{ text, deliverAs?, images? }`     | `{ accepted: true }`     |
| `steer`      | `{ text }`                          | `{ accepted: true }`     |
| `follow_up`  | `{ text }`                          | `{ accepted: true }`     |
| `abort`      | `{}`                                | `{ aborted: true }`      |

`deliverAs` is `steer`, `followUp`, or `aside`; omitted means a normal prompt
when idle and a steer while streaming. `images` is an array of data URLs, capped
at 4 entries and 4 MiB each.

### Reading the session

| `cmd`       | `args`                        | Reply `data`                         |
| ----------- | ----------------------------- | ------------------------------------ |
| `state`     | `{}`                          | the state snapshot                   |
| `history`   | `{ limit?, before? }`         | `{ messages, hasMore }`              |
| `stats`     | `{}`                          | `{ tokens, cost, duration, turns }`  |
| `tools`     | `{}`                          | `{ active, all }`                    |
| `commands`  | `{}`                          | `{ commands }`                       |
| `models`    | `{}`                          | `{ models, current }`                |
| `system_prompt` | `{}`                      | `{ sections }`                       |

`history` returns at most 200 messages; `before` pages backwards by message id.

### Changing session settings

| `cmd`             | `args`                     | Reply `data`             |
| ----------------- | -------------------------- | ------------------------ |
| `set_model`       | `{ provider, id }`         | `{ model }`              |
| `cycle_model`     | `{}`                       | `{ model }`              |
| `set_thinking`    | `{ level }`                | `{ thinkingLevel }`      |
| `set_fast_mode`   | `{ enabled }`              | `{ enabled, active }`    |
| `set_auto_compaction` | `{ enabled }`          | `{ enabled }`            |
| `set_steering_mode`   | `{ mode }`             | `{ mode }`               |
| `set_follow_up_mode`  | `{ mode }`             | `{ mode }`               |
| `set_interrupt_mode`  | `{ mode }`             | `{ mode }`               |
| `set_active_tools` | `{ names }`               | `{ active }`             |
| `set_todos`       | `{ phases }`               | `{ todos }`              |

`level` is `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`.
Steering and follow-up modes are `all` or `one-at-a-time`; interrupt mode is
`immediate` or `wait`.

### Session lifecycle

| `cmd`             | `args`                    | Reply `data`                 |
| ----------------- | ------------------------- | ---------------------------- |
| `new_session`     | `{}`                      | `{ sessionId }`              |
| `switch_session`  | `{ sessionFile }`         | `{ sessionId }`              |
| `list_sessions`   | `{ limit? }`              | `{ sessions }`               |
| `branch`          | `{ entryId }`             | `{ sessionId }`              |
| `compact`         | `{ instructions? }`       | `{ compacted: true }`        |
| `set_session_name`| `{ name }`                | `{ sessionName }`            |

### Running things

| `cmd`         | `args`                | Reply `data`                     |
| ------------- | --------------------- | -------------------------------- |
| `bash`        | `{ command }`         | `{ id }`, output as `bash_output` events |
| `abort_bash`  | `{ id }`              | `{ aborted: true }`              |

There is no command that invokes a slash command remotely. The extension API
exposes no method to execute one, and submitting `/name` through the prompt
path was tested and does not work: it reaches the model as literal text
instead of being expanded. Running one is a workstation action.

`commands` returns a subset, not an inventory: the extension API lists only
extension, prompt, and skill commands, so built-ins the session really has
(`/rename`, `/model`, `/compact`) do not appear. A client MUST present the
result as a reference list and MUST NOT imply it is everything available.

`bash` is a remote shell on the workstation. It runs only for a `control`
connection and is refused when the plugin is started with
`OMP_REMOTE_ALLOW_BASH=0`, which is the default. Turning it on is a deliberate
decision to let whoever holds the control token run commands on the machine.

### Errors

A command for an agent that is not connected fails with
`{ "ok": false, "error": "agent offline" }`. A command from a viewer fails with
`read-only connection`. An unknown `cmd`, malformed `args`, or a value failing
validation fails with a message naming the problem. A command whose reply never
arrives times out after 60 seconds with `command timed out`.

## Limits

- At most 1 MiB per inbound message; a larger one closes the connection.
- Each agent retains its most recent 512 event frames, one state snapshot, and
  all currently pending interactive requests.
- A connection whose outbound queue exceeds 256 frames is closed as too slow.
- Both sides ping every 20 seconds and time out after 60.
- `bash` output is coalesced into at most one `bash_output` event per 100 ms.
