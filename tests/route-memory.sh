#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/SQLiteDatabase.swift Sources/Clinqy/ProcedureStore.swift Sources/Clinqy/TaskMemory.swift Sources/Clinqy/Secrets.swift Sources/Clinqy/Router.swift Sources/Clinqy/History.swift Sources/Clinqy/Workflow.swift tests/RouteMemoryTests.swift -o "$TEST_DIR/route-tests"
"$TEST_DIR/route-tests"
