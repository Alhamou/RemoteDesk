#!/usr/bin/env bash
set -euo pipefail

# scripts/make-app.sh
# Builds a universal macOS application bundle for RemoteDesk.

cd "$(dirname "$0")/.."

VERSION="${VERSION:-${1:-1.1.0}}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
INSTALL="${INSTALL:-0}"

echo "==> Building RemoteDesk v${VERSION} (universal arm64 + x86_64)..."

# Build universal release binary using lipo. Each slice is copied out right
# after its build: the output directory differs between Swift versions (ask
# SwiftPM with --show-bin-path), and some layouts share one directory for
# every architecture, so the next build would overwrite it.
mkdir -p .build/universal
for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH"
    BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
    cp "$BIN_DIR/RemoteDesk" ".build/universal/RemoteDesk-$ARCH"
done
lipo -create -output .build/universal/RemoteDesk \
    .build/universal/RemoteDesk-arm64 \
    .build/universal/RemoteDesk-x86_64
lipo -info .build/universal/RemoteDesk

# Spotlight skips folders ending in .noindex, so this build copy does not show
# up next to the installed /Applications/RemoteDesk.app.
APP="build/RemoteDesk.noindex/RemoteDesk.app"
BIN=".build/universal/RemoteDesk"

if [[ ! -f "$BIN" ]]; then
    if [[ -f ".build/apple/Products/Release/RemoteDesk" ]]; then
        BIN=".build/apple/Products/Release/RemoteDesk"
    elif [[ -f ".build/release/RemoteDesk" ]]; then
        BIN=".build/release/RemoteDesk"
    else
        echo "Error: Compiled binary not found." >&2
        exit 1
    fi
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
IS_DEV_ID=0

if [[ -z "$IDENTITY" ]]; then
    CERT_LINE=$(security find-identity -p codesigning -v 2>/dev/null | grep -E "Developer ID Application|Apple Development" | grep -v "REVOKED" | head -n 1 || true)
    if [[ -n "$CERT_LINE" ]]; then
        IDENTITY=$(echo "$CERT_LINE" | awk '{print $2}')
        if echo "$CERT_LINE" | grep -q "Developer ID Application"; then
            IS_DEV_ID=1
        fi
    fi
elif [[ "$IDENTITY" == *"Developer ID Application"* ]]; then
    IS_DEV_ID=1
fi

if [[ -n "$IDENTITY" ]]; then
    if [[ "$IS_DEV_ID" == "1" ]]; then
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
