package main

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// EnsureAssets downloads and extracts assets from the repo if not present
func EnsureAssets(dataDir string) error {
	assetDir := filepath.Join(dataDir, "assets")
	markerFile := filepath.Join(assetDir, ".commit")

	// Check if assets already exist for this commit
	if data, err := os.ReadFile(markerFile); err == nil {
		if strings.TrimSpace(string(data)) == commit {
			Log("Assets already present for commit %s", commit)
			return nil
		}
		Log("Assets are from different commit, re-downloading...")
	}

	// Need to download assets
	if repoURL == "unknown" || commit == "unknown" {
		return fmt.Errorf("cannot download assets: repoURL or commit not set at build time")
	}

	tarballURL := fmt.Sprintf("%s/archive/%s.tar.gz", repoURL, commit)
	Log("Downloading assets from %s", tarballURL)

	resp, err := http.Get(tarballURL)
	if err != nil {
		return fmt.Errorf("failed to download assets: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("failed to download assets: HTTP %d", resp.StatusCode)
	}

	// Extract tarball
	if err := extractAssets(resp.Body, assetDir); err != nil {
		return fmt.Errorf("failed to extract assets: %w", err)
	}

	// Write marker file
	if err := os.WriteFile(markerFile, []byte(commit), 0644); err != nil {
		Log("Warning: failed to write commit marker: %v", err)
	}

	Log("Assets extracted successfully")
	return nil
}

func extractAssets(r io.Reader, destDir string) error {
	gzr, err := gzip.NewReader(r)
	if err != nil {
		return err
	}
	defer gzr.Close()

	tr := tar.NewReader(gzr)

	// The tarball extracts to {repo}-{commit}/hot-assets/...
	// We want to map hot-assets/* to destDir/*
	var prefix string

	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		// Find the prefix (first component + hot-assets/)
		if prefix == "" {
			parts := strings.SplitN(header.Name, "/", 3)
			if len(parts) >= 2 && parts[1] == "hot-assets" {
				prefix = parts[0] + "/hot-assets/"
			}
			continue
		}

		// Only extract files under hot-assets/
		if !strings.HasPrefix(header.Name, prefix) {
			continue
		}

		// Get relative path under hot-assets/
		relPath := strings.TrimPrefix(header.Name, prefix)
		if relPath == "" {
			continue
		}

		targetPath := filepath.Join(destDir, relPath)

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(targetPath, 0755); err != nil {
				return err
			}

		case tar.TypeReg:
			// Ensure parent directory exists
			if err := os.MkdirAll(filepath.Dir(targetPath), 0755); err != nil {
				return err
			}

			outFile, err := os.Create(targetPath)
			if err != nil {
				return err
			}

			if _, err := io.Copy(outFile, tr); err != nil {
				outFile.Close()
				return err
			}
			outFile.Close()

			// Preserve executable bit
			if header.Mode&0111 != 0 {
				os.Chmod(targetPath, 0755)
			}
		}
	}

	return nil
}
