#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/InputPlan.swift Sources/Clinqy/Clipboard.swift tests/DesktopInputTests.swift -o "$TEST_DIR/desktop-input-tests"
"$TEST_DIR/desktop-input-tests"
