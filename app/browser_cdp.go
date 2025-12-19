package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/page"
	cdpruntime "github.com/chromedp/cdproto/runtime"
	"github.com/chromedp/chromedp"
)

// CDPBrowser manages Chrome via Chrome DevTools Protocol
type CDPBrowser struct {
	mu            sync.Mutex
	cmd           *exec.Cmd
	cancel        context.CancelFunc
	ctx           context.Context
	allocCtx      context.Context
	allocCancel   context.CancelFunc
	assetDir      string
	dataDir       string
	serverPort    int
	onExit        func()
	getScript     func(url, profileID string) string // Function to get service script for URL
}

func NewCDPBrowser(assetDir, dataDir string, serverPort int) *CDPBrowser {
	return &CDPBrowser{
		assetDir:   assetDir,
		dataDir:    dataDir,
		serverPort: serverPort,
	}
}

func (b *CDPBrowser) SetGetScript(fn func(url, profileID string) string) {
	b.mu.Lock()
	b.getScript = fn
	b.mu.Unlock()
}

func (b *CDPBrowser) SetOnExit(fn func()) {
	b.mu.Lock()
	b.onExit = fn
	b.mu.Unlock()
}

// loaderScript returns the JavaScript that will be injected on every page load.
// This sets up globals but does NOT fetch the service script (that's done via CDP after nav).
// Communication back to Go uses console.log with special prefixes that CDP monitors.
func (b *CDPBrowser) loaderScript() string {
	return fmt.Sprintf(`
(function() {
    'use strict';

    const LAUNCHTUBE_PORT = %d;
    const VERSION = '3.0-CDP';

    // Skip non-http pages
    if (!location.protocol.startsWith('http')) return;

    // Skip our own setup page
    if (location.hostname === 'localhost' || location.hostname === '127.0.0.1') return;

    console.log('[LaunchTube CDP] Loader v' + VERSION + ' on ' + location.hostname);

    // Set up globals
    window.LAUNCH_TUBE_PORT = LAUNCHTUBE_PORT;
    window.LAUNCH_TUBE_URL = 'http://localhost:' + LAUNCHTUBE_PORT;

    // Helper to close the browser tab - uses console.log which CDP monitors
    window.launchTubeCloseTab = function() {
        console.log('__LAUNCHTUBE_CMD_CLOSE__');
    };

    // Helper to log to server - uses console.log which CDP monitors
    window.launchTubeLog = function(message, level) {
        console.log('__LAUNCHTUBE_LOG__:' + (level || 'info') + ':' + message);
    };

    // Announce ready
    window.postMessage({ type: 'launchtube-loader-ready', port: LAUNCHTUBE_PORT, version: 3 }, '*');
})();
`, b.serverPort)
}

// Launch starts Chrome and connects via CDP
func (b *CDPBrowser) Launch(url, profileID string) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.cmd != nil {
		return fmt.Errorf("browser already running")
	}

	// Build Chrome options - minimal set, no automation markers
	opts := []chromedp.ExecAllocatorOption{
		chromedp.NoFirstRun,
		chromedp.NoDefaultBrowserCheck,
		chromedp.Flag("start-fullscreen", true),
		chromedp.Flag("disable-infobars", true),
		chromedp.Flag("autoplay-policy", "no-user-gesture-required"),
		chromedp.Flag("hide-crash-restore-bubble", true),
		chromedp.Flag("disable-features", "MediaRouter"),
		// Workaround: open devtools so CDP detection looks like normal user with devtools
		chromedp.Flag("auto-open-devtools-for-tabs", true),
	}

	// Load uBlock Origin if available
	// TODO: MV3 extensions via --load-extension may need additional flags
	// Disabled for now until we resolve the crash
	// ublockPath := filepath.Join(b.assetDir, "extensions", "ublock-origin")
	// if _, err := os.Stat(ublockPath); err == nil {
	// 	opts = append(opts, chromedp.Flag("load-extension", ublockPath))
	// 	Log("CDP: Loading uBlock Origin from %s", ublockPath)
	// }

	// Profile-specific user data dir
	if profileID != "" {
		userDataDir := filepath.Join(b.dataDir, "profiles", profileID, "chrome-cdp")
		opts = append(opts, chromedp.UserDataDir(userDataDir))
	}

	// Find Chrome executable
	chromePath := findChrome()
	if chromePath != "" {
		opts = append(opts, chromedp.ExecPath(chromePath))
	}

	// Create allocator context
	b.allocCtx, b.allocCancel = chromedp.NewExecAllocator(context.Background(), opts...)

	// Create browser context
	b.ctx, b.cancel = chromedp.NewContext(b.allocCtx)

	// Listen for console messages to handle commands from injected scripts
	chromedp.ListenTarget(b.ctx, func(ev interface{}) {
		if ev, ok := ev.(*cdpruntime.EventConsoleAPICalled); ok {
			for _, arg := range ev.Args {
				if arg.Type == cdpruntime.TypeString && arg.Value != nil {
					msg := strings.Trim(string(arg.Value), "\"")
					// Debug: log all console messages
					if !strings.HasPrefix(msg, "[LaunchTube") {
						Log("CDP Console: %s", msg)
					}
					if msg == "__LAUNCHTUBE_CMD_CLOSE__" {
						Log("CDP: Received close command from page")
						go b.Close()
					} else if strings.HasPrefix(msg, "__LAUNCHTUBE_LOG__:") {
						// Parse: __LAUNCHTUBE_LOG__:level:message
						parts := strings.SplitN(msg, ":", 3)
						if len(parts) == 3 {
							Log("[JS:%s] %s", parts[1], parts[2])
						}
					}
				}
			}
		}
	})

	// Add loader script to evaluate on every new document (bypasses CSP)
	// Note: We don't enable Runtime domain as it triggers bot detection
	err := chromedp.Run(b.ctx,
		chromedp.ActionFunc(func(ctx context.Context) error {
			scriptID, err := page.AddScriptToEvaluateOnNewDocument(b.loaderScript()).Do(ctx)
			if err != nil {
				return err
			}
			Log("CDP: Added loader script with ID: %s", scriptID)
			return nil
		}),
	)
	if err != nil {
		b.cleanup()
		return fmt.Errorf("failed to add loader script: %w", err)
	}

	// Navigate to the URL (use page.Navigate directly to avoid waiting for load)
	Log("CDP: Navigating to %s", url)
	err = chromedp.Run(b.ctx,
		chromedp.ActionFunc(func(ctx context.Context) error {
			_, _, _, _, err := page.Navigate(url).Do(ctx)
			return err
		}),
	)
	if err != nil {
		b.cleanup()
		return fmt.Errorf("failed to navigate: %w", err)
	}
	Log("CDP: Navigation started")

	// Wait for body to be ready (with timeout, don't fail if it times out)
	waitCtx, waitCancel := context.WithTimeout(b.ctx, 10*time.Second)
	defer waitCancel()
	if err := chromedp.Run(waitCtx, chromedp.WaitReady("body")); err != nil {
		Log("CDP: Warning - WaitReady timed out: %v (continuing anyway)", err)
	} else {
		Log("CDP: Body ready")
	}

	// Focus the window
	err = chromedp.Run(b.ctx,
		chromedp.ActionFunc(func(ctx context.Context) error {
			return page.BringToFront().Do(ctx)
		}),
		chromedp.Evaluate(`document.body.focus(); window.focus();`, nil),
	)
	if err != nil {
		Log("CDP: Warning - focus failed: %v", err)
	}

	Log("CDP: Browser launched, navigated to %s", url)

	// Inject service script directly via CDP (bypasses HTTPS mixed content issues)
	if b.getScript != nil {
		script := b.getScript(url, profileID)
		if script != "" {
			Log("CDP: Injecting service script (%d bytes)", len(script))
			var result interface{}
			err = chromedp.Run(b.ctx, chromedp.Evaluate(script, &result))
			if err != nil {
				Log("CDP: Warning - failed to inject service script: %v", err)
			} else {
				Log("CDP: Service script injected successfully")
			}
		}
	}

	// Watch for browser exit in background
	go b.watchForExit()

	return nil
}

