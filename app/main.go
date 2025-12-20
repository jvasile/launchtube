package main

import (
	"embed"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	// Parse command line flags
	userFlag := flag.String("user", "", "Username to auto-select on startup (case-insensitive)")
	appFlag := flag.String("app", "", "App name to launch directly (case-insensitive, requires --user if multiple profiles exist)")
	versionFlag := flag.Bool("version", false, "Print version and exit")
	flag.Parse()

	if *versionFlag {
		fmt.Printf("Launch Tube %s\n", version)
		fmt.Printf("Build: %s\n", buildDate)
		fmt.Printf("Commit: %s\n", commit)
		return
	}

	// Initialize logging
	initLog()

	// Create and start HTTP server (for browser extension/userscript API)
	server := NewServer()
	if err := server.Start(); err != nil {
		Log("Warning: Failed to start HTTP server: %v", err)
	}

	Log("Asset directory: %s", server.assetDir)
	Log("Data directory: %s", server.dataDir)

	// Create Wails app
	app := NewApp(server, *userFlag, *appFlag)

	// Run Wails application with panic recovery for better error messages
	defer func() {
		if r := recover(); r != nil {
			msg := fmt.Sprintf("%v", r)
			if strings.Contains(msg, "GTK") || strings.Contains(msg, "gtk") {
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintln(os.Stderr, "Error: Failed to initialize GTK. Missing dependencies.")
				fmt.Fprintln(os.Stderr, "")
				fmt.Fprintln(os.Stderr, "Install required packages:")
				fmt.Fprintln(os.Stderr, "  Debian/Ubuntu: sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0")
				fmt.Fprintln(os.Stderr, "  Fedora:        sudo dnf install gtk3 webkit2gtk4.1")
				fmt.Fprintln(os.Stderr, "  Arch:          sudo pacman -S gtk3 webkit2gtk-4.1")
				os.Exit(1)
			}
			panic(r) // re-panic for other errors
		}
	}()

	err := wails.Run(&options.App{
		Title:            "LaunchTube",
		Width:            1920,
		Height:           1080,
		MinWidth:         800,
		MinHeight:        600,
		Fullscreen:       true,
		Frameless:        true,
		DisableResize:    false,
		BackgroundColour: &options.RGBA{R: 26, G: 26, B: 46, A: 255},
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		OnStartup: app.startup,
		Bind: []interface{}{
			app,
		},
		Linux: &linux.Options{
			WindowIsTranslucent: false,
		},
	})

	if err != nil {
		Log("Error: %v", err)
	}
}
