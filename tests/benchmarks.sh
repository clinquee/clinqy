#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/Clinqy/ActionOutcome.swift Sources/Clinqy/TaskContext.swift -O -parse-as-library Sources/Clinqy/SQLiteDatabase.swift Sources/Clinqy/TaskStore.swift Sources/Clinqy/TaskMemory.swift Sources/Clinqy/Secrets.swift tests/PerformanceBenchmarks.swift -o "$TEST_DIR/benchmarks"
"$TEST_DIR/benchmarks"
