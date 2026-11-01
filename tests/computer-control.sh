#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/ActionOutcome.swift Sources/Clinqy/PointerGesture.swift Sources/Clinqy/InputPlan.swift Sources/Clinqy/ActionContract.swift Sources/Clinqy/VisionPolicy.swift Sources/Clinqy/ControlProtocol.swift Sources/Clinqy/BackgroundPolicy.swift tests/ComputerControlTests.swift -o "$TEST_DIR/control-tests"
"$TEST_DIR/control-tests"
