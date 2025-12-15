package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
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

	args := []string{browser.FullscreenFlag}

	// Add user-data-dir for Chrome/Chromium profile isolation
	if profileID != "" && browser.Name != "Firefox" {
		profilePath := filepath.Join(bm.dataDir, "profiles", profileID, "chrome")
		args = append(args, "--user-data-dir="+profilePath)
	}

	// Add LaunchTube extension for script injection (Chrome/Chromium only)
	if browser.Name != "Firefox" {
		extensionPath := filepath.Join(bm.assetDir, "extensions", "launchtube")
		args = append(args, "--load-extension="+extensionPath)
	}

	// Add remote debugging port
	args = append(args, "--remote-debugging-port=9222")

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

func (bm *BrowserManager) LaunchAdmin(browserName, profileID string, serverPort int) error {
	bm.mu.Lock()
	defer bm.mu.Unlock()

	// Check if already running
	if bm.cmd != nil {
		return &BrowserError{Message: "Browser is already running. Please close it first."}
	}

	// Find the browser
	browser := bm.FindBrowser(browserName)
	if browser == nil {
		browsers := bm.DetectBrowsers()
		if len(browsers) == 0 {
			return &BrowserError{Message: "No browser found"}
		}
		browser = &browsers[0]
	}

	var args []string

	// Use --start-maximized for Chrome/Chromium admin mode, nothing for Firefox
	if browser.Name != "Firefox" {
		args = append(args, "--start-maximized")

		// Add user-data-dir for Chrome/Chromium profile isolation
		if profileID != "" {
			profilePath := filepath.Join(bm.dataDir, "profiles", profileID, "chrome")
			args = append(args, "--user-data-dir="+profilePath)
		}

		// Add LaunchTube extension for script injection
		extensionPath := filepath.Join(bm.assetDir, "extensions", "launchtube")
		args = append(args, "--load-extension="+extensionPath)
	}

	// Add remote debugging port
	args = append(args, "--remote-debugging-port=9222")

	// Add setup URL
	args = append(args, fmt.Sprintf("http://localhost:%d/setup?target=", serverPort))

	Log("Launching admin browser: %s %v", browser.Executable, args)

	cmd := exec.Command(browser.Executable, args...)
	if err := cmd.Start(); err != nil {
		return err
	}

	bm.cmd = cmd
	bm.pid = cmd.Process.Pid
	bm.browser = browser

	Log("Admin browser started with PID: %d", bm.pid)

	// Watch for exit
	go func() {
		cmd.Wait()
		bm.mu.Lock()
		Log("Admin browser process exited")
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

type BrowserError struct {
	Message string
}

func (e *BrowserError) Error() string {
	return e.Message
}
