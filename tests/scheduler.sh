#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/Clinqy/SQLiteDatabase.swift -parse-as-library Sources/Clinqy/TaskContext.swift Sources/Clinqy/ActionOutcome.swift Sources/Clinqy/BackgroundPolicy.swift Sources/Clinqy/TaskStore.swift Sources/Clinqy/Scheduler.swift tests/SchedulerTests.swift -o "$TEST_DIR/scheduler-tests"
"$TEST_DIR/scheduler-tests"
