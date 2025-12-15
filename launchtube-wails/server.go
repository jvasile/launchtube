package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	version   = "dev"
	commit    = "unknown"
	buildDate = "unknown"
)

type Server struct {
	port         int
	assetDir     string
	dataDir      string
	kvStore      *KVStore
	player       *Player
	fileCache    *FileCache
	apps         []AppConfig
	appsMu       sync.RWMutex
	appsProfile  string
	appsLoadTime time.Time
	browserMgr   *BrowserManager
	cdpBrowser   *CDPBrowser
	useCDP       bool // Use CDP-based browser instead of extension-based
	activeProfile string
	onBrowserExit func()
	onShutdown    func()
}

type AppConfig struct {
	Name        string   `json:"name"`
	URL         string   `json:"url,omitempty"`
	MatchURLs   []string `json:"matchUrls,omitempty"`
	CommandLine string   `json:"commandLine,omitempty"`
	Type        int      `json:"type"`
	ImagePath   string   `json:"imagePath,omitempty"`
	ColorValue  int      `json:"colorValue"`
	ShowName    bool     `json:"showName"`
	ServiceID   string   `json:"serviceId,omitempty"`
}

func NewServer() *Server {
	home, _ := os.UserHomeDir()
	dataDir := filepath.Join(home, ".local", "share", "launchtube")
	assetDir := findAssetDirectory()

	// Extension mode is default (CDP triggers bot detection on YouTube etc)
	useCDP := os.Getenv("LAUNCHTUBE_USE_CDP") == "1"

	s := &Server{
		assetDir:   assetDir,
		dataDir:    dataDir,
		kvStore:    NewKVStore(),
		player:     NewPlayer(),
		fileCache:  NewFileCache(),
		browserMgr: NewBrowserManager(assetDir, dataDir), // Kept as fallback
		useCDP:     useCDP,
	}

	if useCDP {
		Log("Using CDP-based browser (set LAUNCHTUBE_USE_CDP=1)")
	} else {
		Log("Using extension-based browser")
	}

	return s
}

func (s *Server) SetOnBrowserExit(fn func()) {
	s.onBrowserExit = fn
	s.browserMgr.SetOnExit(fn)
}

func (s *Server) SetOnPlayerExit(fn func()) {
	s.player.SetOnExit(fn)
}

func (s *Server) SetOnShutdown(fn func()) {
	s.onShutdown = fn
}

func (s *Server) GetAppsForProfile(profileID string) []AppConfig {
	if profileID == "" {
		s.appsMu.RLock()
		apps := s.apps
		s.appsMu.RUnlock()
		return apps
	}

	s.appsMu.RLock()
	if s.appsProfile == profileID && time.Since(s.appsLoadTime) < 5*time.Second {
		apps := s.apps
		s.appsMu.RUnlock()
		return apps
	}
	s.appsMu.RUnlock()

	appsPath := filepath.Join(s.dataDir, "profiles", profileID, "apps.json")
	data, err := os.ReadFile(appsPath)
	if err != nil {
		Log("Failed to load apps for profile %s: %v", profileID, err)
		return nil
	}

	var apps []AppConfig
	if err := json.Unmarshal(data, &apps); err != nil {
		Log("Failed to parse apps.json for profile %s: %v", profileID, err)
		return nil
	}

	s.appsMu.Lock()
	s.apps = apps
	s.appsProfile = profileID
	s.appsLoadTime = time.Now()
	s.appsMu.Unlock()

	Log("Loaded %d apps for profile %s", len(apps), profileID)
	return apps
}

func findAssetDirectory() string {
	home, _ := os.UserHomeDir()
	installed := filepath.Join(home, ".local", "share", "launchtube", "assets")
	if info, err := os.Stat(installed); err == nil && info.IsDir() {
		return installed
	}

	cwd, _ := os.Getwd()
	hotAssets := filepath.Join(cwd, "hot-assets")
	if info, err := os.Stat(hotAssets); err == nil && info.IsDir() {
		return hotAssets
	}

	// Check parent directory for dev
	hotAssets = filepath.Join(cwd, "..", "hot-assets")
	if info, err := os.Stat(hotAssets); err == nil && info.IsDir() {
		return hotAssets
	}

	return installed
}

