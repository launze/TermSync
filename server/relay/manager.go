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

type WorkspaceInfo struct {
	WorkspaceID string
	OwnerID     string
	Version     int64
	Snapshot    map[string]interface{}
	Subscribers map[string]bool
	UpdatedAt   time.Time
}

type ScreenDelta struct {
	Seq      int64
	Encoding string
	Payload  map[string]interface{}
}

type ScreenStreamInfo struct {
	WorkspaceID string
	PaneID      string
	SessionID   string
	OwnerID     string
	Snapshot    map[string]interface{}
	Snapshots   map[string]map[string]interface{}
	Deltas      []ScreenDelta
	Subscribers map[string]*ScreenSubscriberState
	LastSeq     int64
	UpdatedAt   time.Time
}

type ScreenSubscriberState struct {
	LastAckSeq        int64
	LastSentSeq       int64
	NeedsResync       bool
	SubscribedAt      time.Time
	LastAckAt         time.Time
	LastResyncAskAt   time.Time
	SkippedDeltaCount int
	Encoding          string
}

const (
	outboundQueueSize             = 1024
	screenDeltaBacklogLimit       = 256
	screenDeltaAckLagLimit  int64 = 256
	screenEncodingVT              = "base64+vt"
	screenEncodingCells           = "base64+cells-json"
)

type deviceSender struct {
	conn      *websocket.Conn
	queue     chan []byte
	done      chan struct{}
	closeOnce sync.Once
}

type inboundTrafficStats struct {
	windowStart time.Time
	bytes       int64
	messages    int64
	byType      map[string]int64
}

func newDeviceSender(conn *websocket.Conn) *deviceSender {
	return &deviceSender{
		conn:  conn,
		queue: make(chan []byte, outboundQueueSize),
		done:  make(chan struct{}),
	}
}

// SessionManager manages all WebSocket connections and session routing
// with strict owner/viewer semantics and validated message routing.
type SessionManager struct {
	store *store.Store

	mu sync.RWMutex

	// deviceConnections maps device ID to its WebSocket connection
	deviceConnections map[string]*websocket.Conn

	deviceSenders map[string]*deviceSender

	// connectionIDs maps device ID to the currently active connection ID.
	connectionIDs map[string]string

	// deviceTypes maps device ID to its type ("desktop" | "mobile" | "pc_receiver")
	deviceTypes map[string]string

	selectedProtocols map[string]int
	clientInstances   map[string]string

	workspaces    map[string]*WorkspaceInfo
	paneStreams   map[string]*ScreenStreamInfo
	paneWorkspace map[string]string

	// recentInputs suppresses accidental duplicate input.send delivery.
	recentInputs map[string]time.Time

	recentMessageIDs map[string]time.Time

	inboundStats map[string]*inboundTrafficStats
}

// NewSessionManager creates a new SessionManager.
func NewSessionManager(store *store.Store) *SessionManager {
	return &SessionManager{
		store:             store,
		deviceConnections: make(map[string]*websocket.Conn),
		deviceSenders:     make(map[string]*deviceSender),
		connectionIDs:     make(map[string]string),
		deviceTypes:       make(map[string]string),
		selectedProtocols: make(map[string]int),
		clientInstances:   make(map[string]string),
		workspaces:        make(map[string]*WorkspaceInfo),
		paneStreams:       make(map[string]*ScreenStreamInfo),
		paneWorkspace:     make(map[string]string),
		recentInputs:      make(map[string]time.Time),
		recentMessageIDs:  make(map[string]time.Time),
		inboundStats:      make(map[string]*inboundTrafficStats),
	}
}

// ─── Connection lifecycle ─────────────────────────────────────────────────

type ConnectionMeta struct {
	ConnectionID         string
	ClientInstanceID     string
	ConnectionGeneration int64
	SelectedProtocol     int
}

// RegisterConnection registers a new WebSocket connection for a device.
func (sm *SessionManager) RegisterConnection(deviceID, deviceType string, conn *websocket.Conn, meta ConnectionMeta) {
	if meta.ConnectionID == "" {
		meta.ConnectionID = fmt.Sprintf("%s:%d", deviceID, time.Now().UnixNano())
	}
	if meta.SelectedProtocol != 3 {
		meta.SelectedProtocol = 3
	}

	sm.mu.Lock()

	var oldConn *websocket.Conn
	var oldSender *deviceSender
	var oldConnectionID string
	if oldConn, ok := sm.deviceConnections[deviceID]; ok {
		oldConnectionID = sm.connectionIDs[deviceID]
		_ = oldConn
		oldSender = sm.deviceSenders[deviceID]
	}

	sender := newDeviceSender(conn)
	sm.deviceConnections[deviceID] = conn
	sm.deviceSenders[deviceID] = sender
	sm.connectionIDs[deviceID] = meta.ConnectionID
	sm.deviceTypes[deviceID] = deviceType
	sm.selectedProtocols[deviceID] = meta.SelectedProtocol
	sm.clientInstances[deviceID] = meta.ClientInstanceID

	// Update online status in database
	ctx := context.Background()
	sm.store.SetOnline(ctx, deviceID)

	total := len(sm.deviceConnections)
	sm.mu.Unlock()

	go sm.runDeviceSender(deviceID, conn, sender)

	if oldConn != nil {
		sm.notifyConnectionReplaced(oldConn, oldSender, deviceID, oldConnectionID, meta.ConnectionID)
	}

	log.Printf(
		"[conn] Device %s (%s) connected conn=%s instance=%s protocol=v%d generation=%d (total: %d)",
		deviceID,
		deviceType,
		meta.ConnectionID,
		meta.ClientInstanceID,
		meta.SelectedProtocol,
		meta.ConnectionGeneration,
		total,
	)

	go func() {
		sm.broadcastPeerStateForDevice(deviceID)
		sm.broadcastPeerStateToPairedDevices(deviceID)
	}()
}

// UnregisterConnection removes a WebSocket connection and clears viewer
// subscriptions. Owner state is restored from the next v3 layout/screen publish.
func (sm *SessionManager) UnregisterConnection(deviceID string, conn *websocket.Conn) {
	sm.mu.Lock()

	currentConn, exists := sm.deviceConnections[deviceID]
	if !exists || currentConn != conn {
		sm.mu.Unlock()
		return
	}

	deviceType := sm.deviceTypes[deviceID]
	sender := sm.deviceSenders[deviceID]
	delete(sm.deviceConnections, deviceID)
	delete(sm.deviceSenders, deviceID)
	delete(sm.connectionIDs, deviceID)
	delete(sm.deviceTypes, deviceID)
	delete(sm.selectedProtocols, deviceID)
	delete(sm.clientInstances, deviceID)

	// Update online status
	ctx := context.Background()
	sm.store.SetOffline(ctx, deviceID)

	// Capture connection count while under lock
	remaining := len(sm.deviceConnections)

	// Release lock before broadcasting to avoid deadlock
	sm.mu.Unlock()

	if sender != nil {
		sender.close()
	}

	log.Printf("[conn] Device %s disconnected (remaining: %d)", deviceID, remaining)
	go sm.broadcastPeerStateToPairedDevicesWithType(deviceID, deviceType)
}

// ─── Message dispatch with validation ─────────────────────────────────────

// HandleConnectionMessage routes a message from a concrete WebSocket
// connection. Retired connections are dropped before business routing.
func (sm *SessionManager) HandleConnectionMessage(deviceID string, conn *websocket.Conn, msgData []byte) error {
	if !sm.isCurrentConnection(deviceID, conn) {
		log.Printf("[conn] dropped message from retired connection device=%s", deviceID)
		return nil
	}
	return sm.HandleMessage(deviceID, msgData)
}

