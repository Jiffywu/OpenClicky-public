#!/bin/zsh
# Build OpenClicky.app from the SwiftPM products and sign it.
#   scripts/build-app.sh [debug|release]
# OPENCLICKY_APP_PATH writes an isolated bundle without replacing a running dist/OpenClicky.app.
# Signing identity: $OPENCLICKY_SIGN_IDENTITY, else the local "OpenClicky Local Signing" identity
# (scripts/make-signing-identity.sh creates it; codesign uses it without a Keychain prompt), else ad hoc.
# A stable identity keeps macOS permissions (microphone, screen recording, accessibility) across rebuilds;
# ad hoc signing makes macOS ask again after every build.
set -euo pipefail
ROOT=${0:A:h:h}
CONFIG=${1:-release}
cd "$ROOT"

# Validate the replacement target before compiling or removing anything.
APP=${OPENCLICKY_APP_PATH:-"$ROOT/dist/OpenClicky.app"}
if [[ -L "$APP" ]]; then
  print -u2 "Refusing to replace a symlink: $APP"
  exit 2
fi
APP=${APP:a}
if [[ ${APP:t} != OpenClicky.app ]]; then
  print -u2 "OPENCLICKY_APP_PATH must name an OpenClicky.app bundle: $APP"
  exit 2
fi
if [[ -e "$APP" ]]; then
  BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null) || BUNDLE_ID=""
  if [[ ! -d "$APP" || "$BUNDLE_ID" != com.openclicky.app ]]; then
    print -u2 "Refusing to replace a path that is not an OpenClicky app bundle: $APP"
    exit 2
  fi
fi

swift build --jobs 2 -c "$CONFIG" --product OpenClicky
swift build --jobs 2 -c "$CONFIG" --product occtl
swift build --jobs 2 -c "$CONFIG" --product OpenClickyBrowserHost
BIN=$(swift build --jobs 2 -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OpenClicky" "$APP/Contents/MacOS/OpenClicky"
cp "$BIN/occtl" "$APP/Contents/MacOS/occtl"
mkdir -p "$APP/Contents/Helpers" && cp "$BIN/OpenClickyBrowserHost" "$APP/Contents/Helpers/OpenClickyBrowserHost"
# The unpacked Chrome extension (Settings → Browser copies it to Application Support for Load unpacked); never its tests.
rsync -a --exclude tests --exclude '.*' "$ROOT/Extension/chrome/" "$APP/Contents/Resources/BrowserExtension/"
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
[[ -d "$ROOT/Resources/App" ]] && cp -R "$ROOT/Resources/App/." "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.openclicky.app</string>
	<key>CFBundleName</key><string>OpenClicky</string>
	<key>CFBundleDisplayName</key><string>OpenClicky</string>
	<key>CFBundleIconFile</key><string>AppIcon.icns</string>
	<key>CFBundleExecutable</key><string>OpenClicky</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>OpenClickyGitDescribe</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>OpenClicky listens while you hold the talk keys so you can talk to it.</string>
	<key>NSSpeechRecognitionUsageDescription</key><string>OpenClicky can transcribe your voice on this Mac with Apple Speech.</string>
	<key>NSScreenCaptureUsageDescription</key><string>OpenClicky looks at your screen when you ask it about what you see.</string>
	<key>NSCalendarsFullAccessUsageDescription</key><string>OpenClicky checks and adds calendar events when you ask, and shows a countdown before your next meeting.</string>
	<key>NSAppleEventsUsageDescription</key><string>OpenClicky reads the document you're viewing so it can answer about the whole file.</string>
	<key>NSDesktopFolderUsageDescription</key><string>OpenClicky reads the document you're viewing so it can answer about the whole file.</string>
	<key>NSDocumentsFolderUsageDescription</key><string>OpenClicky reads the document you're viewing so it can answer about the whole file.</string>
	<key>NSDownloadsFolderUsageDescription</key><string>OpenClicky reads the document you're viewing so it can answer about the whole file.</string>
	<key>CFBundleURLTypes</key>
	<array><dict><key>CFBundleURLName</key><string>com.openclicky.app</string><key>CFBundleURLSchemes</key><array><string>openclicky</string></array></dict></array>
</dict>
</plist>
PLIST

LOCAL_KC="$HOME/Library/Keychains/openclicky-signing.keychain-db"
if [[ -z "${OPENCLICKY_SIGN_IDENTITY:-}" && -f "$LOCAL_KC" ]]; then
  security unlock-keychain -p openclicky-local "$LOCAL_KC"
  LOCAL_ID=$(security find-identity -p codesigning "$LOCAL_KC" | sed -nE 's/^ *1\) ([0-9A-F]{40}) "OpenClicky Local Signing".*/\1/p' | head -1)
fi
IDENTITY=${OPENCLICKY_SIGN_IDENTITY:-${LOCAL_ID:--}}
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/occtl"
codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/OpenClickyBrowserHost"
codesign --force --sign "$IDENTITY" --entitlements "$ROOT/scripts/OpenClicky.entitlements" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed: $IDENTITY)"
