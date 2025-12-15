package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
)

type BrowserInfo struct {
	Name           string `json:"name"`
	Executable     string `json:"executable"`
	FullscreenFlag string `json:"fullscreenFlag"`
}

var knownBrowsers = []BrowserInfo{
	{Name: "Firefox", Executable: "firefox", FullscreenFlag: "--kiosk"},
	{Name: "Firefox", Executable: "firefox.exe", FullscreenFlag: "--kiosk"},
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
	assetDir       string
	dataDir        string
	onExit         func()
}

func NewBrowserManager(assetDir, dataDir string) *BrowserManager {
	return &BrowserManager{
		assetDir: assetDir,
		dataDir:  dataDir,
	}
}

func (bm *BrowserManager) SetOnExit(fn func()) {
	bm.mu.Lock()
	bm.onExit = fn
	bm.mu.Unlock()
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

func (bm *BrowserManager) Launch(browserName, url, profileID string, serverPort int) error {
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

	// Add user-data-dir for Chrome/Chromium profile isolation
	if profileID != "" && browser.Name != "Firefox" {
		profilePath := filepath.Join(bm.dataDir, "profiles", profileID, "chrome")
		args = append(args, "--user-data-dir="+profilePath)

		// Clear service worker cache if our extension has been updated
		bm.clearStaleServiceWorkerCache(profileID)
	}

	// Load extensions for Chrome/Chromium
	if browser.Name != "Firefox" {
		var extensions []string

		// LaunchTube loader extension
		launchtubeExt := filepath.Join(bm.assetDir, "extensions", "launchtube")
		if _, err := os.Stat(launchtubeExt); err == nil {
			extensions = append(extensions, launchtubeExt)
			Log("Loading LaunchTube extension from: %s", launchtubeExt)
		}

		// uBlock Origin Lite
		ublockExt := filepath.Join(bm.assetDir, "extensions", "ublock-origin")
		if _, err := os.Stat(ublockExt); err == nil {
			extensions = append(extensions, ublockExt)
			Log("Loading uBlock Origin from: %s", ublockExt)
		}

		// Dark Reader
		darkReaderExt := filepath.Join(bm.assetDir, "extensions", "dark-reader")
		if _, err := os.Stat(darkReaderExt); err == nil {
			extensions = append(extensions, darkReaderExt)
			Log("Loading Dark Reader from: %s", darkReaderExt)
		}

		if len(extensions) > 0 {
			args = append(args, "--load-extension="+strings.Join(extensions, ","))
		}
	}

	// Chrome-specific flags
	if browser.Name != "Firefox" {
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
		)

		// Create policy file for automatic fullscreen permission
		if profileID != "" {
			policyDir := filepath.Join(bm.dataDir, "profiles", profileID, "chrome", "policies", "managed")
			os.MkdirAll(policyDir, 0755)
			policyFile := filepath.Join(policyDir, "launchtube.json")
			policy := `{"AutomaticFullscreenAllowedForUrls": ["https://www.youtube.com", "https://youtube.com", "*"]}`
			os.WriteFile(policyFile, []byte(policy), 0644)
		}
	}

	// Add the URL
	if browser.Name == "Firefox" && serverPort > 0 {
		// Firefox needs setup page for userscript installation
		args = append(args, fmt.Sprintf("http://localhost:%d/setup?target=%s", serverPort, url))
	} else {
		args = append(args, url)
	}

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
