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
	"runtime"
	"strings"
	"sync"
	"time"
)

var (
	version   = "dev"
	commit    = "unknown"
	buildDate = "unknown"

	// On Windows, don't kill/respawn Flutter - no freeze bug there
	manageFlutterLifecycle = runtime.GOOS != "windows"
)

type Server struct {
	port              int
	assetDir          string
	dataDir           string
	kvStore           *KVStore
	player            *Player
	fileCache         *FileCache
	apps              []AppConfig
	appsMu            sync.RWMutex
	appsProfile       string
	appsLoadTime      time.Time
	browserMgr        *BrowserManager
	flutterMgr        *FlutterManager
	activeProfile     string
}

type AppConfig struct {
	Name      string   `json:"name"`
	URL       string   `json:"url,omitempty"`
	MatchURLs []string `json:"matchUrls,omitempty"`
	ImagePath string   `json:"imagePath,omitempty"`
	ServiceID string   `json:"serviceId,omitempty"`
}

func NewServer() *Server {
	home, _ := os.UserHomeDir()
	dataDir := filepath.Join(home, ".local", "share", "launchtube")
	assetDir := findAssetDirectory()

	s := &Server{
		assetDir:   assetDir,
		dataDir:    dataDir,
		kvStore:    NewKVStore(),
		player:     NewPlayer(),
		fileCache:  NewFileCache(),
		browserMgr: NewBrowserManager(assetDir, dataDir),
		flutterMgr: NewFlutterManager(),
	}

	// Set up lifecycle callbacks (Linux only - respawn Flutter after app exits)
	if manageFlutterLifecycle {
		s.browserMgr.SetOnExit(func() {
			Log("Browser exited, respawning Flutter UI (profile=%s)", s.activeProfile)
			s.flutterMgr.LaunchWithPortAndProfile(s.port, s.activeProfile)
		})

		s.player.SetOnExit(func() {
			Log("Player exited, respawning Flutter UI (profile=%s)", s.activeProfile)
			s.flutterMgr.LaunchWithPortAndProfile(s.port, s.activeProfile)
		})
	}

	return s
}

func (s *Server) getAppsForProfile(profileID string) []AppConfig {
	if profileID == "" {
		// No profile specified, return empty or cached apps
		s.appsMu.RLock()
		apps := s.apps
		s.appsMu.RUnlock()
		return apps
	}

	// Check if we have cached apps for this profile
	s.appsMu.RLock()
	if s.appsProfile == profileID && time.Since(s.appsLoadTime) < 5*time.Second {
		apps := s.apps
		s.appsMu.RUnlock()
		return apps
	}
	s.appsMu.RUnlock()

	// Load apps from profile's apps.json
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

	// Cache the loaded apps
	s.appsMu.Lock()
	s.apps = apps
	s.appsProfile = profileID
	s.appsLoadTime = time.Now()
	s.appsMu.Unlock()

	Log("Loaded %d apps for profile %s", len(apps), profileID)
	return apps
}

func findAssetDirectory() string {
	// Priority: installed location, then dev location
	home, _ := os.UserHomeDir()
	installed := filepath.Join(home, ".local", "share", "launchtube", "assets")
	if info, err := os.Stat(installed); err == nil && info.IsDir() {
		return installed
	}

	// Development location - check relative to executable or cwd
	cwd, _ := os.Getwd()
	hotAssets := filepath.Join(cwd, "hot-assets")
	if info, err := os.Stat(hotAssets); err == nil && info.IsDir() {
		return hotAssets
	}

	// Fallback to installed location even if not exists
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
			// Port in use, try next
			continue
		}
		s.port = port
		log.Printf("LaunchTube server running on port %d", port)

		// Start wake detector (Linux only)
		s.startWakeDetector()

		// Launch Flutter UI now that we know the port
		if err := s.flutterMgr.LaunchWithPort(s.port); err != nil {
			Log("Warning: Failed to launch Flutter UI: %v", err)
		}

		return http.Serve(ln, s.corsMiddleware(mux))
	}
	return fmt.Errorf("failed to start server - all ports in use")
}

