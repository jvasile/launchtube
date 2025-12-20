package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type BrowserInfo struct {
	Name           string `json:"name"`
	Executable     string `json:"executable"`
	FullscreenFlag string `json:"fullscreenFlag"`
}

var knownBrowsers = []BrowserInfo{
	{Name: "Chrome", Executable: "google-chrome", FullscreenFlag: "--start-fullscreen"},
	{Name: "Chrome", Executable: "google-chrome-stable", FullscreenFlag: "--start-fullscreen"},
	{Name: "Chrome", Executable: "chrome", FullscreenFlag: "--start-fullscreen"},
	{Name: "Chrome", Executable: "chrome.exe", FullscreenFlag: "--start-fullscreen"},
	{Name: "Chromium", Executable: "chromium", FullscreenFlag: "--start-fullscreen"},
	{Name: "Chromium", Executable: "chromium-browser", FullscreenFlag: "--start-fullscreen"},
	{Name: "Chromium", Executable: "chromium.exe", FullscreenFlag: "--start-fullscreen"},
	{Name: "Brave", Executable: "brave", FullscreenFlag: "--start-fullscreen"},
	{Name: "Brave", Executable: "brave-browser", FullscreenFlag: "--start-fullscreen"},
	{Name: "Brave", Executable: "brave.exe", FullscreenFlag: "--start-fullscreen"},
}

type BrowserManager struct {
	mu             sync.Mutex
	cmd            *exec.Cmd
	pid            int
	browser        *BrowserInfo
	overridesDir   string
	assetDir       string
	dataDir        string
	onExit         func()
}

func NewBrowserManager(overridesDir, assetDir, dataDir string) *BrowserManager {
	return &BrowserManager{
		overridesDir: overridesDir,
		assetDir:     assetDir,
		dataDir:      dataDir,
	}
}

func (bm *BrowserManager) SetOnExit(fn func()) {
	bm.mu.Lock()
	bm.onExit = fn
	bm.mu.Unlock()
}

