package main

import (
	"crypto/tls"
	_ "embed"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

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
	if err := loadEnvFile(filepath.Join(execDir, ".env")); err != nil {
		log.Printf("⚠️ Failed to load .env: %v", err)
	}

	// Configuration
	port := getEnv("TERMSYNC_PORT", "7373")
	httpPort := getEnv("TERMSYNC_HTTP_PORT", "8080")
	dbPath := resolveRuntimePath(execDir, getEnv("TERMSYNC_DB_PATH", "./data/termsync.db"))
	downloadsDir := resolveRuntimePath(execDir, getEnv("TERMSYNC_DOWNLOADS_DIR", "./downloads"))
	jwtSecret := getEnv("TERMSYNC_JWT_SECRET", "termsync-secret-change-in-production")
	defaultAIAPIKey := getEnv("TERMSYNC_DEFAULT_AI_API_KEY", "")
	defaultAIBaseURL := getEnv("TERMSYNC_DEFAULT_AI_BASE_URL", "https://ark.cn-beijing.volces.com/api/coding/v3")
	defaultAIModel := getEnv("TERMSYNC_DEFAULT_AI_MODEL", "DeepSeek-V4-Pro")

	log.Println("🚀 TermSync Server starting...")
	log.Printf("📡 WSS Port: %s", port)
	log.Printf("🌐 HTTP Port: %s", httpPort)
	log.Printf("💾 Database: %s", dbPath)
	log.Printf("📦 Downloads: %s", downloadsDir)
	log.Printf("🤖 Default AI: %s", enabledLabel(defaultAIAPIKey != ""))

	// Ensure the runtime data directory exists next to the configured database path.
	if err := os.MkdirAll(filepath.Dir(dbPath), 0755); err != nil {
		log.Fatalf("❌ Failed to create data directory: %v", err)
	}
	if err := os.MkdirAll(downloadsDir, 0755); err != nil {
		log.Fatalf("❌ Failed to create downloads directory: %v", err)
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
	aiHandler := handler.NewAIHandler(dbStore, defaultAIAPIKey, defaultAIBaseURL, defaultAIModel)

	// Setup Chi router
	r := chi.NewRouter()
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(handler.CORSMiddleware)

	// Routes
	r.Get("/", serveHome(downloadsDir, httpPort))
	r.Handle("/downloads/*", http.StripPrefix("/downloads/", http.FileServer(http.Dir(downloadsDir))))
	r.Get("/api/releases/latest", serveLatestRelease(downloadsDir, httpPort))
	r.Get("/api/mobile/latest", serveLatestMobile(downloadsDir, httpPort))
	r.Post("/api/register", authHandler.HandleRegister)
	r.Post("/api/login", authHandler.HandleLogin)
	r.Post("/api/ai/chat", aiHandler.HandleDefaultChat)
	r.Post("/api/pairing/start", apiHandler.HandleStartPairing)
	r.Post("/api/pairing/complete", apiHandler.HandleCompletePairing)
	r.Get("/api/sessions", apiHandler.HandleGetSessions)
	r.Get("/api/health", apiHandler.HandleHealthCheck)
	r.Get("/api/cert", apiHandler.ServeCertContent("server.crt", embeddedServerCert))
	r.Get("/ws", wsHandler.HandleWebSocket)

	// HTTP download server. Downloads are intentionally available over plain HTTP
	// because mobile and desktop browsers commonly block executable downloads
	// from this server's private HTTPS certificate.
	go func() {
		downloadRouter := chi.NewRouter()
		downloadRouter.Use(middleware.Logger)
		downloadRouter.Use(middleware.Recoverer)
		downloadRouter.Use(handler.CORSMiddleware)
		downloadRouter.Get("/", serveHome(downloadsDir, httpPort))
		downloadRouter.Handle("/downloads/*", http.StripPrefix("/downloads/", http.FileServer(http.Dir(downloadsDir))))

		httpHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/" || strings.HasPrefix(r.URL.Path, "/downloads/") {
				downloadRouter.ServeHTTP(w, r)
				return
			}
			target := fmt.Sprintf("https://%s:%s%s", hostWithoutPort(r.Host), port, r.URL.RequestURI())
			http.Redirect(w, r, target, http.StatusMovedPermanently)
		})

		log.Printf("📥 HTTP download server listening on :%s", httpPort)
		if err := http.ListenAndServe(":"+httpPort, httpHandler); err != nil {
			log.Printf("⚠️ HTTP download server error: %v", err)
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

func loadEnvFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		if key == "" || os.Getenv(key) != "" {
			continue
		}
		if err := os.Setenv(key, value); err != nil {
			return err
		}
	}
	return nil
}

