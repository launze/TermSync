package main

import (
	"crypto/tls"
	_ "embed"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"termsync-server/handler"
	"termsync-server/relay"
	"termsync-server/store"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

//go:embed certs/server.crt
var embeddedServerCert []byte

//go:embed certs/server.key
var embeddedServerKey []byte

func main() {
	execDir, err := executableDir()
	if err != nil {
		log.Fatalf("❌ Failed to resolve executable directory: %v", err)
	}

	// Configuration
	port := getEnv("TERMSYNC_PORT", "7373")
	httpPort := getEnv("TERMSYNC_HTTP_PORT", "8080")
	dbPath := resolveRuntimePath(execDir, getEnv("TERMSYNC_DB_PATH", "./data/termsync.db"))
	jwtSecret := getEnv("TERMSYNC_JWT_SECRET", "termsync-secret-change-in-production")

	log.Println("🚀 TermSync Server starting...")
	log.Printf("📡 WSS Port: %s", port)
	log.Printf("🌐 HTTP Port: %s", httpPort)
	log.Printf("💾 Database: %s", dbPath)

	// Ensure the runtime data directory exists next to the configured database path.
	if err := os.MkdirAll(filepath.Dir(dbPath), 0755); err != nil {
		log.Fatalf("❌ Failed to create data directory: %v", err)
	}

	// Initialize SQLite store
	dbStore, err := store.New(dbPath)
	if err != nil {
		log.Fatalf("❌ Failed to initialize database: %v", err)
	}
	defer dbStore.Close()
	log.Println("✅ Database initialized")

	// Initialize session manager
	sessionManager := relay.NewSessionManager(dbStore)
	log.Println("✅ Session manager initialized")

	// Initialize handlers
	authHandler := handler.NewAuthHandler(dbStore, []byte(jwtSecret))
	wsHandler := handler.NewWSHandler(sessionManager, authHandler)
	apiHandler := handler.NewAPIHandler(sessionManager, dbStore)

	// Setup Chi router
	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(handler.CORSMiddleware)

	// Routes
	r.Post("/api/register", authHandler.HandleRegister)
	r.Post("/api/login", authHandler.HandleLogin)
	r.Post("/api/pairing/start", apiHandler.HandleStartPairing)
	r.Post("/api/pairing/complete", apiHandler.HandleCompletePairing)
	r.Get("/api/sessions", apiHandler.HandleGetSessions)
	r.Get("/api/health", apiHandler.HandleHealthCheck)
	r.Get("/api/cert", apiHandler.ServeCertContent("server.crt", embeddedServerCert))
	r.Get("/ws", wsHandler.HandleWebSocket)

	// HTTP redirect server (8080 -> WSS port)
	go func() {
		redirectHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			target := fmt.Sprintf("https://%s:%s%s", r.Host[:len(r.Host)-len(":"+httpPort)], port, r.URL.String())
			http.Redirect(w, r, target, http.StatusMovedPermanently)
		})

		log.Printf("🔄 HTTP redirect server listening on :%s", httpPort)
		if err := http.ListenAndServe(":"+httpPort, redirectHandler); err != nil {
			log.Printf("⚠️ HTTP redirect server error: %v", err)
		}
	}()

	// Graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	// Start HTTPS server in goroutine
	go func() {
		log.Printf("🔒 WSS server listening on :%s", port)
		server, err := newTLSServer(":"+port, r)
		if err != nil {
			log.Printf("❌ Failed to initialize TLS server: %v", err)
			return
		}
		if err := server.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
			log.Printf("❌ WSS server error: %v", err)
		}
	}()

	// Wait for shutdown signal
	<-stop
	log.Println("\n👋 Shutting down TermSync Server...")
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func executableDir() (string, error) {
	execPath, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(execPath), nil
}

func resolveRuntimePath(baseDir, configuredPath string) string {
	if filepath.IsAbs(configuredPath) {
		return configuredPath
	}
	return filepath.Join(baseDir, filepath.FromSlash(configuredPath))
}

func newTLSServer(addr string, handler http.Handler) (*http.Server, error) {
	certificate, err := tls.X509KeyPair(embeddedServerCert, embeddedServerKey)
	if err != nil {
		return nil, err
	}

	return &http.Server{
		Addr:    addr,
		Handler: handler,
		TLSConfig: &tls.Config{
			MinVersion:   tls.VersionTLS12,
			Certificates: []tls.Certificate{certificate},
		},
	}, nil
}

// Print startup banner
func init() {
	banner := `
╔═══════════════════════════════════════╗
║                                       ║
║   ███████╗███████╗███████╗██╗   ██╗║
║   ██╔══██╗██╔════╝██╔════╝╚██╗ ██╔╝║
║   ███████║█████╗  █████╗   ╚████╔╝ ║
║   ██╔══██║██╔══╝  ██╔══╝    ╚██╔╝  ║
║   ██║  ██║███████╗██║        ██║   ║
║   ╚═╝  ╚═╝╚══════╝╚═╝        ╚═╝   ║
║                                       ║
║        Cross-Platform Terminal        ║
║              v1.0.0                   ║
║                                       ║
╚═══════════════════════════════════════╝
`
	fmt.Print(banner)
}
