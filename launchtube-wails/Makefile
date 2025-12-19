VERSION := 1.1.0
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE := $(shell date -u +"%Y-%m-%d" 2>/dev/null || echo unknown)

LDFLAGS := -X main.version=$(VERSION) -X main.commit=$(GIT_COMMIT) -X main.buildDate=$(BUILD_DATE)

.PHONY: build linux windows dev clean install-wails copy-assets

build: linux

install-wails:
	@which wails > /dev/null || go install github.com/wailsapp/wails/v2/cmd/wails@latest

copy-assets:
	@mkdir -p assets/services assets/images/launchtube-logo assets/images/profile-photos
	@cp -u ../hot-assets/services/*.webp ../hot-assets/services/*.png ../hot-assets/services/*.jpg ../hot-assets/services/*.svg assets/services/ 2>/dev/null || true
	@cp -u ../hot-assets/services/*.json ../hot-assets/services/*.js assets/services/ 2>/dev/null || true
	@cp -u ../hot-assets/setup.html assets/
	@cp -u ../hot-assets/images/launchtube-logo/*.svg ../hot-assets/images/launchtube-logo/*.webp assets/images/launchtube-logo/ 2>/dev/null || true
	@cp -u ../hot-assets/images/profile-photos/*.webp assets/images/profile-photos/ 2>/dev/null || true

linux: install-wails copy-assets
	wails build -tags webkit2_41 -ldflags "$(LDFLAGS)"

windows: install-wails copy-assets
	wails build -platform windows/amd64 -ldflags "$(LDFLAGS)"

dev: install-wails copy-assets
	wails dev -tags webkit2_41

clean:
	rm -rf build/bin/*
	rm -rf frontend/dist
	rm -rf frontend/node_modules
	rm -rf assets

run: linux
	./build/bin/launchtube-wails
