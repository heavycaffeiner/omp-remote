package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"sync"
	"time"
)

const (
	eventRingCap     = 512
	commandTimeout   = 60 * time.Second
	outboundQueueCap = 256
)

// eventRecord is one retained event frame in an agent's replay ring.
type eventRecord struct {
	seq   int64
	event json.RawMessage
}

// pendingRequest is a retained interactive request awaiting a control
// client's answer.
type pendingRequest struct {
	id      string
	request json.RawMessage
}

// clientState is the hub's bookkeeping for one connected client. It is
// keyed by the connection itself, since the client-supplied clientId is
// informational and carries no uniqueness guarantee.
type clientState struct {
	conn          *outConn
	role          Role
	clientID      string
	subscriptions map[string]struct{}
	pendingCmdIDs map[string]struct{}
}

// agentState is the hub's bookkeeping for one agent id. It survives the
// agent's connection going offline so replay and roster stay available.
type agentState struct {
	info            AgentInfo
	online          bool
	conn            *outConn
	events          []eventRecord
	state           json.RawMessage
	pendingRequests []pendingRequest
	subs            map[*outConn]*clientState
	lastControl     int
	lastViewer      int
	viewersSent     bool
}

// pendingCmd tracks one in-flight command routed to an agent, so the reply
// can be translated back to the originating client's own id.
type pendingCmd struct {
	clientConn *outConn
	origID     string
	agentID    string
	timer      *time.Timer
}

// Hub is the routing core: agent registry, client registry, subscriptions,
// replay buffers, and the command routing table. All mutation happens under
// mu; sends to connections are always non-blocking so a slow or dead peer
// can never stall the hub.
type Hub struct {
	mu          sync.Mutex
	agents      map[string]*agentState
	clients     map[*outConn]*clientState
	pendingCmds map[string]*pendingCmd
	cmdSeq      uint64
}

func NewHub() *Hub {
	return &Hub{
		agents:      make(map[string]*agentState),
		clients:     make(map[*outConn]*clientState),
		pendingCmds: make(map[string]*pendingCmd),
	}
}

func (h *Hub) getOrCreateAgentLocked(agentID string) *agentState {
	a, ok := h.agents[agentID]
	if !ok {
		a = &agentState{
			info: AgentInfo{AgentID: agentID},
			subs: make(map[*outConn]*clientState),
		}
		h.agents[agentID] = a
	}
	return a
}

func (h *Hub) rosterLocked() []AgentInfo {
	roster := make([]AgentInfo, 0, len(h.agents))
	for _, a := range h.agents {
		roster = append(roster, a.info)
	}
	sort.Slice(roster, func(i, j int) bool { return roster[i].AgentID < roster[j].AgentID })
	return roster
}

func (h *Hub) broadcastRosterLocked() {
	frame := encodeFrame(agentsOut{T: tAgents, Agents: h.rosterLocked()})
	for _, c := range h.clients {
		if !c.conn.trySend(frame) {
			c.conn.closeAsync(statusTooSlow, "outbound queue full")
		}
	}
}

// sendViewersLocked notifies the agent's current connection of subscriber
// counts, but only when the counts actually changed since the last send.
func (h *Hub) sendViewersLocked(a *agentState) {
	if a.conn == nil {
		return
	}
	control, viewer := 0, 0
	for _, c := range a.subs {
		if c.role == RoleControl {
			control++
		} else {
			viewer++
		}
	}
	if a.viewersSent && control == a.lastControl && viewer == a.lastViewer {
		return
	}
	a.lastControl, a.lastViewer, a.viewersSent = control, viewer, true
	frame := encodeFrame(viewersOut{T: tViewers, Control: control, Viewer: viewer})
	if !a.conn.trySend(frame) {
		a.conn.closeAsync(statusTooSlow, "outbound queue full")
	}
}

