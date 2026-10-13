#!/bin/bash
# Builds Eddie for distribution: Developer ID signed, notarized by Apple, stapled, in a DMG.
#
#   scripts/release.sh            # build, sign, notarize, package → dist/Eddie-<version>.dmg
#   scripts/release.sh --no-notarize   # signed build + DMG only (for a quick local check)
#
# One-time setup for notarization (an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials eddie --apple-id <you@example.com> --team-id F77F7X4Q2W
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${EDDIE_SIGN_IDENTITY:-Developer ID Application: Deadalus Systems (F77F7X4Q2W)}"
TEAM="${EDDIE_TEAM_ID:-F77F7X4Q2W}"
PROFILE="${EDDIE_NOTARY_PROFILE:-eddie}"
NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

step() { printf "\n▸ %s\n" "$1"; }

step "Generating the Xcode project"
xcodegen generate --quiet

step "Building Release (signed with $IDENTITY)"
rm -rf build/dist
xcodebuild -project Eddie.xcodeproj -scheme Eddie -configuration Release \
  -derivedDataPath build/dist-derived \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build -quiet

mkdir -p build/dist dist
APP=build/dist/Eddie.app
ditto build/dist-derived/Build/Products/Release/Eddie.app "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

step "Checking the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
ENTITLEMENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null || true)
[[ "$ENTITLEMENTS" == *audio-input* ]] || { echo "missing microphone entitlement"; exit 1; }
for BIN in "$APP" "$APP/Contents/MacOS/eddie-mcp"; do
  INFO=$(codesign -dv "$BIN" 2>&1 || true)
  [[ "$INFO" == *"(runtime)"* ]] || { echo "hardened runtime is off for $BIN"; exit 1; }
  [[ "$INFO" == *"TeamIdentifier=$TEAM"* ]] || { echo "$BIN isn't signed by team $TEAM"; exit 1; }
done

if [[ $NOTARIZE == 1 ]]; then
  step "Notarizing the app (Apple scans it; usually a few minutes)"
  ditto -c -k --keepParent "$APP" build/dist/Eddie.zip
  xcrun notarytool submit build/dist/Eddie.zip --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
fi

step "Making the DMG"
DMG="dist/Eddie-$VERSION.dmg"
STAGE=build/dist/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Eddie.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Eddie" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  step "Notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  step "Gatekeeper check"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi

step "Done: $DMG ($(du -h "$DMG" | cut -f1))"
