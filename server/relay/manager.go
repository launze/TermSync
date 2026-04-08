package relay

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"termsync-server/models"
	"termsync-server/store"

	"nhooyr.io/websocket"
)

// SessionInfo holds metadata about a session.
type SessionInfo struct {
	OwnerID   string
	Title     string
	Cols      int
	Rows      int
	Status    string // "active" | "closing"
	TaskState string
	Preview   string
	Activity  string
	Viewers   map[string]bool // deviceID -> true
	CreatedAt time.Time
}

// SessionManager manages all WebSocket connections and session routing
// with strict owner/viewer semantics and validated message routing.
type SessionManager struct {
	store *store.Store

	mu sync.RWMutex

	// deviceConnections maps device ID to its WebSocket connection
	deviceConnections map[string]*websocket.Conn

	// deviceTypes maps device ID to its type ("desktop" | "mobile")
	deviceTypes map[string]string

	// sessions maps session ID to its metadata
	sessions map[string]*SessionInfo

	// deviceSessions maps device ID to the set of session IDs it owns
	deviceSessions map[string]map[string]bool
}

// NewSessionManager creates a new SessionManager.
func NewSessionManager(store *store.Store) *SessionManager {
	return &SessionManager{
		store:             store,
		deviceConnections: make(map[string]*websocket.Conn),
		deviceTypes:       make(map[string]string),
		sessions:          make(map[string]*SessionInfo),
		deviceSessions:    make(map[string]map[string]bool),
	}
}

// ─── Connection lifecycle ─────────────────────────────────────────────────

// RegisterConnection registers a new WebSocket connection for a device.
func (sm *SessionManager) RegisterConnection(deviceID, deviceType string, conn *websocket.Conn) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	// Close existing connection if any
	if oldConn, ok := sm.deviceConnections[deviceID]; ok {
		oldConn.Close(websocket.StatusGoingAway, "replaced by new connection")
	}

	sm.deviceConnections[deviceID] = conn
	sm.deviceTypes[deviceID] = deviceType

	// Ensure device session set exists
	if sm.deviceSessions[deviceID] == nil {
		sm.deviceSessions[deviceID] = make(map[string]bool)
	}

	// Update online status in database
	ctx := context.Background()
	sm.store.SetOnline(ctx, deviceID)

	log.Printf("[conn] Device %s (%s) connected (total: %d)", deviceID, deviceType, len(sm.deviceConnections))
}

// UnregisterConnection removes a WebSocket connection and cleans up all owned sessions.
func (sm *SessionManager) UnregisterConnection(deviceID string, conn *websocket.Conn) {
	sm.mu.Lock()

	currentConn, exists := sm.deviceConnections[deviceID]
	if !exists || currentConn != conn {
		sm.mu.Unlock()
		return
	}

	delete(sm.deviceConnections, deviceID)
	delete(sm.deviceTypes, deviceID)

	// Collect sessions to close and remove them from the map atomically
	sessionsToClose := make([]string, 0)
	viewerSnapshots := make(map[string][]string) // sessionID -> viewer list for notification
	for sessionID := range sm.deviceSessions[deviceID] {
		if si, ok := sm.sessions[sessionID]; ok {
			si.Status = "closed"
			sessionsToClose = append(sessionsToClose, sessionID)
			// Snapshot the viewer set before deleting
			viewers := make([]string, 0, len(si.Viewers))
			for vid := range si.Viewers {
				if vid != deviceID {
					viewers = append(viewers, vid)
				}
			}
			viewerSnapshots[sessionID] = viewers
			delete(sm.sessions, sessionID)
		}
	}

	// Close all sessions owned by this device
	delete(sm.deviceSessions, deviceID)

	// Remove this device from all viewer sets of sessions it didn't own
	for _, si := range sm.sessions {
		delete(si.Viewers, deviceID)
	}

	// Update online status
	ctx := context.Background()
	sm.store.SetOffline(ctx, deviceID)

	// Capture connection count while under lock
	remaining := len(sm.deviceConnections)

	// Release lock before broadcasting to avoid deadlock
	sm.mu.Unlock()

	// Notify remaining viewers and persist status (outside lock, using snapshots)
	for _, sessionID := range sessionsToClose {
		sm.store.UpdateSessionStatus(context.Background(), sessionID, "closed")
		closeMsg := models.Message{
			Type:      string(models.MsgSessionClose),
			SessionID: sessionID,
			Timestamp: time.Now().Unix(),
			Payload: map[string]interface{}{
				"reason": "owner_disconnected",
			},
		}
		for _, vid := range viewerSnapshots[sessionID] {
			sm.sendToDevice(vid, closeMsg)
		}
	}

	log.Printf("[conn] Device %s disconnected (remaining: %d)", deviceID, remaining)
}

