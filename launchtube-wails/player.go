package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"
)

type PlaylistItem struct {
	URL        string                 `json:"url"`
	ItemID     string                 `json:"itemId"`
	OnComplete map[string]interface{} `json:"onComplete"`
}

type Player struct {
	mu               sync.Mutex
	cmd              *exec.Cmd
	position         float64
	duration         float64
	paused           bool
	playing          bool
	mpvPath          string
	mpvOptions       string
	socketPath       string
	playlist         []PlaylistItem
	playlistPos      int
	onComplete       map[string]interface{}
	onProgress       map[string]interface{}
	lastProgressTime int64
	stopPolling      chan struct{}
	onExit           func()
}

func (p *Player) SetOnExit(fn func()) {
	p.mu.Lock()
	p.onExit = fn
	p.mu.Unlock()
}

func NewPlayer() *Player {
	p := &Player{
		mpvPath: "mpv",
	}
	p.detectMpv()
	return p
}

func (p *Player) detectMpv() {
	// Try common locations
	candidates := []string{"mpv"}

	if runtime.GOOS == "windows" {
		candidates = append(candidates,
			`C:\Program Files\mpv\mpv.exe`,
			`C:\Program Files (x86)\mpv\mpv.exe`,
		)
	}

	for _, path := range candidates {
		if _, err := exec.LookPath(path); err == nil {
			p.mpvPath = path
			return
		}
	}
}

func (p *Player) SetMpvPath(path string) {
	p.mu.Lock()
	p.mpvPath = path
	p.mu.Unlock()
}

func (p *Player) SetMpvOptions(options string) {
	p.mu.Lock()
	p.mpvOptions = options
	p.mu.Unlock()
}

func (p *Player) GetMpvPath() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.mpvPath
}

func (p *Player) GetMpvOptions() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.mpvOptions
}

func (p *Player) Play(url, title string, startPosition float64, onComplete, onProgress map[string]interface{}) error {
	p.Stop()

	p.mu.Lock()
	defer p.mu.Unlock()

	Log("ExternalPlayer: Playing %s", url)

	p.onComplete = onComplete
	p.onProgress = onProgress
	p.position = startPosition
	p.duration = 0
	p.paused = false
	p.playing = true
	p.playlist = nil
	p.playlistPos = 0

	return p.startMpv(url, title, startPosition)
}

func (p *Player) PlayPlaylist(items []PlaylistItem, startPosition float64) error {
	if len(items) == 0 {
		return fmt.Errorf("empty playlist")
	}

	p.Stop()

	p.mu.Lock()
	defer p.mu.Unlock()

	p.playlist = items
	p.playlistPos = 0
	p.position = startPosition
	p.duration = 0
	p.paused = false
	p.playing = true

	// Use first item's onComplete for now
	if items[0].OnComplete != nil {
		p.onComplete = items[0].OnComplete
	}

	return p.startMpvPlaylist(items, startPosition)
}

func (p *Player) startMpv(url, title string, startPosition float64) error {
	// Determine socket path
	if runtime.GOOS == "windows" || isWSL() {
		p.socketPath = `\\.\pipe\launchtube-mpv`
	} else {
		p.socketPath = "/tmp/launchtube-mpv.sock"
		// Remove existing socket
		os.Remove(p.socketPath)
	}

	args := []string{
		"--fullscreen",
		fmt.Sprintf("--input-ipc-server=%s", p.socketPath),
	}

	if startPosition > 0 {
		args = append(args, fmt.Sprintf("--start=%d", int(startPosition)))
	}

	if title != "" {
		args = append(args, fmt.Sprintf("--title=%s", title))
	}

	if p.mpvOptions != "" {
		// Split options and add them
		opts := strings.Fields(p.mpvOptions)
		args = append(args, opts...)
	}

	args = append(args, url)

	Log("ExternalPlayer: Starting mpv with args: %v", args)

	p.cmd = exec.Command(p.mpvPath, args...)
	if err := p.cmd.Start(); err != nil {
		return err
	}

	// Start position polling
	p.stopPolling = make(chan struct{})
	go p.pollPosition()

	// Wait for process to exit
	go func() {
		p.cmd.Wait()
		p.mu.Lock()
		p.playing = false
		p.cmd = nil
		onExit := p.onExit
		p.mu.Unlock()

		// Close polling
		select {
		case <-p.stopPolling:
		default:
			close(p.stopPolling)
		}

		// Execute onComplete callback
		p.executeOnComplete()

		// Execute onExit callback (for Flutter respawn)
		if onExit != nil {
			onExit()
		}
	}()

	return nil
}

