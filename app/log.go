package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var (
	logFile   *os.File
	logMu     sync.Mutex
	logInited bool
)

func initLog() {
	if logInited {
		return
	}

	home, _ := os.UserHomeDir()
	logDir := filepath.Join(home, ".local", "share", "launchtube")
	os.MkdirAll(logDir, 0755)

	logPath := filepath.Join(logDir, "launchtube.log")

	var err error
	logFile, err = os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to open log file: %v\n", err)
		return
	}

	logInited = true

	// Write startup marker
	now := time.Now()
	fmt.Fprintf(logFile, "=== LaunchTube (Go) started at %s ===\n", now.Format("2006-01-02 15:04:05.000000"))
	fmt.Printf("=== LaunchTube (Go) started at %s ===\n", now.Format("2006-01-02 15:04:05.000000"))
}

func Log(format string, args ...interface{}) {
	logMu.Lock()
	defer logMu.Unlock()

	if !logInited {
		initLog()
	}

	now := time.Now()
	timestamp := now.Format("2006-01-02T15:04:05.000000")
	message := fmt.Sprintf(format, args...)
	line := fmt.Sprintf("%s %s\n", timestamp, message)

	fmt.Print(line)
	if logFile != nil {
		logFile.WriteString(line)
	}
}