// ─── Message dispatch with validation ─────────────────────────────────────

// HandleMessage routes an incoming message with strict permission checks.
func (sm *SessionManager) HandleMessage(deviceID string, msgData []byte) error {
	var msg models.Message
	if err := json.Unmarshal(msgData, &msg); err != nil {
		sm.sendError(deviceID, "invalid_json", "Failed to parse message")
		return err
	}

	msgType := models.MsgType(msg.Type)

	// Validate timestamp (reject messages older than 60s)
	if msg.Timestamp > 0 {
		age := time.Now().Unix() - msg.Timestamp
		if age > 60 || age < -10 {
			sm.sendError(deviceID, "bad_timestamp", fmt.Sprintf("Message timestamp too old or in future: %d", msg.Timestamp))
			return nil
		}
	}

	switch msgType {
	// Auth
	case models.MsgAuth:
		// Auth is handled by WSHandler before registration; ignore here
		return nil

	// Session lifecycle (owner-only operations)
	case models.MsgSessionCreate:
		return sm.handleSessionCreate(deviceID, msg)
	case models.MsgSessionCreateRequest:
		return sm.handleSessionCreateRequest(deviceID, msg)
	case models.MsgSessionClose:
		return sm.handleSessionClose(deviceID, msg)
	case models.MsgSessionCloseRequest:
		return sm.handleSessionCloseRequest(deviceID, msg)
	case models.MsgSessionUpdate:
		return sm.handleSessionUpdate(deviceID, msg)
	case models.MsgSessionListReq:
		return sm.handleSessionList(deviceID, msg)

	// Terminal I/O
	case models.MsgTerminalOutput:
		return sm.relayTerminalOutput(deviceID, msg)
	case models.MsgTerminalInput:
		return sm.relayTerminalInput(deviceID, msg)
	case models.MsgTerminalResize:
		return sm.relayTerminalResize(deviceID, msg)
	case models.MsgTerminalReplayRequest:
		return sm.relayTerminalReplayRequest(deviceID, msg)
	case models.MsgTerminalReplay:
		return sm.relayTerminalReplay(deviceID, msg)

	// Subscription
	case models.MsgSubscribe:
		return sm.handleSubscribe(deviceID, msg)
	case models.MsgUnsubscribe:
		return sm.handleUnsubscribe(deviceID, msg)

	// Heartbeat
	case models.MsgHeartbeat:
		return sm.handleHeartbeat(deviceID)

	default:
		sm.sendError(deviceID, "unknown_type", fmt.Sprintf("Unknown message type: %s", msg.Type))
		return nil
	}
}

// ─── Session lifecycle ────────────────────────────────────────────────────