func (s *Server) startWakeDetector() {
	if !manageFlutterLifecycle {
		return
	}

	Log("Starting wake detector (poll every 5s, threshold 7s)")
	ticker := time.NewTicker(5 * time.Second)
	lastCheck := time.Now()

	go func() {
		for range ticker.C {
			now := time.Now()
			elapsed := now.Sub(lastCheck)

			// If more than 7 seconds passed but ticker is 5s, system likely woke from sleep
			if elapsed > 7*time.Second && s.flutterMgr.IsRunning() {
				Log("Wake detected (gap: %v), respawning Flutter UI", elapsed)
				s.flutterMgr.Kill()
				time.Sleep(500 * time.Millisecond)
				s.flutterMgr.LaunchWithPortAndProfile(s.port, s.activeProfile)
			}

			lastCheck = now
		}
	}()
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
	mux.HandleFunc("/api/1/shutdown", s.handleShutdown)
	mux.HandleFunc("/api/1/restart", s.handleRestart)
	mux.HandleFunc("/api/1/match", s.handleMatch)
	mux.HandleFunc("/api/1/service/", s.handleService)
	mux.HandleFunc("/api/1/kv/", s.handleKV)
	mux.HandleFunc("/api/1/player/play", s.handlePlayerPlay)
	mux.HandleFunc("/api/1/player/playlist", s.handlePlayerPlaylist)
	mux.HandleFunc("/api/1/player/status", s.handlePlayerStatus)
	mux.HandleFunc("/api/1/player/stop", s.handlePlayerStop)
	mux.HandleFunc("/api/1/browser/launch", s.handleBrowserLaunch)
	mux.HandleFunc("/api/1/browser/close", s.handleBrowserClose)
	mux.HandleFunc("/api/1/browser/status", s.handleBrowserStatus)
	mux.HandleFunc("/api/1/browsers", s.handleBrowsersList)
	mux.HandleFunc("/api/1/app/launch", s.handleAppLaunch)
	mux.HandleFunc("/api/1/flutter/kill", s.handleFlutterKill)
	mux.HandleFunc("/api/1/flutter/launch", s.handleFlutterLaunch)
	mux.HandleFunc("/api/1/flutter/status", s.handleFlutterStatus)
	mux.HandleFunc("/api/1/detect-extensions", s.handleDetectExtensions)
	mux.HandleFunc("/api/1/userscript", s.handleUserscript)
	mux.HandleFunc("/api/1/log", s.handleLog)
	mux.HandleFunc("/api/1/profile", s.handleProfile)
	mux.HandleFunc("/launchtube-loader.user.js", s.handleUserscript)
	mux.HandleFunc("/setup", s.handleSetup)
	mux.HandleFunc("/install", s.handleInstall)
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
		"endpoints": []string{
			"/api/1/ping",
			"/api/1/version",
			"/api/1/status",
			"/api/1/shutdown",
			"/api/1/restart",
			"/api/1/match?url={pageUrl}&version={serviceVersion}",
			"/api/1/service/{serviceId}",
			"/api/1/kv/{serviceId}",
			"/api/1/kv/{serviceId}/{key}",
			"/api/1/player/play",
			"/api/1/player/playlist",
			"/api/1/player/status",
			"/api/1/player/stop",
			"/api/1/browser/close",
			"/api/1/detect-extensions",
			"/api/1/userscript",
			"/setup",
			"/install",
			"/launchtube-loader.user.js",
		},
	})
}

func (s *Server) handleShutdown(w http.ResponseWriter, r *http.Request) {
	s.player.Stop()
	s.browserMgr.Close()
	s.flutterMgr.Kill()

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","message":"shutting down"}`)

	go func() {
		time.Sleep(100 * time.Millisecond)
		os.Exit(0)
	}()
}

func (s *Server) handleRestart(w http.ResponseWriter, r *http.Request) {
	s.player.Stop()
	s.browserMgr.Close()
	s.flutterMgr.Kill()

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","message":"restarting"}`)

	go func() {
		time.Sleep(100 * time.Millisecond)
		exe, _ := os.Executable()
		cmd := exec.Command(exe)
		cmd.Start()
		os.Exit(0)
	}()
}

