#!/bin/bash
# Preflight for DigUp Plus public distribution (Gatekeeper).
# Exit 0 only when a Developer ID Application identity exists and (optionally)
# a notarytool keychain profile is usable.
#
#   ./scripts/check-plus-distribution.sh
#   NOTARY_PROFILE=DigUpPlus ./scripts/check-plus-distribution.sh
#   REQUIRE_NOTARY=1 NOTARY_PROFILE=DigUpPlus ./scripts/check-plus-distribution.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== DigUp Plus distribution preflight =="
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "?")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist 2>/dev/null || echo "?")
echo "Version: $VERSION ($BUILD)"

IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
echo "$IDENTITIES"

DEV_ID_LINE=$(echo "$IDENTITIES" | grep -F 'Developer ID Application' | head -1 || true)
APPLE_DEV_LINE=$(echo "$IDENTITIES" | grep -F 'Apple Development' | head -1 || true)

if [[ -z "$DEV_ID_LINE" ]]; then
  echo
  echo "FAIL: no Developer ID Application identity in the keychain."
  echo "Gatekeeper will reject browser-downloaded builds signed only with Apple Development."
  echo
  echo "Fix:"
  echo "  1. Apple Developer → Certificates → Developer ID Application (team 3396ALL92C)"
  echo "  2. Install the cert + private key into login keychain"
  echo "  3. Re-run this script"
  echo "See DIGUP_PLUS_DISTRIBUTION.zh-CN.md"
  if [[ -n "$APPLE_DEV_LINE" ]]; then
    echo
    echo "Note: Apple Development is present — fine for local ./build.sh, not for public DMG/ZIP."
  fi
  exit 2
fi

SIGN_ID=$(echo "$DEV_ID_LINE" | sed -E 's/.*"([^"]+)".*/\1/')
echo "OK: Developer ID → $SIGN_ID"

PROFILE="${NOTARY_PROFILE:-}"
if [[ -z "$PROFILE" ]]; then
  echo "WARN: NOTARY_PROFILE unset — notarization step will not run."
  echo "      Example: NOTARY_PROFILE=DigUpPlus $0"
  if [[ "${REQUIRE_NOTARY:-}" == 1 ]]; then
    exit 3
  fi
else
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "OK: notarytool profile \"$PROFILE\""
  else
    echo "FAIL: notarytool cannot use keychain profile \"$PROFILE\""
    echo "Fix once:"
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id YOU --team-id 3396ALL92C"
    exit 4
  fi
fi

APP_GROUP=$(/usr/libexec/PlistBuddy -c "Print DUAppGroupIdentifier" Resources/Info.plist 2>/dev/null || echo "")
echo "App Group (Info.plist): ${APP_GROUP:-unset}"
if [[ -n "$APP_GROUP" && "$APP_GROUP" != 3396ALL92C.* ]]; then
  echo "WARN: App Group should stay team-prefixed for Developer ID installs."
fi

echo
echo "Ready for:"
echo "  SIGN_ID=$(printf %q "$SIGN_ID") NOTARY_PROFILE=${PROFILE:-DigUpPlus} ./scripts/plus-release.sh"
exit 0
