#!/bin/bash
# Explicit maintainer action: stage a signed draft after committing and pushing the release changes.
# Publishing is deferred until main's mac-release workflow verifies this exact source commit.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < MAC_VERSION)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
TAG="mac-v$VERSION"
SOURCE_PATHS=(MAC_VERSION Package.swift Sources extension assets bin skills env.example build.sh make-dmg.sh website/public/fonts)
[[ -z "$(git status --porcelain --untracked-files=normal -- "${SOURCE_PATHS[@]}")" ]] || { echo "Commit the Mac build sources before staging a release." >&2; exit 1; }
COMMIT=$(git rev-parse HEAD)
gh api "repos/Amrit-Nigam/clinqy/commits/$COMMIT" --silent
STATE_DIR=$(mktemp -d)
trap 'rm -rf "$STATE_DIR"' EXIT
if gh release view "$TAG" --json isDraft > "$STATE_DIR/release.json" 2>/dev/null; then
  python3 - "$STATE_DIR/release.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['isDraft'], 'This version is already published; bump MAC_VERSION instead.'
PY
fi
./make-dmg.sh
./scripts/verify-mac-release.sh
printf '%s\n' "$COMMIT" > dist/Clinqy.source-commit.txt
cat > dist/Clinqy.release-notes.md <<'NOTES'
- Integrate persistent task memory, corrections, replay history and bounded delegation.
- Improve browser request ownership, cancellation cleanup and cross-origin iframe control.
- Support basic foreground browser control without requiring extension installation.
- Strengthen native input contracts, outcome verification and recovery checkpoints.
- Preserve unreadable data stores and report failed saves instead of silently overwriting data.
- Expand Mac, browser, memory and delegation regression coverage.

Requires Apple silicon and macOS 14+. The app uses the existing stable signing identity and is not Apple notarized.
NOTES
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" dist/Clinqy.dmg dist/Clinqy.dmg.sha256 dist/Clinqy.source-commit.txt --clobber
  gh release edit "$TAG" --notes-file dist/Clinqy.release-notes.md --target "$COMMIT" --latest=false
else
  gh release create "$TAG" dist/Clinqy.dmg dist/Clinqy.dmg.sha256 dist/Clinqy.source-commit.txt \
    --draft --title "Clinqy for Mac $VERSION" --notes-file dist/Clinqy.release-notes.md --target "$COMMIT" --latest=false
fi
printf 'Staged %s as a draft. The main-branch workflow publishes it after merge.\n' "$TAG"
