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

.PHONY: all build test release app install uninstall clean

all: build

build:
	swift build

test:
	swift run smbkeeper-tests

release:
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