// handleSessionCreate creates a new terminal session (owner-only).
func (sm *SessionManager) handleSessionCreate(deviceID string, msg models.Message) error {
	// Validate: must have a session_id
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "session.create requires session_id")
		return nil
	}

	sm.mu.Lock()

	// Check if session already exists
	if existing, exists := sm.sessions[msg.SessionID]; exists {
		// If the same owner re-creates, treat as idempotent (reconnect scenario)
		if existing.OwnerID == deviceID {
			sm.mu.Unlock()
			log.Printf("[session] %s re-registered by same owner %s (idempotent)", msg.SessionID, deviceID)
			return nil
		}
		sm.mu.Unlock()
		sm.sendError(deviceID, "session_exists", fmt.Sprintf("Session %s already exists", msg.SessionID))
		return nil
	}

	cols := 80
	rows := 24
	if c, ok := numField(msg.Payload, "cols"); ok {
		cols = int(c)
	}
	if r, ok := numField(msg.Payload, "rows"); ok {
		rows = int(r)
	}
	title := strField(msg.Payload, "title", "Terminal")

	si := &SessionInfo{
		OwnerID:   deviceID,
		Title:     title,
		Cols:      cols,
		Rows:      rows,
		Status:    "active",
		TaskState: "idle",
		Activity:  "终端已就绪",
		Viewers:   make(map[string]bool),
		CreatedAt: time.Now(),
	}
	si.Viewers[deviceID] = true // owner is implicitly a viewer

	sm.sessions[msg.SessionID] = si
	if sm.deviceSessions[deviceID] == nil {
		sm.deviceSessions[deviceID] = make(map[string]bool)
	}
	sm.deviceSessions[deviceID][msg.SessionID] = true

	sm.mu.Unlock()

	// Persist to database
	session := &models.Session{
		ID:       msg.SessionID,
		DeviceID: deviceID,
		Title:    title,
		Status:   "active",
		Cols:     cols,
		Rows:     rows,
	}
	sm.store.CreateSession(context.Background(), session)

	// Push a typed snapshot so paired mobiles can populate the list immediately.
	sm.notifyPairedMobiles(deviceID, models.Message{
		Type:      string(models.MsgSessionState),
		SessionID: msg.SessionID,
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"snapshot": sessionSnapshot(msg.SessionID, si),
		},
	})

	log.Printf("[session] %s created by %s (%dx%d)", msg.SessionID, deviceID, cols, rows)
	return nil
}

// handleSessionUpdate updates user-facing session metadata (owner-only).
func (sm *SessionManager) handleSessionUpdate(deviceID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "session.update requires session_id")
		return nil
	}

	sm.mu.Lock()
	si, exists := sm.sessions[msg.SessionID]
	if !exists {
		sm.mu.Unlock()
		sm.sendError(deviceID, "session_not_found", fmt.Sprintf("Session %s not found", msg.SessionID))
		return nil
	}

	if si.OwnerID != deviceID {
		sm.mu.Unlock()
		sm.sendError(deviceID, "permission_denied", "Only session owner can update session metadata")
		return nil
	}

	if title, ok := optionalStrField(msg.Payload, "title"); ok {
		si.Title = title
	}
	if activity, ok := optionalStrField(msg.Payload, "activity"); ok {
		si.Activity = activity
	}
	if preview, ok := optionalStrField(msg.Payload, "preview"); ok {
		si.Preview = preview
	}
	if taskState, ok := optionalStrField(msg.Payload, "task_state"); ok {
		si.TaskState = taskState
	}

	snapshot := sessionSnapshot(msg.SessionID, si)
	sm.mu.Unlock()

	sm.broadcastToViewers(msg.SessionID, models.Message{
		Type:      string(models.MsgSessionState),
		SessionID: msg.SessionID,
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"snapshot": snapshot,
		},
	}, deviceID)

	log.Printf(
		"[session] %s updated by %s task_state=%s activity=%q",
		msg.SessionID,
		deviceID,
		snapshot.TaskState,
		snapshot.Activity,
	)
	return nil
}