func (p *Player) startMpvPlaylist(items []PlaylistItem, startPosition float64) error {
	if len(items) == 0 {
		return fmt.Errorf("empty playlist")
	}

	// For now, just play the first item
	// TODO: Implement full playlist support with position tracking
	return p.startMpv(items[0].URL, "", startPosition)
}

func (p *Player) pollPosition() {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-p.stopPolling:
			return
		case <-ticker.C:
			p.queryPosition()

			// Send progress update every 3 seconds
			now := time.Now().Unix()
			p.mu.Lock()
			if p.onProgress != nil && now-p.lastProgressTime >= 3 {
				p.lastProgressTime = now
				go p.executeOnProgress()
			}
			p.mu.Unlock()
		}
	}
}

func (p *Player) queryPosition() {
	if runtime.GOOS == "windows" || isWSL() {
		p.queryPositionWindows()
	} else {
		p.queryPositionUnix()
	}
}

func (p *Player) queryPositionUnix() {
	conn, err := net.Dial("unix", p.socketPath)
	if err != nil {
		return
	}
	defer conn.Close()

	conn.SetDeadline(time.Now().Add(500 * time.Millisecond))

	// Query time-pos
	conn.Write([]byte(`{"command":["get_property","time-pos"],"request_id":1}` + "\n"))
	// Query duration
	conn.Write([]byte(`{"command":["get_property","duration"],"request_id":2}` + "\n"))
	// Query pause
	conn.Write([]byte(`{"command":["get_property","pause"],"request_id":3}` + "\n"))

	reader := bufio.NewReader(conn)
	for i := 0; i < 3; i++ {
		line, err := reader.ReadString('\n')
		if err != nil {
			break
		}
		p.parseIpcResponse(line)
	}
}

func (p *Player) queryPositionWindows() {
	// Use PowerShell to communicate with named pipe
	script := fmt.Sprintf(`
$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "launchtube-mpv", [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(500)
$writer = New-Object System.IO.StreamWriter($pipe)
$reader = New-Object System.IO.StreamReader($pipe)
$writer.WriteLine('{"command":["get_property","time-pos"],"request_id":1}')
$writer.WriteLine('{"command":["get_property","duration"],"request_id":2}')
$writer.WriteLine('{"command":["get_property","pause"],"request_id":3}')
$writer.Flush()
Write-Output $reader.ReadLine()
Write-Output $reader.ReadLine()
Write-Output $reader.ReadLine()
$pipe.Close()
`)

	cmd := exec.Command("powershell", "-Command", script)
	output, err := cmd.Output()
	if err != nil {
		return
	}

	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		p.parseIpcResponse(line)
	}
}

