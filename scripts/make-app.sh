#!/usr/bin/env bash
set -euo pipefail

# scripts/make-app.sh
# Builds a universal macOS application bundle for RemoteDesk.

cd "$(dirname "$0")/.."

VERSION="${VERSION:-${1:-1.0.0}}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
INSTALL="${INSTALL:-0}"

echo "==> Building RemoteDesk v${VERSION} (universal arm64 + x86_64)..."

# Build universal release binary
swift build -c release --arch arm64 --arch x86_64

APP="build/RemoteDesk.app"
BIN_UNIVERSAL=".build/apple/Products/Release/RemoteDesk"
BIN_SINGLE=".build/release/RemoteDesk"

if [[ -f "$BIN_UNIVERSAL" ]]; then
    BIN="$BIN_UNIVERSAL"
elif [[ -f "$BIN_SINGLE" ]]; then
    BIN="$BIN_SINGLE"
else
    echo "Error: Compiled binary not found." >&2
    exit 1
fi

echo "==> Assembling app bundle at $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/RemoteDesk"
chmod +x "$APP/Contents/MacOS/RemoteDesk"

# Copy and update Info.plist
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" 2>/dev/null || \
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" 2>/dev/null || \
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Code signing
# If CODESIGN_IDENTITY is provided, use it (with hardened runtime for Developer ID)
# Otherwise check for a local Apple Development certificate to keep TCC permissions stable
# Fall back to ad-hoc signing (-)
IDENTITY="${CODESIGN_IDENTITY:-}"

if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | grep "Apple Development" | grep -v "REVOKED" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
fi

if [[ -n "$IDENTITY" ]]; then
    if [[ "$IDENTITY" == *"Developer ID Application"* ]]; then
        echo "==> Signing with Developer ID Application: $IDENTITY (Hardened Runtime)"
        codesign --force --options runtime --sign "$IDENTITY" --timestamp "$APP"
    else
        echo "==> Signing with development identity: $IDENTITY"
        codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
    fi
else
    echo "==> Notice: No signing identity specified or found. Signing ad-hoc (-)..."
    codesign --force --sign - --timestamp=none "$APP"
fi

# Optional local installation to /Applications (or automatic update if already present)
if [[ "$INSTALL" == "1" || "${1:-}" == "--install" || -d "/Applications/RemoteDesk.app" ]]; then
    echo "==> Updating /Applications/RemoteDesk.app..."
    rm -rf /Applications/RemoteDesk.app
    cp -R "$APP" /Applications/RemoteDesk.app
    touch /Applications/RemoteDesk.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/RemoteDesk.app 2>/dev/null || true
fi

# Re-register build bundle with LaunchServices so Finder and Dock update icon
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "==> Successfully built $APP (v${VERSION})"
