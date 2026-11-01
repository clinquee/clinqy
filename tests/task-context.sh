#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/Clinqy/SQLiteDatabase.swift -parse-as-library Sources/Clinqy/TaskContext.swift Sources/Clinqy/ActionOutcome.swift Sources/Clinqy/TaskStore.swift tests/TaskContextTests.swift -o "$TEST_DIR/context-tests"
"$TEST_DIR/context-tests"