// HandleMessage routes a v3 message with strict permission checks.
func (sm *SessionManager) HandleMessage(deviceID string, msgData []byte) error {
	var msg models.Message
	if err := json.Unmarshal(msgData, &msg); err != nil {
		sm.sendError(deviceID, "invalid_json", "Failed to parse message")
		return err
	}

	sm.recordInboundTraffic(deviceID, msg.Type, len(msgData))

	if msg.V != 3 {
		sm.sendError(deviceID, "unsupported_protocol", "TermSync server now accepts protocol v3 messages only")
		return nil
	}

	if msg.ID != "" && sm.shouldDropDuplicateMessage(deviceID, msg.ID) {
		log.Printf("[msg] duplicate dropped device=%s id=%s type=%s", deviceID, msg.ID, msg.Type)
		return nil
	}

	msgType := models.MsgType(msg.Type)

	// Device clocks can drift or jump after sleep/resume. Treat timestamp as
	// diagnostic metadata instead of a user-visible protocol error.
	if msg.Timestamp > 0 {
		age := time.Now().Unix() - msg.Timestamp
		if age > 24*60*60 || age < -5*60 {
			log.Printf("[msg] suspicious timestamp device=%s type=%s timestamp=%d age=%ds", deviceID, msg.Type, msg.Timestamp, age)
		}
	}

	switch msgType {
	// Auth
	case models.MsgAuth:
		// Auth is handled by WSHandler before registration; ignore here
		return nil

	case models.MsgWorkspaceList:
		return sm.handleWorkspaceList(deviceID, msg)
	case models.MsgWorkspaceSubscribe:
		return sm.handleWorkspaceSubscribe(deviceID, msg)
	case models.MsgWorkspaceUnsubscribe:
		return sm.handleWorkspaceUnsubscribe(deviceID, msg)
	case models.MsgLayoutSnapshot:
		return sm.handleLayoutSnapshot(deviceID, msg)
	case models.MsgLayoutPatch:
		return sm.handleLayoutPatch(deviceID, msg)
	case models.MsgLayoutActionRequest:
		return sm.handleLayoutActionRequest(deviceID, msg)
	case models.MsgLayoutActionResult:
		return sm.handleLayoutActionResult(deviceID, msg)
	case models.MsgScreenSubscribe:
		return sm.handleScreenSubscribe(deviceID, msg)
	case models.MsgScreenUnsubscribe:
		return sm.handleScreenUnsubscribe(deviceID, msg)
	case models.MsgScreenSnapshot:
		return sm.handleScreenSnapshot(deviceID, msg)
	case models.MsgScreenDelta:
		return sm.handleScreenDelta(deviceID, msg)
	case models.MsgScreenAck:
		return sm.handleScreenAck(deviceID, msg)
	case models.MsgScreenResyncRequest:
		return sm.handleScreenResyncRequest(deviceID, msg)
	case models.MsgScreenHistoryRequest:
		return sm.handleScreenHistoryRequest(deviceID, msg)
	case models.MsgScreenHistoryResponse:
		return sm.handleScreenHistoryResponse(deviceID, msg)
	case models.MsgScreenClear:
		return sm.handleScreenClear(deviceID, msg)
	case models.MsgInputSend:
		return sm.handleInputSend(deviceID, msg)

	// Heartbeat
	case models.MsgHeartbeat:
		return sm.handleHeartbeat(deviceID)

	default:
		sm.sendError(deviceID, "unknown_type", fmt.Sprintf("Unknown message type: %s", msg.Type))
		return nil
	}
}

func (sm *SessionManager) handleScreenHistoryRequest(deviceID string, msg models.Message) error {
	paneID := msg.PaneID
	if paneID == "" {
		paneID = strField(msg.Payload, "pane_id", "")
	}
	if paneID == "" {
		sm.sendError(deviceID, "missing_pane_id", "screen.history_request requires pane_id")
		return nil
	}
	sm.mu.RLock()
	stream, _ := sm.findScreenStreamLocked(msg.WorkspaceID, paneID)
	sm.mu.RUnlock()
	if stream == nil {
		sm.sendError(deviceID, "screen_not_found", "Screen stream not found")
		return nil
	}
	if err := sm.requireWorkspaceAccess(deviceID, stream.OwnerID); err != nil {
		sm.sendError(deviceID, "permission_denied", err.Error())
		return nil
	}
	if deviceID == stream.OwnerID {
		return nil
	}
	if msg.Payload == nil {
		msg.Payload = map[string]interface{}{}
	}
	msg.V = 3
	msg.WorkspaceID = stream.WorkspaceID
	msg.PaneID = paneID
	msg.Payload["requested_by"] = deviceID
	sm.sendToDevice(stream.OwnerID, msg)
	return nil
}

func (sm *SessionManager) handleScreenHistoryResponse(deviceID string, msg models.Message) error {
	if !sm.isOwnerDevice(deviceID) {
		sm.sendError(deviceID, "permission_denied", "Only screen owner can publish history")
		return nil
	}
	paneID := msg.PaneID
	if paneID == "" {
		paneID = strField(msg.Payload, "pane_id", "")
	}
	target := strField(msg.Payload, "target_device_id", "")
	if paneID == "" || target == "" {
		sm.sendError(deviceID, "invalid_history_response", "pane_id and target_device_id are required")
		return nil
	}
	sm.mu.RLock()
	stream, _ := sm.findScreenStreamLocked(msg.WorkspaceID, paneID)
	subscribed := false
	if stream != nil {
		_, subscribed = stream.Subscribers[target]
	}
	sm.mu.RUnlock()
	if stream == nil || stream.OwnerID != deviceID || !subscribed {
		sm.sendError(deviceID, "permission_denied", "History target is not subscribed to this screen")
		return nil
	}
	msg.V = 3
	msg.WorkspaceID = stream.WorkspaceID
	msg.PaneID = paneID
	sm.sendToDevice(target, msg)
	return nil
}

func (sm *SessionManager) recordInboundTraffic(deviceID, msgType string, byteCount int) {
	if deviceID == "" || byteCount <= 0 {
		return
	}
	if msgType == "" {
		msgType = "unknown"
	}

	now := time.Now()
	sm.mu.Lock()
	stats := sm.inboundStats[deviceID]
	if stats == nil {
		stats = &inboundTrafficStats{
			windowStart: now,
			byType:      make(map[string]int64),
		}
		sm.inboundStats[deviceID] = stats
	}
	if now.Sub(stats.windowStart) >= 5*time.Second {
		elapsed := now.Sub(stats.windowStart).Seconds()
		bytes := stats.bytes
		messages := stats.messages
		byType := make(map[string]int64, len(stats.byType))
		for key, value := range stats.byType {
			byType[key] = value
		}
		stats.windowStart = now
		stats.bytes = int64(byteCount)
		stats.messages = 1
		stats.byType = make(map[string]int64)
		stats.byType[msgType] = int64(byteCount)
		sm.mu.Unlock()

		if elapsed > 0 && bytes > 0 {
			log.Printf("[traffic:in] device=%s app_bytes=%d app_bps=%.0f messages=%d by_type=%v", deviceID, bytes, float64(bytes)/elapsed, messages, byType)
		}
		return
	}
	stats.bytes += int64(byteCount)
	stats.messages += 1
	stats.byType[msgType] += int64(byteCount)
	sm.mu.Unlock()
}

