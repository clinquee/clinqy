#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library Sources/Clinqy/ACPAgentSession.swift tests/ACPAgentSessionTests.swift -o "$TEST_DIR/acp-tests"
CLINQY_TEST_CONFIG_CURSOR_API_KEY="test-cursor-key" \
CLINQY_TEST_CONFIG_OPENCODE_API_KEY="test-opencode-key" \
CLINQY_TEST_CONFIG_OPENCODE_DB="test-opencode.db" \
CLINQY_TEST_CONFIG_OPENCODE_CONFIG_CONTENT='{"model":"openai/gpt-4o","permissions":[{"action":"read","resource":"*","effect":"allow"}],"agents":{"clinqy":{"permissions":[{"action":"shell","resource":"*","effect":"allow"}]}}}' \
CLINQY_FAKE_ACP="$PWD/tests/fake-acp-server.py" "$TEST_DIR/acp-tests"