// findExtension looks for an extension, checking overrides first then assetDir
func (bm *BrowserManager) findExtension(name string) string {
	// Check overrides first
	if bm.overridesDir != "" {
		path := filepath.Join(bm.overridesDir, "extensions", name)
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	// Fall back to assetDir
	path := filepath.Join(bm.assetDir, "extensions", name)
	if _, err := os.Stat(path); err == nil {
		return path
	}
	return ""
}

func (bm *BrowserManager) DetectBrowsers() []BrowserInfo {
	var found []BrowserInfo
	for _, browser := range knownBrowsers {
		if _, err := exec.LookPath(browser.Executable); err == nil {
			found = append(found, browser)
		}
	}
	return found
}

func (bm *BrowserManager) FindBrowser(name string) *BrowserInfo {
	for _, browser := range knownBrowsers {
		if browser.Name == name || browser.Executable == name {
			if _, err := exec.LookPath(browser.Executable); err == nil {
				return &browser
			}
		}
	}
	return nil
}

func (bm *BrowserManager) Launch(browserName, url, profileID string) error {
	bm.mu.Lock()
	defer bm.mu.Unlock()

	// Find the browser
	browser := bm.FindBrowser(browserName)
	if browser == nil {
		// Try to find any available browser
		browsers := bm.DetectBrowsers()
		if len(browsers) == 0 {
			return &BrowserError{Message: "No browser found"}
		}
		browser = &browsers[0]
	}

	// Don't use --start-fullscreen; let the script handle fullscreen on user gesture
	args := []string{}

	// Add user-data-dir for profile isolation
	if profileID != "" {
		profilePath := filepath.Join(bm.dataDir, "profiles", profileID, "chrome")
		args = append(args, "--user-data-dir="+profilePath)

		// Clear service worker cache if our extension has been updated
		bm.clearStaleServiceWorkerCache(profileID)
	}

	// Load extensions
	var extensions []string

	// LaunchTube loader extension
	if ext := bm.findExtension("launchtube"); ext != "" {
		extensions = append(extensions, ext)
		Log("Loading LaunchTube extension from: %s", ext)
	}

	// uBlock Origin Lite
	if ext := bm.findExtension("ublock-origin"); ext != "" {
		extensions = append(extensions, ext)
		Log("Loading uBlock Origin from: %s", ext)
	}

	// Dark Reader
	if ext := bm.findExtension("dark-reader"); ext != "" {
		extensions = append(extensions, ext)
		Log("Loading Dark Reader from: %s", ext)
	}

	if len(extensions) > 0 {
		args = append(args, "--load-extension="+strings.Join(extensions, ","))
	}

	// Chrome flags
	args = append(args,
		"--disable-infobars",
		"--autoplay-policy=no-user-gesture-required",
		"--hide-crash-restore-bubble",
		"--disable-features=MediaRouter,GlobalMediaControls,LocalNetworkAccessChecks",
		"--disable-device-discovery-notifications",
		"--disable-notifications",
		"--disable-sync",
		"--no-first-run",
		"--disable-default-apps",
		"--force-dark-mode",
		"--enable-features=AutomaticFullscreenContentSetting",
		"--start-fullscreen",
		"--remote-debugging-port=9222",
	)

	// Create policy file for automatic fullscreen permission
	if profileID != "" {
		policyDir := filepath.Join(bm.dataDir, "profiles", profileID, "chrome", "policies", "managed")
		os.MkdirAll(policyDir, 0755)
		policyFile := filepath.Join(policyDir, "launchtube.json")
		policy := `{"AutomaticFullscreenAllowedForUrls": ["https://www.youtube.com", "https://youtube.com", "*"]}`
		os.WriteFile(policyFile, []byte(policy), 0644)
	}

	// Add the URL
	args = append(args, url)

	Log("Launching browser: %s %v", browser.Executable, args)

	cmd := exec.Command(browser.Executable, args...)
	if err := cmd.Start(); err != nil {
		return err
	}

	bm.cmd = cmd
	bm.pid = cmd.Process.Pid
	bm.browser = browser

	Log("Browser started with PID: %d", bm.pid)

	// Watch for exit
	go func() {
		cmd.Wait()
		bm.mu.Lock()
		Log("Browser process exited")
		bm.cmd = nil
		bm.pid = 0
		bm.browser = nil
		onExit := bm.onExit
		bm.mu.Unlock()

		if onExit != nil {
			onExit()
		}
	}()

	return nil
}

func (bm *BrowserManager) Close() {
	bm.mu.Lock()
	defer bm.mu.Unlock()

	if bm.cmd == nil || bm.cmd.Process == nil {
		Log("No browser process to close")
		return
	}

	Log("Closing browser process PID: %d", bm.pid)

	if runtime.GOOS == "windows" {
		exec.Command("taskkill", "/F", "/PID", strconv.Itoa(bm.pid)).Run()
	} else {
		bm.cmd.Process.Signal(os.Interrupt)
	}

	bm.cmd = nil
	bm.pid = 0
	bm.browser = nil
}

func (bm *BrowserManager) IsRunning() bool {
	bm.mu.Lock()
	defer bm.mu.Unlock()
	return bm.cmd != nil
}

func (bm *BrowserManager) GetPID() int {
	bm.mu.Lock()
	defer bm.mu.Unlock()
	return bm.pid
}

func (bm *BrowserManager) clearStaleServiceWorkerCache(profileID string) {
	bgScript := filepath.Join(bm.assetDir, "extensions", "launchtube", "background.js")
	mtimeFile := filepath.Join(bm.dataDir, "profiles", profileID, "sw_mtime")
	swDir := filepath.Join(bm.dataDir, "profiles", profileID, "chrome", "Default", "Service Worker")

	// Get background.js mtime
	bgInfo, err := os.Stat(bgScript)
	if err != nil {
		return
	}
	bgMtime := bgInfo.ModTime().Unix()

	// Read stored mtime
	storedMtime := int64(0)
	if data, err := os.ReadFile(mtimeFile); err == nil {
		fmt.Sscanf(string(data), "%d", &storedMtime)
	}

	// If background.js is newer, clear entire service worker directory
	if bgMtime > storedMtime {
		Log("Extension updated, clearing service worker cache")
		if err := os.RemoveAll(swDir); err == nil {
			Log("Removed service worker directory")
		}

		// Update stored mtime
		os.WriteFile(mtimeFile, []byte(fmt.Sprintf("%d", bgMtime)), 0644)
	}
}

type BrowserError struct {
	Message string
}

func (e *BrowserError) Error() string {
	return e.Message
}

// findCDPTarget finds a browser tab matching urlPattern and returns its ID
func (bm *BrowserManager) findCDPTarget(urlPattern string) (string, error) {
	resp, err := http.Get("http://localhost:9222/json")
	if err != nil {
		return "", fmt.Errorf("failed to get CDP targets: %w", err)
	}
	defer resp.Body.Close()

	var targets []struct {
		ID   string `json:"id"`
		Type string `json:"type"`
		URL  string `json:"url"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&targets); err != nil {
		return "", fmt.Errorf("failed to decode CDP targets: %w", err)
	}

	for _, t := range targets {
		Log("CDP target: type=%s id=%s url=%s", t.Type, t.ID, t.URL)
		if t.Type == "page" && strings.Contains(t.URL, urlPattern) {
			Log("CDP matched target id=%s url=%s", t.ID, t.URL)
			return t.ID, nil
		}
	}

	return "", fmt.Errorf("no tab found matching %s", urlPattern)
}

// cdpEvaluate evaluates JavaScript in a specific target via CDP websocket
func (bm *BrowserManager) cdpEvaluate(targetID, expression string) (interface{}, error) {
	wsURL := fmt.Sprintf("ws://localhost:9222/devtools/page/%s", targetID)
	Log("CDP connecting to: %s", wsURL)

	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return nil, fmt.Errorf("websocket dial failed: %w", err)
	}
	defer conn.Close()

	// Send Runtime.evaluate command
	cmd := map[string]interface{}{
		"id":     1,
		"method": "Runtime.evaluate",
		"params": map[string]interface{}{
			"expression": expression,
		},
	}

	if err := conn.WriteJSON(cmd); err != nil {
		return nil, fmt.Errorf("write command failed: %w", err)
	}

	// Read response
	var response struct {
		ID     int `json:"id"`
		Result struct {
			Result struct {
				Value interface{} `json:"value"`
			} `json:"result"`
		} `json:"result"`
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}

	if err := conn.ReadJSON(&response); err != nil {
		return nil, fmt.Errorf("read response failed: %w", err)
	}

	if response.Error.Message != "" {
		return nil, fmt.Errorf("CDP error: %s", response.Error.Message)
	}

	Log("CDP evaluate result: %v", response.Result.Result.Value)
	return response.Result.Result.Value, nil
}

// SendFocusToPage connects to the browser via CDP and focuses the page content
func (bm *BrowserManager) SendFocusToPage() error {
	Log("CDP SendFocusToPage: waiting 5 seconds for page to load...")
	time.Sleep(5 * time.Second)

	targetID, err := bm.findCDPTarget("youtube.com")
	if err != nil {
		Log("CDP SendFocusToPage: %v", err)
		return err
	}

	Log("CDP SendFocusToPage: clicking page...")
	_, err = bm.cdpEvaluate(targetID, `document.body.click()`)
	if err != nil {
		Log("CDP SendFocusToPage click failed: %v", err)
		return err
	}

	Log("CDP SendFocusToPage succeeded")
	return nil
}

// SendKeyToPage sends a key press to a tab matching urlPattern via CDP
// If focusSelector is provided, focuses that element first
func (bm *BrowserManager) SendKeyToPage(urlPattern, key, focusSelector string) error {
	// TODO: Implement with raw websocket CDP - chromedp closes browser on context cancel
	Log("CDP SendKeyToPage: not implemented (chromedp causes browser close)")
	return nil
}

// ClickElement clicks an element matching selector in a tab matching urlPattern via CDP
func (bm *BrowserManager) ClickElement(urlPattern, selector string) error {
	// TODO: Implement with raw websocket CDP - chromedp closes browser on context cancel
	Log("CDP ClickElement: not implemented (chromedp causes browser close)")
	return nil
}

// EvalJS evaluates JavaScript in a tab matching urlPattern via CDP
func (bm *BrowserManager) EvalJS(urlPattern, script string) error {
	targetID, err := bm.findCDPTarget(urlPattern)
	if err != nil {
		Log("CDP EvalJS: %v", err)
		return err
	}

	_, err = bm.cdpEvaluate(targetID, script)
	if err != nil {
		Log("CDP EvalJS failed: %v", err)
		return err
	}

	return nil
}
