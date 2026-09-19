# SMB Keeper — build without Xcode.
#
#   make            debug build
#   make test       run the custom test harness (no XCTest)
#   make release    optimised build in .build/release
#   make app        assemble build/SMB Keeper.app (ad-hoc signed)
#   make install    copy the app to ~/Applications and start it at login
#   make uninstall  remove the launch agent and the app (config and logs stay)

PREFIX ?= $(HOME)
APPDIR ?= $(PREFIX)/Applications
APP     = build/SMB Keeper.app
EXE     = $(APPDIR)/SMB Keeper.app/Contents/MacOS/SMBKeeperApp

.PHONY: all build test release app install uninstall clean check-state

all: build

# @State is a macro in the macOS 27 SDK and its plugin ships only with Xcode,
# so it does not build with the Command Line Tools. Use @ViewState instead
# (Sources/SMBKeeperApp/ViewState.swift). This check stops a machine that has
# Xcode from letting one back in.
check-state:
	@if grep -rnE '^[^/]*@State([^A-Za-z0-9_]|$$)' Sources/ >/dev/null; then \
	  echo "error: '@State' does not build with the Command Line Tools; use '@ViewState' instead:" >&2; \
	  grep -rnE '^[^/]*@State([^A-Za-z0-9_]|$$)' Sources/ >&2; \
	  exit 1; \
	fi

build: check-state
	swift build

test: check-state
	swift run smbkeeper-tests

release: check-state
	swift build -c release

app:
	scripts/make-app.sh build

install: app
	mkdir -p "$(APPDIR)"
	rm -rf "$(APPDIR)/SMB Keeper.app"
	cp -R "$(APP)" "$(APPDIR)/"
	"$(EXE)" --install-agent
	@echo ""
	@echo "NOTE: this build has a new ad-hoc code signature, so macOS treats it as"
	@echo "a new app and asks again for access to network volumes. Approve the"
	@echo "prompt, or allow SMB Keeper under System Settings > Privacy & Security >"
	@echo "Files and Folders. Until then every share reads 'stale / never answered"
	@echo "since startup' and nothing is unmounted. Set CODESIGN_IDENTITY to a"
	@echo "Developer ID to keep the identity, and the approval, stable."

uninstall:
	-"$(EXE)" --uninstall-agent
	rm -rf "$(APPDIR)/SMB Keeper.app"

clean:
	rm -rf .build build