// RegisterAgent registers a hello'd agent connection, replacing any prior
// live connection for the same id (takeover). It returns the connection
// that must be closed as evicted, if any, and the welcome frame to send.
func (h *Hub) RegisterAgent(agentID string, info AgentInfo, conn *outConn, connectedAt int64) (evicted *outConn, welcome []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()

	a := h.getOrCreateAgentLocked(agentID)
	if a.online && a.conn != nil {
		evicted = a.conn
	}
	// A hello starts a fresh epoch: the agent's seq counter restarts at 1,
	// so retained frames from the previous run would replay out of order
	// and read as a restart to a client that is merely resuming.
	a.events = nil
	a.state = nil
	for _, pr := range a.pendingRequests {
		frame := encodeFrame(requestCancelOut{T: tRequestCancel, AgentID: agentID, ID: pr.id, Reason: "shutdown"})
		for _, c := range a.subs {
			if !c.conn.trySend(frame) {
				c.conn.closeAsync(statusTooSlow, "outbound queue full")
			}
		}
	}
	a.pendingRequests = nil

	info.AgentID = agentID
	info.Online = true
	info.ConnectedAt = connectedAt
	a.info = info
	a.online = true
	a.conn = conn
	a.viewersSent = false // force a fresh viewers frame on the new connection

	h.broadcastRosterLocked()
	h.sendViewersLocked(a)

	welcome = encodeFrame(welcomeAgentOut{T: tWelcome, Protocol: ProtocolVersion, AgentID: agentID})
	return evicted, welcome
}

// UnregisterAgent marks an agent offline, but only if conn is still its
// current connection (a takeover may have already replaced it).
func (h *Hub) UnregisterAgent(agentID string, conn *outConn) {
	h.mu.Lock()
	defer h.mu.Unlock()

	a, ok := h.agents[agentID]
	if !ok || a.conn != conn {
		return
	}
	a.online = false
	a.info.Online = false
	a.conn = nil

	for _, pr := range a.pendingRequests {
		frame := encodeFrame(requestCancelOut{T: tRequestCancel, AgentID: agentID, ID: pr.id, Reason: "shutdown"})
		for _, c := range a.subs {
			if !c.conn.trySend(frame) {
				c.conn.closeAsync(statusTooSlow, "outbound queue full")
			}
		}
	}
	a.pendingRequests = nil

	h.broadcastRosterLocked()
}

// RegisterClient adds a client connection to the registry and returns the
// welcome frame, which includes the current roster and the client's role.
func (h *Hub) RegisterClient(conn *outConn, role Role, clientID string) []byte {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.clients[conn] = &clientState{
		conn:          conn,
		role:          role,
		clientID:      clientID,
		subscriptions: make(map[string]struct{}),
		pendingCmdIDs: make(map[string]struct{}),
	}
	return encodeFrame(welcomeClientOut{
		T: tWelcome, Protocol: ProtocolVersion, ClientID: clientID, Role: role, Agents: h.rosterLocked(),
	})
}

// UnregisterClient drops a client's subscriptions and pending commands.
func (h *Hub) UnregisterClient(conn *outConn) {
	h.mu.Lock()
	defer h.mu.Unlock()

	c, ok := h.clients[conn]
	if !ok {
		return
	}
	for agentID := range c.subscriptions {
		if a, ok := h.agents[agentID]; ok {
			delete(a.subs, conn)
			h.sendViewersLocked(a)
		}
	}
	for relayID := range c.pendingCmdIDs {
		if pc, ok := h.pendingCmds[relayID]; ok {
			pc.timer.Stop()
			delete(h.pendingCmds, relayID)
		}
	}
	delete(h.clients, conn)
}

