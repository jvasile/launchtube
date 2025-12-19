package main

import (
	"bufio"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// ScreensaverInhibitor manages xscreensaver inhibition based on video playback
type ScreensaverInhibitor struct {
	mu            sync.Mutex
	player        *Player
	browserMgr    *BrowserManager
	ticker        *time.Ticker
	stopChan      chan struct{}
	checkInterval time.Duration
	isNativeLinux *bool
}

func NewScreensaverInhibitor(player *Player, browserMgr *BrowserManager) *ScreensaverInhibitor {
	return &ScreensaverInhibitor{
		player:        player,
		browserMgr:    browserMgr,
		checkInterval: 60 * time.Second, // Default, will be updated from config
	}
}

// Start begins periodic screensaver inhibition checks
func (s *ScreensaverInhibitor) Start() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.ticker != nil {
		return // Already running
	}

	// Only run on native Linux
	if !s.isOnNativeLinux() {
		Log("ScreensaverInhibitor: Not on native Linux, disabled")
		return
	}

	// Read xscreensaver config for timeout
	s.readXscreensaverTimeout()

	// Deactivate on startup
	s.inhibit()

	s.stopChan = make(chan struct{})
	s.ticker = time.NewTicker(s.checkInterval)

	go func() {
		for {
			select {
			case <-s.ticker.C:
				s.checkAndUpdate()
			case <-s.stopChan:
				return
			}
		}
	}()

	Log("ScreensaverInhibitor: Started, checking every %v", s.checkInterval)
}

// Stop ends the periodic checks
func (s *ScreensaverInhibitor) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.ticker != nil {
		s.ticker.Stop()
		close(s.stopChan)
		s.ticker = nil
		Log("ScreensaverInhibitor: Stopped")
	}
}

func (s *ScreensaverInhibitor) isOnNativeLinux() bool {
	if s.isNativeLinux != nil {
		return *s.isNativeLinux
	}

	result := false
	if runtime.GOOS == "linux" && !isWSL() {
		result = true
	}
	s.isNativeLinux = &result
	return result
}

// Read timeout from ~/.xscreensaver and set interval to half of it
func (s *ScreensaverInhibitor) readXscreensaverTimeout() {
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}

	configPath := filepath.Join(home, ".xscreensaver")
	file, err := os.Open(configPath)
	if err != nil {
		return
	}
	defer file.Close()

	// Look for line like "timeout: 0:05:00" (hours:minutes:seconds)
	re := regexp.MustCompile(`timeout:\s*(\d+):(\d+):(\d+)`)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		matches := re.FindStringSubmatch(line)
		if len(matches) == 4 {
			hours, _ := strconv.Atoi(matches[1])
			minutes, _ := strconv.Atoi(matches[2])
			seconds, _ := strconv.Atoi(matches[3])
			totalSeconds := hours*3600 + minutes*60 + seconds

			// Set check interval to half the timeout, minimum 30 seconds, max 300
			intervalSeconds := totalSeconds / 2
			if intervalSeconds < 30 {
				intervalSeconds = 30
			}
			if intervalSeconds > 300 {
				intervalSeconds = 300
			}
			s.checkInterval = time.Duration(intervalSeconds) * time.Second
			Log("ScreensaverInhibitor: xscreensaver timeout is %d seconds, checking every %d seconds", totalSeconds, intervalSeconds)
			return
		}
	}
}

func (s *ScreensaverInhibitor) checkAndUpdate() {
	if s.isVideoPlaying() {
		s.inhibit()
	}
}

func (s *ScreensaverInhibitor) isVideoPlaying() bool {
	// Check mpv player first
	if s.player != nil {
		status := s.player.GetStatus()
		if playing, ok := status["playing"].(bool); ok && playing {
			if paused, ok := status["paused"].(bool); ok && !paused {
				return true
			}
		}
	}

	// Check browser for fullscreen video via CDP
	if s.browserMgr != nil && s.browserMgr.IsRunning() {
		if s.checkBrowserVideoPlaying() {
			return true
		}
	}

	return false
}

func (s *ScreensaverInhibitor) checkBrowserVideoPlaying() bool {
	// Get CDP targets
	resp, err := http.Get("http://localhost:9222/json")
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	var targets []struct {
		ID                   string `json:"id"`
		Type                 string `json:"type"`
		WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&targets); err != nil {
		return false
	}

	// Check each page target for fullscreen video
	for _, t := range targets {
		if t.Type == "page" && t.WebSocketDebuggerURL != "" {
			if s.checkPageForVideo(t.WebSocketDebuggerURL) {
				return true
			}
		}
	}

	return false
}

func (s *ScreensaverInhibitor) checkPageForVideo(wsURL string) bool {
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return false
	}
	defer conn.Close()

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	conn.SetWriteDeadline(time.Now().Add(2 * time.Second))

	// Query for playing fullscreen video
	cmd := map[string]interface{}{
		"id":     1,
		"method": "Runtime.evaluate",
		"params": map[string]interface{}{
			"expression": `(function() {
				// Only inhibit if there's a playing video AND we're in fullscreen
				if (!document.fullscreenElement) {
					return false;
				}
				const videos = document.querySelectorAll('video');
				for (const v of videos) {
					if (!v.paused && !v.ended && v.readyState > 2) {
						return true;
					}
				}
				return false;
			})()`,
			"returnByValue": true,
		},
	}

	if err := conn.WriteJSON(cmd); err != nil {
		return false
	}

	var response struct {
		ID     int `json:"id"`
		Result struct {
			Result struct {
				Value interface{} `json:"value"`
			} `json:"result"`
		} `json:"result"`
	}

	if err := conn.ReadJSON(&response); err != nil {
		return false
	}

	if result, ok := response.Result.Result.Value.(bool); ok {
		return result
	}

	return false
}

func (s *ScreensaverInhibitor) inhibit() {
	cmd := exec.Command("xscreensaver-command", "-deactivate")
	if err := cmd.Run(); err != nil {
		// xscreensaver-command may not be installed or xscreensaver not running
		// This is fine, just means no screensaver to inhibit
		if !strings.Contains(err.Error(), "not found") {
			Log("ScreensaverInhibitor: Failed to deactivate: %v", err)
		}
	}
}
