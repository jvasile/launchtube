package main

import (
	"encoding/json"
	"fmt"
	"io"
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
	port                  int
	assetDir              string
	dataDir               string
	kvStore               *KVStore
	player                *Player
	fileCache             *FileCache
	apps                  []AppConfig
	appsMu                sync.RWMutex
	appsProfile           string
	appsLoadTime          time.Time
	browserMgr            *BrowserManager
	cdpBrowser            *CDPBrowser
	useCDP                bool // Use CDP-based browser instead of extension-based
	activeProfile         string
	onBrowserExit         func()
	onShutdown            func()
	screensaverInhibitor  *ScreensaverInhibitor
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
	FocusAlert  bool     `json:"focusAlert,omitempty"`
	ServiceID   string   `json:"serviceId,omitempty"`
}

func NewServer() *Server {
	home, _ := os.UserHomeDir()
	dataDir := filepath.Join(home, ".local", "share", "launchtube")
	assetDir := findAssetDirectory()

	// Extension mode is default (CDP triggers bot detection on YouTube etc)
	useCDP := os.Getenv("LAUNCHTUBE_USE_CDP") == "1"

	player := NewPlayer(dataDir)
	browserMgr := NewBrowserManager(assetDir, dataDir)

	s := &Server{
		assetDir:   assetDir,
		dataDir:    dataDir,
		kvStore:    NewKVStore(),
		player:     player,
		fileCache:  NewFileCache(),
		browserMgr: browserMgr, // Kept as fallback
		useCDP:     useCDP,
		screensaverInhibitor: NewScreensaverInhibitor(player, browserMgr),
	}

	if useCDP {
		Log("Using CDP-based browser (set LAUNCHTUBE_USE_CDP=1)")
	} else {
		Log("Using extension-based browser")
	}

	// Start screensaver inhibitor
	s.screensaverInhibitor.Start()

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
		// Use active profile if no profile specified
		if s.activeProfile != "" {
			profileID = s.activeProfile
		} else {
			s.appsMu.RLock()
			apps := s.apps
			s.appsMu.RUnlock()
			return apps
		}
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
	mux.HandleFunc("/api/1/focus-alert", s.handleFocusAlert)
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
	mux.HandleFunc("/api/1/cookies", s.handleCookies)
	mux.HandleFunc("/api/1/youtube/fullscreen", s.handleYouTubeFullscreen)
	mux.HandleFunc("/api/1/profile", s.handleProfile)
	mux.HandleFunc("/launchtube-loader.user.js", s.handleUserscript)
	mux.HandleFunc("/setup", s.handleSetup)
	mux.HandleFunc("/install", s.handleInstall)
	mux.HandleFunc("/api/1/image", s.handleImage)
	mux.HandleFunc("/api/1/services", s.handleServiceLibrary)
	mux.HandleFunc("/api/1/shutdown", s.handleShutdown)
	mux.HandleFunc("/youtube-loader", s.handleYouTubeLoader)
}

