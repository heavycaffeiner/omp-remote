package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
)

const (
	maxMessageBytes = 1 << 20 // 1 MiB
	// Only the first frame is deadlined; see readFrame.
	helloTimeout = 15 * time.Second
	pingInterval = 20 * time.Second
	writeTimeout = 10 * time.Second

	statusTooSlow          = websocket.StatusPolicyViolation
	statusProtocolMismatch = websocket.StatusPolicyViolation
	statusTakeover         = websocket.StatusNormalClosure
)

// outConn wraps a websocket.Conn with a bounded outbound queue and a
// dedicated writer goroutine, so a slow or dead peer can never block the
// hub or any other connection. trySend is non-blocking: a full queue means
// the connection is too slow and gets closed rather than growing without
// bound.
type outConn struct {
	ws        *websocket.Conn
	send      chan []byte
	closeOnce sync.Once
	closed    chan struct{}
}

func newOutConn(ws *websocket.Conn) *outConn {
	return &outConn{
		ws:     ws,
		send:   make(chan []byte, outboundQueueCap),
		closed: make(chan struct{}),
	}
}

// trySend enqueues a frame for the writer goroutine. It returns false if
// the connection is closed or its queue is already full; the caller (the
// hub) treats false as "too slow" and closes the connection.
func (o *outConn) trySend(frame []byte) bool {
	select {
	case <-o.closed:
		return false
	default:
	}
	select {
	case o.send <- frame:
		return true
	default:
		return false
	}
}

// closeAsync closes the underlying connection without blocking the caller.
// It is safe to call multiple times and from any goroutine, including from
// inside the hub while holding its lock.
func (o *outConn) closeAsync(code websocket.StatusCode, reason string) {
	o.closeOnce.Do(func() {
		close(o.closed)
		go o.ws.Close(code, reason)
	})
}

// writePump drains the outbound queue to the wire. It exits when the
// connection closes or a write fails, and closes the connection on the way
// out so the read loop unwinds too.
func (o *outConn) writePump() {
	for frame := range o.send {
		ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
		err := o.ws.Write(ctx, websocket.MessageText, frame)
		cancel()
		if err != nil {
			o.closeAsync(websocket.StatusInternalError, "write failed")
			return
		}
		select {
		case <-o.closed:
			return
		default:
		}
	}
}

// pinger sends a periodic ping so a dead peer is detected even when
// otherwise idle. A failed ping closes the connection.
func (o *outConn) pinger() {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-o.closed:
			return
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
			err := o.ws.Ping(ctx)
			cancel()
			if err != nil {
				o.closeAsync(websocket.StatusGoingAway, "ping failed")
				return
			}
		}
	}
}

// readFrame blocks for the next message under the protocol's size limit.
//
// There is deliberately no read deadline. A client that is only watching a
// session, and an agent whose session is idle, both send nothing for minutes
// at a time; a per-read deadline closed exactly those connections once a
// minute, and each reconnect replayed the session again. Liveness is the
// pinger's job: Ping waits for the pong and closes the connection when it
// does not come.
func readFrame(ws *websocket.Conn) ([]byte, error) {
	_, raw, err := ws.Read(context.Background())
	return raw, err
}

// readHelloFrame reads the first frame under a deadline: a connection that
// authenticates and then says nothing must not sit here holding a slot.
func readHelloFrame(ws *websocket.Conn) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), helloTimeout)
	defer cancel()
	_, raw, err := ws.Read(ctx)
	return raw, err
}

func acceptOptions() *websocket.AcceptOptions {
	return &websocket.AcceptOptions{
		// Bearer token auth is the real trust boundary here; connections
		// come from native workstation and mobile clients, not browser
		// pages where the Origin check guards against CSRF.
		InsecureSkipVerify: true,
	}
}

// agentHandler builds the /agent HTTP handler: auth before upgrade, then
// hand off to the agent connection lifecycle.
func agentHandler(hub *Hub, agentToken string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !checkAgentAuth(r, agentToken) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		ws, err := websocket.Accept(w, r, acceptOptions())
		if err != nil {
			return
		}
		ws.SetReadLimit(maxMessageBytes)
		runAgentConn(hub, ws)
	}
}

// clientHandler builds the /client HTTP handler: auth before upgrade,
// deriving the connection's role from which token matched.
func clientHandler(hub *Hub, controlToken, viewerToken string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		role, ok := checkClientAuth(r, controlToken, viewerToken)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		ws, err := websocket.Accept(w, r, acceptOptions())
		if err != nil {
			return
		}
		ws.SetReadLimit(maxMessageBytes)
		runClientConn(hub, ws, role)
	}
}