// handleSessionCreateRequest forwards a mobile-originated create request to a paired desktop.
func (sm *SessionManager) handleSessionCreateRequest(deviceID string, msg models.Message) error {
	if sm.getDeviceType(deviceID) != "mobile" {
		sm.sendError(deviceID, "permission_denied", "Only mobile devices can request remote terminal creation")
		return nil
	}

	desktopID := strField(msg.Payload, "desktop_id", "")
	if desktopID == "" {
		sm.sendError(deviceID, "missing_desktop_id", "session.create_request requires desktop_id")
		return nil
	}

	paired, err := sm.store.IsPaired(context.Background(), desktopID, deviceID)
	if err != nil {
		sm.sendError(deviceID, "pairing_lookup_failed", "Failed to verify pairing")
		return err
	}
	if !paired {
		sm.sendError(deviceID, "permission_denied", "Device is not paired with this desktop")
		return nil
	}

	if !sm.isDeviceOnline(desktopID) {
		sm.sendError(deviceID, "desktop_not_connected", "Paired desktop is not currently connected")
		return nil
	}

	if msg.Payload == nil {
		msg.Payload = map[string]interface{}{}
	}
	msg.Payload["requested_by"] = deviceID

	sm.sendToDevice(desktopID, msg)
	return nil
}

// handleSessionClose closes a terminal session (owner-only).
func (sm *SessionManager) handleSessionClose(deviceID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "session.close requires session_id")
		return nil
	}

	sm.mu.Lock()
	si, exists := sm.sessions[msg.SessionID]
	if !exists {
		sm.mu.Unlock()
		sm.sendError(deviceID, "session_not_found", fmt.Sprintf("Session %s not found", msg.SessionID))
		return nil
	}

	// Permission check: only owner can close
	if si.OwnerID != deviceID {
		sm.mu.Unlock()
		sm.sendError(deviceID, "permission_denied", "Only session owner can close the session")
		return nil
	}

	// Snapshot viewer list and delete session atomically
	viewers := make([]string, 0, len(si.Viewers))
	for vid := range si.Viewers {
		if vid != deviceID {
			viewers = append(viewers, vid)
		}
	}
	delete(sm.sessions, msg.SessionID)
	delete(sm.deviceSessions[deviceID], msg.SessionID)
	sm.mu.Unlock()

	// Notify viewers outside the lock using the snapshot
	closeMsg := models.Message{
		Type:      string(models.MsgSessionClose),
		SessionID: msg.SessionID,
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"reason": "owner_closed",
		},
	}
	for _, vid := range viewers {
		sm.sendToDevice(vid, closeMsg)
	}

	sm.store.UpdateSessionStatus(context.Background(), msg.SessionID, "closed")

	log.Printf("[session] %s closed by owner %s", msg.SessionID, deviceID)
	return nil
}

// handleSessionCloseRequest forwards a close request to the owning desktop.
func (sm *SessionManager) handleSessionCloseRequest(deviceID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "session.close_request requires session_id")
		return nil
	}

	sm.mu.RLock()
	si, exists := sm.sessions[msg.SessionID]
	ownerID := ""
	if exists {
		ownerID = si.OwnerID
	}
	sm.mu.RUnlock()

	if !exists {
		sm.sendError(deviceID, "session_not_found", fmt.Sprintf("Session %s not found", msg.SessionID))
		return nil
	}

	if deviceID == ownerID {
		return sm.handleSessionClose(deviceID, models.Message{
			Type:      string(models.MsgSessionClose),
			SessionID: msg.SessionID,
			Timestamp: msg.Timestamp,
			Payload:   msg.Payload,
		})
	}

	if sm.getDeviceType(deviceID) != "mobile" {
		sm.sendError(deviceID, "permission_denied", "Only mobile devices can request remote terminal close")
		return nil
	}

	paired, err := sm.store.IsPaired(context.Background(), ownerID, deviceID)
	if err != nil {
		sm.sendError(deviceID, "pairing_lookup_failed", "Failed to verify pairing")
		return err
	}
	if !paired {
		sm.sendError(deviceID, "permission_denied", "Device is not paired with this desktop")
		return nil
	}

	if !sm.isDeviceOnline(ownerID) {
		sm.sendError(deviceID, "desktop_not_connected", "Owning desktop is not currently connected")
		return nil
	}

	if msg.Payload == nil {
		msg.Payload = map[string]interface{}{}
	}
	msg.Payload["requested_by"] = deviceID

	sm.sendToDevice(ownerID, msg)
	return nil
}

