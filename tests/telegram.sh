#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/Clinqy/SQLiteDatabase.swift -parse-as-library -enable-bare-slash-regex Sources/Clinqy/ImageAsset.swift Sources/Clinqy/ExecutionMode.swift Sources/Clinqy/TaskContext.swift Sources/Clinqy/ActionOutcome.swift Sources/Clinqy/TaskStore.swift Sources/Clinqy/Telegram.swift tests/TelegramAttachmentTests.swift -o "$TEST_DIR/telegram-tests"
"$TEST_DIR/telegram-tests"