// Subscribe attaches a client to an agent's stream and sends the replay:
// the retained state snapshot, any open pending requests, then buffered
// events with seq > since. Registration happens before the replay is
// gathered so no event can be lost or duplicated across the transition.
func (h *Hub) Subscribe(conn *outConn, agentID string, since int64) {
	h.mu.Lock()
	defer h.mu.Unlock()

	c, ok := h.clients[conn]
	if !ok {
		return
	}
	a := h.getOrCreateAgentLocked(agentID)
	a.subs[conn] = c
	c.subscriptions[agentID] = struct{}{}

	if a.state != nil {
		if !conn.trySend(encodeFrame(stateOut{T: tState, AgentID: agentID, State: a.state})) {
			conn.closeAsync(statusTooSlow, "outbound queue full")
		}
	}
	for _, pr := range a.pendingRequests {
		if !conn.trySend(encodeFrame(requestOut{T: tRequest, AgentID: agentID, ID: pr.id, Request: pr.request})) {
			conn.closeAsync(statusTooSlow, "outbound queue full")
		}
	}
	for _, ev := range a.events {
		if ev.seq <= since {
			continue
		}
		if !conn.trySend(encodeFrame(eventOut{T: tEvent, AgentID: agentID, Seq: ev.seq, Event: ev.event})) {
			conn.closeAsync(statusTooSlow, "outbound queue full")
		}
	}
	h.sendViewersLocked(a)
}

func (h *Hub) Unsubscribe(conn *outConn, agentID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	c, ok := h.clients[conn]
	if !ok {
		return
	}
	delete(c.subscriptions, agentID)
	if a, ok := h.agents[agentID]; ok {
		delete(a.subs, conn)
		h.sendViewersLocked(a)
	}
}

// HandleAgentEvent appends an event to the replay ring and fans it out to
// every subscriber.
func (h *Hub) HandleAgentEvent(agentID string, seq int64, event json.RawMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()

	a := h.getOrCreateAgentLocked(agentID)
	a.events = append(a.events, eventRecord{seq: seq, event: event})
	if len(a.events) > eventRingCap {
		a.events = a.events[len(a.events)-eventRingCap:]
	}
	frame := encodeFrame(eventOut{T: tEvent, AgentID: agentID, Seq: seq, Event: event})
	for conn, c := range a.subs {
		if !conn.trySend(frame) {
			c.conn.closeAsync(statusTooSlow, "outbound queue full")
		}
	}
}

// HandleAgentState overwrites the retained snapshot and fans it out.
func (h *Hub) HandleAgentState(agentID string, state json.RawMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()

	a := h.getOrCreateAgentLocked(agentID)
	a.state = state
	frame := encodeFrame(stateOut{T: tState, AgentID: agentID, State: state})
	for conn, c := range a.subs {
		if !conn.trySend(frame) {
			c.conn.closeAsync(statusTooSlow, "outbound queue full")
		}
	}
}

// HandleAgentRequest retains an interactive request and fans it out to
// every subscriber, control and viewer alike.
func (h *Hub) HandleAgentRequest(agentID, id string, request json.RawMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()

	a := h.getOrCreateAgentLocked(agentID)
	a.pendingRequests = append(a.pendingRequests, pendingRequest{id: id, request: request})
	frame := encodeFrame(requestOut{T: tRequest, AgentID: agentID, ID: id, Request: request})
	for conn, c := range a.subs {
		if !conn.trySend(frame) {
			c.conn.closeAsync(statusTooSlow, "outbound queue full")
		}
	}
}

// HandleAgentRequestCancel clears a retained request and fans out the
// cancellation.
func (h *Hub) HandleAgentRequestCancel(agentID, id, reason string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	a, ok := h.agents[agentID]
	if !ok {
		return
	}
	for i, pr := range a.pendingRequests {
		if pr.id == id {
			a.pendingRequests = append(a.pendingRequests[:i], a.pendingRequests[i+1:]...)
			break
		}
	}
	frame := encodeFrame(requestCancelOut{T: tRequestCancel, AgentID: agentID, ID: id, Reason: reason})
	for conn, c := range a.subs {
		if !conn.trySend(frame) {
			c.conn.closeAsync(statusTooSlow, "outbound queue full")
		}
	}
}

