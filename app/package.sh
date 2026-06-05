#!/usr/bin/env bash
# Build a Developer-ID-signed, drag-to-install  PharosVPN.dmg. The .app bundles
# the caravel-mac Go worker (universal), so it runs on a clean Mac with no Go
# toolchain. By default it signs with your "Developer ID Application" identity;
# set NOTARY_PROFILE=name to also notarize+staple (zero Gatekeeper warnings on
# other Macs). NO_SIGN=1 forces an ad-hoc build (local use only).
#
# Requires: full Xcode (xcodebuild), xcodegen, Go, and your Developer ID cert.
# Run from a real Terminal (codesign needs keychain access).
set -euo pipefail
cd "$(dirname "$0")"          # app/
ROOT="$(cd .. && pwd)"        # caravel-mac/

APP_NAME="PharosVPN"         # PRODUCT_NAME
SCHEME="Caravel"             # xcodegen target/scheme
BUILD_DIR="$ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
STAGE="$BUILD_DIR/dmg"

if [ "${NO_SIGN:-0}" = 1 ]; then
  DEVID=""
else
  DEVID="${DEVID:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

echo "==> (1/5) building universal caravel-mac worker…"
mkdir -p "$BUILD_DIR" Caravel/Resources
( cd "$ROOT"
  GOOS=darwin GOARCH=arm64 go build -o "$BUILD_DIR/caravel-mac-arm64" ./cmd/caravel-mac
  GOOS=darwin GOARCH=amd64 go build -o "$BUILD_DIR/caravel-mac-amd64" ./cmd/caravel-mac )
lipo -create "$BUILD_DIR/caravel-mac-arm64" "$BUILD_DIR/caravel-mac-amd64" -o Caravel/Resources/caravel-mac
chmod +x Caravel/Resources/caravel-mac
echo "    universal worker ($(lipo -archs Caravel/Resources/caravel-mac))"

echo "==> (2/5) xcodegen + xcodebuild Release…"
command -v xcodegen >/dev/null && xcodegen >/dev/null
rm -rf "$DERIVED"
xcodebuild -project Caravel.xcodeproj -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build >/dev/null
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "!! build failed: $APP not found" >&2; exit 1; }

echo "==> (3/5) inject worker into the bundle + sign (inside-out)…"
mkdir -p "$APP/Contents/Resources"
cp Caravel/Resources/caravel-mac "$APP/Contents/Resources/caravel-mac"
chmod +x "$APP/Contents/Resources/caravel-mac"
# sign_devid signs one path with the hardened runtime, preferring a secure
# Apple timestamp (needed for notarization) but falling back to no timestamp if
# the timestamp server is unreachable — so a flaky network can't block a local
# signed build.
sign_devid() {
  local p="$1"
  for _ in 1 2 3; do
    codesign --force --options runtime --timestamp ${2:+--deep} -s "$DEVID" "$p" 2>/tmp/cs.err && return 0
    grep -qi timestamp /tmp/cs.err || { cat /tmp/cs.err >&2; return 1; }
  done
  echo "    (timestamp server unreachable — signing without a secure timestamp; not notarizable until re-signed online)" >&2
  codesign --force --options runtime --timestamp=none ${2:+--deep} -s "$DEVID" "$p"
}
if [ -n "$DEVID" ]; then
  sign_devid "$APP/Contents/Resources/caravel-mac"
  sign_devid "$APP" deep
  codesign --verify --strict --verbose=2 "$APP"
  echo "    Developer-ID signed: $DEVID"
else
  codesign --force -s - "$APP/Contents/Resources/caravel-mac"
  codesign --force --deep -s - "$APP"
  echo "    ad-hoc signed (personal). Other Macs: right-click → Open on first launch."
fi

echo "==> (4/5) building DMG…"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"
DMG="$BUILD_DIR/$APP_NAME-$VER.dmg"
rm -f "$DMG"
for v in /Volumes/"$APP_NAME"*; do [ -d "$v" ] && hdiutil detach "$v" -force >/dev/null 2>&1 || true; done
hdiutil create -srcfolder "$STAGE" -volname "$APP_NAME" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
if [ -n "$DEVID" ]; then
  codesign --force --timestamp -s "$DEVID" "$DMG" 2>/dev/null \
    || codesign --force --timestamp=none -s "$DEVID" "$DMG"
  echo "    signed DMG"
fi

echo "==> (5/5) notarize…"
if [ -n "$DEVID" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "    submitting to Apple notary (profile: $NOTARY_PROFILE)…"
  if xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tail -3; then
    xcrun stapler staple "$DMG" && echo "    notarized + stapled ✓"
  else
    echo "    !! notarization failed — DMG is Developer-ID signed but not stapled."
  fi
else
  echo "    skipped (Developer-ID-signed opens fine on this Mac; set NOTARY_PROFILE=name to notarize for others)."
fi

echo ""
echo "==> done:  $DMG"