// ─── Session lifecycle ────────────────────────────────────────────────────

func (sm *SessionManager) handleWorkspaceList(deviceID string, msg models.Message) error {
	deviceType := sm.getDeviceType(deviceID)
	allowedOwners, err := sm.allowedWorkspaceOwners(deviceID, deviceType)
	if err != nil {
		sm.sendError(deviceID, "pairing_lookup_failed", "Failed to load paired desktops")
		return err
	}

	sm.mu.RLock()
	workspaces := make([]map[string]interface{}, 0, len(sm.workspaces))
	for workspaceID, ws := range sm.workspaces {
		if !allowedOwners[ws.OwnerID] {
			continue
		}
		workspaces = append(workspaces, map[string]interface{}{
			"workspace_id":    workspaceID,
			"owner_device_id": ws.OwnerID,
			"layout_version":  ws.Version,
			"updated_at":      ws.UpdatedAt.Unix(),
		})
	}
	sm.mu.RUnlock()

	sm.sendToDevice(deviceID, models.Message{
		Type:      string(models.MsgWorkspaceListRes),
		V:         3,
		ID:        newMessageID(),
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"workspaces": workspaces,
		},
	})
	return nil
}

func (sm *SessionManager) handleWorkspaceSubscribe(deviceID string, msg models.Message) error {
	workspaceID := msg.WorkspaceID
	if workspaceID == "" {
		workspaceID = strField(msg.Payload, "workspace_id", "")
	}
	if workspaceID == "" {
		sm.sendError(deviceID, "missing_workspace_id", "workspace.subscribe requires workspace_id")
		return nil
	}

	sm.mu.RLock()
	ws, exists := sm.workspaces[workspaceID]
	ownerID := ""
	if exists {
		ownerID = ws.OwnerID
	}
	sm.mu.RUnlock()
	if !exists {
		sm.sendError(deviceID, "workspace_not_found", fmt.Sprintf("Workspace %s not found", workspaceID))
		return nil
	}
	if err := sm.requireWorkspaceAccess(deviceID, ownerID); err != nil {
		sm.sendError(deviceID, "permission_denied", err.Error())
		return nil
	}

	sm.mu.Lock()
	ws, exists = sm.workspaces[workspaceID]
	if !exists {
		sm.mu.Unlock()
		sm.sendError(deviceID, "workspace_not_found", fmt.Sprintf("Workspace %s not found", workspaceID))
		return nil
	}
	ws.Subscribers[deviceID] = true
	snapshot := clonePayload(ws.Snapshot)
	version := ws.Version
	sm.mu.Unlock()

	sm.sendToDevice(deviceID, models.Message{
		Type:        string(models.MsgLayoutSnapshot),
		V:           3,
		ID:          newMessageID(),
		WorkspaceID: workspaceID,
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"layout_version": version,
			"snapshot":       snapshot,
		},
	})
	return nil
}

func (sm *SessionManager) handleWorkspaceUnsubscribe(deviceID string, msg models.Message) error {
	workspaceID := msg.WorkspaceID
	if workspaceID == "" {
		workspaceID = strField(msg.Payload, "workspace_id", "")
	}
	sm.mu.Lock()
	if workspaceID != "" {
		if ws, ok := sm.workspaces[workspaceID]; ok {
			delete(ws.Subscribers, deviceID)
		}
	} else {
		for _, ws := range sm.workspaces {
			delete(ws.Subscribers, deviceID)
		}
	}
	sm.mu.Unlock()
	return nil
}

func (sm *SessionManager) handleLayoutSnapshot(deviceID string, msg models.Message) error {
	if msg.WorkspaceID == "" {
		sm.sendError(deviceID, "missing_workspace_id", "layout.snapshot requires workspace_id")
		return nil
	}
	if !sm.isOwnerDevice(deviceID) {
		sm.sendError(deviceID, "permission_denied", "Only desktop owner can publish layout.snapshot")
		return nil
	}
	snapshot := objectField(msg.Payload, "snapshot")
	if snapshot == nil {
		snapshot = clonePayload(msg.Payload)
	}
	version := int64Field(msg.Payload, "layout_version", time.Now().UnixMilli())

	sm.mu.Lock()
	ws := sm.workspaces[msg.WorkspaceID]
	if ws == nil {
		ws = &WorkspaceInfo{
			WorkspaceID: msg.WorkspaceID,
			OwnerID:     deviceID,
			Subscribers: make(map[string]bool),
		}
		sm.workspaces[msg.WorkspaceID] = ws
	}
	if ws.OwnerID != deviceID {
		sm.mu.Unlock()
		sm.sendError(deviceID, "permission_denied", "Only workspace owner can publish layout")
		return nil
	}
	ws.Version = version
	ws.Snapshot = snapshot
	ws.UpdatedAt = time.Now()
	subscribers := keysExcept(ws.Subscribers, deviceID)
	sm.indexWorkspacePanesLocked(msg.WorkspaceID, deviceID, snapshot)
	sm.mu.Unlock()

	msg.V = 3
	if msg.ID == "" {
		msg.ID = newMessageID()
	}
	msg.Payload = map[string]interface{}{
		"layout_version": version,
		"snapshot":       snapshot,
	}
	for _, subscriber := range subscribers {
		sm.sendToDevice(subscriber, msg)
	}
	return nil
}

func (sm *SessionManager) handleLayoutPatch(deviceID string, msg models.Message) error {
	if msg.WorkspaceID == "" {
		sm.sendError(deviceID, "missing_workspace_id", "layout.patch requires workspace_id")
		return nil
	}
	if !sm.isOwnerDevice(deviceID) {
		sm.sendError(deviceID, "permission_denied", "Only desktop owner can publish layout.patch")
		return nil
	}

	sm.mu.Lock()
	ws := sm.workspaces[msg.WorkspaceID]
	if ws == nil || ws.OwnerID != deviceID {
		sm.mu.Unlock()
		sm.sendError(deviceID, "workspace_not_found", "Workspace not found for owner")
		return nil
	}
	if version := int64Field(msg.Payload, "layout_version", 0); version > 0 {
		ws.Version = version
	} else {
		ws.Version++
	}
	if snapshot := objectField(msg.Payload, "snapshot"); snapshot != nil {
		ws.Snapshot = snapshot
		sm.indexWorkspacePanesLocked(msg.WorkspaceID, deviceID, snapshot)
	}
	ws.UpdatedAt = time.Now()
	subscribers := keysExcept(ws.Subscribers, deviceID)
	sm.mu.Unlock()

	msg.V = 3
	if msg.ID == "" {
		msg.ID = newMessageID()
	}
	for _, subscriber := range subscribers {
		sm.sendToDevice(subscriber, msg)
	}
	return nil
}

func (sm *SessionManager) handleLayoutActionRequest(deviceID string, msg models.Message) error {
	workspaceID := msg.WorkspaceID
	if workspaceID == "" {
		workspaceID = strField(msg.Payload, "workspace_id", "")
	}
	sm.mu.RLock()
	ws := sm.workspaces[workspaceID]
	sm.mu.RUnlock()
	if ws == nil {
		sm.sendError(deviceID, "workspace_not_found", "Workspace not found")
		return nil
	}
	if err := sm.requireWorkspaceAccess(deviceID, ws.OwnerID); err != nil {
		sm.sendError(deviceID, "permission_denied", err.Error())
		return nil
	}
	if deviceID == ws.OwnerID {
		return nil
	}
	if msg.Payload == nil {
		msg.Payload = map[string]interface{}{}
	}
	msg.Payload["requested_by"] = deviceID
	msg.WorkspaceID = workspaceID
	msg.V = 3
	if msg.ID == "" {
		msg.ID = newMessageID()
	}
	sm.sendToDevice(ws.OwnerID, msg)
	return nil
}