func runAgentConn(hub *Hub, ws *websocket.Conn) {
	oc := newOutConn(ws)
	go oc.writePump()
	go oc.pinger()

	raw, err := readHelloFrame(ws)
	if err != nil {
		oc.closeAsync(websocket.StatusProtocolError, "no hello received")
		return
	}
	t, err := envelopeType(raw)
	if err != nil || t != tHello {
		oc.closeAsync(statusProtocolMismatch, "first frame must be hello")
		return
	}
	var hello helloAgentIn
	if err := json.Unmarshal(raw, &hello); err != nil {
		oc.closeAsync(statusProtocolMismatch, "malformed hello")
		return
	}
	if hello.Protocol != ProtocolVersion {
		oc.closeAsync(statusProtocolMismatch, "protocol version mismatch")
		return
	}
	if hello.AgentID == "" {
		oc.closeAsync(statusProtocolMismatch, "agentId is required")
		return
	}
	var info AgentInfo
	if len(hello.Info) > 0 {
		if err := json.Unmarshal(hello.Info, &info); err != nil {
			oc.closeAsync(statusProtocolMismatch, "malformed info")
			return
		}
	}

	evicted, welcome := hub.RegisterAgent(hello.AgentID, info, oc, time.Now().UnixMilli())
	if evicted != nil {
		evicted.closeAsync(statusTakeover, "replaced by a new connection")
	}
	if !oc.trySend(welcome) {
		oc.closeAsync(statusTooSlow, "outbound queue full")
		return
	}

	defer hub.UnregisterAgent(hello.AgentID, oc)

	for {
		raw, err := readFrame(ws)
		if err != nil {
			oc.closeAsync(websocket.StatusNormalClosure, "")
			return
		}
		handleAgentFrame(hub, hello.AgentID, raw)
	}
}

func handleAgentFrame(hub *Hub, agentID string, raw []byte) {
	t, err := envelopeType(raw)
	if err != nil {
		return
	}
	switch t {
	case tEvent:
		var f eventIn
		if json.Unmarshal(raw, &f) != nil {
			return
		}
		hub.HandleAgentEvent(agentID, f.Seq, f.Event)
	case tState:
		var f stateIn
		if json.Unmarshal(raw, &f) != nil {
			return
		}
		hub.HandleAgentState(agentID, f.State)
	case tReply:
		var f replyIn
		if json.Unmarshal(raw, &f) != nil {
			return
		}
		hub.HandleAgentReply(f.ID, f.OK, f.Data, f.Error)
	case tRequest:
		var f requestIn
		if json.Unmarshal(raw, &f) != nil {
			return
		}
		hub.HandleAgentRequest(agentID, f.ID, f.Request)
	case tRequestCancel:
		var f requestCancelIn
		if json.Unmarshal(raw, &f) != nil {
			return
		}
		hub.HandleAgentRequestCancel(agentID, f.ID, f.Reason)
	default:
		log.Printf("relay: agent %s sent unknown frame type %q", agentID, t)
	}
}

func runClientConn(hub *Hub, ws *websocket.Conn, role Role) {
	oc := newOutConn(ws)
	go oc.writePump()
	go oc.pinger()

	raw, err := readHelloFrame(ws)
	if err != nil {
		oc.closeAsync(websocket.StatusProtocolError, "no hello received")
		return
	}
	t, err := envelopeType(raw)
	if err != nil || t != tHello {
		oc.closeAsync(statusProtocolMismatch, "first frame must be hello")
		return
	}
	var hello helloClientIn
	if err := json.Unmarshal(raw, &hello); err != nil {
		oc.closeAsync(statusProtocolMismatch, "malformed hello")
		return
	}
	if hello.Protocol != ProtocolVersion {
		oc.closeAsync(statusProtocolMismatch, "protocol version mismatch")
		return
	}

	welcome := hub.RegisterClient(oc, role, hello.ClientID)
	if !oc.trySend(welcome) {
		oc.closeAsync(statusTooSlow, "outbound queue full")
		return
	}

	defer hub.UnregisterClient(oc)

	for {
		raw, err := readFrame(ws)
		if err != nil {
			oc.closeAsync(websocket.StatusNormalClosure, "")
			return
		}
		handleClientFrame(hub, oc, raw)
	}
}

func handleClientFrame(hub *Hub, oc *outConn, raw []byte) {
	t, err := envelopeType(raw)
	if err != nil {
		return
	}
	switch t {
	case tSubscribe:
		var f subscribeIn
		if json.Unmarshal(raw, &f) != nil {
			return
		}
		hub.Subscribe(oc, f.AgentID, f.Since)
	case tUnsubscribe:
		var f unsubscribeIn
		if json.Unmarshal(raw, &f) != nil {
			return
		}
		hub.Unsubscribe(oc, f.AgentID)
	case tCommand:
		var f commandIn
		if json.Unmarshal(raw, &f) != nil {
			return
		}
		hub.HandleClientCommand(oc, f.ID, f.AgentID, f.Cmd, f.Args)
	case tResponse:
		var f responseIn
		if json.Unmarshal(raw, &f) != nil {
			return
		}
		hub.HandleClientResponse(oc, f.ID, f.AgentID, f.Response)
	default:
		log.Printf("relay: client sent unknown frame type %q", t)
	}
}
