#!/bin/sh
# Builds a universal MagicTrack.app (and, with signing env vars, a notarized DMG).
#   SIGN_IDENTITY="Developer ID Application: …"   default: ad-hoc
#   NOTARY_PROFILE=<keychain profile from `xcrun notarytool store-credentials`>   enables DMG + notarization
set -eu
cd "$(dirname "$0")/.."

BUILD="swift build -c release --arch arm64 --arch x86_64"
$BUILD
APP=build/MagicTrack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$($BUILD --show-bin-path)/MagicTrack" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --options runtime --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
echo "Built $APP"

[ -n "${NOTARY_PROFILE:-}" ] || exit 0
DMG=build/MagicTrack.dmg
rm -f "$DMG"
hdiutil create -volname MagicTrack -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
echo "Notarized $DMG"
