package main

import (
	"encoding/json"
	"fmt"
)

// ProtocolVersion is the wire protocol version this relay implements.
const ProtocolVersion = 2

// Role is the permission level of a client connection, fixed at handshake
// time by which token authenticated it. It is never taken from the client.
type Role string

const (
	RoleControl Role = "control"
	RoleViewer  Role = "viewer"
)

// Frame discriminators (the "t" field).
const (
	tHello         = "hello"
	tWelcome       = "welcome"
	tEvent         = "event"
	tState         = "state"
	tReply         = "reply"
	tCommand       = "command"
	tRequest       = "request"
	tRequestCancel = "request_cancel"
	tResponse      = "response"
	tSubscribe     = "subscribe"
	tUnsubscribe   = "unsubscribe"
	tAgents        = "agents"
	tViewers       = "viewers"
)

// AgentInfo describes an agent, carried in hello and in every roster entry.
type AgentInfo struct {
	AgentID     string `json:"agentId"`
	Name        string `json:"name"`
	Host        string `json:"host"`
	Cwd         string `json:"cwd"`
	Online      bool   `json:"online"`
	ConnectedAt int64  `json:"connectedAt"`
}

// envelopeType sniffs the "t" discriminator of a raw frame without
// committing to a specific frame shape.
func envelopeType(raw []byte) (string, error) {
	var e struct {
		T string `json:"t"`
	}
	if err := json.Unmarshal(raw, &e); err != nil {
		return "", fmt.Errorf("invalid json: %w", err)
	}
	if e.T == "" {
		return "", fmt.Errorf("missing \"t\" field")
	}
	return e.T, nil
}

// --- Agent to relay ---

type helloAgentIn struct {
	Protocol int             `json:"protocol"`
	AgentID  string          `json:"agentId"`
	Info     json.RawMessage `json:"info"`
}

type eventIn struct {
	Seq   int64           `json:"seq"`
	Event json.RawMessage `json:"event"`
}

type stateIn struct {
	State json.RawMessage `json:"state"`
}

type replyIn struct {
	ID    string          `json:"id"`
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data,omitempty"`
	Error string          `json:"error,omitempty"`
}

type requestIn struct {
	ID      string          `json:"id"`
	Request json.RawMessage `json:"request"`
}

type requestCancelIn struct {
	ID     string `json:"id"`
	Reason string `json:"reason"`
}

// responseIn covers both the agent's outbound shape (id, response) and the
// client's outbound shape (id, agentId, response); AgentID is empty when the
// frame came from an agent.
type responseIn struct {
	ID       string          `json:"id"`
	AgentID  string          `json:"agentId"`
	Response json.RawMessage `json:"response"`
}

// --- Client to relay ---

type helloClientIn struct {
	Protocol int    `json:"protocol"`
	ClientID string `json:"clientId"`
	Name     string `json:"name"`
}

type subscribeIn struct {
	AgentID string `json:"agentId"`
	Since   int64  `json:"since"`
}

type unsubscribeIn struct {
	AgentID string `json:"agentId"`
}

type commandIn struct {
	ID      string          `json:"id"`
	AgentID string          `json:"agentId"`
	Cmd     string          `json:"cmd"`
	Args    json.RawMessage `json:"args"`
}

// --- Relay to agent ---

type welcomeAgentOut struct {
	T        string `json:"t"`
	Protocol int    `json:"protocol"`
	AgentID  string `json:"agentId"`
}

type commandOut struct {
	T    string          `json:"t"`
	ID   string          `json:"id"`
	Cmd  string          `json:"cmd"`
	Args json.RawMessage `json:"args"`
}

type responseOut struct {
	T        string          `json:"t"`
	ID       string          `json:"id"`
	Response json.RawMessage `json:"response"`
}

type viewersOut struct {
	T       string `json:"t"`
	Control int    `json:"control"`
	Viewer  int    `json:"viewer"`
}

// --- Relay to client ---

type welcomeClientOut struct {
	T        string      `json:"t"`
	Protocol int         `json:"protocol"`
	ClientID string      `json:"clientId"`
	Role     Role        `json:"role"`
	Agents   []AgentInfo `json:"agents"`
}

type agentsOut struct {
	T      string      `json:"t"`
	Agents []AgentInfo `json:"agents"`
}

type eventOut struct {
	T       string          `json:"t"`
	AgentID string          `json:"agentId"`
	Seq     int64           `json:"seq"`
	Event   json.RawMessage `json:"event"`
}

type stateOut struct {
	T       string          `json:"t"`
	AgentID string          `json:"agentId"`
	State   json.RawMessage `json:"state"`
}

type replyOut struct {
	T     string          `json:"t"`
	ID    string          `json:"id"`
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data,omitempty"`
	Error string          `json:"error,omitempty"`
}

type requestOut struct {
	T       string          `json:"t"`
	AgentID string          `json:"agentId"`
	ID      string          `json:"id"`
	Request json.RawMessage `json:"request"`
}

type requestCancelOut struct {
	T       string `json:"t"`
	AgentID string `json:"agentId"`
	ID      string `json:"id"`
	Reason  string `json:"reason"`
}

func encodeFrame(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		// Every outbound type above is a plain struct with json.RawMessage
		// payloads that were themselves already valid JSON; a marshal
		// failure here means a programming error, not a runtime condition.
		panic(fmt.Sprintf("relay: encode frame: %v", err))
	}
	return b
}

func replyError(id, errMsg string) []byte {
	return encodeFrame(replyOut{T: tReply, ID: id, OK: false, Error: errMsg})
}

// requestKind extracts the "k" discriminator of a retained request object.
func requestKind(raw json.RawMessage) (string, error) {
	var k struct {
		K string `json:"k"`
	}
	if err := json.Unmarshal(raw, &k); err != nil {
		return "", err
	}
	if k.K == "" {
		return "", fmt.Errorf("request missing \"k\" field")
	}
	return k.K, nil
}

// validateResponseShape checks a response object against the answer shape
// documented for its request kind, without interpreting the values.
func validateResponseShape(kind string, response json.RawMessage) error {
	switch kind {
	case "select":
		var v struct {
			Index *int `json:"index"`
		}
		if err := json.Unmarshal(response, &v); err != nil || v.Index == nil {
			return fmt.Errorf("expected integer \"index\"")
		}
	case "confirm":
		var v struct {
			Confirmed *bool `json:"confirmed"`
		}
		if err := json.Unmarshal(response, &v); err != nil || v.Confirmed == nil {
			return fmt.Errorf("expected boolean \"confirmed\"")
		}
	case "input", "editor":
		var v struct {
			Value *string `json:"value"`
		}
		if err := json.Unmarshal(response, &v); err != nil || v.Value == nil {
			return fmt.Errorf("expected string \"value\"")
		}
	case "approval":
		var v struct {
			Decision string `json:"decision"`
		}
		if err := json.Unmarshal(response, &v); err != nil {
			return fmt.Errorf("expected string \"decision\"")
		}
		if v.Decision != "allow" && v.Decision != "deny" && v.Decision != "always" {
			return fmt.Errorf("\"decision\" must be allow, deny, or always")
		}
	default:
		return fmt.Errorf("unknown request kind %q", kind)
	}
	return nil
}

// truncate caps a display string at n runes, matching the protocol's
// untrusted-name handling.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}
