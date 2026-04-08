package handler

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"termsync-server/models"
	"termsync-server/relay"
	"termsync-server/store"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

// AuthHandler handles device authentication
type AuthHandler struct {
	store     *store.Store
	jwtSecret []byte
}

// NewAuthHandler creates a new AuthHandler
func NewAuthHandler(store *store.Store, jwtSecret []byte) *AuthHandler {
	return &AuthHandler{
		store:     store,
		jwtSecret: jwtSecret,
	}
}

// HandleRegister handles device registration
func (h *AuthHandler) HandleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Name string `json:"name"`
		Type string `json:"type"` // "desktop" or "mobile"
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	if req.Name == "" {
		req.Name = "Unnamed Device"
	}
	if req.Type == "" {
		req.Type = "desktop"
	}
	if req.Type != "desktop" && req.Type != "mobile" {
		http.Error(w, "Invalid device type", http.StatusBadRequest)
		return
	}

	// Generate device credentials
	device := &models.Device{
		ID:    uuid.New().String(),
		Name:  req.Name,
		Token: uuid.New().String(),
		Type:  req.Type,
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	if err := h.store.CreateDevice(ctx, device); err != nil {
		log.Printf("❌ Failed to register device: %v", err)
		http.Error(w, "Failed to register device", http.StatusInternalServerError)
		return
	}

	// Generate JWT token
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"device_id": device.ID,
		"type":      device.Type,
		"exp":       time.Now().AddDate(1, 0, 0).Unix(), // 1 year expiry
	})

	tokenString, err := token.SignedString(h.jwtSecret)
	if err != nil {
		log.Printf("❌ Failed to generate JWT: %v", err)
		http.Error(w, "Failed to generate token", http.StatusInternalServerError)
		return
	}

	resp := map[string]interface{}{
		"success": true,
		"device": map[string]string{
			"id":    device.ID,
			"name":  device.Name,
			"token": device.Token,
			"type":  device.Type,
		},
		"jwt_token": tokenString,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)

	log.Printf("✅ Device registered: %s (%s) - %s", device.Name, device.Type, device.ID)
}

// HandleLogin handles device login with existing token
func (h *AuthHandler) HandleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req models.AuthRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	device, err := h.store.GetDeviceByToken(ctx, req.Token)
	if err != nil {
		w.WriteHeader(http.StatusUnauthorized)
		json.NewEncoder(w).Encode(models.AuthResponse{
			Success: false,
			Message: "Invalid token",
		})
		return
	}

	// Generate JWT token
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"device_id": device.ID,
		"type":      device.Type,
		"exp":       time.Now().AddDate(1, 0, 0).Unix(),
	})

	tokenString, err := token.SignedString(h.jwtSecret)
	if err != nil {
		log.Printf("❌ Failed to generate JWT: %v", err)
		http.Error(w, "Failed to generate token", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":   true,
		"device_id": device.ID,
		"jwt_token": tokenString,
	})

	log.Printf("🔐 Device logged in: %s (%s)", device.Name, device.ID)
}

// ValidateJWT validates a JWT token from request header
func (h *AuthHandler) ValidateJWT(r *http.Request) (string, string, error) {
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		return "", "", nil // No token, allow for WebSocket (will handle auth in WS)
	}

	tokenStr := authHeader[len("Bearer "):]
	token, err := jwt.Parse(tokenStr, func(token *jwt.Token) (interface{}, error) {
		return h.jwtSecret, nil
	})

	if err != nil || !token.Valid {
		return "", "", err
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		return "", "", nil
	}

	deviceID, _ := claims["device_id"].(string)
	deviceType, _ := claims["type"].(string)

	return deviceID, deviceType, nil
}

// WSHandler handles WebSocket connections
type WSHandler struct {
	manager     *relay.SessionManager
	authHandler *AuthHandler
}

// NewWSHandler creates a new WSHandler
func NewWSHandler(manager *relay.SessionManager, authHandler *AuthHandler) *WSHandler {
	return &WSHandler{
		manager:     manager,
		authHandler: authHandler,
	}
}

// HandleWebSocket upgrades HTTP to WebSocket and handles the connection
func (h *WSHandler) HandleWebSocket(w http.ResponseWriter, r *http.Request) {
	// Upgrade to WebSocket
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		InsecureSkipVerify: true, // Allow self-signed certs during dev
		Subprotocols:       []string{"termsync-protocol"},
	})
	if err != nil {
		log.Printf("❌ WebSocket upgrade failed: %v", err)
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "connection closed")

	// Set a generous read limit for large terminal output messages (1MB)
	conn.SetReadLimit(1 << 20)

	// Wait for auth message first
	deviceID, deviceType, err := h.waitForAuth(r.Context(), conn)
	if err != nil {
		conn.Close(websocket.StatusPolicyViolation, "authentication failed")
		return
	}

	// Register connection
	h.manager.RegisterConnection(deviceID, deviceType, conn)
	defer h.manager.UnregisterConnection(deviceID, conn)
	if err := h.manager.PushSessionList(deviceID); err != nil {
		log.Printf("❌ Failed to push initial session list to %s: %v", deviceID, err)
	}

	// Start server-side keepalive: ping the client every 30s.
	// If no pong is received within 10s the context is cancelled and
	// conn.Read below returns an error, cleaning up the dead connection.
	keepaliveCtx, keepaliveCancel := context.WithCancel(r.Context())
	defer keepaliveCancel()
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-keepaliveCtx.Done():
				return
			case <-ticker.C:
				pingCtx, pingCancel := context.WithTimeout(keepaliveCtx, 10*time.Second)
				err := conn.Ping(pingCtx)
				pingCancel()
				if err != nil {
					log.Printf("❌ WebSocket ping failed for %s: %v", deviceID, err)
					keepaliveCancel()
					return
				}
			}
		}
	}()

	// Message loop with keepalive-aware context
	for {
		_, message, err := conn.Read(keepaliveCtx)

		if err != nil {
			if websocket.CloseStatus(err) == websocket.StatusNormalClosure {
				return
			}
			log.Printf("❌ WebSocket read error for %s: %v", deviceID, err)
			return
		}

		if err := h.manager.HandleMessage(deviceID, message); err != nil {
			log.Printf("❌ Message handling error: %v", err)
		}
	}
}