func (p *Player) parseIpcResponse(line string) {
	var resp struct {
		RequestID int         `json:"request_id"`
		Data      interface{} `json:"data"`
		Error     string      `json:"error"`
	}

	if err := json.Unmarshal([]byte(line), &resp); err != nil {
		return
	}

	if resp.Error != "" && resp.Error != "success" {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	switch resp.RequestID {
	case 1: // time-pos
		if pos, ok := resp.Data.(float64); ok {
			p.position = pos
		}
	case 2: // duration
		if dur, ok := resp.Data.(float64); ok {
			p.duration = dur
		}
	case 3: // pause
		if paused, ok := resp.Data.(bool); ok {
			p.paused = paused
		}
	}
}

func (p *Player) executeOnComplete() {
	p.mu.Lock()
	onComplete := p.onComplete
	position := p.position
	p.mu.Unlock()

	if onComplete == nil {
		return
	}

	url, _ := onComplete["url"].(string)
	method, _ := onComplete["method"].(string)
	headers, _ := onComplete["headers"].(map[string]interface{})
	bodyTemplate, _ := onComplete["bodyTemplate"].(map[string]interface{})

	if url == "" || method == "" {
		return
	}

	// Build body from template
	positionTicks := int64(position * 10000000) // Convert to ticks
	body := make(map[string]interface{})
	for k, v := range bodyTemplate {
		if s, ok := v.(string); ok {
			s = strings.ReplaceAll(s, "${positionTicks}", fmt.Sprintf("%d", positionTicks))
			s = strings.ReplaceAll(s, "${isPaused}", "false")
			body[k] = s
		} else {
			body[k] = v
		}
	}

	bodyBytes, _ := json.Marshal(body)

	req, err := http.NewRequest(method, url, bytes.NewReader(bodyBytes))
	if err != nil {
		return
	}

	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		if s, ok := v.(string); ok {
			req.Header.Set(k, s)
		}
	}

	client := &http.Client{Timeout: 10 * time.Second}
	client.Do(req)
}

func (p *Player) executeOnProgress() {
	p.mu.Lock()
	onProgress := p.onProgress
	position := p.position
	paused := p.paused
	p.mu.Unlock()

	if onProgress == nil {
		return
	}

	url, _ := onProgress["url"].(string)
	method, _ := onProgress["method"].(string)
	headers, _ := onProgress["headers"].(map[string]interface{})
	bodyTemplate, _ := onProgress["bodyTemplate"].(map[string]interface{})

	if url == "" || method == "" {
		return
	}

	positionTicks := int64(position * 10000000)
	isPaused := "false"
	if paused {
		isPaused = "true"
	}

	body := make(map[string]interface{})
	for k, v := range bodyTemplate {
		if s, ok := v.(string); ok {
			s = strings.ReplaceAll(s, "${positionTicks}", fmt.Sprintf("%d", positionTicks))
			s = strings.ReplaceAll(s, "${isPaused}", isPaused)
			body[k] = s
		} else {
			body[k] = v
		}
	}

	bodyBytes, _ := json.Marshal(body)

	req, err := http.NewRequest(method, url, bytes.NewReader(bodyBytes))
	if err != nil {
		return
	}

	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		if s, ok := v.(string); ok {
			req.Header.Set(k, s)
		}
	}

	client := &http.Client{Timeout: 10 * time.Second}
	client.Do(req)
}

func (p *Player) Stop() {
	p.mu.Lock()
	defer p.mu.Unlock()

	Log("ExternalPlayer: stop() called, cmd=%v", p.cmd)

	if p.cmd == nil || p.cmd.Process == nil {
		return
	}

	if p.stopPolling != nil {
		select {
		case <-p.stopPolling:
		default:
			close(p.stopPolling)
		}
	}

	if runtime.GOOS == "windows" {
		exec.Command("taskkill", "/F", "/PID", fmt.Sprintf("%d", p.cmd.Process.Pid)).Run()
	} else {
		p.cmd.Process.Signal(os.Interrupt)
	}

	p.cmd = nil
	p.playing = false
}

func (p *Player) GetStatus() map[string]interface{} {
	p.mu.Lock()
	defer p.mu.Unlock()

	return map[string]interface{}{
		"playing":  p.playing,
		"paused":   p.paused,
		"position": p.position,
		"duration": p.duration,
	}
}

func isWSL() bool {
	data, err := os.ReadFile("/proc/version")
	if err != nil {
		return false
	}
	return strings.Contains(strings.ToLower(string(data)), "microsoft")
}
