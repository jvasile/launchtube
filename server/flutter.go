package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"
)

type FlutterManager struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	flutterBin string
	onExit     func()
}

func NewFlutterManager() *FlutterManager {
	fm := &FlutterManager{}
	fm.detectFlutterBin()
	return fm
}

func (fm *FlutterManager) detectFlutterBin() {
	// Look for Flutter binary in common locations
	candidates := []string{}

	exe, _ := os.Executable()
	exeDir := filepath.Dir(exe)
	cwd, _ := os.Getwd()

	if runtime.GOOS == "windows" {
		// Windows paths
		candidates = append(candidates, filepath.Join(exeDir, "launchtube-ui.exe"))
		candidates = append(candidates, filepath.Join(exeDir, "launchtube.exe"))
		candidates = append(candidates, filepath.Join(exeDir, "..", "build", "windows", "x64", "runner", "Release", "launchtube.exe"))
		candidates = append(candidates, filepath.Join(cwd, "..", "build", "windows", "x64", "runner", "Release", "launchtube.exe"))
		candidates = append(candidates, filepath.Join(cwd, "build", "windows", "x64", "runner", "Release", "launchtube.exe"))
	} else {
		// Linux paths
		candidates = append(candidates, filepath.Join(exeDir, "launchtube-ui"))
		candidates = append(candidates, filepath.Join(exeDir, "launchtube-flutter"))
		candidates = append(candidates, filepath.Join(exeDir, "..", "build", "linux", "x64", "release", "bundle", "launchtube"))
		candidates = append(candidates, filepath.Join(cwd, "..", "build", "linux", "x64", "release", "bundle", "launchtube"))
		candidates = append(candidates, filepath.Join(cwd, "build", "linux", "x64", "release", "bundle", "launchtube"))
	}

	for _, path := range candidates {
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			fm.flutterBin = path
			Log("Found Flutter UI at: %s", path)
			return
		}
	}

	Log("Flutter UI binary not found")
}

func (fm *FlutterManager) SetBinaryPath(path string) {
	fm.mu.Lock()
	fm.flutterBin = path
	fm.mu.Unlock()
}

func (fm *FlutterManager) SetOnExit(fn func()) {
	fm.mu.Lock()
	fm.onExit = fn
	fm.mu.Unlock()
}

func (fm *FlutterManager) Launch() error {
	return fm.LaunchWithPortAndProfile(0, "")
}

func (fm *FlutterManager) LaunchWithPort(serverPort int) error {
	return fm.LaunchWithPortAndProfile(serverPort, "")
}

func (fm *FlutterManager) LaunchWithPortAndProfile(serverPort int, profileID string) error {
	fm.mu.Lock()
	defer fm.mu.Unlock()

	if fm.cmd != nil {
		Log("Flutter UI already running")
		return nil
	}

	if fm.flutterBin == "" {
		return &FlutterError{Message: "Flutter UI binary not found"}
	}

	Log("Launching Flutter UI: %s (profile=%s)", fm.flutterBin, profileID)

	cmd := exec.Command(fm.flutterBin)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	// Pass Go server port and active profile to Flutter via environment
	env := os.Environ()
	if serverPort > 0 {
		env = append(env, "LAUNCHTUBE_SERVER_PORT="+strconv.Itoa(serverPort))
	}
	if profileID != "" {
		env = append(env, "LAUNCHTUBE_ACTIVE_PROFILE="+profileID)
	}
	cmd.Env = env

	if err := cmd.Start(); err != nil {
		return err
	}

	fm.cmd = cmd
	Log("Flutter UI started with PID: %d", cmd.Process.Pid)

	// Watch for exit
	go func() {
		cmd.Wait()
		fm.mu.Lock()
		Log("Flutter UI process exited")
		fm.cmd = nil
		onExit := fm.onExit
		fm.mu.Unlock()

		if onExit != nil {
			onExit()
		}
	}()

	return nil
}

func (fm *FlutterManager) Kill() {
	fm.mu.Lock()
	defer fm.mu.Unlock()

	if fm.cmd == nil || fm.cmd.Process == nil {
		Log("No Flutter UI process to kill")
		return
	}

	pid := fm.cmd.Process.Pid
	Log("Killing Flutter UI PID: %d", pid)

	if runtime.GOOS == "windows" {
		exec.Command("taskkill", "/F", "/PID", strconv.Itoa(pid)).Run()
	} else {
		fm.cmd.Process.Signal(os.Interrupt)
		// Give it a moment to exit gracefully, then force kill
		cmd := fm.cmd
		go func() {
			time.Sleep(500 * time.Millisecond)
			if cmd.Process != nil {
				cmd.Process.Kill()
			}
		}()
	}

	fm.cmd = nil
}

func (fm *FlutterManager) IsRunning() bool {
	fm.mu.Lock()
	defer fm.mu.Unlock()
	return fm.cmd != nil
}

func (fm *FlutterManager) GetPID() int {
	fm.mu.Lock()
	defer fm.mu.Unlock()
	if fm.cmd != nil && fm.cmd.Process != nil {
		return fm.cmd.Process.Pid
	}
	return 0
}

type FlutterError struct {
	Message string
}

func (e *FlutterError) Error() string {
	return e.Message
}
