#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
S=Sources/Clinqy
swiftc -parse-as-library $S/Config.swift $S/Pdf.swift $S/Files.swift $S/Tables.swift $S/Media.swift $S/Profile.swift \
  $S/Memory.swift $S/MemoryGraph.swift $S/Embedder.swift $S/TextEncoder.swift tests/DataStoreTests.swift -o "$TEST_DIR/data-tests"
"$TEST_DIR/data-tests"
