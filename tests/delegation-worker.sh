#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
python3 tests/delegation-server.py "$TEST_DIR/port" > "$TEST_DIR/http.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/Delegation.swift Sources/Clinqy/SourceCache.swift Sources/Clinqy/DelegationWorker.swift Sources/Clinqy/Secrets.swift tests/DelegationWorkerTests.swift -o "$TEST_DIR/worker-tests"
"$TEST_DIR/worker-tests" "http://127.0.0.1:$(cat "$TEST_DIR/port")"