func (s *Server) handleYouTubeLoader(w http.ResponseWriter, r *http.Request) {
	htmlPath := filepath.Join(s.assetDir, "youtube-loader.html")
	http.ServeFile(w, r, htmlPath)
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

func (s *Server) handleFocusAlert(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	pageURL := r.URL.Query().Get("url")
	if pageURL == "" {
		json.NewEncoder(w).Encode(map[string]bool{"focusAlert": false})
		return
	}

	profileID := r.URL.Query().Get("profile")
	apps := s.GetAppsForProfile(profileID)
	normalizedPageURL := normalizeURL(pageURL)

	for _, app := range apps {
		urlsToCheck := []string{}
		if app.URL != "" {
			urlsToCheck = append(urlsToCheck, app.URL)
		}
		urlsToCheck = append(urlsToCheck, app.MatchURLs...)

		for _, checkURL := range urlsToCheck {
			normalizedAppURL := normalizeURL(checkURL)
			if strings.HasPrefix(normalizedPageURL, normalizedAppURL) {
				w.Header().Set("Content-Type", "application/json")
				json.NewEncoder(w).Encode(map[string]bool{"focusAlert": app.FocusAlert})
				return
			}
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]bool{"focusAlert": false})
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

	data, err := s.readServiceFile(serviceID + ".js")
	if err != nil {
		Log("GetServiceScript: Script not found for %s", serviceID)
		return ""
	}

	return fmt.Sprintf("window.LAUNCH_TUBE_VERSION = \"%s\";\n%s", version, string(data))
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
	var content []byte
	var err error
	var mtime time.Time

	if requestedVersion != "" {
		// Versioned scripts are filesystem-only
		versionedPath := s.findBestVersionedScript(serviceID, requestedVersion)
		if versionedPath == "" {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		var contentStr string
		contentStr, mtime, err = s.fileCache.GetString(versionedPath)
		content = []byte(contentStr)
	} else {
		// Regular scripts use assetDir->embedded fallback
		content, err = s.readServiceFile(serviceID + ".js")
		// Check if from filesystem for mtime
		fsPath := filepath.Join(s.assetDir, "services", serviceID+".js")
		if info, statErr := os.Stat(fsPath); statErr == nil {
			mtime = info.ModTime()
		}
	}

	if err != nil {
		http.Error(w, fmt.Sprintf("// Script not found for service: %s", serviceID), http.StatusNotFound)
		return
	}

	versionedScript := fmt.Sprintf("window.LAUNCH_TUBE_VERSION = \"%s\";\n%s", version, string(content))

	w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	if !mtime.IsZero() {
		w.Header().Set("ETag", fmt.Sprintf(`"%d"`, mtime.UnixMilli()))
	}
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
	Log("handlePlayerPlay: received request method=%s", r.Method)
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
		Log("handlePlayerPlay: decode error: %v", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"Invalid request"}`, http.StatusBadRequest)
		return
	}

	Log("handlePlayerPlay: url=%s title=%s start=%.1f", req.URL, req.Title, req.StartPosition)

	if req.URL == "" {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"url is required"}`, http.StatusBadRequest)
		return
	}

	Log("handlePlayerPlay: calling player.Play()")
	err := s.player.Play(req.URL, req.Title, req.StartPosition, req.OnComplete, req.OnProgress)
	if err != nil {
		Log("handlePlayerPlay: player.Play() returned error: %v", err)
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err.Error()), http.StatusInternalServerError)
		return
	}

	Log("handlePlayerPlay: success, sending response")
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
	w.Header().Set("Cache-Control", "no-cache")
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

func (s *Server) handleCookies(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read body", http.StatusBadRequest)
		return
	}

	cookiesPath := filepath.Join(s.dataDir, "cookies.txt")
	if err := os.WriteFile(cookiesPath, body, 0600); err != nil {
		Log("Failed to write cookies: %v", err)
		http.Error(w, "Failed to write cookies", http.StatusInternalServerError)
		return
	}

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
func (s *Server) LaunchBrowser(browserName, url, profileID string, focusAlert bool) error {
	Log("Launching browser: %s url=%s profile=%s useCDP=%v focusAlert=%v", browserName, url, profileID, s.useCDP, focusAlert)
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

	err := s.browserMgr.Launch(browserName, url, profileID, s.port)
	if err != nil {
		return err
	}

	// If focusAlert is enabled, use CDP to focus the page content
	if focusAlert {
		go s.browserMgr.SendFocusToPage()
	}

	return nil
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

// nameToServiceID converts a service name to a filesystem-safe ID
func nameToServiceID(name string) string {
	id := strings.ToLower(name)
	id = strings.ReplaceAll(id, " ", "-")
	id = strings.ReplaceAll(id, "+", "")
	return id
}

// readServiceFile reads a service file, checking assetDir first then embedded
func (s *Server) readServiceFile(filename string) ([]byte, error) {
	// Try filesystem first (hot-assets override)
	path := filepath.Join(s.assetDir, "services", filename)
	if data, err := os.ReadFile(path); err == nil {
		return data, nil
	}

	// Fall back to embedded
	return serviceAssets.ReadFile("services/" + filename)
}

// listServiceFiles returns all service files with given extension, merging filesystem and embedded
func (s *Server) listServiceFiles(ext string) []string {
	seen := make(map[string]bool)
	var files []string

	// Check filesystem first
	servicesDir := filepath.Join(s.assetDir, "services")
	if entries, err := os.ReadDir(servicesDir); err == nil {
		for _, entry := range entries {
			if !entry.IsDir() && strings.HasSuffix(entry.Name(), ext) {
				files = append(files, entry.Name())
				seen[entry.Name()] = true
			}
		}
	}

	// Add embedded files not already seen
	if entries, err := serviceAssets.ReadDir("services"); err == nil {
		for _, entry := range entries {
			if !entry.IsDir() && strings.HasSuffix(entry.Name(), ext) && !seen[entry.Name()] {
				files = append(files, entry.Name())
			}
		}
	}

	return files
}

// handleImage serves images from embedded assets or local filesystem
func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	// Check for service param (embedded image lookup by name)
	if service := r.URL.Query().Get("service"); service != "" {
		s.serveServiceImage(w, r, service)
		return
	}

	// Fall back to path param (filesystem lookup)
	path := r.URL.Query().Get("path")
	if path == "" {
		http.Error(w, "Missing path or service parameter", http.StatusBadRequest)
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

	info, err := os.Stat(absPath)
	if err != nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}

	// Check If-Modified-Since for cache validation
	modTime := info.ModTime()
	if ims := r.Header.Get("If-Modified-Since"); ims != "" {
		if t, err := http.ParseTime(ims); err == nil {
			if modTime.Truncate(time.Second).Compare(t.Truncate(time.Second)) <= 0 {
				w.WriteHeader(http.StatusNotModified)
				return
			}
		}
	}

	data, err := os.ReadFile(absPath)
	if err != nil {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}

	s.writeImageResponse(w, filepath.Ext(absPath), data, modTime)
}

