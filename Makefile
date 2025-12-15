VERSION := 1.1.0
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE := $(shell date -u +"%Y-%m-%d" 2>/dev/null || echo unknown)

DART_DEFINES := --dart-define=APP_VERSION=$(VERSION) \
                --dart-define=GIT_COMMIT=$(GIT_COMMIT) \
                --dart-define=BUILD_DATE=$(BUILD_DATE)

GO_LDFLAGS := -X main.version=$(VERSION) -X main.commit=$(GIT_COMMIT) -X main.buildDate=$(BUILD_DATE)

.PHONY: build linux windows clean run

build: linux

linux:
	flutter build linux $(DART_DEFINES)
	cd server && GOOS=linux GOARCH=amd64 go build -ldflags "$(GO_LDFLAGS)" -o launchtube-server .

windows:
	flutter build windows $(DART_DEFINES)
	cd server && GOOS=windows GOARCH=amd64 go build -ldflags "$(GO_LDFLAGS)" -o launchtube-server.exe .

run:
	flutter run $(DART_DEFINES)

clean:
	flutter clean
