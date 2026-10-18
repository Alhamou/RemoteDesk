#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build

BIN=".build/debug/RemoteDesk"

echo "== self-test =="
"$BIN" --self-test

echo "== e2e: host + client over loopback =="
TMP="$(mktemp -d)"
HOST_PID=""
cleanup() {
  if [[ -n "$HOST_PID" ]]; then
    kill "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

"$BIN" --host --test-pattern --no-ui --port 8799 >"$TMP/host.log" 2>&1 &
HOST_PID=$!

READY=0
for _ in $(seq 1 50); do
  if grep -q "HOST READY" "$TMP/host.log" 2>/dev/null; then
    READY=1
    break
  fi
  if ! kill -0 "$HOST_PID" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

if [[ "$READY" != "1" ]]; then
  echo "host did not become ready; host log:" >&2
  cat "$TMP/host.log" >&2 || true
  exit 1
fi

"$BIN" --client --connect 127.0.0.1:8799 --headless --no-ui --expect-frames 30 --timeout 20

echo "E2E: PASS"
