package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"strings"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// App struct - main Wails application
type App struct {
	ctx         context.Context
	server      *Server
	initialUser string
	initialApp  string
}

// NewApp creates a new App application struct
func NewApp(server *Server, initialUser, initialApp string) *App {
	return &App{
		server:      server,
		initialUser: initialUser,
		initialApp:  initialApp,
	}
}

// GetInitialUser returns the user specified via --user flag (for auto-login)
func (a *App) GetInitialUser() string {
	return a.initialUser
}

// GetInitialApp returns the app specified via --app flag (for direct launch)
func (a *App) GetInitialApp() string {
	return a.initialApp
}

// GetProfileCount returns the number of profiles (for --app validation)
func (a *App) GetProfileCount() int {
	return len(a.GetProfiles())
}

// startup is called when the app starts
func (a *App) startup(ctx context.Context) {
	a.ctx = ctx

	// Set up callbacks to show window when browser/player exits
	a.server.SetOnBrowserExit(func() {
		Log("Browser exited, showing window")
		runtime.WindowShow(a.ctx)
	})
	a.server.SetOnPlayerExit(func() {
		Log("Player exited, showing window")
		runtime.WindowShow(a.ctx)
	})
	// Set up shutdown callback
	a.server.SetOnShutdown(func() {
		Log("Shutdown requested via API")
		runtime.Quit(a.ctx)
	})
}

// Profile represents a user profile
type Profile struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	ColorValue  int    `json:"colorValue"`
	PhotoPath   string `json:"photoPath,omitempty"`
	Order       int    `json:"order"`
}

// GetProfiles returns all user profiles
func (a *App) GetProfiles() []Profile {
	profilesDir := filepath.Join(a.server.dataDir, "profiles")
	entries, err := os.ReadDir(profilesDir)
	if err != nil {
		Log("Failed to read profiles dir: %v", err)
		return []Profile{}
	}

	var profiles []Profile
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		profileDir := filepath.Join(profilesDir, entry.Name())
		profilePath := filepath.Join(profileDir, "profile.json")
		data, err := os.ReadFile(profilePath)
		if err != nil {
			continue
		}

		var profile Profile
		if err := json.Unmarshal(data, &profile); err != nil {
			continue
		}

		// Convert relative photoPath to absolute (photos are in assets/images/profile-photos/)
		if profile.PhotoPath != "" && !filepath.IsAbs(profile.PhotoPath) {
			profile.PhotoPath = filepath.Join(a.server.assetDir, "images", "profile-photos", profile.PhotoPath)
		}

		profiles = append(profiles, profile)
	}

	// Sort by order
	sort.Slice(profiles, func(i, j int) bool {
		return profiles[i].Order < profiles[j].Order
	})

	return profiles
}

// GetApps returns apps for a profile
func (a *App) GetApps(profileID string) []AppConfig {
	return a.server.GetAppsForProfile(profileID)
}

// SaveApps saves apps for a profile
func (a *App) SaveApps(profileID string, apps []AppConfig) error {
	appsPath := filepath.Join(a.server.dataDir, "profiles", profileID, "apps.json")
	data, err := json.MarshalIndent(apps, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(appsPath, data, 0644)
}

// GetBrowsers returns available browsers
func (a *App) GetBrowsers() []BrowserInfo {
	return a.server.DetectBrowsers()
}

// LaunchApp launches a website or native app
func (a *App) LaunchApp(app AppConfig, profileID string, browserName string) error {
	if app.Type == 0 && app.URL != "" {
		// Website - launch browser and hide window
		runtime.WindowHide(a.ctx)
		err := a.server.LaunchBrowser(browserName, app.URL, profileID)
		if err != nil {
			runtime.WindowShow(a.ctx)
		}
		return err
	} else if app.CommandLine != "" {
		// Native app
		runtime.WindowHide(a.ctx)
		err := a.server.LaunchApp(app.CommandLine, profileID)
		if err != nil {
			runtime.WindowShow(a.ctx)
		}
		return err
	}
	return nil
}

// CloseBrowser closes the running browser
func (a *App) CloseBrowser() {
	a.server.CloseBrowser()
	runtime.WindowShow(a.ctx)
}

// Quit closes the application
func (a *App) Quit() {
	a.server.CloseBrowser()
	a.server.StopPlayer()
	runtime.Quit(a.ctx)
}

// GetVersion returns version info
func (a *App) GetVersion() map[string]string {
	return map[string]string{
		"version": version,
		"commit":  commit,
		"build":   buildDate,
	}
}

// GetServerPort returns the HTTP server port
func (a *App) GetServerPort() int {
	return a.server.GetPort()
}

// GetLogoPath returns the logo image path
func (a *App) GetLogoPath() string {
	return filepath.Join(a.server.assetDir, "images", "launch-tube-logo", "logo_wide.png")
}

// ServiceTemplate represents a streaming service from the library
type ServiceTemplate struct {
	Name       string   `json:"name"`
	URL        string   `json:"url"`
	MatchURLs  []string `json:"matchUrls,omitempty"`
	ColorValue int      `json:"colorValue"`
	LogoPath   string   `json:"logoPath,omitempty"`
}

// CreateProfile creates a new profile
func (a *App) CreateProfile(displayName string, colorValue int) (Profile, error) {
	// Check for duplicate name (case-insensitive)
	profiles := a.GetProfiles()
	nameLower := strings.ToLower(displayName)
	for _, p := range profiles {
		if strings.ToLower(p.DisplayName) == nameLower {
			return Profile{}, fmt.Errorf("a user with this name already exists")
		}
	}

	// Generate ID from display name
	id := strings.ToLower(strings.ReplaceAll(displayName, " ", "-"))
	id = strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			return r
		}
		return -1
	}, id)

	profileDir := filepath.Join(a.server.dataDir, "profiles", id)
	if err := os.MkdirAll(profileDir, 0755); err != nil {
		return Profile{}, err
	}

	order := len(profiles)

	profile := Profile{
		ID:          id,
		DisplayName: displayName,
		ColorValue:  colorValue,
		Order:       order,
	}

	data, err := json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return Profile{}, err
	}

	profilePath := filepath.Join(profileDir, "profile.json")
	if err := os.WriteFile(profilePath, data, 0644); err != nil {
		return Profile{}, err
	}

	// Create empty apps.json
	appsPath := filepath.Join(profileDir, "apps.json")
	os.WriteFile(appsPath, []byte("[]"), 0644)

	Log("Created profile: %s (%s)", displayName, id)
	return profile, nil
}