// serveServiceImage serves an image for a service by name
func (s *Server) serveServiceImage(w http.ResponseWriter, r *http.Request, serviceName string) {
	serviceID := nameToServiceID(serviceName)
	extensions := []string{".webp", ".png", ".jpg", ".svg"}

	// Try filesystem in assetDir/services/ first (hot-assets override)
	for _, ext := range extensions {
		path := filepath.Join(s.assetDir, "services", serviceID+ext)
		if info, err := os.Stat(path); err == nil {
			// Check If-Modified-Since for filesystem files
			modTime := info.ModTime()
			if ims := r.Header.Get("If-Modified-Since"); ims != "" {
				if t, err := http.ParseTime(ims); err == nil {
					if modTime.Truncate(time.Second).Compare(t.Truncate(time.Second)) <= 0 {
						w.WriteHeader(http.StatusNotModified)
						return
					}
				}
			}
			if data, err := os.ReadFile(path); err == nil {
				w.Header().Set("Cache-Control", "no-cache")
				s.writeImageResponse(w, ext, data, modTime)
				return
			}
		}
	}

	// Fall back to embedded assets
	for _, ext := range extensions {
		filename := "services/" + serviceID + ext
		if data, err := serviceAssets.ReadFile(filename); err == nil {
			// Embedded assets don't change, use long cache
			w.Header().Set("Cache-Control", "max-age=86400")
			s.writeImageResponse(w, ext, data, time.Time{})
			return
		}
	}

	http.Error(w, "Service image not found", http.StatusNotFound)
}

// writeImageResponse writes image data with appropriate headers
func (s *Server) writeImageResponse(w http.ResponseWriter, ext string, data []byte, modTime time.Time) {
	contentType := "application/octet-stream"
	switch strings.ToLower(ext) {
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
	if !modTime.IsZero() {
		w.Header().Set("Last-Modified", modTime.UTC().Format(http.TimeFormat))
	}
	w.Write(data)
}

// ServiceLibraryItem represents a streaming service template
type ServiceLibraryItem struct {
	Name       string   `json:"name"`
	URL        string   `json:"url"`
	MatchURLs  []string `json:"matchUrls,omitempty"`
	Color      string   `json:"color"`
	ColorValue int      `json:"colorValue"`
	HasLogo    bool     `json:"hasLogo"`
	FocusAlert bool     `json:"focusAlert,omitempty"`
}

// handleServiceLibrary returns available streaming services
func (s *Server) handleServiceLibrary(w http.ResponseWriter, r *http.Request) {
	jsonFiles := s.listServiceFiles(".json")

	var services []ServiceLibraryItem
	for _, name := range jsonFiles {
		data, err := s.readServiceFile(name)
		if err != nil {
			continue
		}

		var raw struct {
			Name       string   `json:"name"`
			URL        string   `json:"url"`
			MatchURLs  []string `json:"matchUrls,omitempty"`
			Color      string   `json:"color"`
			FocusAlert bool     `json:"focusAlert,omitempty"`
		}
		if err := json.Unmarshal(data, &raw); err != nil {
			continue
		}

		service := ServiceLibraryItem{
			Name:       raw.Name,
			URL:        raw.URL,
			MatchURLs:  raw.MatchURLs,
			Color:      raw.Color,
			FocusAlert: raw.FocusAlert,
		}

		// Parse color
		if raw.Color != "" {
			hexColor := strings.TrimPrefix(raw.Color, "#")
			if colorVal, err := strconv.ParseInt("FF"+hexColor, 16, 64); err == nil {
				service.ColorValue = int(colorVal)
			}
		}

		// Check if logo exists (filesystem or embedded)
		baseName := name[:len(name)-5]
		for _, ext := range []string{".png", ".jpg", ".svg", ".webp"} {
			if _, err := s.readServiceFile(baseName + ext); err == nil {
				service.HasLogo = true
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
