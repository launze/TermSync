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
	return NewSessionManager(s), cleanup
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
	sm.deviceTypes[id] = deviceType
}

func seedPairing(t *testing.T, sm *SessionManager, desktopID, viewerID string) {
	t.Helper()
	err := sm.store.CreatePairingCode(context.Background(), desktopID, "123456", time.Now().Add(5*time.Minute))
	if err != nil {
		t.Fatalf("Failed to seed pairing code for %s: %v", desktopID, err)
	}
	if _, err := sm.store.ConsumePairingCode(context.Background(), viewerID, "123456"); err != nil {
		t.Fatalf("Failed to seed pairing %s -> %s: %v", desktopID, viewerID, err)
	}
}

func marshalMsg(t *testing.T, msg models.Message) []byte {
	t.Helper()
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	return data
}

func TestNewSessionManager(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	if sm.deviceConnections == nil || sm.connectionIDs == nil || sm.workspaces == nil || sm.paneStreams == nil {
		t.Fatal("manager maps should be initialized")
	}
}

func TestV3OnlyRejectsLegacyMessage(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	msg := models.Message{
		Type:      string(models.MsgWorkspaceList),
		Timestamp: time.Now().Unix(),
	}
	if err := sm.HandleMessage("viewer-1", marshalMsg(t, msg)); err != nil {
		t.Fatalf("HandleMessage should not return transport error: %v", err)
	}
	if len(sm.workspaces) != 0 {
		t.Fatal("legacy message must not mutate v3 state")
	}
}

func TestLayoutSnapshotCreatesWorkspaceAndIndexesPanes(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")

	msg := models.Message{
		Type:        string(models.MsgLayoutSnapshot),
		V:           3,
		ID:          "layout-1",
		WorkspaceID: "desktop-1:default",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"layout_version": 1.0,
			"snapshot": map[string]interface{}{
				"active_tab_id": "tab-1",
				"tabs": []interface{}{
					map[string]interface{}{
						"tab_id": "tab-1",
						"root": map[string]interface{}{
							"type":    "leaf",
							"pane_id": "pane-1",
						},
					},
				},
			},
		},
	}
	if err := sm.HandleMessage("desktop-1", marshalMsg(t, msg)); err != nil {
		t.Fatalf("layout.snapshot failed: %v", err)
	}

	ws := sm.workspaces["desktop-1:default"]
	if ws == nil {
		t.Fatal("workspace should be created")
	}
	if ws.OwnerID != "desktop-1" || ws.Version != 1 {
		t.Fatalf("unexpected workspace: %#v", ws)
	}
	if sm.paneWorkspace["pane-1"] != "desktop-1:default" {
		t.Fatalf("pane should be indexed to workspace, got %q", sm.paneWorkspace["pane-1"])
	}
}

func TestLayoutPatchUpdatesWorkspaceSnapshot(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")

	sm.workspaces["desktop-1:default"] = &WorkspaceInfo{
		WorkspaceID: "desktop-1:default",
		OwnerID:     "desktop-1",
		Version:     1,
		Snapshot:    map[string]interface{}{"tabs": []interface{}{}},
		Subscribers: map[string]bool{},
	}

	if err := sm.HandleMessage("desktop-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgLayoutPatch),
		V:           3,
		ID:          "patch-1",
		WorkspaceID: "desktop-1:default",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"layout_version": 2.0,
			"snapshot": map[string]interface{}{
				"tabs": []interface{}{
					map[string]interface{}{
						"tab_id": "tab-1",
						"panes": []interface{}{
							map[string]interface{}{"pane_id": "pane-2"},
						},
					},
				},
			},
		},
	})); err != nil {
		t.Fatalf("layout.patch failed: %v", err)
	}

	ws := sm.workspaces["desktop-1:default"]
	if ws.Version != 2 {
		t.Fatalf("expected version 2, got %d", ws.Version)
	}
	if sm.paneWorkspace["pane-2"] != "desktop-1:default" {
		t.Fatalf("pane should be indexed from patch, got %q", sm.paneWorkspace["pane-2"])
	}
}

