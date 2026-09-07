package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const (
	testAgentToken   = "agent-secret"
	testControlToken = "control-secret"
	testViewerToken  = "viewer-secret"
)

// testRelay starts a real HTTP server backed by a fresh hub, matching
// main.go's wiring, with viewer auth optionally disabled.
func testRelay(t *testing.T, viewerToken string) *httptest.Server {
	t.Helper()
	hub := NewHub()
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthzHandler)
	mux.Handle("/agent", agentHandler(hub, testAgentToken))
	mux.Handle("/client", clientHandler(hub, testControlToken, viewerToken))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func wsURL(srv *httptest.Server, path, token string) string {
	return "ws" + strings.TrimPrefix(srv.URL, "http") + path + "?token=" + token
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", url, err)
	}
	t.Cleanup(func() { ws.Close(websocket.StatusNormalClosure, "") })
	return ws
}

func writeJSON(t *testing.T, ws *websocket.Conn, v any) {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := ws.Write(ctx, websocket.MessageText, b); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func readFrameT(t *testing.T, ws *websocket.Conn) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, raw, err := ws.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal %s: %v", raw, err)
	}
	return m
}

// readFrameOfType reads frames until one with the given "t" arrives,
// skipping others (used where an unrelated roster broadcast could race
// with the frame under test).
func readFrameOfType(t *testing.T, ws *websocket.Conn, want string) map[string]any {
	t.Helper()
	for i := 0; i < 10; i++ {
		f := readFrameT(t, ws)
		if f["t"] == want {
			return f
		}
	}
	t.Fatalf("did not see a %q frame within 10 reads", want)
	return nil
}

func connectAgent(t *testing.T, srv *httptest.Server, agentID string) *websocket.Conn {
	t.Helper()
	ws := dial(t, wsURL(srv, "/agent", testAgentToken))
	writeJSON(t, ws, map[string]any{
		"t": "hello", "protocol": ProtocolVersion, "agentId": agentID,
		"info": map[string]any{"name": agentID, "host": "h", "cwd": "/"},
	})
	welcome := readFrameOfType(t, ws, "welcome")
	if welcome["agentId"] != agentID {
		t.Fatalf("welcome agentId = %v, want %v", welcome["agentId"], agentID)
	}
	return ws
}

func connectClient(t *testing.T, srv *httptest.Server, token, clientID string) (*websocket.Conn, map[string]any) {
	t.Helper()
	ws := dial(t, wsURL(srv, "/client", token))
	writeJSON(t, ws, map[string]any{"t": "hello", "protocol": ProtocolVersion, "clientId": clientID})
	welcome := readFrameOfType(t, ws, "welcome")
	return ws, welcome
}

func TestAgentHelloWelcomeAndProtocolMismatch(t *testing.T) {
	srv := testRelay(t, testViewerToken)

	agentWS := connectAgent(t, srv, "workstation/proj")
	_ = agentWS

	// A second agent with a mismatched protocol version must be rejected
	// with a close, never a welcome.
	bad := dial(t, wsURL(srv, "/agent", testAgentToken))
	writeJSON(t, bad, map[string]any{"t": "hello", "protocol": 999, "agentId": "other"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, _, err := bad.Read(ctx)
	if err == nil {
		t.Fatal("expected read error after protocol mismatch, got none")
	}
	if code := websocket.CloseStatus(err); code == -1 {
		t.Fatalf("expected a close status, got err %v", err)
	}
}

func TestRoleAssignmentByToken(t *testing.T) {
	srv := testRelay(t, testViewerToken)

	_, controlWelcome := connectClient(t, srv, testControlToken, "phone-control")
	if controlWelcome["role"] != "control" {
		t.Fatalf("control token gave role %v, want control", controlWelcome["role"])
	}

	_, viewerWelcome := connectClient(t, srv, testViewerToken, "phone-viewer")
	if viewerWelcome["role"] != "viewer" {
		t.Fatalf("viewer token gave role %v, want viewer", viewerWelcome["role"])
	}
}

func TestAuthRejectionPath(t *testing.T) {
	srv := testRelay(t, testViewerToken)

	// Wrong token: 401, no upgrade.
	resp, err := http.Get(srv.URL + "/client?token=nonsense")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong token: status = %d, want 401", resp.StatusCode)
	}

	// Missing token: 401.
	resp, err = http.Get(srv.URL + "/client")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("missing token: status = %d, want 401", resp.StatusCode)
	}

	// Agent token presented at /client is not a client token: 401.
	resp, err = http.Get(srv.URL + "/client?token=" + testAgentToken)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("agent token at /client: status = %d, want 401", resp.StatusCode)
	}

	// Viewer token disabled entirely (empty env) refuses viewer connections.
	srvNoViewer := testRelay(t, "")
	resp, err = http.Get(srvNoViewer.URL + "/client?token=" + testViewerToken)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("viewer token with viewer auth disabled: status = %d, want 401", resp.StatusCode)
	}
}