// handleSessionList returns a snapshot of all active sessions.
func (sm *SessionManager) handleSessionList(deviceID string, msg models.Message) error {
	return sm.PushSessionList(deviceID)
}

// ─── Terminal I/O routing ─────────────────────────────────────────────────

// relayTerminalOutput: owner -> all viewers (including mobile).
// Only the session owner can send terminal output.
func (sm *SessionManager) relayTerminalOutput(ownerID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(ownerID, "missing_session_id", "terminal.output requires session_id")
		return nil
	}

	sm.mu.RLock()
	si, exists := sm.sessions[msg.SessionID]
	sm.mu.RUnlock()

	if !exists {
		// Silently drop — the session may not have been registered yet (race
		// between terminal.output and session.create during reconnection).
		return nil
	}

	// Permission check: only owner sends output
	if si.OwnerID != ownerID {
		sm.sendError(ownerID, "permission_denied", "Only session owner can send terminal output")
		return nil
	}

	// Relay to all viewers (excluding owner who already has the data)
	sm.broadcastToViewers(msg.SessionID, msg, ownerID)
	return nil
}

// relayTerminalInput: viewer -> owner.
// Any viewer (or owner) can send input to the session owner.
func (sm *SessionManager) relayTerminalInput(deviceID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "terminal.input requires session_id")
		return nil
	}

	sm.mu.RLock()
	si, exists := sm.sessions[msg.SessionID]
	ownerID := ""
	if exists {
		ownerID = si.OwnerID
	}
	sm.mu.RUnlock()

	if !exists {
		sm.sendError(deviceID, "session_not_found", fmt.Sprintf("Session %s not found", msg.SessionID))
		return nil
	}

	// Permission check: must be owner or viewer
	if deviceID != ownerID && !sm.isViewer(msg.SessionID, deviceID) {
		sm.sendError(deviceID, "permission_denied", "Must be subscribed to send input")
		return nil
	}

	// Forward input to owner
	if ownerID != deviceID {
		sm.sendToDevice(ownerID, msg)
	}
	return nil
}

// relayTerminalResize: desktop owner/viewer -> owner.
// Mobile viewers render locally and must not resize the owner's PTY.
func (sm *SessionManager) relayTerminalResize(deviceID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "terminal.resize requires session_id")
		return nil
	}

	sm.mu.RLock()
	si, exists := sm.sessions[msg.SessionID]
	ownerID := ""
	if exists {
		ownerID = si.OwnerID
	}
	sm.mu.RUnlock()

	if !exists {
		sm.sendError(deviceID, "session_not_found", fmt.Sprintf("Session %s not found", msg.SessionID))
		return nil
	}

	if deviceID != ownerID && sm.getDeviceType(deviceID) == "mobile" {
		log.Printf("[resize] ignored mobile viewer resize session=%s viewer=%s", msg.SessionID, deviceID)
		return nil
	}

	// Permission check: must be owner or viewer
	if deviceID != ownerID && !sm.isViewer(msg.SessionID, deviceID) {
		sm.sendError(deviceID, "permission_denied", "Must be subscribed to resize")
		return nil
	}

	// Forward resize to owner
	if ownerID != deviceID {
		sm.sendToDevice(ownerID, msg)
	}
	return nil
}

