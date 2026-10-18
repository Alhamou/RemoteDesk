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

codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP"
echo "Run with: open \"$APP\" or \"./$APP/Contents/MacOS/RemoteDesk --help\""