func (s *Server) Start() error {
	ports := []int{8765, 8766, 8767, 8768, 8769}

	mux := http.NewServeMux()
	s.registerRoutes(mux)

	for _, port := range ports {
		addr := fmt.Sprintf("127.0.0.1:%d", port)
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			continue
		}
		s.port = port
		log.Printf("LaunchTube API server running on port %d", port)

		go http.Serve(ln, s.corsMiddleware(mux))
		return nil
	}
	return fmt.Errorf("failed to start server - all ports in use")
}

func (s *Server) GetPort() int {
	return s.port
}

func (s *Server) corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "*")
		w.Header().Set("Cache-Control", "no-cache, must-revalidate")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func (s *Server) registerRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/api/1/ping", s.handlePing)
	mux.HandleFunc("/api/1/version", s.handleVersion)
	mux.HandleFunc("/api/1/status", s.handleStatus)
	mux.HandleFunc("/api/1/match", s.handleMatch)
	mux.HandleFunc("/api/1/service/", s.handleService)
	mux.HandleFunc("/api/1/kv/", s.handleKV)
	mux.HandleFunc("/api/1/player/play", s.handlePlayerPlay)
	mux.HandleFunc("/api/1/player/playlist", s.handlePlayerPlaylist)
	mux.HandleFunc("/api/1/player/status", s.handlePlayerStatus)
	mux.HandleFunc("/api/1/player/stop", s.handlePlayerStop)
	mux.HandleFunc("/api/1/browser/close", s.handleBrowserClose)
	mux.HandleFunc("/api/1/browser/status", s.handleBrowserStatus)
	mux.HandleFunc("/api/1/browsers", s.handleBrowsersList)
	mux.HandleFunc("/api/1/detect-extensions", s.handleDetectExtensions)
	mux.HandleFunc("/api/1/userscript", s.handleUserscript)
	mux.HandleFunc("/api/1/log", s.handleLog)
	mux.HandleFunc("/api/1/profile", s.handleProfile)
	mux.HandleFunc("/launchtube-loader.user.js", s.handleUserscript)
	mux.HandleFunc("/setup", s.handleSetup)
	mux.HandleFunc("/install", s.handleInstall)
	mux.HandleFunc("/api/1/image", s.handleImage)
	mux.HandleFunc("/api/1/services", s.handleServiceLibrary)
	mux.HandleFunc("/api/1/shutdown", s.handleShutdown)
}

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","app":"launchtube"}`)
}

func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"app":     "launchtube",
		"version": version,
		"commit":  commit,
		"build":   buildDate,
	})
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "ok",
		"app":    "launchtube",
		"port":   s.port,
	})
}

func (s *Server) handleMatch(w http.ResponseWriter, r *http.Request) {
	pageURL := r.URL.Query().Get("url")
	if pageURL == "" {
		http.Error(w, "// Missing url parameter", http.StatusBadRequest)
		return
	}

	profileID := r.URL.Query().Get("profile")
	apps := s.GetAppsForProfile(profileID)

	normalizedPageURL := normalizeURL(pageURL)
	Log("Match request: pageUrl=%s profile=%s normalized=%s", pageURL, profileID, normalizedPageURL)

	var matchedServiceName string
	for _, app := range apps {
		urlsToCheck := []string{}
		if app.URL != "" {
			urlsToCheck = append(urlsToCheck, app.URL)
		}
		urlsToCheck = append(urlsToCheck, app.MatchURLs...)

		if len(urlsToCheck) == 0 {
			continue
		}

		for _, checkURL := range urlsToCheck {
			normalizedAppURL := normalizeURL(checkURL)
			if strings.HasPrefix(normalizedPageURL, normalizedAppURL) {
				matchedServiceName = app.Name
				break
			}
		}
		if matchedServiceName != "" {
			break
		}
	}

	if matchedServiceName == "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	serviceID := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(matchedServiceName, " ", "-"), "+", ""))
	serviceVersion := r.URL.Query().Get("version")
	s.serveServiceScript(w, serviceID, serviceVersion)
}

func normalizeURL(url string) string {
	normalized := strings.ToLower(url)
	normalized = strings.TrimPrefix(normalized, "https://")
	normalized = strings.TrimPrefix(normalized, "http://")
	normalized = strings.TrimPrefix(normalized, "www.")
	return normalized
}

