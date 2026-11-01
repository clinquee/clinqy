#!/usr/bin/env bash
set -euo pipefail

binary="${1:-$PWD/.build/release/Clinqy}"
if [[ ! -x "$binary" ]]; then
  echo "Clinqy executable not found: $binary" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/opencode" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$OPENCODE_TEST_ARGS"
SH
chmod +x "$tmp/opencode"

installed_exe="/Applications/Clinqy.app/Contents/MacOS/Clinqy"
if [[ -x "$installed_exe" ]]; then
  expected_exe="$installed_exe"
else
  expected_exe="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$binary")"
fi
printf 'mcp\nadd\nclinqy\n--global\n--\n%s\nmcp\n' "$expected_exe" > "$tmp/expected"

OPENCODE_PATH="$tmp/opencode" OPENCODE_TEST_ARGS="$tmp/args" "$binary" connect opencode
diff -u "$tmp/expected" "$tmp/args"
