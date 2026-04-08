package relay

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"termsync-server/models"
	"termsync-server/store"

	"nhooyr.io/websocket"
)

// setupTestStore creates a temporary SQLite store for testing.
func setupTestStore(t *testing.T) (*store.Store, func()) {
	t.Helper()
	tmpFile := t.TempDir() + "/test.db"
	s, err := store.New(tmpFile)
	if err != nil {
		t.Fatalf("Failed to create test store: %v", err)
	}
	return s, func() { s.Close() }
}

func newTestManager(t *testing.T) (*SessionManager, func()) {
	t.Helper()
	s, cleanup := setupTestStore(t)
	sm := NewSessionManager(s)
	return sm, cleanup
}

func seedDevice(t *testing.T, sm *SessionManager, id, token, deviceType string) {
	t.Helper()
	err := sm.store.CreateDevice(context.Background(), &models.Device{
		ID:    id,
		Name:  id,
		Token: token,
		Type:  deviceType,
	})
	if err != nil {
		t.Fatalf("Failed to seed device %s: %v", id, err)
	}
}

func seedPairing(t *testing.T, sm *SessionManager, desktopID, mobileID string) {
	t.Helper()
	err := sm.store.CreatePairingCode(context.Background(), desktopID, "123456", time.Now().Add(5*time.Minute))
	if err != nil {
		t.Fatalf("Failed to seed pairing code for %s: %v", desktopID, err)
	}
	if _, err := sm.store.ConsumePairingCode(context.Background(), mobileID, "123456"); err != nil {
		t.Fatalf("Failed to seed pairing %s -> %s: %v", desktopID, mobileID, err)
	}
}

func TestNewSessionManager(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	if sm.deviceConnections == nil {
		t.Error("deviceConnections should be initialized")
	}
	if sm.deviceTypes == nil {
		t.Error("deviceTypes should be initialized")
	}
	if sm.sessions == nil {
		t.Error("sessions should be initialized")
	}
	if sm.deviceSessions == nil {
		t.Error("deviceSessions should be initialized")
	}
}

func TestSessionCreateAndClose(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	deviceID := "desktop-1"

	// Create session
	createMsg := models.Message{
		Type:      string(models.MsgSessionCreate),
		SessionID: "sess-1",
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"cols":  120.0,
			"rows":  40.0,
			"title": "My Terminal",
		},
	}
	data, _ := json.Marshal(createMsg)
	if err := sm.HandleMessage(deviceID, data); err != nil {
		t.Fatalf("session.create failed: %v", err)
	}

	// Verify session exists
	si, ok := sm.GetSessionInfo("sess-1")
	if !ok {
		t.Fatal("Session should exist after create")
	}
	if si.OwnerID != deviceID {
		t.Errorf("Expected owner %s, got %s", deviceID, si.OwnerID)
	}
	if si.Cols != 120 || si.Rows != 40 {
		t.Errorf("Expected 120x40, got %dx%d", si.Cols, si.Rows)
	}

	// Close session (owner)
	closeMsg := models.Message{
		Type:      string(models.MsgSessionClose),
		SessionID: "sess-1",
		Timestamp: time.Now().Unix(),
	}
	data, _ = json.Marshal(closeMsg)
	if err := sm.HandleMessage(deviceID, data); err != nil {
		t.Fatalf("session.close failed: %v", err)
	}

	// Verify session is gone
	_, ok = sm.GetSessionInfo("sess-1")
	if ok {
		t.Error("Session should be gone after close")
	}
}

func TestSessionClosePermissionDenied(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	ownerID := "desktop-1"
	otherID := "desktop-2"

	// Owner creates session
	createMsg := models.Message{
		Type:      string(models.MsgSessionCreate),
		SessionID: "sess-2",
		Timestamp: time.Now().Unix(),
		Payload:   map[string]interface{}{},
	}
	data, _ := json.Marshal(createMsg)
	_ = sm.HandleMessage(ownerID, data)

	// Other device tries to close - should fail with error
	closeMsg := models.Message{
		Type:      string(models.MsgSessionClose),
		SessionID: "sess-2",
		Timestamp: time.Now().Unix(),
	}
	data, _ = json.Marshal(closeMsg)
	if err := sm.HandleMessage(otherID, data); err != nil {
		t.Fatalf("HandleMessage should not return error for permission denied (error goes in message): %v", err)
	}

	// Session should still exist
	_, ok := sm.GetSessionInfo("sess-2")
	if !ok {
		t.Error("Session should still exist - close was denied")
	}
}

func TestSubscribeSendsSnapshot(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	ownerID := "desktop-1"
	viewerID := "mobile-1"
	seedDevice(t, sm, ownerID, "desktop-token", "desktop")
	seedDevice(t, sm, viewerID, "mobile-token", "mobile")
	seedPairing(t, sm, ownerID, viewerID)

	// Create session
	createMsg := models.Message{
		Type:      string(models.MsgSessionCreate),
		SessionID: "sess-3",
		Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{
			"cols":  80.0,
			"rows":  24.0,
			"title": "Test",
		},
	}
	data, _ := json.Marshal(createMsg)
	_ = sm.HandleMessage(ownerID, data)

	// Viewer subscribes
	subMsg := models.Message{
		Type:      string(models.MsgSubscribe),
		SessionID: "sess-3",
		Timestamp: time.Now().Unix(),
	}
	data, _ = json.Marshal(subMsg)
	_ = sm.HandleMessage(viewerID, data)

	// Verify viewer is in the viewer set
	if !sm.isViewer("sess-3", viewerID) {
		t.Error("Viewer should be subscribed")
	}
}

