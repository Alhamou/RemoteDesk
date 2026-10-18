#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/RemoteDesk.app"
BIN=".build/release/RemoteDesk"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/RemoteDesk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Find a valid code signing identity (e.g. Apple Development)
# This prevents macOS from revoking TCC permissions (Screen Recording / Accessibility) on every rebuild.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | grep "Apple Development" | grep -v "REVOKED" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi

if [[ -n "$IDENTITY" ]]; then
    echo "Signing with identity: $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "Notice: No valid Apple Development certificate found, signing ad-hoc (-)"
    codesign --force --sign - --timestamp=none "$APP"
fi

if [[ -d "/Applications/RemoteDesk.app" ]]; then
    echo "Updating /Applications/RemoteDesk.app..."
    rm -rf /Applications/RemoteDesk.app
    cp -R "$APP" /Applications/RemoteDesk.app
fi

echo "Built $APP"
echo "Run with: open \"$APP\" or \"./$APP/Contents/MacOS/RemoteDesk --help\""