func enabledLabel(enabled bool) string {
	if enabled {
		return "enabled"
	}
	return "disabled"
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

type downloadItem struct {
	Name      string
	Path      string
	Size      string
	UpdatedAt string
	Platform  string
	Primary   bool
}

type homePageData struct {
	Downloads []downloadItem
	Generated string
}

func serveHome(downloadsDir, httpPort string) http.HandlerFunc {
	tmpl := template.Must(template.New("home").Parse(homeHTML))
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		downloadBaseURL := ""
		if r.TLS != nil && httpPort != "" {
			downloadBaseURL = "http://" + hostWithoutPort(r.Host) + ":" + httpPort
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := tmpl.Execute(w, homePageData{
			Downloads: listDownloads(downloadsDir, downloadBaseURL),
			Generated: time.Now().Format("2006-01-02 15:04:05"),
		}); err != nil {
			log.Printf("render home failed: %v", err)
		}
	}
}

func serveLatestMobile(downloadsDir, httpPort string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		writeLatestRelease(w, r, downloadsDir, httpPort, "android")
	}
}

func serveLatestRelease(downloadsDir, httpPort string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		platform := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("platform")))
		if platform == "" {
			platform = "desktop"
		}
		writeLatestRelease(w, r, downloadsDir, httpPort, platform)
	}
}

func writeLatestRelease(w http.ResponseWriter, r *http.Request, downloadsDir, httpPort, platform string) {
	items := listDownloads(downloadsDir, mobileDownloadBaseURL(r, httpPort))
	var latest *downloadItem
	var latestVersion string
	for i := range items {
		item := &items[i]
		if !matchesReleasePlatform(item.Name, platform) {
			continue
		}
		version := versionFromDownloadName(item.Name)
		if version == "" {
			continue
		}
		if latest == nil || compareVersion(version, latestVersion) > 0 {
			latest = item
			latestVersion = version
		}
	}

	w.Header().Set("Content-Type", "application/json")
	if latest == nil {
		json.NewEncoder(w).Encode(map[string]interface{}{
			"available": false,
			"platform":  platform,
		})
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"available":    true,
		"platform":     platform,
		"version_name": latestVersion,
		"file_name":    latest.Name,
		"download_url": latest.Path,
		"size":         latest.Size,
		"updated_at":   latest.UpdatedAt,
	})
}

func matchesReleasePlatform(name, platform string) bool {
	lower := strings.ToLower(name)
	ext := strings.ToLower(filepath.Ext(name))
	switch platform {
	case "android", "mobile":
		return ext == ".apk"
	case "desktop", "pc":
		return ext == ".exe" || ext == ".msi" || ext == ".deb" || ext == ".appimage" ||
			ext == ".dmg" || ext == ".zip" || strings.Contains(lower, "windows") ||
			strings.Contains(lower, "macos") || strings.Contains(lower, "linux")
	default:
		return false
	}
}

func mobileDownloadBaseURL(r *http.Request, httpPort string) string {
	host := hostWithoutPort(r.Host)
	if host == "" || httpPort == "" {
		return ""
	}
	return "http://" + host + ":" + httpPort
}

func listDownloads(downloadsDir, downloadBaseURL string) []downloadItem {
	entries, err := os.ReadDir(downloadsDir)
	if err != nil {
		log.Printf("read downloads dir failed: %v", err)
		return nil
	}

	items := make([]downloadItem, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		name := entry.Name()
		if shouldHideDownload(name) {
			continue
		}
		path := "/downloads/" + name
		if downloadBaseURL != "" {
			path = strings.TrimRight(downloadBaseURL, "/") + path
		}
		items = append(items, downloadItem{
			Name:      name,
			Path:      path,
			Size:      humanSize(info.Size()),
			UpdatedAt: info.ModTime().Format("2006-01-02 15:04"),
			Platform:  platformLabel(name),
			Primary:   isPrimaryDownload(name),
		})
	}
	return items
}

func versionFromDownloadName(name string) string {
	base := strings.TrimSuffix(name, filepath.Ext(name))
	fields := strings.FieldsFunc(base, func(r rune) bool {
		return r == '-' || r == '_' || r == ' '
	})
	for i := len(fields) - 1; i >= 0; i-- {
		field := strings.TrimPrefix(strings.ToLower(fields[i]), "v")
		if looksLikeVersion(field) {
			return field
		}
	}
	return ""
}

func looksLikeVersion(value string) bool {
	if value == "" {
		return false
	}
	hasDigit := false
	for _, r := range value {
		if r >= '0' && r <= '9' {
			hasDigit = true
			continue
		}
		if r != '.' {
			return false
		}
	}
	return hasDigit
}

