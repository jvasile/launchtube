# Use bash explicitly (works on Linux and Windows with Git for Windows)
SHELL := bash

VERSION := $(shell grep '^version:' pubspec.yaml | sed 's/version: //' | sed 's/+.*//')
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")$(shell git diff --quiet 2>/dev/null || echo "+")
BUILD_DATE := $(shell date -u +"%Y-%m-%d")

DART_DEFINES := --dart-define=APP_VERSION=$(VERSION) \
                --dart-define=GIT_COMMIT=$(GIT_COMMIT) \
                --dart-define=BUILD_DATE=$(BUILD_DATE)

.PHONY: build linux windows clean run

build: linux

linux:
	@echo "Building Launch Tube for Linux"
	@echo "  Version: $(VERSION)"
	@echo "  Commit:  $(GIT_COMMIT)"
	@echo "  Date:    $(BUILD_DATE)"
	@echo
	flutter build linux $(DART_DEFINES)

windows:
	@echo "Building Launch Tube for Windows"
	@echo "  Version: $(VERSION)"
	@echo "  Commit:  $(GIT_COMMIT)"
	@echo "  Date:    $(BUILD_DATE)"
	@echo
	flutter build windows $(DART_DEFINES)

run:
	flutter run $(DART_DEFINES)

clean:
	flutter clean
