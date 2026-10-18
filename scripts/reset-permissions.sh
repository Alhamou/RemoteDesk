#!/usr/bin/env bash
set -euo pipefail

echo "Resetting Screen Recording and Accessibility permissions for local.remotedesk..."

tccutil reset ScreenCapture local.remotedesk || true
tccutil reset Accessibility local.remotedesk || true
tccutil reset ListenEvent local.remotedesk || true
tccutil reset PostEvent local.remotedesk || true

echo "Permissions have been reset."
echo "Launch RemoteDesk and click 'Share This Mac' to request fresh permissions."