func (b *CDPBrowser) watchForExit() {
	// Wait for context to be done (browser closed)
	<-b.ctx.Done()

	b.mu.Lock()
	Log("CDP: Browser context done")
	onExit := b.onExit
	b.cmd = nil
	b.mu.Unlock()

	if onExit != nil {
		onExit()
	}
}

func (b *CDPBrowser) cleanup() {
	if b.cancel != nil {
		b.cancel()
		b.cancel = nil
	}
	if b.allocCancel != nil {
		b.allocCancel()
		b.allocCancel = nil
	}
	b.ctx = nil
	b.allocCtx = nil
}

// Close terminates the browser
func (b *CDPBrowser) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()

	Log("CDP: Closing browser")
	b.cleanup()
}

// Navigate goes to a new URL in the existing browser
func (b *CDPBrowser) Navigate(url string) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.ctx == nil {
		return fmt.Errorf("browser not running")
	}

	return chromedp.Run(b.ctx, chromedp.Navigate(url))
}

// IsRunning returns true if browser is active
func (b *CDPBrowser) IsRunning() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.ctx != nil
}

// ExecuteScript runs JavaScript in the current page
func (b *CDPBrowser) ExecuteScript(script string) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.ctx == nil {
		return fmt.Errorf("browser not running")
	}

	var result interface{}
	return chromedp.Run(b.ctx, chromedp.Evaluate(script, &result))
}

// findChrome locates the Chrome executable
func findChrome() string {
	var candidates []string

	switch runtime.GOOS {
	case "linux":
		candidates = []string{
			"google-chrome",
			"google-chrome-stable",
			"chromium",
			"chromium-browser",
		}
	case "darwin":
		candidates = []string{
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			"/Applications/Chromium.app/Contents/MacOS/Chromium",
		}
	case "windows":
		candidates = []string{
			`C:\Program Files\Google\Chrome\Application\chrome.exe`,
			`C:\Program Files (x86)\Google\Chrome\Application\chrome.exe`,
			filepath.Join(os.Getenv("LOCALAPPDATA"), `Google\Chrome\Application\chrome.exe`),
		}
	}

	for _, path := range candidates {
		if _, err := exec.LookPath(path); err == nil {
			return path
		}
		// Also check absolute paths
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}

	return ""
}

// WaitForLoad waits for the page to finish loading
func (b *CDPBrowser) WaitForLoad(timeout time.Duration) error {
	b.mu.Lock()
	ctx := b.ctx
	b.mu.Unlock()

	if ctx == nil {
		return fmt.Errorf("browser not running")
	}

	timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	return chromedp.Run(timeoutCtx, chromedp.WaitReady("body"))
}

// GetCurrentURL returns the current page URL
func (b *CDPBrowser) GetCurrentURL() (string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.ctx == nil {
		return "", fmt.Errorf("browser not running")
	}

	var url string
	err := chromedp.Run(b.ctx, chromedp.Location(&url))
	return url, err
}

// Screenshot captures the current page (useful for debugging)
func (b *CDPBrowser) Screenshot() ([]byte, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.ctx == nil {
		return nil, fmt.Errorf("browser not running")
	}

	var buf []byte
	err := chromedp.Run(b.ctx, chromedp.CaptureScreenshot(&buf))
	return buf, err
}