func TestTerminalOutputPermission(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	ownerID := "desktop-1"
	viewerID := "mobile-1"

	// Create session
	createMsg := models.Message{
		Type:      string(models.MsgSessionCreate),
		SessionID: "sess-4",
		Timestamp: time.Now().Unix(),
		Payload:   map[string]interface{}{},
	}
	data, _ := json.Marshal(createMsg)
	_ = sm.HandleMessage(ownerID, data)

	// Viewer tries to send output - should be denied
	outputMsg := models.Message{
		Type:      string(models.MsgTerminalOutput),
		SessionID: "sess-4",
		Timestamp: time.Now().Unix(),
		Payload:   map[string]interface{}{"data": "hello"},
	}
	data, _ = json.Marshal(outputMsg)
	_ = sm.HandleMessage(viewerID, data)

	// Owner sends output - should succeed
	_ = sm.HandleMessage(ownerID, data)
}

func TestSessionList(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")
	seedDevice(t, sm, "mobile-1", "mobile-token", "mobile")
	seedPairing(t, sm, "desktop-1", "mobile-1")

	// Create two sessions
	for i := 1; i <= 2; i++ {
		createMsg := models.Message{
			Type:      string(models.MsgSessionCreate),
			SessionID: "sess-list-" + string(rune('0'+i)),
			Timestamp: time.Now().Unix(),
			Payload:   map[string]interface{}{},
		}
		data, _ := json.Marshal(createMsg)
		_ = sm.HandleMessage("desktop-1", data)
	}

	// Request list
	listMsg := models.Message{
		Type:      string(models.MsgSessionListReq),
		Timestamp: time.Now().Unix(),
	}
	data, _ := json.Marshal(listMsg)
	_ = sm.HandleMessage("mobile-1", data)
}

func TestBadTimestamp(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	// Message with timestamp 120 seconds in the past
	badMsg := models.Message{
		Type:      string(models.MsgSessionCreate),
		SessionID: "sess-bad",
		Timestamp: time.Now().Unix() - 120,
	}
	data, _ := json.Marshal(badMsg)
	err := sm.HandleMessage("desktop-1", data)
	// Should not error at the HandleMessage level; error is sent as MsgError
	_ = err
}

func TestUnsubscribe(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	ownerID := "desktop-1"
	viewerID := "mobile-1"
	seedDevice(t, sm, ownerID, "desktop-token", "desktop")
	seedDevice(t, sm, viewerID, "mobile-token", "mobile")
	seedPairing(t, sm, ownerID, viewerID)

	// Create session
	createMsg := models.Message{
		Type:      string(models.MsgSessionCreate),
		SessionID: "sess-unsub",
		Timestamp: time.Now().Unix(),
		Payload:   map[string]interface{}{},
	}
	data, _ := json.Marshal(createMsg)
	_ = sm.HandleMessage(ownerID, data)

	// Subscribe
	subMsg := models.Message{
		Type:      string(models.MsgSubscribe),
		SessionID: "sess-unsub",
		Timestamp: time.Now().Unix(),
	}
	data, _ = json.Marshal(subMsg)
	_ = sm.HandleMessage(viewerID, data)

	if !sm.isViewer("sess-unsub", viewerID) {
		t.Fatal("Viewer should be subscribed")
	}

	// Unsubscribe
	unsubMsg := models.Message{
		Type:      string(models.MsgUnsubscribe),
		SessionID: "sess-unsub",
		Timestamp: time.Now().Unix(),
	}
	data, _ = json.Marshal(unsubMsg)
	_ = sm.HandleMessage(viewerID, data)

	if sm.isViewer("sess-unsub", viewerID) {
		t.Error("Viewer should be unsubscribed")
	}
}

func TestOwnerDisconnectClosesSessions(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	ownerID := "desktop-1"

	// Create session
	createMsg := models.Message{
		Type:      string(models.MsgSessionCreate),
		SessionID: "sess-disconnect",
		Timestamp: time.Now().Unix(),
		Payload:   map[string]interface{}{},
	}
	data, _ := json.Marshal(createMsg)
	_ = sm.HandleMessage(ownerID, data)

	// Verify session exists
	_, ok := sm.GetSessionInfo("sess-disconnect")
	if !ok {
		t.Fatal("Session should exist")
	}

	// Disconnect owner
	conn := &websocket.Conn{}
	sm.RegisterConnection(ownerID, "desktop", conn)
	sm.UnregisterConnection(ownerID, conn)

	// Session should be cleaned up
	_, ok = sm.GetSessionInfo("sess-disconnect")
	if ok {
		t.Error("Session should be cleaned up after owner disconnect")
	}
}
