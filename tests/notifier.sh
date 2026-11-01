#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/NotificationLedger.swift tests/NotificationLedgerTests.swift -o "$TEST_DIR/ledger-tests"
"$TEST_DIR/ledger-tests"
swiftc -parse-as-library Sources/Clinqy/ConnectionDrafts.swift tests/ConnectionDraftsTests.swift -o "$TEST_DIR/drafts-tests"
"$TEST_DIR/drafts-tests"
