# SMB Keeper — build without Xcode.
#
#   make            debug build
#   make test       run the custom test harness (no XCTest)
#   make release    optimised binaries in .build/release
#   make app        assemble build/SMB Keeper.app (ad-hoc signed)
#   make install    copy the app to ~/Applications, link the CLI into ~/bin,
#                   and register the launch agent so it starts at login
#   make uninstall  remove the launch agent, app, and CLI link (config and logs stay)
#   make integration  live checks against the configured NAS (needs a config)

PREFIX ?= $(HOME)
APPDIR ?= $(PREFIX)/Applications
BINDIR ?= $(PREFIX)/bin
APP     = build/SMB Keeper.app

.PHONY: all build test release app install uninstall integration clean

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
	mkdir -p "$(APPDIR)" "$(BINDIR)"
	rm -rf "$(APPDIR)/SMB Keeper.app"
	cp -R "$(APP)" "$(APPDIR)/"
	ln -sf "$(APPDIR)/SMB Keeper.app/Contents/MacOS/smbkeeper" "$(BINDIR)/smbkeeper"
	"$(BINDIR)/smbkeeper" install-agent --app "$(APPDIR)/SMB Keeper.app"
	@echo ""
	@echo "installed. Put $(BINDIR) on your PATH if it is not already."
	@echo ""
	@echo "NOTE: this build has a new ad-hoc code signature, so macOS treats it as"
	@echo "a new app and asks again for access to network volumes. Approve the"
	@echo "prompt, or allow SMB Keeper under System Settings > Privacy & Security >"
	@echo "Files and Folders. Until then every share reads 'stale / never answered"
	@echo "since startup' and nothing is unmounted. Set CODESIGN_IDENTITY to a"
	@echo "Developer ID to keep the identity, and the approval, stable."

uninstall:
	-"$(BINDIR)/smbkeeper" uninstall-agent
	rm -f "$(BINDIR)/smbkeeper"
	rm -rf "$(APPDIR)/SMB Keeper.app"

integration: build
	scripts/integration.sh

clean:
	rm -rf .build build