func TestReplayAfterSubscribeWithSinceCursor(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	agentWS := connectAgent(t, srv, "agent-1")

	for seq := int64(1); seq <= 5; seq++ {
		writeJSON(t, agentWS, map[string]any{
			"t": "event", "seq": seq, "event": map[string]any{"k": "notice", "level": "info", "text": "x"},
		})
	}
	writeJSON(t, agentWS, map[string]any{
		"t": "state", "state": map[string]any{"sessionId": "s1", "cwd": "/"},
	})
	time.Sleep(50 * time.Millisecond) // let the hub apply agent frames before subscribing

	clientWS, _ := connectClient(t, srv, testControlToken, "c1")
	writeJSON(t, clientWS, map[string]any{"t": "subscribe", "agentId": "agent-1", "since": int64(2)})

	state := readFrameOfType(t, clientWS, "state")
	if state["agentId"] != "agent-1" {
		t.Fatalf("state agentId = %v", state["agentId"])
	}

	var seqs []float64
	for i := 0; i < 3; i++ {
		ev := readFrameOfType(t, clientWS, "event")
		seqs = append(seqs, ev["seq"].(float64))
	}
	if len(seqs) != 3 || seqs[0] != 3 || seqs[1] != 4 || seqs[2] != 5 {
		t.Fatalf("replayed seqs = %v, want [3 4 5]", seqs)
	}
}

func TestReplaySinceZeroGetsWholeBuffer(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	agentWS := connectAgent(t, srv, "agent-2")

	for seq := int64(1); seq <= 3; seq++ {
		writeJSON(t, agentWS, map[string]any{
			"t": "event", "seq": seq, "event": map[string]any{"k": "turn_start"},
		})
	}
	time.Sleep(50 * time.Millisecond)

	clientWS, _ := connectClient(t, srv, testControlToken, "c2")
	writeJSON(t, clientWS, map[string]any{"t": "subscribe", "agentId": "agent-2", "since": int64(0)})

	var seqs []float64
	for i := 0; i < 3; i++ {
		ev := readFrameOfType(t, clientWS, "event")
		seqs = append(seqs, ev["seq"].(float64))
	}
	if len(seqs) != 3 || seqs[0] != 1 || seqs[1] != 2 || seqs[2] != 3 {
		t.Fatalf("replayed seqs = %v, want [1 2 3]", seqs)
	}
}

func TestAgentRestartClearsRetainedBuffer(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	agentWS := connectAgent(t, srv, "agent-restart")

	for seq := int64(1); seq <= 5; seq++ {
		writeJSON(t, agentWS, map[string]any{
			"t": "event", "seq": seq, "event": map[string]any{"k": "notice", "level": "info", "text": "old"},
		})
	}
	writeJSON(t, agentWS, map[string]any{
		"t": "state", "state": map[string]any{"sessionId": "before", "cwd": "/"},
	})
	time.Sleep(50 * time.Millisecond)

	// The agent restarts: its seq counter goes back to 1. Retaining the
	// previous run's frames would replay seq 2..5 after the new seq 1 and
	// read as a restart to a client that is merely resuming.
	restarted := connectAgent(t, srv, "agent-restart")
	writeJSON(t, restarted, map[string]any{
		"t": "event", "seq": int64(1), "event": map[string]any{"k": "notice", "level": "info", "text": "new"},
	})
	writeJSON(t, restarted, map[string]any{
		"t": "state", "state": map[string]any{"sessionId": "after", "cwd": "/"},
	})
	time.Sleep(50 * time.Millisecond)

	clientWS, _ := connectClient(t, srv, testControlToken, "c-restart")
	writeJSON(t, clientWS, map[string]any{"t": "subscribe", "agentId": "agent-restart", "since": int64(0)})

	state := readFrameOfType(t, clientWS, "state")
	inner, _ := state["state"].(map[string]any)
	if inner == nil || inner["sessionId"] != "after" {
		t.Fatalf("replayed state = %v, want the post-restart snapshot", state["state"])
	}

	ev := readFrameOfType(t, clientWS, "event")
	if ev["seq"].(float64) != 1 {
		t.Fatalf("first replayed seq = %v, want 1", ev["seq"])
	}
	body, _ := ev["event"].(map[string]any)
	if body == nil || body["text"] != "new" {
		t.Fatalf("replayed event = %v, want the post-restart event", ev["event"])
	}

	// Nothing from the previous run may survive.
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	for {
		_, data, err := clientWS.Read(ctx)
		if err != nil {
			break
		}
		var f map[string]any
		if json.Unmarshal(data, &f) != nil {
			continue
		}
		if f["t"] != "event" {
			continue
		}
		if b, _ := f["event"].(map[string]any); b != nil && b["text"] == "old" {
			t.Fatalf("pre-restart event replayed after restart: %v", f)
		}
	}
}