// waitForAuth waits for the first authentication message
func (h *WSHandler) waitForAuth(ctx context.Context, conn *websocket.Conn) (string, string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	_, message, err := conn.Read(ctx)
	if err != nil {
		return "", "", err
	}

	var msg models.Message
	if err := json.Unmarshal(message, &msg); err != nil {
		return "", "", err
	}

	if msg.Type != string(models.MsgAuth) {
		return "", "", fmt.Errorf("expected auth message, got %q", msg.Type)
	}

	token, _ := msg.Payload["token"].(string)
	if token == "" {
		return "", "", fmt.Errorf("missing auth token")
	}

	// Look up device
	device, err := h.authHandler.store.GetDeviceByToken(context.Background(), token)
	if err != nil {
		return "", "", err
	}

	// Send auth success
	resp := models.Message{
		Type: string(models.MsgAuthResponse),
		Payload: map[string]interface{}{
			"success":     true,
			"device_id":   device.ID,
			"device_type": device.Type,
		},
	}
	respData, _ := json.Marshal(resp)
	if err := conn.Write(ctx, websocket.MessageText, respData); err != nil {
		return "", "", err
	}

	return device.ID, device.Type, nil
}

// APIHandler handles REST API endpoints
type APIHandler struct {
	manager *relay.SessionManager
	store   *store.Store
}

// NewAPIHandler creates a new APIHandler
func NewAPIHandler(manager *relay.SessionManager, store *store.Store) *APIHandler {
	return &APIHandler{
		manager: manager,
		store:   store,
	}
}

// HandleGetSessions returns all active sessions
func (h *APIHandler) HandleGetSessions(w http.ResponseWriter, r *http.Request) {
	sessions, err := h.manager.GetAllActiveSessions()
	if err != nil {
		http.Error(w, "Failed to get sessions", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"sessions":       sessions,
		"online_devices": h.manager.GetOnlineDeviceCount(),
	})
}

// HandleStartPairing creates a short-lived pairing code for a desktop device.
func (h *APIHandler) HandleStartPairing(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}
	if req.Token == "" {
		http.Error(w, "Missing device token", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	device, err := h.store.GetDeviceByToken(ctx, req.Token)
	if err != nil {
		http.Error(w, "Invalid device token", http.StatusUnauthorized)
		return
	}
	if device.Type != "desktop" {
		http.Error(w, "Only desktop devices can generate pairing codes", http.StatusForbidden)
		return
	}

	code, err := generatePairingCode()
	if err != nil {
		http.Error(w, "Failed to generate pairing code", http.StatusInternalServerError)
		return
	}

	expiresAt := time.Now().Add(5 * time.Minute)
	if err := h.store.CreatePairingCode(ctx, device.ID, code, expiresAt); err != nil {
		log.Printf("❌ Failed to create pairing code: %v", err)
		http.Error(w, "Failed to create pairing code", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"code":    code,
		"desktop": map[string]string{
			"id":   device.ID,
			"name": device.Name,
		},
		"expires_at": expiresAt.Unix(),
	})
}

// HandleCompletePairing binds a mobile device to the desktop associated with a pairing code.
func (h *APIHandler) HandleCompletePairing(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Token string `json:"token"`
		Code  string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}
	if req.Token == "" || req.Code == "" {
		http.Error(w, "Missing token or pairing code", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	device, err := h.store.GetDeviceByToken(ctx, req.Token)
	if err != nil {
		http.Error(w, "Invalid device token", http.StatusUnauthorized)
		return
	}
	if device.Type != "mobile" {
		http.Error(w, "Only mobile devices can complete pairing", http.StatusForbidden)
		return
	}

	pairing, err := h.store.ConsumePairingCode(ctx, device.ID, req.Code)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"pairing": pairing,
	})
}

// HandleHealthCheck returns server health status
func (h *APIHandler) HandleHealthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":         "healthy",
		"online_devices": h.manager.GetOnlineDeviceCount(),
		"timestamp":      time.Now().Unix(),
	})
}

// ServeCert serves the server certificate for clients to download
func (h *APIHandler) ServeCert(certPath string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, certPath)
	}
}

// ServeCertContent serves an in-memory certificate bundled into the binary.
func (h *APIHandler) ServeCertContent(filename string, certContent []byte) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-x509-ca-cert")
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", filename))
		w.Write(certContent)
	}
}

func generatePairingCode() (string, error) {
	const alphabet = "0123456789"
	buf := make([]byte, 6)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	for i := range buf {
		buf[i] = alphabet[int(buf[i])%len(alphabet)]
	}
	return string(buf), nil
}

// LogMiddleware logs HTTP requests
func LogMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}

// CORS middleware for development
func CORSMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// Ensure io is used (for potential future streaming)
var _ = io.EOF
