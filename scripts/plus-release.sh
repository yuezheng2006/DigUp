#!/bin/bash
# DigUp Plus release: Developer ID + notarize + staple DMG (wraps scripts/release.sh).
# Refuses to run when distribution preflight fails — avoids shipping Gatekeeper-rejected builds.
#
#   SIGN_ID='Developer ID Application: … (3396ALL92C)' \
#     NOTARY_PROFILE=DigUpPlus ./scripts/plus-release.sh
#
# Or omit SIGN_ID and let preflight + auto-detect pick the Developer ID identity:
#   NOTARY_PROFILE=DigUpPlus ./scripts/plus-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE_NOTARY=1 ./scripts/check-plus-distribution.sh

if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID=$(security find-identity -v -p codesigning | grep -F 'Developer ID Application' | head -1 \
    | sed -E 's/.*"([^"]+)".*/\1/')
fi
: "${SIGN_ID:?could not resolve Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile)}"

case "$SIGN_ID" in
  Developer\ ID\ Application:*) ;;
  *)
    echo "Refusing SIGN_ID that is not Developer ID Application: $SIGN_ID" >&2
    echo "Apple Development builds will be Gatekeeper-rejected for other users." >&2
    exit 2
    ;;
esac

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
echo "Releasing DigUp Plus $VERSION with $SIGN_ID (profile $NOTARY_PROFILE)"
SIGN_ID="$SIGN_ID" NOTARY_PROFILE="$NOTARY_PROFILE" ./scripts/release.sh

DMG="build.noindex/release/DigUp-$VERSION.dmg"
APP="build.noindex/DigUp.app"
echo
echo "== Gatekeeper assess =="
spctl --assess --type execute --verbose=2 "$APP" || {
  echo "App still rejected by Gatekeeper after notarization — do not publish." >&2
  exit 5
}
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || {
  echo "DMG still rejected — do not publish." >&2
  exit 5
}
echo "Publish candidate: $DMG"
