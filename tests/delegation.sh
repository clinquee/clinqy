#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/Delegation.swift tests/DelegationTests.swift -o "$TEST_DIR/delegation-tests"
"$TEST_DIR/delegation-tests"