func (sm *SessionManager) handleLayoutActionResult(deviceID string, msg models.Message) error {
	if msg.WorkspaceID == "" {
		sm.sendError(deviceID, "missing_workspace_id", "layout.action_result requires workspace_id")
		return nil
	}
	sm.mu.RLock()
	ws := sm.workspaces[msg.WorkspaceID]
	sm.mu.RUnlock()
	if ws == nil || ws.OwnerID != deviceID {
		sm.sendError(deviceID, "permission_denied", "Only workspace owner can publish action result")
		return nil
	}
	target := strField(msg.Payload, "target_device_id", "")
	if target != "" {
		sm.sendToDevice(target, msg)
		return nil
	}
	sm.broadcastWorkspace(msg.WorkspaceID, msg, deviceID)
	return nil
}

func (sm *SessionManager) handleScreenSubscribe(deviceID string, msg models.Message) error {
	paneID := msg.PaneID
	if paneID == "" {
		paneID = strField(msg.Payload, "pane_id", "")
	}
	if paneID == "" {
		sm.sendError(deviceID, "missing_pane_id", "screen.subscribe requires pane_id")
		return nil
	}
	encoding := normalizeScreenEncoding(strField(msg.Payload, "encoding", strField(msg.Payload, "preferred_encoding", "")))

	sm.mu.RLock()
	stream, _ := sm.findScreenStreamLocked(msg.WorkspaceID, paneID)
	if stream == nil && msg.WorkspaceID != "" {
		if ws := sm.workspaces[msg.WorkspaceID]; ws != nil {
			stream = &ScreenStreamInfo{
				WorkspaceID: msg.WorkspaceID,
				PaneID:      paneID,
				OwnerID:     ws.OwnerID,
				Subscribers: map[string]*ScreenSubscriberState{},
				UpdatedAt:   time.Now(),
			}
		}
	}
	sm.mu.RUnlock()
	if stream == nil {
		sm.sendError(deviceID, "screen_not_found", "Screen stream not found")
		return nil
	}
	if err := sm.requireWorkspaceAccess(deviceID, stream.OwnerID); err != nil {
		sm.sendError(deviceID, "permission_denied", err.Error())
		return nil
	}

	sm.mu.Lock()
	stream, _ = sm.findScreenStreamLocked(msg.WorkspaceID, paneID)
	if stream == nil {
		stream = &ScreenStreamInfo{
			WorkspaceID: msg.WorkspaceID,
			PaneID:      paneID,
			OwnerID:     sm.workspaceOwnerLocked(msg.WorkspaceID),
			Subscribers: map[string]*ScreenSubscriberState{},
			UpdatedAt:   time.Now(),
		}
		sm.paneStreams[screenStreamKey(msg.WorkspaceID, paneID)] = stream
	}
	stream.Subscribers[deviceID] = &ScreenSubscriberState{
		SubscribedAt: time.Now(),
		Encoding:     encoding,
	}
	snapshot := clonePayload(screenSnapshotForEncoding(stream, encoding))
	lastSeq := stream.LastSeq
	sm.mu.Unlock()

	if snapshot != nil {
		sm.sendToDevice(deviceID, models.Message{
			Type:        string(models.MsgScreenSnapshot),
			V:           3,
			ID:          newMessageID(),
			WorkspaceID: stream.WorkspaceID,
			PaneID:      paneID,
			SessionID:   stream.SessionID,
			Timestamp:   time.Now().Unix(),
			Payload:     snapshot,
		})
	}
	if stream.OwnerID != "" && stream.OwnerID != deviceID {
		sm.sendToDevice(stream.OwnerID, models.Message{
			Type:        string(models.MsgScreenResyncRequest),
			V:           3,
			ID:          newMessageID(),
			WorkspaceID: stream.WorkspaceID,
			PaneID:      paneID,
			SessionID:   stream.SessionID,
			Timestamp:   time.Now().Unix(),
			Payload: map[string]interface{}{
				"requested_by": deviceID,
				"last_seq":     lastSeq,
				"encoding":     encoding,
			},
		})
	}
	return nil
}

func (sm *SessionManager) handleScreenUnsubscribe(deviceID string, msg models.Message) error {
	paneID := msg.PaneID
	if paneID == "" {
		paneID = strField(msg.Payload, "pane_id", "")
	}
	sm.mu.Lock()
	if paneID != "" {
		if stream, _ := sm.findScreenStreamLocked(msg.WorkspaceID, paneID); stream != nil {
			delete(stream.Subscribers, deviceID)
		}
	} else {
		for _, stream := range sm.paneStreams {
			delete(stream.Subscribers, deviceID)
		}
	}
	sm.mu.Unlock()
	return nil
}

func (sm *SessionManager) handleScreenSnapshot(deviceID string, msg models.Message) error {
	if msg.PaneID == "" {
		sm.sendError(deviceID, "missing_pane_id", "screen.snapshot requires pane_id")
		return nil
	}
	if !sm.isOwnerDevice(deviceID) {
		sm.sendError(deviceID, "permission_denied", "Only owner can publish screen.snapshot")
		return nil
	}
	workspaceID := msg.WorkspaceID
	if workspaceID == "" {
		workspaceID = sm.workspaceForOwnedPane(deviceID, msg.PaneID)
	}
	sm.mu.Lock()
	if !sm.paneBelongsToWorkspaceLocked(workspaceID, msg.PaneID) {
		sm.mu.Unlock()
		sm.sendError(deviceID, "stale_pane", "Pane is not present in the current workspace layout")
		return nil
	}
	stream, _ := sm.findScreenStreamLocked(workspaceID, msg.PaneID)
	if stream == nil {
		stream = &ScreenStreamInfo{
			WorkspaceID: workspaceID,
			PaneID:      msg.PaneID,
			SessionID:   msg.SessionID,
			OwnerID:     deviceID,
			Subscribers: map[string]*ScreenSubscriberState{},
		}
		sm.paneStreams[screenStreamKey(workspaceID, msg.PaneID)] = stream
	}
	if stream.OwnerID != "" && stream.OwnerID != deviceID {
		sm.mu.Unlock()
		sm.sendError(deviceID, "permission_denied", "Only screen owner can publish snapshot")
		return nil
	}
	stream.OwnerID = deviceID
	stream.WorkspaceID = workspaceID
	stream.SessionID = msg.SessionID
	encoding := normalizeScreenEncoding(strField(msg.Payload, "encoding", ""))
	if stream.Snapshots == nil {
		stream.Snapshots = map[string]map[string]interface{}{}
	}
	stream.Snapshots[encoding] = clonePayload(msg.Payload)
	if encoding == screenEncodingVT {
		stream.Snapshot = clonePayload(msg.Payload)
	}
	stream.LastSeq = int64Field(msg.Payload, "snapshot_seq", stream.LastSeq)
	stream.UpdatedAt = time.Now()
	subscribers := screenSubscribersExceptEncoding(stream.Subscribers, deviceID, encoding)
	sm.mu.Unlock()

	msg.V = 3
	if msg.ID == "" {
		msg.ID = newMessageID()
	}
	msg.WorkspaceID = workspaceID
	for _, subscriber := range subscribers {
		sm.sendToDevice(subscriber, msg)
	}
	return nil
}