// relayTerminalReplayRequest forwards a replay request from a viewer to the owner.
func (sm *SessionManager) relayTerminalReplayRequest(deviceID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "terminal.replay_request requires session_id")
		return nil
	}

	sm.mu.RLock()
	si, exists := sm.sessions[msg.SessionID]
	ownerID := ""
	if exists {
		ownerID = si.OwnerID
	}
	sm.mu.RUnlock()

	if !exists {
		sm.sendError(deviceID, "session_not_found", fmt.Sprintf("Session %s not found", msg.SessionID))
		return nil
	}

	if deviceID != ownerID && !sm.isViewer(msg.SessionID, deviceID) {
		sm.sendError(deviceID, "permission_denied", "Must be subscribed to request replay")
		return nil
	}

	if msg.Payload == nil {
		msg.Payload = map[string]interface{}{}
	}
	msg.Payload["target_device_id"] = deviceID

	if ownerID != deviceID {
		sm.sendToDevice(ownerID, msg)
	}
	return nil
}

// relayTerminalReplay forwards replay data from the owner to a specific viewer.
func (sm *SessionManager) relayTerminalReplay(deviceID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "terminal.replay requires session_id")
		return nil
	}

	sm.mu.RLock()
	si, exists := sm.sessions[msg.SessionID]
	sm.mu.RUnlock()

	if !exists {
		sm.sendError(deviceID, "session_not_found", fmt.Sprintf("Session %s not found", msg.SessionID))
		return nil
	}

	if si.OwnerID != deviceID {
		sm.sendError(deviceID, "permission_denied", "Only session owner can send replay data")
		return nil
	}

	targetDeviceID := strField(msg.Payload, "target_device_id", "")
	if targetDeviceID == "" {
		sm.sendError(deviceID, "missing_target_device", "terminal.replay requires target_device_id")
		return nil
	}

	if targetDeviceID != deviceID && !sm.isViewer(msg.SessionID, targetDeviceID) {
		sm.sendError(deviceID, "permission_denied", "Replay target must be subscribed to this session")
		return nil
	}

	sm.sendToDevice(targetDeviceID, msg)
	return nil
}

// ─── Subscription ─────────────────────────────────────────────────────────

// handleSubscribe: adds device as viewer, pushes full session snapshot.
func (sm *SessionManager) handleSubscribe(deviceID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "session.subscribe requires session_id")
		return nil
	}

	// First, look up the session owner WITHOUT holding the lock for the DB query.
	sm.mu.RLock()
	si, exists := sm.sessions[msg.SessionID]
	var ownerID string
	if exists {
		ownerID = si.OwnerID
	}
	sm.mu.RUnlock()

	if !exists {
		sm.sendError(deviceID, "session_not_found", fmt.Sprintf("Session %s not found", msg.SessionID))
		return nil
	}

	// Pairing check runs OUTSIDE the lock — no global stall during DB I/O.
	if deviceID != ownerID {
		paired, err := sm.store.IsPaired(context.Background(), ownerID, deviceID)
		if err != nil {
			sm.sendError(deviceID, "pairing_lookup_failed", "Failed to verify pairing")
			return err
		}
		if !paired {
			sm.sendError(deviceID, "permission_denied", "Device is not paired with this desktop")
			return nil
		}
	}

	// Now take the write lock briefly to add the viewer.
	sm.mu.Lock()
	si, exists = sm.sessions[msg.SessionID]
	if !exists {
		sm.mu.Unlock()
		sm.sendError(deviceID, "session_not_found", fmt.Sprintf("Session %s not found", msg.SessionID))
		return nil
	}
	si.Viewers[deviceID] = true
	snapshot := sessionSnapshot(msg.SessionID, si)
	sm.mu.Unlock()

	// Push full snapshot to the subscribing device
	snapshotMsg := models.Message{
		Type:      string(models.MsgSessionState),
		SessionID: msg.SessionID,
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"snapshot": snapshot,
		},
	}
	sm.sendToDevice(deviceID, snapshotMsg)

	log.Printf("[sub] Device %s subscribed to session %s", deviceID, msg.SessionID)
	return nil
}

