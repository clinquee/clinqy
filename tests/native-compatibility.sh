#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/Clinqy/ActionOutcome.swift Sources/Clinqy/TaskContext.swift -parse-as-library Sources/Clinqy/ObservationGeometry.swift Sources/Clinqy/NativeWindowObservation.swift Sources/Clinqy/AXEngine.swift tests/NativeCompatibilityTests.swift -o "$TEST_DIR/native-compatibility"
"$TEST_DIR/native-compatibility"
