package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"termsync-server/store"
)

// AIHandler proxies the built-in AI provider without exposing provider keys to clients.
type AIHandler struct {
	store      *store.Store
	apiKey     string
	baseURL    string
	model      string
	httpClient *http.Client
}

// NewAIHandler creates the default server-side AI proxy.
func NewAIHandler(store *store.Store, apiKey, baseURL, model string) *AIHandler {
	if strings.TrimSpace(baseURL) == "" {
		baseURL = "https://ark.cn-beijing.volces.com/api/coding/v3"
	}
	if strings.TrimSpace(model) == "" {
		model = "DeepSeek-V4-Pro"
	}
	return &AIHandler{
		store:   store,
		apiKey:  strings.TrimSpace(apiKey),
		baseURL: strings.TrimSpace(baseURL),
		model:   strings.TrimSpace(model),
		httpClient: &http.Client{
			Timeout: 90 * time.Second,
		},
	}
}

// HandleDefaultChat accepts OpenAI-compatible messages and forwards them to the server-side default provider.
func (h *AIHandler) HandleDefaultChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAIError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}
	if h.apiKey == "" {
		writeAIError(w, http.StatusServiceUnavailable, "Default AI is not enabled on this server")
		return
	}
	if _, err := h.authenticateDevice(r); err != nil {
		writeAIError(w, http.StatusUnauthorized, "Unauthorized")
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	defer r.Body.Close()

	var payload map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeAIError(w, http.StatusBadRequest, "Invalid request body")
		return
	}
	messages, ok := payload["messages"].([]interface{})
	if !ok || len(messages) == 0 {
		writeAIError(w, http.StatusBadRequest, "messages is required")
		return
	}

	payload["model"] = h.model
	payload["stream"] = false
	delete(payload, "api_key")
	delete(payload, "apiKey")

	body, err := json.Marshal(payload)
	if err != nil {
		writeAIError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, h.chatCompletionsURL(), bytes.NewReader(body))
	if err != nil {
		writeAIError(w, http.StatusInternalServerError, "Failed to create upstream request")
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+h.apiKey)

	resp, err := h.httpClient.Do(req)
	if err != nil {
		log.Printf("default ai request failed: %v", err)
		writeAIError(w, http.StatusBadGateway, "Default AI request failed")
		return
	}
	defer resp.Body.Close()

	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header.Get("Content-Type")))
	w.WriteHeader(resp.StatusCode)
	if _, err := io.Copy(w, resp.Body); err != nil {
		log.Printf("default ai response copy failed: %v", err)
	}
}

func (h *AIHandler) authenticateDevice(r *http.Request) (string, error) {
	authHeader := r.Header.Get("Authorization")
	if !strings.HasPrefix(authHeader, "Bearer ") {
		return "", fmt.Errorf("missing bearer token")
	}
	token := strings.TrimSpace(strings.TrimPrefix(authHeader, "Bearer "))
	if token == "" {
		return "", fmt.Errorf("empty bearer token")
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	device, err := h.store.GetDeviceByToken(ctx, token)
	if err != nil {
		return "", err
	}
	return device.ID, nil
}

func (h *AIHandler) chatCompletionsURL() string {
	base := strings.TrimRight(h.baseURL, "/")
	if strings.HasSuffix(strings.ToLower(base), "/chat/completions") {
		return base
	}
	return base + "/chat/completions"
}

func contentTypeOrJSON(contentType string) string {
	if strings.TrimSpace(contentType) == "" {
		return "application/json"
	}
	return contentType
}

func writeAIError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"error": map[string]string{
			"message": message,
		},
	})
}