// UpdateProfile updates an existing profile
func (a *App) UpdateProfile(id string, displayName string, colorValue int, photoPath string, order int) error {
	// Check for duplicate name (case-insensitive), excluding current profile
	profiles := a.GetProfiles()
	nameLower := strings.ToLower(displayName)
	for _, p := range profiles {
		if p.ID != id && strings.ToLower(p.DisplayName) == nameLower {
			return fmt.Errorf("a user with this name already exists")
		}
	}

	profileDir := filepath.Join(a.server.dataDir, "profiles", id)
	profilePath := filepath.Join(profileDir, "profile.json")

	data, err := os.ReadFile(profilePath)
	if err != nil {
		return err
	}

	var profile Profile
	if err := json.Unmarshal(data, &profile); err != nil {
		return err
	}

	profile.DisplayName = displayName
	profile.ColorValue = colorValue
	profile.Order = order
	if photoPath != "" {
		// Store just the filename, not full path
		profile.PhotoPath = filepath.Base(photoPath)
	}

	data, err = json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return err
	}

	Log("Updated profile: %s (order: %d)", id, order)
	return os.WriteFile(profilePath, data, 0644)
}

// DeleteProfile deletes a profile
func (a *App) DeleteProfile(id string) error {
	// Don't allow deleting the last profile
	profiles := a.GetProfiles()
	if len(profiles) <= 1 {
		return fmt.Errorf("cannot delete the last profile")
	}

	profileDir := filepath.Join(a.server.dataDir, "profiles", id)
	Log("Deleting profile: %s", id)
	return os.RemoveAll(profileDir)
}

// GetProfilePhotos returns available profile photos
func (a *App) GetProfilePhotos() []string {
	photosDir := filepath.Join(a.server.assetDir, "images", "profile-photos")
	entries, err := os.ReadDir(photosDir)
	if err != nil {
		return []string{}
	}

	var photos []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		ext := strings.ToLower(filepath.Ext(name))
		if ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".webp" {
			photos = append(photos, filepath.Join(photosDir, name))
		}
	}
	return photos
}

// GetMpvPaths returns available mpv installations
func (a *App) GetMpvPaths() []string {
	candidates := []string{"mpv"}
	if goruntime.GOOS == "windows" {
		candidates = append(candidates,
			`C:\Program Files\mpv\mpv.exe`,
			`C:\Program Files (x86)\mpv\mpv.exe`,
		)
	}

	var found []string
	for _, path := range candidates {
		if _, err := exec.LookPath(path); err == nil {
			found = append(found, path)
		}
	}
	return found
}

// GetSelectedMpv returns the currently selected mpv path
func (a *App) GetSelectedMpv() string {
	return a.server.player.GetMpvPath()
}

// SetSelectedMpv sets the mpv path
func (a *App) SetSelectedMpv(path string) {
	a.server.player.SetMpvPath(path)
}

// GetMpvOptions returns custom mpv options
func (a *App) GetMpvOptions() string {
	return a.server.player.GetMpvOptions()
}

// SetMpvOptions sets custom mpv options
func (a *App) SetMpvOptions(options string) {
	a.server.player.SetMpvOptions(options)
}

// GetServiceLibrary returns available streaming services
func (a *App) GetServiceLibrary() []ServiceTemplate {
	servicesDir := filepath.Join(a.server.assetDir, "services")
	entries, err := os.ReadDir(servicesDir)
	if err != nil {
		Log("Failed to read services dir: %v", err)
		return []ServiceTemplate{}
	}

	var services []ServiceTemplate
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		name := entry.Name()
		if filepath.Ext(name) != ".json" {
			continue
		}

		jsonPath := filepath.Join(servicesDir, name)
		data, err := os.ReadFile(jsonPath)
		if err != nil {
			continue
		}

		var service ServiceTemplate
		if err := json.Unmarshal(data, &service); err != nil {
			continue
		}

		// Check for logo
		baseName := name[:len(name)-5] // Remove .json
		for _, ext := range []string{".png", ".jpg", ".svg"} {
			logoPath := filepath.Join(servicesDir, baseName+ext)
			if _, err := os.Stat(logoPath); err == nil {
				service.LogoPath = logoPath
				break
			}
		}

		services = append(services, service)
	}

	return services
}