// HandleClientCommand routes a control client's command to its target
// agent, or synthesizes an immediate error reply without touching the
// registry when the agent is unknown or offline.
func (h *Hub) HandleClientCommand(conn *outConn, origID, agentID, cmd string, args json.RawMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()

	c, ok := h.clients[conn]
	if !ok {
		return
	}
	if c.role == RoleViewer {
		if !conn.trySend(replyError(origID, "read-only connection")) {
			conn.closeAsync(statusTooSlow, "outbound queue full")
		}
		return
	}

	a, ok := h.agents[agentID]
	if !ok || !a.online || a.conn == nil {
		if !conn.trySend(replyError(origID, "agent offline")) {
			conn.closeAsync(statusTooSlow, "outbound queue full")
		}
		return
	}

	h.cmdSeq++
	relayID := fmt.Sprintf("c%d", h.cmdSeq)
	pc := &pendingCmd{clientConn: conn, origID: origID, agentID: agentID}
	pc.timer = time.AfterFunc(commandTimeout, func() { h.timeoutCommand(relayID) })
	h.pendingCmds[relayID] = pc
	c.pendingCmdIDs[relayID] = struct{}{}

	frame := encodeFrame(commandOut{T: tCommand, ID: relayID, Cmd: cmd, Args: args})
	if !a.conn.trySend(frame) {
		a.conn.closeAsync(statusTooSlow, "outbound queue full")
	}
}

func (h *Hub) timeoutCommand(relayID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	pc, ok := h.pendingCmds[relayID]
	if !ok {
		return
	}
	delete(h.pendingCmds, relayID)
	if c, ok := h.clients[pc.clientConn]; ok {
		delete(c.pendingCmdIDs, relayID)
	}
	if !pc.clientConn.trySend(replyError(pc.origID, "command timed out")) {
		pc.clientConn.closeAsync(statusTooSlow, "outbound queue full")
	}
}

// HandleAgentReply translates a routed command's reply back to the
// originating client's own id and delivers it there only.
func (h *Hub) HandleAgentReply(relayID string, ok bool, data json.RawMessage, errMsg string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	pc, exists := h.pendingCmds[relayID]
	if !exists {
		return // late reply after timeout, or a bogus id; nothing to deliver
	}
	pc.timer.Stop()
	delete(h.pendingCmds, relayID)
	if c, ok := h.clients[pc.clientConn]; ok {
		delete(c.pendingCmdIDs, relayID)
	}

	frame := encodeFrame(replyOut{T: tReply, ID: pc.origID, OK: ok, Data: data, Error: errMsg})
	if !pc.clientConn.trySend(frame) {
		pc.clientConn.closeAsync(statusTooSlow, "outbound queue full")
	}
}

// HandleClientResponse answers an interactive request. A viewer is rejected
// outright. A control client's answer must target an open request and match
// its kind's answer shape; the first valid answer wins and forwards to the
// agent unchanged (the id is the agent's own, never translated).
func (h *Hub) HandleClientResponse(conn *outConn, id, agentID string, response json.RawMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()

	c, ok := h.clients[conn]
	if !ok {
		return
	}
	if c.role == RoleViewer {
		if !conn.trySend(replyError(id, "read-only connection")) {
			conn.closeAsync(statusTooSlow, "outbound queue full")
		}
		return
	}

	a, ok := h.agents[agentID]
	if !ok {
		if !conn.trySend(replyError(id, "request already answered")) {
			conn.closeAsync(statusTooSlow, "outbound queue full")
		}
		return
	}
	idx := -1
	for i, pr := range a.pendingRequests {
		if pr.id == id {
			idx = i
			break
		}
	}
	if idx == -1 {
		if !conn.trySend(replyError(id, "request already answered")) {
			conn.closeAsync(statusTooSlow, "outbound queue full")
		}
		return
	}

	kind, err := requestKind(a.pendingRequests[idx].request)
	if err == nil {
		err = validateResponseShape(kind, response)
	}
	if err != nil {
		if !conn.trySend(replyError(id, "invalid response")) {
			conn.closeAsync(statusTooSlow, "outbound queue full")
		}
		return
	}

	a.pendingRequests = append(a.pendingRequests[:idx], a.pendingRequests[idx+1:]...)
	if a.conn != nil {
		frame := encodeFrame(responseOut{T: tResponse, ID: id, Response: response})
		if !a.conn.trySend(frame) {
			a.conn.closeAsync(statusTooSlow, "outbound queue full")
		}
	}
}
