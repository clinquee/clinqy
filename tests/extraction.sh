#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/Clinqy/ObservationGeometry.swift -O -parse-as-library Sources/Clinqy/Tables.swift Sources/Clinqy/Reader.swift tests/ExtractionTests.swift -o "$TEST_DIR/extraction-tests"
"$TEST_DIR/extraction-tests"
