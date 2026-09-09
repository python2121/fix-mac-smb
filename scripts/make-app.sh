#!/bin/sh
# Assemble "SMB Keeper.app" from the SwiftPM release build. No Xcode project.
#
#   scripts/make-app.sh [output-dir]      default: ./build
#
# The bundle is ad-hoc signed, which is enough for a personal tool. Replace
# "-" with a Developer ID identity in CODESIGN_IDENTITY to distribute it.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/SMB Keeper.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)"

cd "$ROOT"
swift build -c release --product SMBKeeperApp
swift build -c release --product smbkeeper
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SMBKeeperApp" "$APP/Contents/MacOS/SMBKeeperApp"
cp "$BIN/smbkeeper" "$APP/Contents/MacOS/smbkeeper"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>SMBKeeperApp</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.smbkeeper</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>SMB Keeper</string>
	<key>CFBundleDisplayName</key>
	<string>SMB Keeper</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSNetworkVolumesUsageDescription</key>
	<string>SMB Keeper checks that your network volumes are still responding, and remounts them when they are not.</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>SMB Keeper checks that mounted volumes are still responding.</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>SMB Keeper does not read your Desktop; this is required only because mounted volumes can appear there.</string>
	<key>NSHumanReadableCopyright</key>
	<string>MIT</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/MacOS/smbkeeper"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "built: $APP"
