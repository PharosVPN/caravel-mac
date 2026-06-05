#!/usr/bin/env bash
# Dev build: compile the caravel-mac worker into the app bundle's Resources and
# (re)generate the Xcode project. Run once, then open Caravel.xcodeproj and ⌘R.
#   ./app/build.sh && open app/Caravel.xcodeproj
# For a signed, distributable DMG use ./app/package.sh instead.
set -euo pipefail
cd "$(dirname "$0")"          # app/
ROOT="$(cd .. && pwd)"        # caravel-mac/

command -v go >/dev/null || { echo "!! Go not found — brew install go (1.25+)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "!! Xcode not found (xcodebuild)" >&2; exit 1; }

echo "==> building caravel-mac worker → Caravel/Resources/caravel-mac"
mkdir -p Caravel/Resources
( cd "$ROOT" && go build -o app/Caravel/Resources/caravel-mac ./cmd/caravel-mac )
chmod +x Caravel/Resources/caravel-mac

if command -v xcodegen >/dev/null 2>&1; then
  echo "==> generating Xcode project (xcodegen)…"
  xcodegen
  echo "==> done. open $(pwd)/Caravel.xcodeproj  (then ⌘R)"
else
  echo "!! xcodegen not found — brew install xcodegen, then re-run ./app/build.sh"
fi