func (sm *SessionManager) handleScreenDelta(deviceID string, msg models.Message) error {
	if msg.PaneID == "" {
		sm.sendError(deviceID, "missing_pane_id", "screen.delta requires pane_id")
		return nil
	}
	if !sm.isOwnerDevice(deviceID) {
		sm.sendError(deviceID, "permission_denied", "Only owner can publish screen.delta")
		return nil
	}
	seq := int64Field(msg.Payload, "seq", 0)
	workspaceID := msg.WorkspaceID
	if workspaceID == "" {
		workspaceID = sm.workspaceForOwnedPane(deviceID, msg.PaneID)
	}

	sm.mu.Lock()
	if !sm.paneBelongsToWorkspaceLocked(workspaceID, msg.PaneID) {
		sm.mu.Unlock()
		sm.sendError(deviceID, "stale_pane", "Pane is not present in the current workspace layout")
		return nil
	}
	stream, _ := sm.findScreenStreamLocked(workspaceID, msg.PaneID)
	if stream == nil {
		stream = &ScreenStreamInfo{
			WorkspaceID: workspaceID,
			PaneID:      msg.PaneID,
			SessionID:   msg.SessionID,
			OwnerID:     deviceID,
			Subscribers: map[string]*ScreenSubscriberState{},
		}
		sm.paneStreams[screenStreamKey(workspaceID, msg.PaneID)] = stream
	}
	if stream.OwnerID != "" && stream.OwnerID != deviceID {
		sm.mu.Unlock()
		sm.sendError(deviceID, "permission_denied", "Only screen owner can publish delta")
		return nil
	}
	stream.OwnerID = deviceID
	stream.WorkspaceID = workspaceID
	stream.SessionID = msg.SessionID
	encoding := normalizeScreenEncoding(strField(msg.Payload, "encoding", ""))
	if seq > stream.LastSeq {
		stream.LastSeq = seq
	}
	stream.Deltas = append(stream.Deltas, ScreenDelta{Seq: seq, Encoding: encoding, Payload: clonePayload(msg.Payload)})
	if len(stream.Deltas) > 512 {
		stream.Deltas = stream.Deltas[len(stream.Deltas)-512:]
	}
	stream.UpdatedAt = time.Now()
	subscribers := sm.screenSubscribersForDeltaLocked(stream, deviceID, seq, encoding)
	sm.mu.Unlock()

	msg.V = 3
	if msg.ID == "" {
		msg.ID = newMessageID()
	}
	msg.WorkspaceID = workspaceID
	for _, subscriber := range subscribers {
		sm.sendToDevice(subscriber, msg)
	}

	sm.requestResyncForLaggingSubscribers(workspaceID, msg.PaneID, deviceID)
	return nil
}

func (sm *SessionManager) handleScreenAck(deviceID string, msg models.Message) error {
	paneID := msg.PaneID
	if paneID == "" {
		paneID = strField(msg.Payload, "pane_id", "")
	}
	if paneID == "" {
		sm.sendError(deviceID, "missing_pane_id", "screen.ack requires pane_id")
		return nil
	}
	ackSeq := int64Field(msg.Payload, "ack_seq", int64Field(msg.Payload, "seq", 0))
	if ackSeq <= 0 {
		sm.sendError(deviceID, "missing_ack_seq", "screen.ack requires ack_seq")
		return nil
	}

	sm.mu.RLock()
	stream, _ := sm.findScreenStreamLocked(msg.WorkspaceID, paneID)
	if stream == nil {
		sm.mu.RUnlock()
		sm.sendError(deviceID, "screen_not_found", "Screen stream not found")
		return nil
	}
	ownerID := stream.OwnerID
	sm.mu.RUnlock()
	if err := sm.requireWorkspaceAccess(deviceID, ownerID); err != nil {
		sm.sendError(deviceID, "permission_denied", err.Error())
		return nil
	}

	sm.mu.Lock()
	stream, _ = sm.findScreenStreamLocked(msg.WorkspaceID, paneID)
	if stream == nil {
		sm.mu.Unlock()
		sm.sendError(deviceID, "screen_not_found", "Screen stream not found")
		return nil
	}
	state := stream.Subscribers[deviceID]
	if state == nil {
		// ACK is only meaningful for an active subscription. A delayed ACK
		// arriving after screen.unsubscribe must not recreate the subscriber.
		sm.mu.Unlock()
		return nil
	}
	if ackSeq > state.LastAckSeq {
		state.LastAckSeq = ackSeq
	}
	state.LastAckAt = time.Now()
	if state.LastAckSeq >= stream.LastSeq {
		state.NeedsResync = false
	}
	sm.mu.Unlock()
	return nil
}

func (sm *SessionManager) handleScreenResyncRequest(deviceID string, msg models.Message) error {
	paneID := msg.PaneID
	if paneID == "" {
		paneID = strField(msg.Payload, "pane_id", "")
	}
	encoding := normalizeScreenEncoding(strField(msg.Payload, "encoding", ""))
	sm.mu.RLock()
	stream, _ := sm.findScreenStreamLocked(msg.WorkspaceID, paneID)
	if stream != nil {
		if state := stream.Subscribers[deviceID]; state != nil && state.Encoding != "" {
			encoding = state.Encoding
		}
	}
	snapshot := clonePayload(screenSnapshotForEncoding(stream, encoding))
	sm.mu.RUnlock()
	if stream == nil {
		sm.sendError(deviceID, "screen_not_found", "Screen stream not found")
		return nil
	}
	if err := sm.requireWorkspaceAccess(deviceID, stream.OwnerID); err != nil {
		sm.sendError(deviceID, "permission_denied", err.Error())
		return nil
	}
	if snapshot != nil {
		sm.markScreenSnapshotSent(stream.WorkspaceID, paneID, deviceID)
		sm.sendToDevice(deviceID, models.Message{
			Type:        string(models.MsgScreenSnapshot),
			V:           3,
			ID:          newMessageID(),
			WorkspaceID: stream.WorkspaceID,
			PaneID:      stream.PaneID,
			SessionID:   stream.SessionID,
			Timestamp:   time.Now().Unix(),
			Payload:     snapshot,
		})
	}
	if deviceID != stream.OwnerID {
		msg.V = 3
		if msg.ID == "" {
			msg.ID = newMessageID()
		}
		if msg.Payload == nil {
			msg.Payload = map[string]interface{}{}
		}
		msg.Payload["requested_by"] = deviceID
		msg.Payload["encoding"] = encoding
		sm.sendToDevice(stream.OwnerID, msg)
	}
	return nil
}

