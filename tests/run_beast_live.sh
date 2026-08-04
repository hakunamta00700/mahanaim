#!/usr/bin/env sh
## Run the Linux-only httpx server and a real TCP/WebSocket client together.
set -eu

marker="/tmp/mahanaim-beast-live-$$.marker"
log="/tmp/mahanaim-beast-live-$$.log"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    ## httpx's event loop has no public stop API; terminate only this fixture
    ## process after the session-level graceful close has been observed.
    kill -KILL "$server_pid" 2>/dev/null || true
  fi
  rm -f "$marker" "$log"
}
trap cleanup EXIT INT TERM

MAHANAIM_BEAST_MARKER="$marker" ./tests/test_beast_live server >"$log" 2>&1 &
server_pid=$!
sleep 1

passed=false
attempt=0
while [ "$attempt" -lt 3 ]; do
  if MAHANAIM_BEAST_MARKER="$marker" timeout 3 ./tests/test_beast_live client; then
    passed=true
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$log"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done

if [ "$passed" != true ]; then
  cat "$log"
  exit 1
fi

test -f "$marker"
