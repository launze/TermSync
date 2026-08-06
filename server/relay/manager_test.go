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

func readQueuedMessage(t *testing.T, sender *deviceSender) models.Message {
	t.Helper()
	select {
	case data := <-sender.queue:
		var msg models.Message
		if err := json.Unmarshal(data, &msg); err != nil {
			t.Fatalf("unmarshal queued message failed: %v", err)
		}
		return msg
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for queued message")
		return models.Message{}
	}
}

func TestNewSessionManager(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()

	if sm.deviceConnections == nil || sm.connectionIDs == nil || sm.workspaces == nil || sm.paneStreams == nil {
		t.Fatal("manager maps should be initialized")
	}
}

func TestScreenHistoryRoutesOnlyBetweenRequesterAndOwner(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")
	seedDevice(t, sm, "mobile-1", "mobile-token", "mobile")
	seedPairing(t, sm, "desktop-1", "mobile-1")

	sm.paneStreams["pane-1"] = &ScreenStreamInfo{
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		OwnerID:     "desktop-1",
		Subscribers: map[string]*ScreenSubscriberState{"mobile-1": {}},
	}
	ownerSender := newDeviceSender(nil)
	mobileSender := newDeviceSender(nil)
	sm.deviceConnections["desktop-1"] = &websocket.Conn{}
	sm.deviceConnections["mobile-1"] = &websocket.Conn{}
	sm.deviceSenders["desktop-1"] = ownerSender
	sm.deviceSenders["mobile-1"] = mobileSender

	request := models.Message{
		Type: string(models.MsgScreenHistoryRequest), V: 3, ID: "history-1",
		WorkspaceID: "desktop-1:default", PaneID: "pane-1", Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{"request_id": "history-1", "before_line": 2000.0},
	}
	if err := sm.HandleMessage("mobile-1", marshalMsg(t, request)); err != nil {
		t.Fatalf("history request failed: %v", err)
	}
	forwarded := readQueuedMessage(t, ownerSender)
	if got := strField(forwarded.Payload, "requested_by", ""); got != "mobile-1" {
		t.Fatalf("requested_by = %q, want mobile-1", got)
	}

	response := models.Message{
		Type: string(models.MsgScreenHistoryResponse), V: 3, ID: "history-response-1",
		WorkspaceID: "desktop-1:default", PaneID: "pane-1", SessionID: "session-1", Timestamp: time.Now().Unix(),
		Payload: map[string]interface{}{"request_id": "history-1", "target_device_id": "mobile-1", "data": "e30="},
	}
	if err := sm.HandleMessage("desktop-1", marshalMsg(t, response)); err != nil {
		t.Fatalf("history response failed: %v", err)
	}
	if got := readQueuedMessage(t, mobileSender); got.Type != string(models.MsgScreenHistoryResponse) {
		t.Fatalf("response type = %q", got.Type)
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
	key := screenStreamKey("desktop-1:default", "pane-1")
	if sm.paneWorkspace[key] != "desktop-1:default" {
		t.Fatalf("pane should be indexed to workspace, got %q", sm.paneWorkspace[key])
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
	key := screenStreamKey("desktop-1:default", "pane-2")
	if sm.paneWorkspace[key] != "desktop-1:default" {
		t.Fatalf("pane should be indexed from patch, got %q", sm.paneWorkspace[key])
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
	newKey := screenStreamKey("desktop-1:default", "pane-2")
	if sm.paneWorkspace[newKey] != "desktop-1:default" {
		t.Fatalf("new pane should be indexed, got %q", sm.paneWorkspace[newKey])
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
	stream := sm.paneStreams[screenStreamKey("desktop-1:default", "pane-1")]
	if stream == nil || stream.Subscribers["pc-1"] == nil {
		t.Fatal("viewer should be subscribed to pane screen")
	}
}

func TestScreenStreamsAreScopedByWorkspace(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token-1", "desktop")
	seedDevice(t, sm, "desktop-2", "desktop-token-2", "desktop")
	seedDevice(t, sm, "mobile-2", "mobile-token-2", "mobile")
	seedPairing(t, sm, "desktop-2", "mobile-2")

	for _, ownerID := range []string{"desktop-1", "desktop-2"} {
		workspaceID := ownerID + ":default"
		if err := sm.HandleMessage(ownerID, marshalMsg(t, models.Message{
			Type:        string(models.MsgLayoutSnapshot),
			V:           3,
			WorkspaceID: workspaceID,
			Payload: map[string]interface{}{
				"layout_version": 1.0,
				"snapshot": map[string]interface{}{
					"root": map[string]interface{}{"pane_id": "1"},
				},
			},
		})); err != nil {
			t.Fatalf("layout.snapshot for %s failed: %v", ownerID, err)
		}
		if err := sm.HandleMessage(ownerID, marshalMsg(t, models.Message{
			Type:        string(models.MsgScreenDelta),
			V:           3,
			WorkspaceID: workspaceID,
			PaneID:      "1",
			SessionID:   ownerID + "-session",
			Payload: map[string]interface{}{
				"seq":      1.0,
				"prev_seq": 0.0,
				"data":     "YQ==",
			},
		})); err != nil {
			t.Fatalf("screen.delta for %s failed: %v", ownerID, err)
		}
	}

	first := sm.paneStreams[screenStreamKey("desktop-1:default", "1")]
	second := sm.paneStreams[screenStreamKey("desktop-2:default", "1")]
	if first == nil || second == nil {
		t.Fatal("same pane id should create one stream per workspace")
	}
	if first.OwnerID != "desktop-1" || second.OwnerID != "desktop-2" {
		t.Fatalf("unexpected stream owners: first=%q second=%q", first.OwnerID, second.OwnerID)
	}
	if err := sm.HandleMessage("mobile-2", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenSubscribe),
		V:           3,
		WorkspaceID: "desktop-2:default",
		PaneID:      "1",
	})); err != nil {
		t.Fatalf("screen.subscribe for second workspace failed: %v", err)
	}
	if second.Subscribers["mobile-2"] == nil {
		t.Fatal("viewer should subscribe to the requested workspace stream")
	}
	if first.Subscribers["mobile-2"] != nil {
		t.Fatal("viewer must not subscribe to the same pane id in another workspace")
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

	if err := sm.HandleMessage("pc-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenAck),
		V:           3,
		ID:          "late-ack-after-unsubscribe",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"ack_seq": 1.0,
		},
	})); err != nil {
		t.Fatalf("late screen.ack failed: %v", err)
	}
	if _, ok := sm.paneStreams["pane-1"].Subscribers["pc-1"]; ok {
		t.Fatal("late ack must not recreate an unsubscribed viewer")
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

func TestScreenDeltaFanoutRespectsSubscriberEncoding(t *testing.T) {
	sm, cleanup := newTestManager(t)
	defer cleanup()
	seedDevice(t, sm, "desktop-1", "desktop-token", "desktop")
	seedDevice(t, sm, "pc-1", "pc-token", "pc_receiver")
	seedDevice(t, sm, "mobile-1", "mobile-token", "mobile")
	seedPairing(t, sm, "desktop-1", "pc-1")
	seedPairing(t, sm, "desktop-1", "mobile-1")

	sm.workspaces["desktop-1:default"] = &WorkspaceInfo{
		WorkspaceID: "desktop-1:default",
		OwnerID:     "desktop-1",
		Subscribers: map[string]bool{"pc-1": true, "mobile-1": true},
	}
	sm.paneStreams["pane-1"] = &ScreenStreamInfo{
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		OwnerID:     "desktop-1",
		Snapshot: map[string]interface{}{
			"snapshot_seq": 1.0,
			"encoding":     "base64+vt",
			"data":         "dnQ=",
		},
		Snapshots: map[string]map[string]interface{}{
			screenEncodingVT: {
				"snapshot_seq": 1.0,
				"encoding":     "base64+vt",
				"data":         "dnQ=",
			},
			screenEncodingCells: {
				"snapshot_seq": 1.0,
				"encoding":     "base64+cells-json",
				"data":         "e30=",
			},
		},
		Subscribers: map[string]*ScreenSubscriberState{},
		LastSeq:     1,
	}
	pcSender := newDeviceSender(nil)
	mobileSender := newDeviceSender(nil)
	sm.deviceConnections["pc-1"] = &websocket.Conn{}
	sm.deviceConnections["mobile-1"] = &websocket.Conn{}
	sm.deviceSenders["pc-1"] = pcSender
	sm.deviceSenders["mobile-1"] = mobileSender

	if err := sm.HandleMessage("pc-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenSubscribe),
		V:           3,
		ID:          "pc-sub",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		Timestamp:   time.Now().Unix(),
	})); err != nil {
		t.Fatalf("pc screen.subscribe failed: %v", err)
	}
	if err := sm.HandleMessage("mobile-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenSubscribe),
		V:           3,
		ID:          "mobile-sub",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"encoding": "base64+cells-json",
		},
	})); err != nil {
		t.Fatalf("mobile screen.subscribe failed: %v", err)
	}
	_ = readQueuedMessage(t, pcSender)
	_ = readQueuedMessage(t, mobileSender)

	if err := sm.HandleMessage("desktop-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenDelta),
		V:           3,
		ID:          "vt-delta",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"seq":      2.0,
			"prev_seq": 1.0,
			"encoding": "base64+vt",
			"data":     "dnQ=",
		},
	})); err != nil {
		t.Fatalf("vt screen.delta failed: %v", err)
	}
	pcMsg := readQueuedMessage(t, pcSender)
	if got := strField(pcMsg.Payload, "encoding", ""); got != screenEncodingVT {
		t.Fatalf("pc should receive vt delta, got %q", got)
	}
	if len(mobileSender.queue) != 0 {
		t.Fatalf("mobile must not receive vt delta")
	}

	if err := sm.HandleMessage("desktop-1", marshalMsg(t, models.Message{
		Type:        string(models.MsgScreenDelta),
		V:           3,
		ID:          "cells-delta",
		WorkspaceID: "desktop-1:default",
		PaneID:      "pane-1",
		SessionID:   "session-1",
		Timestamp:   time.Now().Unix(),
		Payload: map[string]interface{}{
			"seq":      2.0,
			"prev_seq": 0.0,
			"encoding": "base64+cells-json",
			"data":     "e30=",
		},
	})); err != nil {
		t.Fatalf("cells screen.delta failed: %v", err)
	}
	mobileMsg := readQueuedMessage(t, mobileSender)
	if got := strField(mobileMsg.Payload, "encoding", ""); got != screenEncodingCells {
		t.Fatalf("mobile should receive cells delta, got %q", got)
	}
	if len(pcSender.queue) != 0 {
		t.Fatalf("pc must not receive cells delta")
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