func (sm *SessionManager) requestResyncForLaggingSubscribers(workspaceID, paneID, ownerID string) {
	sm.mu.Lock()
	stream, _ := sm.findScreenStreamLocked(workspaceID, paneID)
	if stream == nil || stream.OwnerID == "" {
		sm.mu.Unlock()
		return
	}
	now := time.Now()
	type request struct {
		deviceID string
		msg      models.Message
	}
	requests := make([]request, 0)
	for deviceID, state := range stream.Subscribers {
		if deviceID == ownerID || state == nil || !state.NeedsResync {
			continue
		}
		if now.Sub(state.LastResyncAskAt) < 2*time.Second {
			continue
		}
		state.LastResyncAskAt = now
		encoding := normalizeScreenEncoding(state.Encoding)
		if snapshot := screenSnapshotForEncoding(stream, encoding); snapshot != nil {
			requests = append(requests, request{
				deviceID: deviceID,
				msg: models.Message{
					Type:        string(models.MsgScreenSnapshot),
					V:           3,
					ID:          newMessageID(),
					WorkspaceID: stream.WorkspaceID,
					PaneID:      stream.PaneID,
					SessionID:   stream.SessionID,
					Timestamp:   now.Unix(),
					Payload:     clonePayload(snapshot),
				},
			})
			continue
		}
		requests = append(requests, request{
			deviceID: stream.OwnerID,
			msg: models.Message{
				Type:        string(models.MsgScreenResyncRequest),
				V:           3,
				ID:          newMessageID(),
				WorkspaceID: stream.WorkspaceID,
				PaneID:      stream.PaneID,
				SessionID:   stream.SessionID,
				Timestamp:   now.Unix(),
				Payload: map[string]interface{}{
					"requested_by": deviceID,
					"last_seq":     state.LastAckSeq,
					"encoding":     encoding,
				},
			},
		})
	}
	sm.mu.Unlock()

	for _, req := range requests {
		sm.sendToDevice(req.deviceID, req.msg)
	}
}

func (sm *SessionManager) markScreenSnapshotSent(workspaceID, paneID, deviceID string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	if stream, _ := sm.findScreenStreamLocked(workspaceID, paneID); stream != nil {
		if state := stream.Subscribers[deviceID]; state != nil {
			state.NeedsResync = false
			state.LastSentSeq = stream.LastSeq
			state.LastResyncAskAt = time.Now()
		}
	}
}

func (sm *SessionManager) handleScreenClear(deviceID string, msg models.Message) error {
	if msg.PaneID == "" {
		sm.sendError(deviceID, "missing_pane_id", "screen.clear requires pane_id")
		return nil
	}
	sm.mu.Lock()
	stream, _ := sm.findScreenStreamLocked(msg.WorkspaceID, msg.PaneID)
	if stream == nil || stream.OwnerID != deviceID {
		sm.mu.Unlock()
		sm.sendError(deviceID, "permission_denied", "Only screen owner can clear stream")
		return nil
	}
	stream.Snapshot = nil
	stream.Snapshots = nil
	stream.Deltas = nil
	stream.LastSeq = 0
	subscribers := screenSubscribersExcept(stream.Subscribers, deviceID)
	sm.mu.Unlock()
	for _, subscriber := range subscribers {
		sm.sendToDevice(subscriber, msg)
	}
	return nil
}

