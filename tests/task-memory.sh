#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/TaskMemory.swift Sources/Clinqy/Secrets.swift Sources/Clinqy/Router.swift Sources/Clinqy/History.swift tests/TaskMemoryTests.swift -o "$TEST_DIR/memory-tests"
"$TEST_DIR/memory-tests"
