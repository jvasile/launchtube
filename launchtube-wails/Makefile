VERSION := 1.1.0
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE := $(shell date -u +"%Y-%m-%d" 2>/dev/null || echo unknown)

LDFLAGS := -X main.version=$(VERSION) -X main.commit=$(GIT_COMMIT) -X main.buildDate=$(BUILD_DATE)

.PHONY: build linux windows dev clean install-wails

build: linux

install-wails:
	@which wails > /dev/null || go install github.com/wailsapp/wails/v2/cmd/wails@latest

linux: install-wails
	wails build -tags webkit2_41 -ldflags "$(LDFLAGS)"

windows: install-wails
	wails build -platform windows/amd64 -ldflags "$(LDFLAGS)"

dev: install-wails
	wails dev -tags webkit2_41

clean:
	rm -rf build/bin/*
	rm -rf frontend/dist
	rm -rf frontend/node_modules

run: linux
	./build/bin/launchtube-wails
