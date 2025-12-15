VERSION := 1.1.0
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE := $(shell date -u +"%Y-%m-%d" 2>/dev/null || echo unknown)

WAILS := /usr/local/src/golang/bin/wails
LDFLAGS := -X main.version=$(VERSION) -X main.commit=$(GIT_COMMIT) -X main.buildDate=$(BUILD_DATE)

.PHONY: build linux windows dev clean

build: linux

linux:
	$(WAILS) build -tags webkit2_41 -ldflags "$(LDFLAGS)"

windows:
	$(WAILS) build -platform windows/amd64 -ldflags "$(LDFLAGS)"

dev:
	$(WAILS) dev -tags webkit2_41

clean:
	rm -rf build/bin/*
	rm -rf frontend/dist
	rm -rf frontend/node_modules

run: linux
	./build/bin/launchtube-wails