// GetServiceScript returns the service script for a given URL, or empty string if none
func (s *Server) GetServiceScript(pageURL, profileID string) string {
	apps := s.GetAppsForProfile(profileID)
	normalizedPageURL := normalizeURL(pageURL)

	var matchedServiceName string
	for _, app := range apps {
		urlsToCheck := []string{}
		if app.URL != "" {
			urlsToCheck = append(urlsToCheck, app.URL)
		}
		urlsToCheck = append(urlsToCheck, app.MatchURLs...)

		if len(urlsToCheck) == 0 {
			continue
		}

		for _, checkURL := range urlsToCheck {
			normalizedAppURL := normalizeURL(checkURL)
			if strings.HasPrefix(normalizedPageURL, normalizedAppURL) {
				matchedServiceName = app.Name
				break
			}
		}
		if matchedServiceName != "" {
			break
		}
	}

	if matchedServiceName == "" {
		return ""
	}

	serviceID := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(matchedServiceName, " ", "-"), "+", ""))
	scriptPath := filepath.Join(s.assetDir, "services", serviceID+".js")

	content, _, err := s.fileCache.GetString(scriptPath)
	if err != nil {
		Log("GetServiceScript: Script not found for %s at %s", serviceID, scriptPath)
		return ""
	}

	return fmt.Sprintf("window.LAUNCH_TUBE_VERSION = \"%s\";\n%s", version, content)
}

func (s *Server) handleService(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(r.URL.Path, "/")
	if len(parts) < 5 {
		http.Error(w, "Invalid path", http.StatusBadRequest)
		return
	}
	serviceID := parts[4]
	s.serveServiceScript(w, serviceID, "")
}

func (s *Server) serveServiceScript(w http.ResponseWriter, serviceID, requestedVersion string) {
	scriptPath := filepath.Join(s.assetDir, "services", serviceID+".js")

	if requestedVersion != "" {
		versionedPath := s.findBestVersionedScript(serviceID, requestedVersion)
		if versionedPath != "" {
			scriptPath = versionedPath
		} else {
			w.WriteHeader(http.StatusNoContent)
			return
		}
	}

	content, mtime, err := s.fileCache.GetString(scriptPath)
	if err != nil {
		http.Error(w, fmt.Sprintf("// Script not found for service: %s", serviceID), http.StatusNotFound)
		return
	}

	versionedScript := fmt.Sprintf("window.LAUNCH_TUBE_VERSION = \"%s\";\n%s", version, content)

	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "max-age=31536000")
	w.Header().Set("ETag", fmt.Sprintf(`"%d"`, mtime.UnixMilli()))
	fmt.Fprint(w, versionedScript)
}

func (s *Server) findBestVersionedScript(serviceID, requestedVersion string) string {
	servicesDir := filepath.Join(s.assetDir, "services")
	entries, err := os.ReadDir(servicesDir)
	if err != nil {
		return ""
	}

	prefix := serviceID + "-"
	suffix := ".js"
	var bestMatch string
	var bestVersion []int
	var oldestMatch string
	var oldestVersion []int

	requestedParsed := parseVersion(requestedVersion)

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, suffix) {
			continue
		}

		versionStr := name[len(prefix) : len(name)-len(suffix)]
		v := parseVersion(versionStr)

		if oldestVersion == nil || compareVersions(v, oldestVersion) < 0 {
			oldestVersion = v
			oldestMatch = filepath.Join(servicesDir, name)
		}

		if compareVersions(v, requestedParsed) <= 0 {
			if bestVersion == nil || compareVersions(v, bestVersion) > 0 {
				bestVersion = v
				bestMatch = filepath.Join(servicesDir, name)
			}
		}
	}

	if bestMatch != "" {
		return bestMatch
	}
	return oldestMatch
}

func parseVersion(version string) []int {
	parts := strings.Split(version, ".")
	result := make([]int, len(parts))
	for i, p := range parts {
		fmt.Sscanf(p, "%d", &result[i])
	}
	return result
}