func (s *Server) handleMatch(w http.ResponseWriter, r *http.Request) {
	pageURL := r.URL.Query().Get("url")
	if pageURL == "" {
		http.Error(w, "// Missing url parameter", http.StatusBadRequest)
		return
	}

	profileID := r.URL.Query().Get("profile")

	// Load apps for this profile (or use cached if same profile)
	apps := s.getAppsForProfile(profileID)

	normalizedPageURL := normalizeURL(pageURL)
	Log("Match request: pageUrl=%s profile=%s normalized=%s", pageURL, profileID, normalizedPageURL)
	Log("Apps count: %d", len(apps))

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

		Log("  Checking %s: urls=%s", app.Name, strings.Join(urlsToCheck, ", "))

		for _, checkURL := range urlsToCheck {
			normalizedAppURL := normalizeURL(checkURL)
			if strings.HasPrefix(normalizedPageURL, normalizedAppURL) {
				matchedServiceName = app.Name
				Log("  -> MATCHED on %s", checkURL)
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

func (s *Server) handleService(w http.ResponseWriter, r *http.Request) {
	// Extract serviceId from path: /api/1/service/{serviceId}
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
			// Version requested but no versioned script available
			w.WriteHeader(http.StatusNoContent)
			return
		}
	}

	content, mtime, err := s.fileCache.GetString(scriptPath)
	if err != nil {
		http.Error(w, fmt.Sprintf("// Script not found for service: %s", serviceID), http.StatusNotFound)
		return
	}

	// Prepend version
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

		// Track oldest
		if oldestVersion == nil || compareVersions(v, oldestVersion) < 0 {
			oldestVersion = v
			oldestMatch = filepath.Join(servicesDir, name)
		}

		// Find highest <= requested
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
	// Parse: /api/1/kv/{serviceId} or /api/1/kv/{serviceId}/{key}
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
	if r.Method != "POST" {
		http.Error(w, `{"error":"Method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	s.player.Stop()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok"}`)
}

func (s *Server) handleBrowserLaunch(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, `{"error":"Method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Browser   string `json:"browser"`
		URL       string `json:"url"`
		ProfileID string `json:"profileId"`
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

	Log("API: /api/1/browser/launch called - browser=%s url=%s profile=%s", req.Browser, req.URL, req.ProfileID)

	// Store active profile
	s.activeProfile = req.ProfileID

	// Kill Flutter UI before launching browser (Linux only)
	if manageFlutterLifecycle {
		s.flutterMgr.Kill()
	}

	// Launch browser
	if err := s.browserMgr.Launch(req.Browser, req.URL, req.ProfileID, s.port); err != nil {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err.Error()), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","pid":%d}`, s.browserMgr.GetPID())
}

func (s *Server) handleBrowserClose(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, `{"error":"Method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	Log("API: /api/1/browser/close called")
	s.browserMgr.Close()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok"}`)
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

func (s *Server) handleAppLaunch(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, `{"error":"Method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		CommandLine string `json:"commandLine"`
		ProfileID   string `json:"profileId"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"Invalid request"}`, http.StatusBadRequest)
		return
	}

	if req.CommandLine == "" {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"commandLine is required"}`, http.StatusBadRequest)
		return
	}

	Log("API: /api/1/app/launch called - command=%s profile=%s", req.CommandLine, req.ProfileID)

	// Store active profile
	s.activeProfile = req.ProfileID

	// Kill Flutter UI before launching app (Linux only)
	if manageFlutterLifecycle {
		s.flutterMgr.Kill()
	}

	// Parse command line
	parts := strings.Fields(req.CommandLine)
	if len(parts) == 0 {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, `{"error":"empty command"}`, http.StatusBadRequest)
		return
	}

	cmd := exec.Command(parts[0], parts[1:]...)
	if err := cmd.Start(); err != nil {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err.Error()), http.StatusInternalServerError)
		// Respawn Flutter on error (Linux only)
		if manageFlutterLifecycle {
			s.flutterMgr.LaunchWithPortAndProfile(s.port, s.activeProfile)
		}
		return
	}

	Log("Native app started with PID: %d", cmd.Process.Pid)

	// Wait for app to exit and respawn Flutter (Linux only)
	if manageFlutterLifecycle {
		go func() {
			cmd.Wait()
			Log("Native app exited, respawning Flutter UI (profile=%s)", s.activeProfile)
			s.flutterMgr.LaunchWithPortAndProfile(s.port, s.activeProfile)
		}()
	}

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","pid":%d}`, cmd.Process.Pid)
}

func (s *Server) handleFlutterKill(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, `{"error":"Method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	Log("API: /api/1/flutter/kill called")
	s.flutterMgr.Kill()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok"}`)
}

func (s *Server) handleFlutterLaunch(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, `{"error":"Method not allowed"}`, http.StatusMethodNotAllowed)
		return
	}
	Log("API: /api/1/flutter/launch called")
	if err := s.flutterMgr.LaunchWithPort(s.port); err != nil {
		w.Header().Set("Content-Type", "application/json")
		http.Error(w, fmt.Sprintf(`{"error":"%s"}`, err.Error()), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","pid":%d}`, s.flutterMgr.GetPID())
}

func (s *Server) handleFlutterStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"running": s.flutterMgr.IsRunning(),
		"pid":     s.flutterMgr.GetPID(),
	})
}

func (s *Server) handleDetectExtensions(w http.ResponseWriter, r *http.Request) {
	// TODO: Implement CDP connection to detect extensions
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

func (s *Server) SetApps(apps []AppConfig) {
	s.appsMu.Lock()
	s.apps = apps
	s.appsMu.Unlock()
}

func (s *Server) LoadAppsFromFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	var apps []AppConfig
	if err := json.Unmarshal(data, &apps); err != nil {
		return err
	}

	s.SetApps(apps)
	return nil
}

func main() {
	server := NewServer()

	Log("Asset directory: %s", server.assetDir)
	Log("Data directory: %s", server.dataDir)

	// Start server (blocks) - this also launches Flutter UI
	if err := server.Start(); err != nil {
		log.Fatal(err)
	}
}
