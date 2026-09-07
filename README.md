# omp-remote

Remote control for an [oh-my-pi](https://github.com/oh-my-pi) coding session:
watch a running `omp` from a phone, read its stream, and send prompts back.

Three parts, one repository.

| Directory  | What it is                                                              |
| ---------- | ----------------------------------------------------------------------- |
| `plugin/`  | An omp extension. Loads into a session, streams it to a relay.           |
| `relay/`   | A Go WebSocket hub. Runs in Docker, routes between agent and client.     |
| `app/`     | Remote-OMP, a Flutter client for Android and iOS.                        |

Two ways to connect, same client protocol either way. Through the relay,
where both sides dial out and neither end needs an inbound port. Or directly
to the plugin's own WebSocket server, with no relay at all, which is the one
to use over Tailscale or on a LAN.

The wire format is in [`docs/protocol.md`](docs/protocol.md). Read it before
changing anything that crosses a process boundary.

## Running the relay

```sh
cd relay
cp .env.example .env    # then edit the tokens
docker compose up -d --build
curl localhost:8787/healthz
```

Generate tokens with `openssl rand -hex 32`. There are three: agent, control,
and viewer. The viewer token is optional and grants read-only spectating. The
agent token is a workstation credential: anyone holding it can claim any
`agentId`. Terminate TLS in front of the relay and hand out `wss://` URLs;
tokens travel in the request and the frames are session content.

## Loading the plugin

```sh
cd plugin
bun install
omp --extension ./plugin
```

Configure it through the environment, or permanently through
`~/.omp/agent/config.yml`:

```sh
export OMP_REMOTE_RELAY_URL=wss://relay.example.com
export OMP_REMOTE_TOKEN=<agent token>
export OMP_REMOTE_AGENT_ID=kim-thinkpad/omp-remote   # optional
```

The local server runs by default on port 8788, which is what makes a
relayless connection possible. `OMP_REMOTE_LOCAL=0` turns it off.

`/remote-omp` prints a QR code and a pairing link that carries the URL, a
generated token, and the role. `/remote-omp viewer` prints a read-only link
instead. `/remote` reports link status.

Direct pairing works out of the box: the local server mints its own control
and viewer tokens. Relay pairing needs the relay's client tokens passed
through as `OMP_REMOTE_CONTROL_TOKEN` and `OMP_REMOTE_VIEWER_TOKEN`; the
agent token is not a substitute and the relay will not accept it as a client.

## Building the app

Android needs the Android SDK; iOS needs macOS with Xcode.

```sh
cd app
flutter pub get
flutter run -d <device-id>
```

Scan the QR from `/remote-omp` to configure the connection. Manual entry is
available as a fallback. Saved profiles live in `shared_preferences`.

## Development

- Go 1.27, Bun 1.4, Flutter 3.47 / Dart 3.13, targeting Android and iOS.
- `relay/`: `go test ./...`, `go vet ./...`.
- `plugin/`: `bun run typecheck`.
- `app/`: `flutter analyze`, `flutter test`.