func TestCommandRoundTripWithIDTranslation(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	agentWS := connectAgent(t, srv, "agent-3")
	clientWS, _ := connectClient(t, srv, testControlToken, "c3")
	writeJSON(t, clientWS, map[string]any{"t": "subscribe", "agentId": "agent-3", "since": int64(0)})

	writeJSON(t, clientWS, map[string]any{
		"t": "command", "id": "client-side-id", "agentId": "agent-3",
		"cmd": "prompt", "args": map[string]any{"text": "hi"},
	})

	cmd := readFrameOfType(t, agentWS, "command")
	relayID, _ := cmd["id"].(string)
	if relayID == "" {
		t.Fatal("command frame missing id")
	}
	if relayID == "client-side-id" {
		t.Fatal("relay must not forward the client's own id to the agent unchanged")
	}
	if cmd["cmd"] != "prompt" {
		t.Fatalf("cmd = %v, want prompt", cmd["cmd"])
	}

	writeJSON(t, agentWS, map[string]any{
		"t": "reply", "id": relayID, "ok": true, "data": map[string]any{"accepted": true},
	})

	reply := readFrameOfType(t, clientWS, "reply")
	if reply["id"] != "client-side-id" {
		t.Fatalf("reply id = %v, want client-side-id (translated back)", reply["id"])
	}
	if reply["ok"] != true {
		t.Fatalf("reply ok = %v, want true", reply["ok"])
	}
}

func TestCommandToOfflineAgentGetsImmediateError(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	clientWS, _ := connectClient(t, srv, testControlToken, "c4")

	writeJSON(t, clientWS, map[string]any{
		"t": "command", "id": "req-1", "agentId": "no-such-agent",
		"cmd": "state", "args": map[string]any{},
	})

	reply := readFrameOfType(t, clientWS, "reply")
	if reply["id"] != "req-1" {
		t.Fatalf("reply id = %v, want req-1", reply["id"])
	}
	if reply["ok"] != false {
		t.Fatalf("reply ok = %v, want false", reply["ok"])
	}
	if reply["error"] != "agent offline" {
		t.Fatalf("reply error = %v, want \"agent offline\"", reply["error"])
	}
}