// handleUnsubscribe: removes device from viewer set.
func (sm *SessionManager) handleUnsubscribe(deviceID string, msg models.Message) error {
	if msg.SessionID == "" {
		sm.sendError(deviceID, "missing_session_id", "session.unsubscribe requires session_id")
		return nil
	}

	sm.mu.Lock()
	if si, ok := sm.sessions[msg.SessionID]; ok {
		delete(si.Viewers, deviceID)
	}
	sm.mu.Unlock()

	log.Printf("[sub] Device %s unsubscribed from session %s", deviceID, msg.SessionID)
	return nil
}

// ─── Heartbeat ────────────────────────────────────────────────────────────

func (sm *SessionManager) handleHeartbeat(deviceID string) error {
	sm.store.SetOnline(context.Background(), deviceID)

	// Respond with heartbeat ack
	ack := models.Message{
		Type:      string(models.MsgHeartbeat),
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"ack": true,
		},
	}
	sm.sendToDevice(deviceID, ack)
	return nil
}

// ─── Helpers ──────────────────────────────────────────────────────────────

// broadcastToViewers sends a message to all viewers of a session, optionally excluding one device.
func (sm *SessionManager) broadcastToViewers(sessionID string, msg models.Message, excludeDeviceID string) {
	sm.mu.RLock()
	si, exists := sm.sessions[sessionID]
	if !exists {
		sm.mu.RUnlock()
		return
	}
	// Copy viewer set to avoid holding lock during sends
	viewers := make([]string, 0, len(si.Viewers))
	for vid := range si.Viewers {
		if vid != excludeDeviceID {
			viewers = append(viewers, vid)
		}
	}
	sm.mu.RUnlock()

	for _, vid := range viewers {
		sm.sendToDevice(vid, msg)
	}
}

// isViewer checks if a device is a viewer of a session.
func (sm *SessionManager) isViewer(sessionID, deviceID string) bool {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	if si, ok := sm.sessions[sessionID]; ok {
		return si.Viewers[deviceID]
	}
	return false
}

// sendToDevice sends a message to a specific device with retry.
func (sm *SessionManager) sendToDevice(deviceID string, msg models.Message) {
	sm.mu.RLock()
	conn, ok := sm.deviceConnections[deviceID]
	sm.mu.RUnlock()

	if !ok || conn == nil {
		return
	}

	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("[send] Failed to marshal message: %v", err)
		return
	}

	const maxRetries = 2
	for attempt := 0; attempt <= maxRetries; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		err := conn.Write(ctx, websocket.MessageText, data)
		cancel()

		if err == nil {
			return
		}

		// Check if the connection has been replaced while we were retrying
		sm.mu.RLock()
		currentConn := sm.deviceConnections[deviceID]
		sm.mu.RUnlock()
		if currentConn != conn {
			// Connection was replaced; abort retries on the stale one
			return
		}

		if attempt < maxRetries {
			log.Printf("[send] Write to %s failed (attempt %d/%d): %v", deviceID, attempt+1, maxRetries+1, err)
			time.Sleep(200 * time.Millisecond)
		} else {
			log.Printf("[send] Write to %s failed after %d attempts: %v — closing connection", deviceID, maxRetries+1, err)
			go func() {
				_ = conn.Close(websocket.StatusGoingAway, "write failed")
				sm.UnregisterConnection(deviceID, conn)
			}()
		}
	}
}

// sendError sends an error message to a device.
func (sm *SessionManager) sendError(deviceID, code, message string) {
	errMsg := models.Message{
		Type:      string(models.MsgError),
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"code":    code,
			"message": message,
		},
	}
	sm.sendToDevice(deviceID, errMsg)
}

// notifyPairedMobiles sends a message to all mobiles paired with the owner.
func (sm *SessionManager) notifyPairedMobiles(ownerID string, msg models.Message) {
	mobileIDs, err := sm.store.ListPairedMobileIDs(context.Background(), ownerID)
	if err != nil {
		log.Printf("[pairing] Failed to list paired mobiles for %s: %v", ownerID, err)
		return
	}

	for _, deviceID := range mobileIDs {
		dID := deviceID
		go func() {
			sm.sendToDevice(dID, msg)
		}()
	}
}

