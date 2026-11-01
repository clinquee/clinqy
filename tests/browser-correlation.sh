#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/BridgeRequestTable.swift Sources/Clinqy/ReplayOffers.swift tests/BrowserCorrelationTests.swift -o "$TEST_DIR/correlation-tests"
"$TEST_DIR/correlation-tests"