func TestAgentTakeoverOnDuplicateID(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	clientWS, _ := connectClient(t, srv, testControlToken, "c5")

	first := connectAgent(t, srv, "dup-agent")
	readFrameOfType(t, clientWS, "agents") // roster after first connects

	second := connectAgent(t, srv, "dup-agent")
	roster := readFrameOfType(t, clientWS, "agents")

	agents, _ := roster["agents"].([]any)
	onlineCount := 0
	for _, a := range agents {
		m := a.(map[string]any)
		if m["agentId"] == "dup-agent" && m["online"] == true {
			onlineCount++
		}
	}
	if onlineCount != 1 {
		t.Fatalf("expected exactly one online entry for dup-agent, got %d in %v", onlineCount, roster)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := first.Read(ctx); err == nil {
		t.Fatal("expected the evicted first connection to be closed")
	}

	// The surviving connection must still be live and usable.
	writeJSON(t, second, map[string]any{
		"t": "event", "seq": int64(1), "event": map[string]any{"k": "turn_start"},
	})
}

func TestViewerCommandAndResponseRejected(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	agentWS := connectAgent(t, srv, "agent-v")
	viewerWS, welcome := connectClient(t, srv, testViewerToken, "viewer-1")
	if welcome["role"] != "viewer" {
		t.Fatalf("role = %v, want viewer", welcome["role"])
	}
	writeJSON(t, viewerWS, map[string]any{"t": "subscribe", "agentId": "agent-v", "since": int64(0)})

	writeJSON(t, viewerWS, map[string]any{
		"t": "command", "id": "v1", "agentId": "agent-v", "cmd": "prompt", "args": map[string]any{"text": "x"},
	})
	reply := readFrameOfType(t, viewerWS, "reply")
	if reply["error"] != "read-only connection" {
		t.Fatalf("viewer command error = %v, want read-only connection", reply["error"])
	}

	writeJSON(t, viewerWS, map[string]any{
		"t": "response", "id": "req-x", "agentId": "agent-v", "response": map[string]any{"confirmed": true},
	})
	reply2 := readFrameOfType(t, viewerWS, "reply")
	if reply2["error"] != "read-only connection" {
		t.Fatalf("viewer response error = %v, want read-only connection", reply2["error"])
	}

	// The agent must never see a command frame from the viewer's rejected
	// command. The only frame queued for it since welcome is the viewers
	// count bump from the viewer's subscribe.
	frame := readFrameT(t, agentWS)
	if frame["t"] == "command" {
		t.Fatalf("agent received a command frame from a viewer, which must never be routed: %v", frame)
	}
}

func TestRequestFanOutFirstAnswerWinsAndResponseIDPassthrough(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	agentWS := connectAgent(t, srv, "agent-r")
	control1, _ := connectClient(t, srv, testControlToken, "ctl1")
	control2, _ := connectClient(t, srv, testControlToken, "ctl2")
	writeJSON(t, control1, map[string]any{"t": "subscribe", "agentId": "agent-r", "since": int64(0)})
	writeJSON(t, control2, map[string]any{"t": "subscribe", "agentId": "agent-r", "since": int64(0)})

	writeJSON(t, agentWS, map[string]any{
		"t": "request", "id": "agent-req-1",
		"request": map[string]any{"k": "confirm", "title": "Run tests?", "message": "m"},
	})

	req1 := readFrameOfType(t, control1, "request")
	req2 := readFrameOfType(t, control2, "request")
	if req1["id"] != "agent-req-1" || req2["id"] != "agent-req-1" {
		t.Fatalf("both controls must see the agent's own request id unchanged, got %v / %v", req1["id"], req2["id"])
	}

	writeJSON(t, control1, map[string]any{
		"t": "response", "id": "agent-req-1", "agentId": "agent-r", "response": map[string]any{"confirmed": true},
	})

	resp := readFrameOfType(t, agentWS, "response")
	if resp["id"] != "agent-req-1" {
		t.Fatalf("agent-facing response id = %v, want agent-req-1 (passthrough, not translated)", resp["id"])
	}
	if confirmed, _ := resp["response"].(map[string]any)["confirmed"].(bool); !confirmed {
		t.Fatalf("response payload = %v, want confirmed true", resp["response"])
	}

	// The second control's answer to the now-resolved request must fail.
	writeJSON(t, control2, map[string]any{
		"t": "response", "id": "agent-req-1", "agentId": "agent-r", "response": map[string]any{"confirmed": false},
	})
	late := readFrameOfType(t, control2, "reply")
	if late["error"] != "request already answered" {
		t.Fatalf("second answer error = %v, want request already answered", late["error"])
	}
}

func TestPendingRequestReplayedOnSubscribeBeforeEvents(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	agentWS := connectAgent(t, srv, "agent-p")

	writeJSON(t, agentWS, map[string]any{
		"t": "event", "seq": int64(1), "event": map[string]any{"k": "turn_start"},
	})
	writeJSON(t, agentWS, map[string]any{
		"t": "state", "state": map[string]any{"sessionId": "s", "cwd": "/"},
	})
	writeJSON(t, agentWS, map[string]any{
		"t": "request", "id": "req-open", "request": map[string]any{"k": "input", "title": "t", "message": "m"},
	})
	time.Sleep(50 * time.Millisecond)

	clientWS, _ := connectClient(t, srv, testControlToken, "late-sub")
	writeJSON(t, clientWS, map[string]any{"t": "subscribe", "agentId": "agent-p", "since": int64(0)})

	first := readFrameT(t, clientWS)
	if first["t"] != "state" {
		t.Fatalf("first replayed frame = %v, want state", first["t"])
	}
	second := readFrameT(t, clientWS)
	if second["t"] != "request" || second["id"] != "req-open" {
		t.Fatalf("second replayed frame = %v, want the pending request", second)
	}
	third := readFrameT(t, clientWS)
	if third["t"] != "event" {
		t.Fatalf("third replayed frame = %v, want the buffered event (after the pending request)", third["t"])
	}
}

func TestPendingRequestCanceledOnAgentDisconnect(t *testing.T) {
	srv := testRelay(t, testViewerToken)
	agentWS := connectAgent(t, srv, "agent-d")
	clientWS, _ := connectClient(t, srv, testControlToken, "watcher")
	writeJSON(t, clientWS, map[string]any{"t": "subscribe", "agentId": "agent-d", "since": int64(0)})

	writeJSON(t, agentWS, map[string]any{
		"t": "request", "id": "req-disc", "request": map[string]any{"k": "confirm", "title": "t", "message": "m"},
	})
	readFrameOfType(t, clientWS, "request")

	agentWS.Close(websocket.StatusNormalClosure, "")

	cancel := readFrameOfType(t, clientWS, "request_cancel")
	if cancel["id"] != "req-disc" {
		t.Fatalf("cancel id = %v, want req-disc", cancel["id"])
	}
	if cancel["reason"] != "shutdown" {
		t.Fatalf("cancel reason = %v, want shutdown", cancel["reason"])
	}
}