func TestLayoutPatchRemovesStalePaneStreams(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")

	sm.workspaces["desktop-1:default"] = &WorkspaceInfo{
		WorkspaceID: "desktop-1:default",
		OwnerID:     "desktop-1",
		Version:     1,
		Snapshot: map[string]interface{}{
			"root": map[string]interface{}{"pane_id": "pane-1"},
		},
		Subscribers: map[string]bool{},
	}
	sm.paneWorkspace["pane-1"] = "desktop-1:default"
	sm.paneStreams["pane-1"] = &ScreenStreamInfo{
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		OwnerID:     "desktop-1",
		Subscribers: map[string]*ScreenSubscriberState{
			"pc-1": {SubscribedAt: time.Now(), LastAckSeq: 3},
		},
		LastSeq: 3,
	}

	if err := sm.HandleMessage("desktop-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgLayoutPatch),
		V:           3,
		ID:          "patch-remove-pane",
		WorkspaceID: "desktop-1:default",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"layout_version": 2.0,
			"snapshot": map[string]interface{}{
				"root": map[string]interface{}{"pane_id": "pane-2"},
			},
		},
	})); err != nil {
		t.Fatalf("layout.patch failed: %v", err)
	}

	if _, ok := sm.paneWorkspace["pane-1"]; ok {
		t.Fatal("stale pane should be removed from workspace index")
	}
	if _, ok := sm.paneStreams["pane-1"]; ok {
		t.Fatal("stale pane stream should be removed")
	}
	if sm.paneWorkspace["pane-2"] != "desktop-1:default" {
		t.Fatalf("new pane should be indexed, got %q", sm.paneWorkspace["pane-2"])
	}

	if err := sm.HandleMessage("desktop-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenDelta),
		V:           3,
		ID:          "stale-delta",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"seq":      4.0,
			"prev_seq": 3.0,
			"data":     "YQ==",
		},
	})); err != nil {
		t.Fatalf("stale screen.delta should be rejected without transport error: %v", err)
	}
	if _, ok := sm.paneStreams["pane-1"]; ok {
		t.Fatal("stale screen.delta must not recreate removed pane stream")
	}
}

func TestViewerWorkspaceAndScreenSubscribe(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")
	seedDevice(t, sm, "pc-1", "pc-token", "pc_receiver")
	seedPairing(t, sm, "desktop-1", "pc-1")

	_ = sm.HandleMessage("desktop-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgLayoutSnapshot),
		V:           3,
		ID:          "layout-1",
		WorkspaceID: "desktop-1:default",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"layout_version": 1.0,
			"snapshot": map[string]interface{}{
				"root": map[string]interface{}{"pane_id": "pane-1"},
			},
		},
	}))

	if err := sm.HandleMessage("pc-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgWorkspaceSubscribe),
		V:           3,
		ID:          "sub-workspace",
		WorkspaceID: "desktop-1:default",
		Timestamp:   time.Now().Unix(),
	})); err != nil {
		t.Fatalf("workspace.subscribe failed: %v", err)
	}
	if !sm.workspaces["desktop-1:default"].Subscribers["pc-1"] {
		t.Fatal("viewer should be subscribed to workspace")
	}

	if err := sm.HandleMessage("pc-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenSubscribe),
		V:           3,
		ID:          "sub-screen",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		Timestamp:   time.Now().Unix(),
	})); err != nil {
		t.Fatalf("screen.subscribe failed: %v", err)
	}
	if sm.paneStreams["pane-1"].Subscribers["pc-1"] == nil {
		t.Fatal("viewer should be subscribed to pane screen")
	}
}

func TestInputSendRequiresInputIDAndDedupes(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")
	seedDevice(t, sm, "mobile-1", "mobile-token", "mobile")
	seedPairing(t, sm, "desktop-1", "mobile-1")

	sm.workspaces["desktop-1:default"] = &WorkspaceInfo{
		WorkspaceID: "desktop-1:default",
		OwnerID:     "desktop-1",
		Subscribers: map[string]bool{"mobile-1": true},
	}
	sm.paneStreams["pane-1"] = &ScreenStreamInfo{
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		OwnerID:     "desktop-1",
		Subscribers: map[string]*ScreenSubscriberState{"mobile-1": {SubscribedAt: time.Now()}},
	}

	msg := models.Message{
		Type:        string(models.MsgInputSend),
		V:           3,
		ID:          "input-msg-1",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"input_id": "mobile-1:1",
			"encoding": "base64",
			"data":     "YQ==",
		},
	}
	if err := sm.HandleMessage("mobile-1", marshalMsg(t, msg)); err != nil {
		t.Fatalf("input.send failed: %v", err)
	}
	if err := sm.HandleMessage("mobile-1", marshalMsg(t, msg)); err != nil {
		t.Fatalf("duplicate input should be dropped without error: %v", err)
	}
	if len(sm.recentInputs) != 1 {
		t.Fatalf("expected one input dedupe entry, got %d", len(sm.recentInputs))
	}
}

func TestScreenAckAndBackpressureMarksLaggingViewer(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")
	seedDevice(t, sm, "mobile-1", "mobile-token", "mobile")
	seedPairing(t, sm, "desktop-1", "mobile-1")

	sm.workspaces["desktop-1:default"] = &WorkspaceInfo{
		WorkspaceID: "desktop-1:default",
		OwnerID:     "desktop-1",
		Subscribers: map[string]bool{"mobile-1": true},
	}
	sm.paneStreams["pane-1"] = &ScreenStreamInfo{
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		OwnerID:     "desktop-1",
		Subscribers: map[string]*ScreenSubscriberState{
			"mobile-1": {SubscribedAt: time.Now()},
		},
		LastSeq: 1,
	}

	if err := sm.HandleMessage("mobile-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenAck),
		V:           3,
		ID:          "ack-1",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"ack_seq": 1.0,
		},
	})); err != nil {
		t.Fatalf("screen.ack failed: %v", err)
	}
	state := sm.paneStreams["pane-1"].Subscribers["mobile-1"]
	if state == nil || state.LastAckSeq != 1 {
		t.Fatalf("expected ack seq 1, got %#v", state)
	}

	if err := sm.HandleMessage("desktop-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenDelta),
		V:           3,
		ID:          "delta-300",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"seq":      300.0,
			"prev_seq": 299.0,
			"data":     "YQ==",
		},
	})); err != nil {
		t.Fatalf("screen.delta failed: %v", err)
	}
	state = sm.paneStreams["pane-1"].Subscribers["mobile-1"]
	if state == nil || !state.NeedsResync {
		t.Fatalf("lagging viewer should be marked for resync, got %#v", state)
	}
}

