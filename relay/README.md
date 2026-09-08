# omp-remote relay

Go WebSocket hub implementing `docs/protocol.md`. Routes agent (workstation)
connections and client (phone) connections; interprets nothing about session
content.

## Running locally

```
export OMP_RELAY_AGENT_TOKEN=$(head -c 32 /dev/urandom | base64)
export OMP_RELAY_CONTROL_TOKEN=$(head -c 32 /dev/urandom | base64)
export OMP_RELAY_VIEWER_TOKEN=$(head -c 32 /dev/urandom | base64)  # optional
go run .
```

Listens on `:8787` by default. `go test -race ./...` runs the test suite.

## Running in Docker

```
cp .env.example .env
# edit .env with real tokens (head -c 32 /dev/urandom | base64)
docker compose up --build
```

The container has no shell (distroless), so the compose healthcheck runs the
relay binary itself with `-healthcheck`, which dials `/healthz` on localhost
and exits 0 or 1.

## Environment variables

| Variable                 | Required | Meaning                                          |
| ------------------------ | -------- | ------------------------------------------------- |
| `OMP_RELAY_ADDR`         | no       | Listen address, defaults to `:8787`                |
| `OMP_RELAY_AGENT_TOKEN`  | yes      | Bearer token an agent presents at `/agent`         |
| `OMP_RELAY_CONTROL_TOKEN`| yes      | Bearer token that grants a `control` role at `/client` |
| `OMP_RELAY_VIEWER_TOKEN` | no       | Bearer token that grants a `viewer` role at `/client`; when unset, viewer connections are refused |

The relay refuses to start if `OMP_RELAY_AGENT_TOKEN` or
`OMP_RELAY_CONTROL_TOKEN` is empty, rather than accepting everything.

## Security note

The relay trusts the `agentId` an agent claims at `hello`. Anyone holding the
agent token can register as any agent id, including one already in use (the
existing connection is evicted). Treat the agent token as a workstation
credential and run a separate relay deployment per trust domain.

## Keepalive

The relay pings every peer every 20 seconds and waits up to 10 seconds for
the pong, closing the connection when it does not come. That is the only
liveness check: reads have no deadline, because a client that is watching a
session and an agent whose session is idle both send nothing for minutes at
a time, and a per-read deadline closed exactly those connections once a
minute. Only the first frame is deadlined, at 15 seconds, so a connection
that authenticates and then says nothing does not hold a slot.