func compareVersion(left, right string) int {
	leftParts := versionParts(left)
	rightParts := versionParts(right)
	maxLen := len(leftParts)
	if len(rightParts) > maxLen {
		maxLen = len(rightParts)
	}
	for i := 0; i < maxLen; i++ {
		l := 0
		r := 0
		if i < len(leftParts) {
			l = leftParts[i]
		}
		if i < len(rightParts) {
			r = rightParts[i]
		}
		if l > r {
			return 1
		}
		if l < r {
			return -1
		}
	}
	return 0
}

func versionParts(value string) []int {
	parts := strings.Split(value, ".")
	result := make([]int, 0, len(parts))
	for _, part := range parts {
		var n int
		fmt.Sscanf(part, "%d", &n)
		result = append(result, n)
	}
	return result
}

func shouldHideDownload(name string) bool {
	lower := strings.ToLower(name)
	return strings.Contains(lower, "server")
}

func hostWithoutPort(host string) string {
	if host == "" {
		return ""
	}
	if hostname, _, err := net.SplitHostPort(host); err == nil {
		return hostname
	}
	if strings.HasPrefix(host, "[") && strings.Contains(host, "]") {
		return strings.Trim(host, "[]")
	}
	if idx := strings.LastIndex(host, ":"); idx > -1 && strings.Count(host, ":") == 1 {
		return host[:idx]
	}
	return host
}

func platformLabel(name string) string {
	lower := strings.ToLower(name)
	if strings.Contains(lower, "linux") {
		if strings.HasSuffix(lower, ".appimage") {
			return "Linux AppImage"
		}
		if strings.HasSuffix(lower, ".deb") {
			return "Linux DEB"
		}
		return "Linux"
	}
	if strings.Contains(lower, "macos") {
		if strings.Contains(lower, "applesilicon") || strings.Contains(lower, "arm64") {
			return "macOS Apple Silicon"
		}
		if strings.Contains(lower, "intel") || strings.Contains(lower, "x64") {
			return "macOS Intel"
		}
		return "macOS"
	}
	ext := filepath.Ext(name)
	switch ext {
	case ".apk":
		return "Android"
	case ".exe":
		return "Windows Setup"
	case ".msi":
		return "Windows MSI"
	default:
		return "Download"
	}
}

func isPrimaryDownload(name string) bool {
	ext := filepath.Ext(name)
	return ext == ".apk" || ext == ".exe"
}

func humanSize(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

const homeHTML = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>TermSync 下载</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #101214;
      --panel: #181c20;
      --border: #2f363d;
      --text: #f2f5f8;
      --muted: #a8b0b8;
      --accent: #4ec9b0;
      --accent-text: #06231f;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    main {
      width: min(860px, calc(100vw - 32px));
      margin: 0 auto;
      padding: 40px 0;
    }
    header {
      margin-bottom: 24px;
    }
    h1 {
      margin: 0 0 8px;
      font-size: clamp(28px, 5vw, 44px);
      letter-spacing: 0;
    }
    p {
      margin: 0;
      color: var(--muted);
      line-height: 1.6;
    }
    .grid {
      display: grid;
      gap: 12px;
      margin-top: 20px;
    }
    .item {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 12px;
      align-items: center;
      padding: 16px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--panel);
    }
    .name {
      font-weight: 650;
      overflow-wrap: anywhere;
    }
    .meta {
      margin-top: 6px;
      color: var(--muted);
      font-size: 14px;
    }
    .download {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 38px;
      padding: 0 14px;
      border-radius: 7px;
      background: var(--accent);
      color: var(--accent-text);
      font-weight: 700;
      text-decoration: none;
      white-space: nowrap;
    }
    .secondary {
      background: transparent;
      color: var(--text);
      border: 1px solid var(--border);
    }
    .empty {
      padding: 18px;
      border: 1px dashed var(--border);
      border-radius: 8px;
      color: var(--muted);
    }
    footer {
      margin-top: 28px;
      color: var(--muted);
      font-size: 13px;
    }
    @media (max-width: 620px) {
      main { width: min(100vw - 20px, 860px); padding: 24px 0; }
      .item { grid-template-columns: 1fr; }
      .download { width: 100%; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <h1>TermSync 下载</h1>
      <p>下载桌面端和 Android 手机端。安装后默认连接当前服务器。</p>
    </header>
    {{if .Downloads}}
    <section class="grid" aria-label="下载列表">
      {{range .Downloads}}
      <article class="item">
        <div>
          <div class="name">{{.Platform}}</div>
          <div class="meta">{{.Name}} · {{.Size}} · {{.UpdatedAt}}</div>
        </div>
        <a class="download {{if not .Primary}}secondary{{end}}" href="{{.Path}}" download>下载</a>
      </article>
      {{end}}
    </section>
    {{else}}
    <div class="empty">下载文件还没有上传到服务器。</div>
    {{end}}
    <footer>页面生成时间：{{.Generated}}</footer>
  </main>
</body>
</html>`

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
