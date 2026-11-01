#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
python3 tests/delegation-server.py "$TEST_DIR/port" > "$TEST_DIR/http.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT
for attempt in {1..100}; do
  [[ -s "$TEST_DIR/port" ]] && break
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
if [[ ! -s "$TEST_DIR/port" ]]; then
  echo "FAIL: efficiency HTTP fixture did not start" >&2
  cat "$TEST_DIR/http.log" >&2
  exit 1
fi
swiftc Sources/Clinqy/ActionOutcome.swift Sources/Clinqy/TaskContext.swift -O -parse-as-library Sources/Clinqy/SQLiteDatabase.swift Sources/Clinqy/TaskStore.swift Sources/Clinqy/SourceCache.swift Sources/Clinqy/ProcessRunner.swift Sources/Clinqy/ModelStream.swift Sources/Clinqy/Secrets.swift tests/EfficiencyTests.swift -o "$TEST_DIR/efficiency-tests"
"$TEST_DIR/efficiency-tests" "http://127.0.0.1:$(cat "$TEST_DIR/port")/sse"
