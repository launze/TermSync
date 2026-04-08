package store

import (
	"context"
	"os"
	"testing"
	"time"

	"termsync-server/models"
)

func setupTestStore(t *testing.T) (*Store, func()) {
	// Create temp database
	tmpFile, err := os.CreateTemp("", "termsync-test-*.db")
	if err != nil {
		t.Fatalf("Failed to create temp file: %v", err)
	}
	tmpFile.Close()

	store, err := New(tmpFile.Name())
	if err != nil {
		os.Remove(tmpFile.Name())
		t.Fatalf("Failed to create store: %v", err)
	}

	cleanup := func() {
		store.Close()
		os.Remove(tmpFile.Name())
	}

	return store, cleanup
}

func TestNewStore(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	if store == nil {
		t.Fatal("Expected store to be created")
	}
	if store.db == nil {
		t.Fatal("Expected database connection")
	}
}

func TestCreateAndGetDevice(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()
	device := &models.Device{
		ID:    "test-device-1",
		Name:  "Test Device",
		Token: "test-token-123",
		Type:  "desktop",
	}

	// Create device
	err := store.CreateDevice(ctx, device)
	if err != nil {
		t.Fatalf("Failed to create device: %v", err)
	}

	// Get device by token
	retrieved, err := store.GetDeviceByToken(ctx, "test-token-123")
	if err != nil {
		t.Fatalf("Failed to get device: %v", err)
	}

	if retrieved.ID != device.ID {
		t.Errorf("Expected ID %s, got %s", device.ID, retrieved.ID)
	}
	if retrieved.Name != device.Name {
		t.Errorf("Expected Name %s, got %s", device.Name, retrieved.Name)
	}
	if retrieved.Type != device.Type {
		t.Errorf("Expected Type %s, got %s", device.Type, retrieved.Type)
	}
}

func TestGetDeviceNotFound(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()
	_, err := store.GetDeviceByToken(ctx, "nonexistent-token")
	if err == nil {
		t.Fatal("Expected error for nonexistent device")
	}
}

func TestCreateAndGetSession(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()

	// First create a device
	device := &models.Device{
		ID:    "device-1",
		Name:  "Test Device",
		Token: "token-1",
		Type:  "desktop",
	}
	store.CreateDevice(ctx, device)

	// Create session
	session := &models.Session{
		ID:       "session-1",
		DeviceID: "device-1",
		Title:    "Test Terminal",
		Status:   "active",
		Cols:     80,
		Rows:     24,
	}

	err := store.CreateSession(ctx, session)
	if err != nil {
		t.Fatalf("Failed to create session: %v", err)
	}

	// Get session
	retrieved, err := store.GetSession(ctx, "session-1")
	if err != nil {
		t.Fatalf("Failed to get session: %v", err)
	}

	if retrieved.ID != session.ID {
		t.Errorf("Expected ID %s, got %s", session.ID, retrieved.ID)
	}
	if retrieved.Cols != 80 {
		t.Errorf("Expected Cols 80, got %d", retrieved.Cols)
	}
	if retrieved.Rows != 24 {
		t.Errorf("Expected Rows 24, got %d", retrieved.Rows)
	}
}

func TestUpdateSessionStatus(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()

	// Create device and session
	store.CreateDevice(ctx, &models.Device{
		ID: "device-1", Name: "Test", Token: "token", Type: "desktop",
	})
	store.CreateSession(ctx, &models.Session{
		ID: "session-1", DeviceID: "device-1", Status: "active",
	})

	// Update status
	err := store.UpdateSessionStatus(ctx, "session-1", "closed")
	if err != nil {
		t.Fatalf("Failed to update session status: %v", err)
	}

	// Verify
	session, err := store.GetSession(ctx, "session-1")
	if err != nil {
		t.Fatalf("Failed to get session: %v", err)
	}

	if session.Status != "closed" {
		t.Errorf("Expected status 'closed', got '%s'", session.Status)
	}
}

func TestGetActiveSessions(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()

	// Create device with unique ID
	store.CreateDevice(ctx, &models.Device{
		ID: "device-active-test", Name: "Test", Token: "token-active", Type: "desktop",
	})

	// Create multiple sessions
	store.CreateSession(ctx, &models.Session{
		ID: "active-session-1", DeviceID: "device-active-test", Status: "active",
	})
	store.CreateSession(ctx, &models.Session{
		ID: "active-session-2", DeviceID: "device-active-test", Status: "active",
	})
	store.CreateSession(ctx, &models.Session{
		ID: "closed-session-1", DeviceID: "device-active-test", Status: "closed",
	})

	// Get active sessions
	sessions, err := store.GetActiveSessions(ctx, "device-active-test")
	if err != nil {
		t.Fatalf("Failed to get active sessions: %v", err)
	}

	if len(sessions) != 2 {
		t.Errorf("Expected 2 active sessions, got %d", len(sessions))
		for _, s := range sessions {
			t.Logf("  Session: %s (status=%s)", s.ID, s.Status)
		}
	}
}

func TestOnlineStatus(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()

	// Set online
	err := store.SetOnline(ctx, "device-1")
	if err != nil {
		t.Fatalf("Failed to set online: %v", err)
	}

	// Check online
	online, err := store.IsOnline(ctx, "device-1")
	if err != nil {
		t.Fatalf("Failed to check online: %v", err)
	}
	if !online {
		t.Error("Expected device to be online")
	}

	// Set offline
	err = store.SetOffline(ctx, "device-1")
	if err != nil {
		t.Fatalf("Failed to set offline: %v", err)
	}

	// Check offline
	online, err = store.IsOnline(ctx, "device-1")
	if err != nil {
		t.Fatalf("Failed to check online: %v", err)
	}
	if online {
		t.Error("Expected device to be offline")
	}
}

func TestListDevices(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()

	// Create multiple devices
	for i := 0; i < 3; i++ {
		store.CreateDevice(ctx, &models.Device{
			ID:    "device-" + string(rune('1'+i)),
			Name:  "Device " + string(rune('1'+i)),
			Token: "token-" + string(rune('1'+i)),
			Type:  "desktop",
		})
	}

	// List devices
	devices, err := store.ListDevices(ctx)
	if err != nil {
		t.Fatalf("Failed to list devices: %v", err)
	}

	if len(devices) != 3 {
		t.Errorf("Expected 3 devices, got %d", len(devices))
	}
}

func TestConcurrentAccess(t *testing.T) {
	store, cleanup := setupTestStore(t)
	defer cleanup()

	ctx := context.Background()

	// Create a device
	store.CreateDevice(ctx, &models.Device{
		ID: "device-1", Name: "Test", Token: "token", Type: "desktop",
	})

	// Run concurrent operations
	done := make(chan bool)
	for i := 0; i < 10; i++ {
		go func(n int) {
			sessionID := "session-" + string(rune('1'+n))
			store.CreateSession(ctx, &models.Session{
				ID: sessionID, DeviceID: "device-1", Status: "active",
			})
			store.GetActiveSessions(ctx, "device-1")
			store.IsOnline(ctx, "device-1")
			done <- true
		}(i)
	}

	// Wait for all goroutines
	for i := 0; i < 10; i++ {
		select {
		case <-done:
			// OK
		case <-time.After(5 * time.Second):
			t.Fatal("Timeout waiting for concurrent operations")
		}
	}
}