func (sm *SessionManager) handleInputSend(deviceID string, msg models.Message) error {
	paneID := msg.PaneID
	if paneID == "" {
		paneID = strField(msg.Payload, "pane_id", "")
	}
	if paneID == "" {
		sm.sendError(deviceID, "missing_pane_id", "input.send requires pane_id")
		return nil
	}

	sm.mu.RLock()
	stream, _ := sm.findScreenStreamLocked(msg.WorkspaceID, paneID)
	sm.mu.RUnlock()
	if stream == nil {
		sm.sendError(deviceID, "screen_not_found", "Pane stream not found")
		return nil
	}
	if err := sm.requireWorkspaceAccess(deviceID, stream.OwnerID); err != nil {
		sm.sendError(deviceID, "permission_denied", err.Error())
		return nil
	}
	inputID := strField(msg.Payload, "input_id", "")
	if inputID == "" {
		sm.sendError(deviceID, "missing_input_id", "input.send requires input_id")
		return nil
	}
	if sm.shouldDropDuplicateInputV3(deviceID, stream.OwnerID, paneID, inputID) {
		log.Printf("[input] duplicate dropped viewer=%s owner=%s pane=%s input_id=%s", deviceID, stream.OwnerID, paneID, inputID)
		return nil
	}
	if deviceID != stream.OwnerID {
		msg.V = 3
		if msg.ID == "" {
			msg.ID = newMessageID()
		}
		msg.WorkspaceID = stream.WorkspaceID
		msg.PaneID = paneID
		msg.SessionID = stream.SessionID
		sm.sendToDevice(stream.OwnerID, msg)
	}
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

func (sm *SessionManager) runDeviceSender(deviceID string, conn *websocket.Conn, sender *deviceSender) {
	defer func() {
		if recovered := recover(); recovered != nil {
			log.Printf("[send] Recovered writer for %s: %v", deviceID, recovered)
		}
		sender.close()
	}()
	if conn == nil {
		return
	}
	for {
		select {
		case <-sender.done:
			return
		default:
		}
		select {
		case <-sender.done:
			return
		case data := <-sender.queue:
			const maxRetries = 2
			for attempt := 0; attempt <= maxRetries; attempt++ {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				err := conn.Write(ctx, websocket.MessageText, data)
				cancel()

				if err == nil {
					break
				}

				if !sm.isCurrentConnection(deviceID, conn) {
					return
				}

				if attempt < maxRetries {
					log.Printf("[send] Write to %s failed (attempt %d/%d): %v", deviceID, attempt+1, maxRetries+1, err)
					time.Sleep(200 * time.Millisecond)
					continue
				}

				log.Printf("[send] Write to %s failed after %d attempts: %v - closing connection", deviceID, maxRetries+1, err)
				_ = conn.Close(websocket.StatusGoingAway, "write failed")
				sm.UnregisterConnection(deviceID, conn)
				return
			}
		}
	}
}

func (s *deviceSender) close() {
	s.closeOnce.Do(func() {
		close(s.done)
	})
}

// sendToDevice queues a message for a device's single WebSocket writer.
func (sm *SessionManager) sendToDevice(deviceID string, msg models.Message) {
	defer func() {
		if recovered := recover(); recovered != nil {
			log.Printf("[send] Recovered while writing to %s: %v", deviceID, recovered)
		}
	}()

	sm.mu.RLock()
	conn, ok := sm.deviceConnections[deviceID]
	sender := sm.deviceSenders[deviceID]
	sm.mu.RUnlock()

	if !ok || conn == nil || sender == nil {
		return
	}

	if msg.V == 0 {
		msg.V = 3
	}
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("[send] Failed to marshal message: %v", err)
		return
	}

	select {
	case sender.queue <- data:
	case <-sender.done:
	default:
		log.Printf("[send] Outbound queue full for %s - closing connection", deviceID)
		go func() {
			_ = conn.Close(websocket.StatusPolicyViolation, "outbound queue full")
			sm.UnregisterConnection(deviceID, conn)
		}()
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

// notifyPairedMobiles sends a message to all viewer devices paired with the owner.
func (sm *SessionManager) notifyPairedMobiles(ownerID string, msg models.Message) {
	viewerIDs, err := sm.store.ListPairedViewerIDs(context.Background(), ownerID)
	if err != nil {
		log.Printf("[pairing] Failed to list paired viewers for %s: %v", ownerID, err)
		return
	}

	for _, deviceID := range viewerIDs {
		dID := deviceID
		go func() {
			sm.sendToDevice(dID, msg)
		}()
	}
}

// BroadcastPeerStateForPairing refreshes both sides after a new pairing is created.
func (sm *SessionManager) BroadcastPeerStateForPairing(desktopID, viewerID string) {
	go sm.broadcastPeerStateForDevice(desktopID)
	go sm.broadcastPeerStateForDevice(viewerID)
}

func (sm *SessionManager) broadcastPeerStateToPairedDevices(deviceID string) {
	sm.broadcastPeerStateToPairedDevicesWithType(deviceID, sm.getDeviceType(deviceID))
}

func (sm *SessionManager) broadcastPeerStateToPairedDevicesWithType(deviceID, deviceType string) {
	ctx := context.Background()

	if isViewerDeviceType(deviceType) {
		desktopIDs, err := sm.store.ListPairedDesktopIDs(ctx, deviceID)
		if err != nil {
			log.Printf("[pairing] Failed to list paired desktops for %s: %v", deviceID, err)
			return
		}
		for _, desktopID := range desktopIDs {
			sm.broadcastPeerStateForDevice(desktopID)
		}
		return
	}

	viewerIDs, err := sm.store.ListPairedViewerIDs(ctx, deviceID)
	if err != nil {
		log.Printf("[pairing] Failed to list paired viewers for %s: %v", deviceID, err)
		return
	}
	for _, viewerID := range viewerIDs {
		sm.broadcastPeerStateForDevice(viewerID)
	}
}

func (sm *SessionManager) broadcastPeerStateForDevice(deviceID string) {
	peers, err := sm.listPeerSnapshotsForDevice(deviceID)
	if err != nil {
		log.Printf("[pairing] Failed to build peer state for %s: %v", deviceID, err)
		return
	}

	sm.sendToDevice(deviceID, models.Message{
		Type:      string(models.MsgDevicePeers),
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"peers": peers,
		},
	})
}

func (sm *SessionManager) listPeerSnapshotsForDevice(deviceID string) ([]models.PeerDeviceSnapshot, error) {
	deviceType := sm.getDeviceType(deviceID)
	ctx := context.Background()

	var devices []models.Device
	var err error
	if isViewerDeviceType(deviceType) {
		devices, err = sm.store.ListPairedDesktops(ctx, deviceID)
	} else {
		devices, err = sm.store.ListPairedViewers(ctx, deviceID)
	}
	if err != nil {
		return nil, err
	}

	peers := make([]models.PeerDeviceSnapshot, 0, len(devices))
	for _, device := range devices {
		peers = append(peers, models.PeerDeviceSnapshot{
			ID:     device.ID,
			Name:   device.Name,
			Type:   device.Type,
			Online: sm.isDeviceOnline(device.ID),
		})
	}
	return peers, nil
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

func (sm *SessionManager) isOwnerDevice(deviceID string) bool {
	return sm.getDeviceType(deviceID) == "desktop"
}

func (sm *SessionManager) isCurrentConnection(deviceID string, conn *websocket.Conn) bool {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	currentConn, ok := sm.deviceConnections[deviceID]
	return ok && currentConn == conn
}

func (sm *SessionManager) notifyConnectionReplaced(oldConn *websocket.Conn, oldSender *deviceSender, deviceID, oldConnectionID, newConnectionID string) {
	if oldConn == nil {
		return
	}
	msg := models.Message{
		Type:      string(models.MsgPeerReplaced),
		V:         3,
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"device_id":         deviceID,
			"old_connection_id": oldConnectionID,
			"new_connection_id": newConnectionID,
			"reason":            "new_connection_authenticated",
		},
	}
	data, err := json.Marshal(msg)
	if err == nil && oldSender != nil {
		select {
		case oldSender.queue <- data:
		default:
		}
	}
	if oldSender != nil {
		oldSender.close()
	}
	_ = oldConn.Close(websocket.StatusGoingAway, "replaced by new connection")
}

func (sm *SessionManager) allowedWorkspaceOwners(deviceID, deviceType string) (map[string]bool, error) {
	allowed := map[string]bool{}
	if isViewerDeviceType(deviceType) {
		desktopIDs, err := sm.store.ListPairedDesktopIDs(context.Background(), deviceID)
		if err != nil {
			return nil, err
		}
		for _, desktopID := range desktopIDs {
			allowed[desktopID] = true
		}
		return allowed, nil
	}
	allowed[deviceID] = true
	return allowed, nil
}

func (sm *SessionManager) requireWorkspaceAccess(deviceID, ownerID string) error {
	if ownerID == "" {
		return fmt.Errorf("workspace owner is unknown")
	}
	if deviceID == ownerID {
		return nil
	}
	if !isViewerDeviceType(sm.getDeviceType(deviceID)) {
		return fmt.Errorf("device cannot view this workspace")
	}
	paired, err := sm.store.IsPaired(context.Background(), ownerID, deviceID)
	if err != nil {
		return err
	}
	if !paired {
		return fmt.Errorf("device is not paired with this desktop")
	}
	return nil
}

func (sm *SessionManager) broadcastWorkspace(workspaceID string, msg models.Message, excludeDeviceID string) {
	sm.mu.RLock()
	ws := sm.workspaces[workspaceID]
	if ws == nil {
		sm.mu.RUnlock()
		return
	}
	subscribers := keysExcept(ws.Subscribers, excludeDeviceID)
	sm.mu.RUnlock()
	for _, subscriber := range subscribers {
		sm.sendToDevice(subscriber, msg)
	}
}

func screenStreamKey(workspaceID, paneID string) string {
	if workspaceID == "" {
		return paneID
	}
	return workspaceID + "\x00" + paneID
}

// findScreenStreamLocked resolves a pane inside its workspace. The pane-only
// fallback keeps messages from older clients working as long as the pane is
// unambiguous.
func (sm *SessionManager) findScreenStreamLocked(workspaceID, paneID string) (*ScreenStreamInfo, string) {
	if paneID == "" {
		return nil, ""
	}
	if workspaceID != "" {
		key := screenStreamKey(workspaceID, paneID)
		if stream := sm.paneStreams[key]; stream != nil {
			return stream, key
		}
		if stream := sm.paneStreams[paneID]; stream != nil && stream.WorkspaceID == workspaceID {
			return stream, paneID
		}
		return nil, ""
	}
	if stream := sm.paneStreams[paneID]; stream != nil {
		return stream, paneID
	}
	var found *ScreenStreamInfo
	var foundKey string
	for key, stream := range sm.paneStreams {
		if stream == nil || stream.PaneID != paneID {
			continue
		}
		if found != nil && found != stream {
			return nil, ""
		}
		found = stream
		foundKey = key
	}
	return found, foundKey
}

func (sm *SessionManager) workspaceForOwnedPane(ownerID, paneID string) string {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	for _, stream := range sm.paneStreams {
		if stream != nil && stream.PaneID == paneID && stream.OwnerID == ownerID {
			return stream.WorkspaceID
		}
	}
	return ""
}

func (sm *SessionManager) workspaceOwnerLocked(workspaceID string) string {
	if ws := sm.workspaces[workspaceID]; ws != nil {
		return ws.OwnerID
	}
	return ""
}

func (sm *SessionManager) indexWorkspacePanesLocked(workspaceID, ownerID string, snapshot map[string]interface{}) {
	currentPanes := map[string]bool{}
	for _, paneID := range extractPaneIDs(snapshot) {
		currentPanes[paneID] = true
		key := screenStreamKey(workspaceID, paneID)
		sm.paneWorkspace[key] = workspaceID
		if stream, _ := sm.findScreenStreamLocked(workspaceID, paneID); stream != nil {
			stream.WorkspaceID = workspaceID
			if stream.OwnerID == "" {
				stream.OwnerID = ownerID
			}
		} else {
			sm.paneStreams[key] = &ScreenStreamInfo{
				WorkspaceID: workspaceID,
				PaneID:      paneID,
				OwnerID:     ownerID,
				Subscribers: map[string]*ScreenSubscriberState{},
				UpdatedAt:   time.Now(),
			}
		}
	}
	for key, indexedWorkspaceID := range sm.paneWorkspace {
		if indexedWorkspaceID != workspaceID {
			continue
		}
		stream := sm.paneStreams[key]
		paneID := key
		if stream != nil && stream.PaneID != "" {
			paneID = stream.PaneID
		}
		if currentPanes[paneID] {
			continue
		}
		delete(sm.paneWorkspace, key)
		if stream != nil && stream.WorkspaceID == workspaceID {
			delete(sm.paneStreams, key)
		}
	}
}

func (sm *SessionManager) paneBelongsToWorkspaceLocked(workspaceID, paneID string) bool {
	if workspaceID == "" || paneID == "" {
		return true
	}
	if sm.workspaces[workspaceID] == nil {
		return true
	}
	if sm.paneWorkspace[screenStreamKey(workspaceID, paneID)] == workspaceID {
		return true
	}
	stream, _ := sm.findScreenStreamLocked(workspaceID, paneID)
	return stream != nil && stream.WorkspaceID == workspaceID
}

func extractPaneIDs(value interface{}) []string {
	seen := map[string]bool{}
	var result []string
	var walk func(interface{})
	walk = func(node interface{}) {
		switch typed := node.(type) {
		case map[string]interface{}:
			if paneID, ok := typed["pane_id"].(string); ok && paneID != "" && !seen[paneID] {
				seen[paneID] = true
				result = append(result, paneID)
			}
			if paneID, ok := typed["paneId"].(string); ok && paneID != "" && !seen[paneID] {
				seen[paneID] = true
				result = append(result, paneID)
			}
			for _, child := range typed {
				walk(child)
			}
		case []interface{}:
			for _, child := range typed {
				walk(child)
			}
		}
	}
	walk(value)
	return result
}

func keysExcept(values map[string]bool, exclude string) []string {
	result := make([]string, 0, len(values))
	for key := range values {
		if key != exclude {
			result = append(result, key)
		}
	}
	return result
}

func screenSubscribersExcept(values map[string]*ScreenSubscriberState, exclude string) []string {
	result := make([]string, 0, len(values))
	for key := range values {
		if key != exclude {
			result = append(result, key)
		}
	}
	return result
}

func screenSubscribersExceptEncoding(values map[string]*ScreenSubscriberState, exclude, encoding string) []string {
	encoding = normalizeScreenEncoding(encoding)
	result := make([]string, 0, len(values))
	for key, state := range values {
		if key == exclude {
			continue
		}
		if normalizeScreenEncoding(stateEncoding(state)) == encoding {
			result = append(result, key)
		}
	}
	return result
}

func (sm *SessionManager) screenSubscribersForDeltaLocked(stream *ScreenStreamInfo, exclude string, seq int64, encoding string) []string {
	if stream == nil {
		return nil
	}
	encoding = normalizeScreenEncoding(encoding)
	result := make([]string, 0, len(stream.Subscribers))
	for key, state := range stream.Subscribers {
		if key == exclude {
			continue
		}
		if state == nil {
			state = &ScreenSubscriberState{SubscribedAt: time.Now()}
			stream.Subscribers[key] = state
		}
		if normalizeScreenEncoding(state.Encoding) != encoding {
			continue
		}
		if state.NeedsResync {
			continue
		}
		if state.LastAckSeq > 0 && seq-state.LastAckSeq > screenDeltaAckLagLimit {
			state.NeedsResync = true
			state.SkippedDeltaCount++
			continue
		}
		backlog := sm.deviceQueueBacklogLocked(key)
		if backlog >= screenDeltaBacklogLimit {
			state.NeedsResync = true
			state.SkippedDeltaCount++
			log.Printf("[screen] delta backlog viewer=%s pane=%s seq=%d backlog=%d: mark resync", key, stream.PaneID, seq, backlog)
			continue
		}
		state.LastSentSeq = seq
		result = append(result, key)
	}
	return result
}

func normalizeScreenEncoding(encoding string) string {
	switch encoding {
	case screenEncodingCells, "cells", "cells-json":
		return screenEncodingCells
	default:
		return screenEncodingVT
	}
}

func stateEncoding(state *ScreenSubscriberState) string {
	if state == nil {
		return ""
	}
	return state.Encoding
}

func screenSnapshotForEncoding(stream *ScreenStreamInfo, encoding string) map[string]interface{} {
	if stream == nil {
		return nil
	}
	encoding = normalizeScreenEncoding(encoding)
	if stream.Snapshots != nil {
		if snapshot := stream.Snapshots[encoding]; snapshot != nil {
			return snapshot
		}
	}
	if encoding == screenEncodingVT {
		return stream.Snapshot
	}
	return nil
}

func (sm *SessionManager) deviceQueueBacklogLocked(deviceID string) int {
	if sender := sm.deviceSenders[deviceID]; sender != nil {
		return len(sender.queue)
	}
	return 0
}

func clonePayload(payload map[string]interface{}) map[string]interface{} {
	if payload == nil {
		return nil
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return payload
	}
	var cloned map[string]interface{}
	if err := json.Unmarshal(data, &cloned); err != nil {
		return payload
	}
	return cloned
}

func newMessageID() string {
	return fmt.Sprintf("srv-%d", time.Now().UnixNano())
}

func (sm *SessionManager) shouldDropDuplicateMessage(deviceID, messageID string) bool {
	key := deviceID + "|" + messageID
	now := time.Now()
	sm.mu.Lock()
	defer sm.mu.Unlock()
	for existingKey, seenAt := range sm.recentMessageIDs {
		if now.Sub(seenAt) > 2*time.Minute {
			delete(sm.recentMessageIDs, existingKey)
		}
	}
	if _, ok := sm.recentMessageIDs[key]; ok {
		return true
	}
	sm.recentMessageIDs[key] = now
	return false
}

func (sm *SessionManager) shouldDropDuplicateInputV3(viewerID, ownerID, paneID, inputID string) bool {
	key := viewerID + "|" + ownerID + "|" + paneID + "|" + inputID
	now := time.Now()
	sm.mu.Lock()
	defer sm.mu.Unlock()
	for existingKey, seenAt := range sm.recentInputs {
		if now.Sub(seenAt) > time.Minute {
			delete(sm.recentInputs, existingKey)
		}
	}
	if _, ok := sm.recentInputs[key]; ok {
		return true
	}
	sm.recentInputs[key] = now
	return false
}

func isViewerDeviceType(deviceType string) bool {
	return deviceType == "mobile" || deviceType == "pc_receiver"
}

// ─── Payload helpers ──────────────────────────────────────────────────────

func numField(payload map[string]interface{}, key string) (float64, bool) {
	if payload == nil {
		return 0, false
	}
	v, ok := payload[key].(float64)
	return v, ok
}

func intField(payload map[string]interface{}, key string, fallback int) int {
	if v, ok := numField(payload, key); ok {
		return int(v)
	}
	return fallback
}

func int64Field(payload map[string]interface{}, key string, fallback int64) int64 {
	if payload == nil {
		return fallback
	}
	switch value := payload[key].(type) {
	case float64:
		return int64(value)
	case int64:
		return value
	case int:
		return int64(value)
	default:
		return fallback
	}
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

func objectField(payload map[string]interface{}, key string) map[string]interface{} {
	if value, ok := optionalObjectField(payload, key); ok {
		return value
	}
	return nil
}

func optionalObjectField(payload map[string]interface{}, key string) (map[string]interface{}, bool) {
	if payload == nil {
		return nil, false
	}
	value, exists := payload[key]
	if !exists {
		return nil, false
	}
	if value == nil {
		return nil, true
	}
	obj, ok := value.(map[string]interface{})
	if !ok {
		return nil, false
	}
	return obj, true
}
