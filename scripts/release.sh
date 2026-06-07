#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Cut a GitHub release for this component: build the signed DMG (stamped with
# the repo-root VERSION) and publish it as a GitHub release tagged vX.Y.Z.
#   scripts/release.sh
# Requires: a working app/package.sh (full Xcode + Developer ID cert) and gh.
# Signs the DMG (does NOT pass NO_SIGN). Refuses if the tag already exists.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="$(tr -d '[:space:]' < VERSION)"
[ -n "$VERSION" ] || { echo "!! VERSION is empty" >&2; exit 1; }
TAG="v$VERSION"
APP_NAME="PharosVPN"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"

# Refuse if the release/tag already exists (local or on GitHub).
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "!! tag $TAG already exists locally — bump VERSION first" >&2; exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "!! release $TAG already exists on GitHub — bump VERSION first" >&2; exit 1
fi

echo "==> building signed DMG for $TAG …"
"$ROOT/app/package.sh"

[ -f "$DMG" ] || { echo "!! expected DMG not found: $DMG" >&2; exit 1; }
echo "==> DMG: $DMG ($(du -h "$DMG" | cut -f1))"

NOTES="$(cat <<EOF
First public build of the PharosVPN macOS client — **pre-alpha**.

- Signed with an Apple Developer ID for local testing. **Not notarized and not on the App Store**; on a clean Mac you may need to right-click → Open on first launch.
- Dual-protocol data plane: **AmneziaWG** (default) with an **XRay-REALITY** fallback.
- Cloud profile sync from your controller.
- Bundles the **caravel** core worker v$VERSION (universal arm64 + x86_64).

Expect rough edges. Do not rely on this for anything sensitive yet.
EOF
)"

echo "==> publishing GitHub release $TAG …"
gh release create "$TAG" "$DMG" \
  --title "PharosVPN macOS $TAG" \
  --notes "$NOTES"

echo "==> released $TAG"
gh release view "$TAG" --json url -q .url