func compareVersions(a, b []int) int {
	maxLen := len(a)
	if len(b) > maxLen {
		maxLen = len(b)
	}
	for i := 0; i < maxLen; i++ {
		av, bv := 0, 0
		if i < len(a) {
			av = a[i]
		}
		if i < len(b) {
			bv = b[i]
		}
		if av != bv {
			return av - bv
		}
	}
	return 0
}

func (s *Server) handleKV(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 4 {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"Invalid path"}`, http.StatusBadRequest)
		return
	}

	serviceID := parts[3]
	var key string
	if len(parts) > 4 {
		key = parts[4]
	}

	w.Header().Set("Content-Type", "application/json")

	switch r.Method {
	case "GET":
		if key != "" {
			value, ok := s.kvStore.Get(serviceID, key)
			if !ok {
				http.Error(w, `{"error":"Key not found"}`, http.StatusNotFound)
				return
			}
			json.NewEncoder(w).Encode(value)
		} else {
			data := s.kvStore.GetAll(serviceID)
			json.NewEncoder(w).Encode(data)
		}

	case "PUT":
		if key == "" {
			http.Error(w, `{"error":"Key required for PUT"}`, http.StatusBadRequest)
			return
		}
		var value interface{}
		if err := json.NewDecoder(r.Body).Decode(&value); err != nil {
			http.Error(w, `{"error":"Invalid JSON body"}`, http.StatusBadRequest)
			return
		}
		s.kvStore.Set(serviceID, key, value)
		fmt.Fprintf(w, `{"status":"ok"}`)

	case "DELETE":
		if key != "" {
			s.kvStore.Delete(serviceID, key)
		} else {
			s.kvStore.DeleteAll(serviceID)
		}
		fmt.Fprintf(w, `{"status":"ok"}`)

	default:
		http.Error(w, `{"error":"Method not allowed"}`, http.StatusMethodNotAllowed)
	}
}

func (s *Server) handlePlayerPlay(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, `{"error":"Method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		URL           string                 `json:"url"`
		Title         string                 `json:"title"`
		StartPosition float64                `json:"startPosition"`
		OnComplete    map[string]interface{} `json:"onComplete"`
		OnProgress    map[string]interface{} `json:"onProgress"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"Invalid request"}`, http.StatusBadRequest)
		return
	}

	if req.URL == "" {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"url is required"}`, http.StatusBadRequest)
		return
	}

	err := s.player.Play(req.URL, req.Title, req.StartPosition, req.OnComplete, req.OnProgress)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err.Error()), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"playing","position":%.1f}`, req.StartPosition)
}

func (s *Server) handlePlayerPlaylist(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, `{"error":"Method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Items []struct {
			URL        string                 `json:"url"`
			ItemID     string                 `json:"itemId"`
			OnComplete map[string]interface{} `json:"onComplete"`
		} `json:"items"`
		StartPosition float64 `json:"startPosition"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"Invalid request"}`, http.StatusBadRequest)
		return
	}

	if len(req.Items) == 0 {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"items array is required"}`, http.StatusBadRequest)
		return
	}

	items := make([]PlaylistItem, len(req.Items))
	for i, item := range req.Items {
		items[i] = PlaylistItem{
			URL:        item.URL,
			ItemID:     item.ItemID,
			OnComplete: item.OnComplete,
		}
	}

	err := s.player.PlayPlaylist(items, req.StartPosition)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err.Error()), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"playing","count":%d}`, len(items))
}

func (s *Server) handlePlayerStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(s.player.GetStatus())
}

func (s *Server) handlePlayerStop(w http.ResponseWriter, r *http.Request) {
	s.player.Stop()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok"}`)
}

func (s *Server) handleBrowserClose(w http.ResponseWriter, r *http.Request) {
	Log("API: /api/1/browser/close called")
	s.CloseBrowser()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok"}`)
}

func (s *Server) handleShutdown(w http.ResponseWriter, r *http.Request) {
	Log("API: /api/1/shutdown called")
	// Stop player and close browser
	s.player.Stop()
	s.CloseBrowser()
	// Respond before triggering shutdown
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","message":"shutting down"}`)
	// Trigger application shutdown via callback
	if s.onShutdown != nil {
		go func() {
			time.Sleep(100 * time.Millisecond)
			s.onShutdown()
		}()
	}
}

