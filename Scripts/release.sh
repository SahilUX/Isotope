#!/usr/bin/env bash
# Builds Isotope for release, signs it with Developer ID, notarizes and staples
# it when credentials are stored, and installs it to /Applications.
#
# project.yml stays ad-hoc so a clone builds without anyone's certificate; the
# Developer ID identity is applied here, as build-setting overrides.
#
# Notarization reads a notarytool keychain profile (default "isotope-notary").
# Create it once with:
#   xcrun notarytool store-credentials isotope-notary \
#     --apple-id <apple-id> --team-id 627Y9R25T5
# Without the profile the build is still Developer ID signed; it just is not
# notarized, and the script says so.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="627Y9R25T5"
IDENTITY="Developer ID Application"
PROFILE="${NOTARY_PROFILE:-isotope-notary}"

xcodegen generate >/dev/null

SIGNING=(
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$IDENTITY"
  DEVELOPMENT_TEAM="$TEAM_ID"
  OTHER_CODE_SIGN_FLAGS=--timestamp
)

xcodebuild -project Isotope.xcodeproj -scheme Isotope -configuration Release \
  "${SIGNING[@]}" build -quiet

PRODUCTS=$(xcodebuild -project Isotope.xcodeproj -scheme Isotope -configuration Release \
  "${SIGNING[@]}" -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')
APP="$PRODUCTS/Isotope.app"

codesign --verify --strict --deep "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority=Developer ID Application|TeamIdentifier)"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  ZIP=$(mktemp -d)/Isotope.zip
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose "$APP"
  rm -f "$ZIP"
else
  echo "warning: no notarytool profile \"$PROFILE\"; the build is signed but not notarized" >&2
fi

if pgrep -x Isotope >/dev/null; then
  osascript -e 'quit app "Isotope"'
  while pgrep -x Isotope >/dev/null; do sleep 0.5; done
fi
ditto "$APP" /Applications/Isotope.app
open /Applications/Isotope.app
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" /Applications/Isotope.app/Contents/Info.plist