// GetActiveSessionsForDevice returns all active sessions for a device.
func (sm *SessionManager) GetActiveSessionsForDevice(deviceID string) ([]models.Session, error) {
	return sm.store.GetActiveSessions(context.Background(), deviceID)
}

// GetAllActiveSessions returns all active sessions.
func (sm *SessionManager) GetAllActiveSessions() ([]models.Session, error) {
	return sm.store.GetAllActiveSessions(context.Background())
}

// GetOnlineDeviceCount returns the number of currently online devices.
func (sm *SessionManager) GetOnlineDeviceCount() int {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return len(sm.deviceConnections)
}

// GetSessionInfo returns info about a session (thread-safe).
func (sm *SessionManager) GetSessionInfo(sessionID string) (*SessionInfo, bool) {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	si, ok := sm.sessions[sessionID]
	return si, ok
}

func (sm *SessionManager) getDeviceType(deviceID string) string {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return sm.deviceTypes[deviceID]
}

func (sm *SessionManager) isDeviceOnline(deviceID string) bool {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	conn, ok := sm.deviceConnections[deviceID]
	return ok && conn != nil
}

// PushSessionList sends the current visible session snapshot list to a device.
func (sm *SessionManager) PushSessionList(deviceID string) error {
	snapshots, err := sm.listSessionSnapshotsForDevice(deviceID)
	if err != nil {
		sm.sendError(deviceID, "pairing_lookup_failed", "Failed to load paired desktops")
		return err
	}

	resp := models.Message{
		Type:      string(models.MsgSessionListRes),
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"sessions": snapshots,
		},
	}

	sm.sendToDevice(deviceID, resp)
	return nil
}

func (sm *SessionManager) listSessionSnapshotsForDevice(deviceID string) ([]models.SessionSnapshot, error) {
	deviceType := sm.getDeviceType(deviceID)
	allowedOwners := map[string]bool{}
	if deviceType == "mobile" {
		pairedDesktopIDs, err := sm.store.ListPairedDesktopIDs(context.Background(), deviceID)
		if err != nil {
			return nil, err
		}
		for _, ownerID := range pairedDesktopIDs {
			allowedOwners[ownerID] = true
		}
	}

	sm.mu.RLock()
	defer sm.mu.RUnlock()

	snapshots := make([]models.SessionSnapshot, 0, len(sm.sessions))
	for sid, si := range sm.sessions {
		if si.Status != "active" {
			continue
		}
		if deviceType == "mobile" && !allowedOwners[si.OwnerID] {
			continue
		}
		if deviceType != "mobile" && si.OwnerID != deviceID {
			continue
		}
		snapshots = append(snapshots, sessionSnapshot(sid, si))
	}

	return snapshots, nil
}

// ─── Payload helpers ──────────────────────────────────────────────────────

func numField(payload map[string]interface{}, key string) (float64, bool) {
	if payload == nil {
		return 0, false
	}
	v, ok := payload[key].(float64)
	return v, ok
}

func strField(payload map[string]interface{}, key, fallback string) string {
	if payload == nil {
		return fallback
	}
	v, ok := payload[key].(string)
	if !ok {
		return fallback
	}
	return v
}

func optionalStrField(payload map[string]interface{}, key string) (string, bool) {
	if payload == nil {
		return "", false
	}
	value, exists := payload[key]
	if !exists {
		return "", false
	}
	str, ok := value.(string)
	if !ok {
		return "", false
	}
	return str, true
}

func sessionSnapshot(sessionID string, si *SessionInfo) models.SessionSnapshot {
	return models.SessionSnapshot{
		SessionID: sessionID,
		OwnerID:   si.OwnerID,
		Title:     si.Title,
		Cols:      si.Cols,
		Rows:      si.Rows,
		Status:    si.Status,
		TaskState: si.TaskState,
		Preview:   si.Preview,
		Activity:  si.Activity,
	}
}