func (s *Server) handleBrowserStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"running": s.browserMgr.IsRunning(),
		"pid":     s.browserMgr.GetPID(),
	})
}

func (s *Server) handleBrowsersList(w http.ResponseWriter, r *http.Request) {
	browsers := s.browserMgr.DetectBrowsers()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(browsers)
}

func (s *Server) handleDetectExtensions(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"detected":             []string{},
		"hasUserscriptManager": false,
	})
}

func (s *Server) handleUserscript(w http.ResponseWriter, r *http.Request) {
	scriptPath := filepath.Join(s.assetDir, "launchtube-loader.user.js")
	content, mtime, err := s.fileCache.GetString(scriptPath)
	if err != nil {
		http.Error(w, "// Userscript not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "max-age=31536000")
	w.Header().Set("ETag", fmt.Sprintf(`"%d"`, mtime.UnixMilli()))
	fmt.Fprint(w, content)
}

func (s *Server) handleSetup(w http.ResponseWriter, r *http.Request) {
	htmlPath := filepath.Join(s.assetDir, "setup.html")
	content, _, err := s.fileCache.GetString(htmlPath)
	if err != nil {
		http.Error(w, "Setup page not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "text/html")
	fmt.Fprint(w, content)
}

func (s *Server) handleInstall(w http.ResponseWriter, r *http.Request) {
	html := `<!DOCTYPE html>
<html>
<head>
  <title>Launch Tube - Install Userscript</title>
  <style>
    body {
      background: #1A1A2E;
      color: white;
      font-family: system-ui, sans-serif;
      display: flex;
      justify-content: center;
      align-items: center;
      height: 100vh;
      margin: 0;
    }
    .container { text-align: center; }
    a { color: #4FC3F7; font-size: 1.2em; }
  </style>
</head>
<body>
  <div class="container">
    <h2>Installing Launch Tube Userscript...</h2>
    <p>If the install dialog doesn't appear, <a href="/launchtube-loader.user.js">click here</a>.</p>
    <p id="status">This window will close automatically.</p>
  </div>
  <script>
    location.href = '/launchtube-loader.user.js';
    setTimeout(function() { window.close(); }, 2000);
  </script>
</body>
</html>`

	w.Header().Set("Content-Type", "text/html")
	fmt.Fprint(w, html)
}

func (s *Server) handleLog(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Message string `json:"message"`
		Level   string `json:"level"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"Invalid request"}`, http.StatusBadRequest)
		return
	}

	if req.Level == "" {
		req.Level = "info"
	}

	Log("[JS:%s] %s", req.Level, req.Message)

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok"}`)
}

func (s *Server) handleProfile(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"profileId": s.activeProfile,
	})
}

// LaunchBrowser launches a browser with the given URL
func (s *Server) LaunchBrowser(browserName, url, profileID string) error {
	Log("Launching browser: %s url=%s profile=%s useCDP=%v", browserName, url, profileID, s.useCDP)
	s.activeProfile = profileID

	if s.useCDP {
		// Initialize CDP browser if needed
		if s.cdpBrowser == nil {
			s.cdpBrowser = NewCDPBrowser(s.assetDir, s.dataDir, s.port)
			if s.onBrowserExit != nil {
				s.cdpBrowser.SetOnExit(s.onBrowserExit)
			}
			// Wire up script injection
			s.cdpBrowser.SetGetScript(s.GetServiceScript)
		}
		return s.cdpBrowser.Launch(url, profileID)
	}

	return s.browserMgr.Launch(browserName, url, profileID, s.port)
}

// LaunchApp launches a native application
func (s *Server) LaunchApp(commandLine, profileID string) error {
	Log("Launching app: %s profile=%s", commandLine, profileID)
	s.activeProfile = profileID

	parts := strings.Fields(commandLine)
	if len(parts) == 0 {
		return fmt.Errorf("empty command")
	}

	cmd := exec.Command(parts[0], parts[1:]...)
	if err := cmd.Start(); err != nil {
		return err
	}

	Log("Native app started with PID: %d", cmd.Process.Pid)
	return nil
}

