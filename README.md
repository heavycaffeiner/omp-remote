# omp-remote

Drive a running [oh-my-pi](https://github.com/can1357/oh-my-pi) coding session
from your phone. Read the stream as it happens, send prompts, and answer the
questions the agent would otherwise ask at your keyboard.

| Directory | What it is                                                          |
| --------- | ------------------------------------------------------------------- |
| `plugin/` | An omp extension. Loads into a session and serves it.               |
| `relay/`  | A Go WebSocket hub in Docker, for when the phone cannot reach you.  |
| `app/`    | OMPRemote, a Flutter client for Android and iOS.                    |

## Two ways to connect

**Direct.** The plugin listens on port 8788 and the phone dials it. No relay,
no third party, nothing to deploy. Use this on a LAN or over Tailscale. This is
the path to start with.

**Relayed.** Both the workstation and the phone dial out to a relay you run,
so neither needs an inbound port. Use this when the phone cannot reach the
workstation at all.

The app speaks one protocol either way and does not care which it is on. The
wire format is in [`docs/protocol.md`](docs/protocol.md).

## Install

### 1. The plugin

Needs omp 18.1.11 or newer.

```sh
omp plugin install github:heavycaffeiner/omp-remote
```

That is the whole installation. The plugin loads itself in every session
afterwards, starts its local server on port 8788, and is ready to pair.
Everything below is optional.

To pin a version or a branch, append a ref:

```sh
omp plugin install github:heavycaffeiner/omp-remote#v0.0.1
```

Upgrade and removal go the same way:

```sh
omp plugin upgrade omp-remote
omp plugin uninstall omp-remote
```

To work on the plugin instead of just using it, clone it and load the working
copy, which takes precedence over anything installed:

```sh
git clone https://github.com/heavycaffeiner/omp-remote.git
cd omp-remote && bun install
omp --extension .
```

### 2. The app

Prebuilt Android APKs are attached to each
[release](https://github.com/heavycaffeiner/omp-remote/releases). Download
`remote-omp-<version>.apk` and install it.

To build it yourself, or to run on iOS:

```sh
cd app
flutter pub get
flutter run -d <device-id>
```

Android needs the Android SDK. iOS needs macOS with Xcode, plus
`cd ios && pod install`.

### 3. The relay, only if you need one

Skip this if the phone can already reach your workstation.

The relay ships as a container image for `linux/amd64` and `linux/arm64`.
Generate three tokens, then run it:

```sh
openssl rand -hex 32   # once per token
```

```sh
docker run -d -p 8787:8787 \
  -e OMP_RELAY_AGENT_TOKEN=... \
  -e OMP_RELAY_CONTROL_TOKEN=... \
  -e OMP_RELAY_VIEWER_TOKEN=... \
  ghcr.io/heavycaffeiner/omp-remote-relay:latest
```

```sh
curl localhost:8787/healthz     # expect: ok
```

To build it from source instead, `relay/compose.yaml` reads the same three
variables from a `.env` file:

```sh
cd relay && cp .env.example .env
docker compose up -d --build
```

Put TLS in front of it and hand out `wss://` URLs. Tokens travel in the
upgrade request and the frames are your session content.

## Use it

Start omp with the plugin loaded, then:

```
/remote-omp
```

A QR code appears. Scan it with the app and you are connected.

If the camera is not an option, the same output carries a six-character code:

```
    Address:  100.64.0.3:8788
    Code:     HZE6VD
```

In the app choose "Enter a code" and type those. The code works once and
expires in five minutes. This beats copying a 64-character token by hand,
which is what the raw link would otherwise ask of you.

```
/remote-omp viewer    a read-only code and link, for someone who should only watch
/remote-omp relay     force the relay form even when direct is available
/remote               transport status: what is connected and who is attached
```

The plugin picks a reachable address for you, preferring Tailscale, then your
LAN. When several would work it prints them all and you pick.

### Several sessions at once

Run omp in as many directories as you like. Each session takes its own port,
starting at 8788 and moving up, and identifies itself distinctly, so a phone
can hold them all and switch between them. The app finds them by asking each
port in that range who is there; nothing extra is listening for discovery.

On a relay every session appears in one roster and you pick from it.

### What you can do from the phone

Read the transcript as it streams, including thinking blocks and tool calls.
Send a prompt, steer a running turn, or abort it. Change the model or the
thinking level. Compact the context. Watch the todo list.

You can also answer the agent. When it asks a question through the `ask` tool,
that question arrives on your phone and your answer completes the tool call.
The turn continues without you touching the keyboard.

### Watching without touching

A viewer link connects read-only. Viewers see the whole stream and any pending
question, but every command and answer they try is refused. The role comes from
which token authenticated the connection, so a viewer cannot promote itself.

Viewer links only exist for direct pairing out of the box. Over a relay they
need `OMP_REMOTE_VIEWER_TOKEN` set to the relay's own viewer token.

## Configuration

All optional. The plugin works unconfigured.

| Variable                    | Default        | Meaning                                        |
| --------------------------- | -------------- | ---------------------------------------------- |
| `OMP_REMOTE_LOCAL`          | `1`            | `0` disables the local server                   |
| `OMP_REMOTE_LOCAL_PORT`     | `8788`         | Local server port                               |
| `OMP_REMOTE_LOCAL_BIND`     | `0.0.0.0`      | Local server bind address                       |
| `OMP_REMOTE_AGENT_ID`       | `<host>/<dir>` | How this session identifies itself              |
| `OMP_REMOTE_RELAY_URL`      | unset          | `ws://` or `wss://` relay, enables the uplink   |
| `OMP_REMOTE_TOKEN`          | unset          | Agent token, required with a relay URL          |
| `OMP_REMOTE_CONTROL_TOKEN`  | unset          | Relay's control token, for relay pairing links  |
| `OMP_REMOTE_VIEWER_TOKEN`   | unset          | Relay's viewer token, for relay viewer links    |
| `OMP_REMOTE_ALLOW_BASH`     | `0`            | `1` lets a control client run shell commands    |
| `OMP_REMOTE_REMOTE_APPROVAL`| `0`            | `1` forwards tool approvals to the phone        |

## Security

**The pairing link is a credential.** It carries a bearer token for the role it
names. It is rendered to your terminal and never logged or written to disk, but
anyone who reads the QR gets that access.

**The agent token is a workstation credential.** Anyone holding it can register
as any agent id on your relay. It is not a client token and the relay will not
accept it as one.

**`bash` is off by default.** Turning it on lets whoever holds the control
token run shell commands on your machine. That is the whole point of the flag,
so decide deliberately.

**Approval forwarding is deny-only, and off by default.** A remote `deny`
genuinely blocks a tool. A remote `allow` only means the plugin does not
object: omp's own approval gate still runs and still has to be answered at the
workstation. The app labels these accordingly.

## Limits

Known, and unlikely to change without upstream API work.

- **Slash commands cannot be run remotely.** The extension API exposes no way
  to invoke one, and submitting `/name` as a prompt sends it to the model as
  text instead of running it. The app lists commands for reference only.
- **The command list is partial.** It covers extension, prompt, and skill
  commands. Built-ins like `/rename` and `/model` are not enumerated.
- **Some settings are unreachable.** `set_fast_mode`, `set_steering_mode`,
  `set_follow_up_mode`, `set_interrupt_mode`, `cycle_model`, `stats`,
  `set_todos`, `set_auto_compaction`, `new_session`, `switch_session`, and
  `branch` live on a session object extensions never receive. Each fails with
  an explicit error rather than pretending to work.
- **Prompts from other extensions are not forwarded.** Only this plugin's own
  tools, the shadowed `ask`, and tool denials reach your phone.
- **The app has not been run on a device by its authors.** It analyzes clean
  and its tests pass, but the layout is unverified on real hardware.

## Development

```sh
bun install && bun run typecheck          # plugin
cd relay && go test ./... && go vet ./... # relay
cd app   && flutter analyze && flutter test
```

Go 1.27, Bun 1.4, Flutter 3.47 with Dart 3.13.

### Releasing

Pushing a `v*` tag builds the relay image for `linux/amd64` and `linux/arm64`,
builds a signed APK, and attaches it to a GitHub release. The signing key is
held in repository secrets; the workflow fails rather than falling back to the
debug key, since a debug-signed APK cannot be upgraded in place later.

## License

MIT. See [LICENSE](LICENSE).
