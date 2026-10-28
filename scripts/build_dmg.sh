#!/usr/bin/env bash
set -euo pipefail

# scripts/build_dmg.sh
# Builds the universal app bundle and packages it into a release DMG with checksum.

cd "$(dirname "$0")/.."

VERSION="${VERSION:-${1:-1.1.0}}"
APP_PATH="build/RemoteDesk.noindex/RemoteDesk.app"
DMG_NAME="RemoteDesk-${VERSION}.dmg"
DMG_PATH="build/${DMG_NAME}"
SHA_PATH="build/${DMG_NAME}.sha256"

# 1. Build the app bundle
./scripts/make-app.sh "$VERSION"

echo "==> Creating disk image: $DMG_PATH..."
rm -f "$DMG_PATH" "$SHA_PATH"

# 2. Check for create-dmg; fall back to native hdiutil if absent
if command -v create-dmg >/dev/null 2>&1; then
    echo "==> Using create-dmg for styled disk image..."
    VOLICON_ARGS=()
    if [[ -f "Resources/AppIcon.icns" ]]; then
        VOLICON_ARGS=(--volicon "Resources/AppIcon.icns")
    fi

    set +e
    create-dmg \
        --volname "RemoteDesk" \
        "${VOLICON_ARGS[@]}" \
        --window-pos 200 120 \
        --window-size 640 400 \
        --icon-size 120 \
        --icon "RemoteDesk.app" 180 190 \
        --hide-extension "RemoteDesk.app" \
        --app-drop-link 460 190 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$APP_PATH"
    STATUS=$?
    set -e

    # create-dmg exits 2 on non-fatal warnings (e.g., Finder window sizing quirks)
    if [[ $STATUS -ne 0 && $STATUS -ne 2 ]]; then
        echo "Warning: create-dmg failed (code $STATUS). Falling back to hdiutil..."
        rm -f "$DMG_PATH"
        USE_HDIUTIL=1
    else
        USE_HDIUTIL=0
    fi
else
    USE_HDIUTIL=1
fi

if [[ "${USE_HDIUTIL:-0}" -eq 1 ]]; then
    echo "==> Using native hdiutil to create DMG..."
    TMP_STAGE=$(mktemp -d -t remotedesk-stage)
    cleanup_stage() { rm -rf "$TMP_STAGE"; }
    trap cleanup_stage EXIT

    cp -R "$APP_PATH" "$TMP_STAGE/"
    ln -s /Applications "$TMP_STAGE/Applications"

    hdiutil create \
        -volname "RemoteDesk" \
        -srcfolder "$TMP_STAGE" \
        -ov \
        -format UDZO \
        "$DMG_PATH"

    trap - EXIT
    cleanup_stage
fi

# 3. Optional Notarization & Stapling (if credentials configured)
KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
if [[ -n "$KEYCHAIN_PROFILE" ]]; then
    echo "==> Submitting DMG to Apple Notary Service (profile: $KEYCHAIN_PROFILE)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    echo "==> Stapling notarization ticket to DMG..."
    xcrun stapler staple "$DMG_PATH"
fi

# 4. Generate SHA256 checksum
echo "==> Calculating SHA256 checksum..."
(cd build && shasum -a 256 "$DMG_NAME" > "${DMG_NAME}.sha256")

echo "=========================================="
echo "Successfully generated DMG release bundle:"
echo "DMG:      $DMG_PATH"
echo "Checksum: $(cat "$SHA_PATH")"
echo "=========================================="