func TestScreenDeltaSkipsViewerWhenOutboundQueueBacklogged(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")
	seedDevice(t, sm, "mobile-1", "mobile-token", "mobile")
	seedPairing(t, sm, "desktop-1", "mobile-1")

	sm.workspaces["desktop-1:default"] = &WorkspaceInfo{
		WorkspaceID: "desktop-1:default",
		OwnerID:     "desktop-1",
		Subscribers: map[string]bool{"mobile-1": true},
	}
	sm.paneStreams["pane-1"] = &ScreenStreamInfo{
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		OwnerID:     "desktop-1",
		Snapshot: map[string]interface{}{
			"snapshot_seq": 1.0,
			"data":         "YQ==",
		},
		Subscribers: map[string]*ScreenSubscriberState{
			"mobile-1": {
				SubscribedAt: time.Now(),
				LastAckSeq:   1,
			},
		},
		LastSeq: 1,
	}
	sender := newDeviceSender(nil)
	sm.deviceSenders["mobile-1"] = sender
	for i := 0; i < screenDeltaBacklogLimit; i++ {
		sender.queue <- []byte("{}")
	}

	if err := sm.HandleMessage("desktop-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenDelta),
		V:           3,
		ID:          "delta-2",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"seq":      2.0,
			"prev_seq": 1.0,
			"data":     "Yg==",
		},
	})); err != nil {
		t.Fatalf("screen.delta failed: %v", err)
	}

	state := sm.paneStreams["pane-1"].Subscribers["mobile-1"]
	if state == nil || !state.NeedsResync {
		t.Fatalf("backlogged viewer should be marked for resync, got %#v", state)
	}
	if state.LastSentSeq == 2 {
		t.Fatalf("delta should not be marked sent to backlogged viewer")
	}
	if state.SkippedDeltaCount == 0 {
		t.Fatalf("expected skipped delta count to increase")
	}
}

func TestScreenUnsubscribeRemovesViewerFromDeltaFanout(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")
	seedDevice(t, sm, "pc-1", "pc-token", "pc_receiver")
	seedPairing(t, sm, "desktop-1", "pc-1")

	sm.workspaces["desktop-1:default"] = &WorkspaceInfo{
		WorkspaceID: "desktop-1:default",
		OwnerID:     "desktop-1",
		Subscribers: map[string]bool{"pc-1": true},
	}
	sm.paneStreams["pane-1"] = &ScreenStreamInfo{
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		OwnerID:     "desktop-1",
		Subscribers: map[string]*ScreenSubscriberState{
			"pc-1": {SubscribedAt: time.Now(), LastAckSeq: 1},
		},
		LastSeq: 1,
	}

	if err := sm.HandleMessage("pc-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenUnsubscribe),
		V:           3,
		ID:          "unsub-1",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		Timestamp:   time.Now().Unix(),
	})); err != nil {
		t.Fatalf("screen.unsubscribe failed: %v", err)
	}
	if _, ok := sm.paneStreams["pane-1"].Subscribers["pc-1"]; ok {
		t.Fatal("viewer should be removed from screen subscribers")
	}

	if err := sm.HandleMessage("desktop-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenDelta),
		V:           3,
		ID:          "delta-2",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"seq":      2.0,
			"prev_seq": 1.0,
			"data":     "Yg==",
		},
	})); err != nil {
		t.Fatalf("screen.delta failed: %v", err)
	}
	if _, ok := sm.paneStreams["pane-1"].Subscribers["pc-1"]; ok {
		t.Fatal("unsubscribed viewer must not be re-added by delta fanout")
	}
}

func TestRegisterConnectionRetiresOldConnection(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	first := &websocket.Conn{}
	second := &websocket.Conn{}
	sm.RegisterConnection("desktop-1", "desktop", first, ConnectionMeta{
		ConnectionID:     "conn-1",
		SelectedProtocol: 3,
	})
	sm.RegisterConnection("desktop-1", "desktop", second, ConnectionMeta{
		ConnectionID:     "conn-2",
		SelectedProtocol: 3,
	})

	if sm.connectionIDs["desktop-1"] != "conn-2" {
		t.Fatalf("expected latest connection id, got %q", sm.connectionIDs["desktop-1"])
	}
	if sm.isCurrentConnection("desktop-1", first) {
		t.Fatal("old connection must be retired")
	}
	if !sm.isCurrentConnection("desktop-1", second) {
		t.Fatal("new connection should be current")
	}
}
