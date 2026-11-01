#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/Router.swift tests/RouterTests.swift -o "$TEST_DIR/router-tests"
"$TEST_DIR/router-tests"