// CloseBrowser closes the running browser
func (s *Server) CloseBrowser() {
	if s.useCDP && s.cdpBrowser != nil {
		s.cdpBrowser.Close()
	} else {
		s.browserMgr.Close()
	}
}

// StopPlayer stops the media player
func (s *Server) StopPlayer() {
	s.player.Stop()
}

// DetectBrowsers returns available browsers
func (s *Server) DetectBrowsers() []BrowserInfo {
	return s.browserMgr.DetectBrowsers()
}

// handleImage serves images from local filesystem
func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Query().Get("path")
	if path == "" {
		http.Error(w, "Missing path", http.StatusBadRequest)
		return
	}

	// Security: only allow paths under assetDir or dataDir
	absPath, err := filepath.Abs(path)
	if err != nil {
		http.Error(w, "Invalid path", http.StatusBadRequest)
		return
	}

	absAssetDir, _ := filepath.Abs(s.assetDir)
	absDataDir, _ := filepath.Abs(s.dataDir)

	if !strings.HasPrefix(absPath, absAssetDir) && !strings.HasPrefix(absPath, absDataDir) {
		// Also allow hot-assets in parent directory for dev
		cwd, _ := os.Getwd()
		absHotAssets, _ := filepath.Abs(filepath.Join(cwd, "..", "hot-assets"))
		if !strings.HasPrefix(absPath, absHotAssets) {
			http.Error(w, "Access denied", http.StatusForbidden)
			return
		}
	}

	data, err := os.ReadFile(absPath)
	if err != nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}

	// Detect content type
	ext := strings.ToLower(filepath.Ext(absPath))
	contentType := "application/octet-stream"
	switch ext {
	case ".png":
		contentType = "image/png"
	case ".jpg", ".jpeg":
		contentType = "image/jpeg"
	case ".gif":
		contentType = "image/gif"
	case ".svg":
		contentType = "image/svg+xml"
	case ".webp":
		contentType = "image/webp"
	}

	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "max-age=3600")
	w.Write(data)
}

// ServiceLibraryItem represents a streaming service template
type ServiceLibraryItem struct {
	Name       string   `json:"name"`
	URL        string   `json:"url"`
	MatchURLs  []string `json:"matchUrls,omitempty"`
	Color      string   `json:"color"`
	ColorValue int      `json:"colorValue"`
	LogoPath   string   `json:"logoPath,omitempty"`
}

// handleServiceLibrary returns available streaming services
func (s *Server) handleServiceLibrary(w http.ResponseWriter, r *http.Request) {
	servicesDir := filepath.Join(s.assetDir, "services")
	entries, err := os.ReadDir(servicesDir)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode([]ServiceLibraryItem{})
		return
	}

	var services []ServiceLibraryItem
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		name := entry.Name()
		if filepath.Ext(name) != ".json" {
			continue
		}

		jsonPath := filepath.Join(servicesDir, name)
		data, err := os.ReadFile(jsonPath)
		if err != nil {
			continue
		}

		var raw struct {
			Name      string   `json:"name"`
			URL       string   `json:"url"`
			MatchURLs []string `json:"matchUrls,omitempty"`
			Color     string   `json:"color"`
		}
		if err := json.Unmarshal(data, &raw); err != nil {
			continue
		}

		service := ServiceLibraryItem{
			Name:      raw.Name,
			URL:       raw.URL,
			MatchURLs: raw.MatchURLs,
			Color:     raw.Color,
		}

		// Parse color
		if raw.Color != "" {
			hexColor := strings.TrimPrefix(raw.Color, "#")
			if colorVal, err := strconv.ParseInt("FF"+hexColor, 16, 64); err == nil {
				service.ColorValue = int(colorVal)
			}
		}

		// Find logo
		baseName := name[:len(name)-5]
		for _, ext := range []string{".png", ".jpg", ".svg", ".webp"} {
			logoPath := filepath.Join(servicesDir, baseName+ext)
			if _, err := os.Stat(logoPath); err == nil {
				service.LogoPath = logoPath
				break
			}
		}

		services = append(services, service)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(services)
}

// GetAssetDir returns the asset directory path
func (s *Server) GetAssetDir() string {
	return s.assetDir
}

// GetDataDir returns the data directory path
func (s *Server) GetDataDir() string {
	return s.dataDir
}
