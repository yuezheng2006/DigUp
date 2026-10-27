#!/bin/bash
# Builds build.noindex/DigUp.app, signed with the hardened runtime (as releases are, so dev builds behave the same).
#   ./build.sh                       signed with the identity named in .sign-id (one line, gitignored), so macOS keeps
#                                    folder permissions across rebuilds; ad-hoc without it (macOS then asks again
#                                    after each build)
#   SIGN_ID="<identity>" ./build.sh  this identity instead
#   RELEASE=1 SIGN_ID="Developer ID Application: …" ./build.sh   plus the secure timestamp notarization needs
#                                    (scripts/release.sh does that, then notarizes and makes the DMG)
# There's no install step: run it from build.noindex (see scripts/dev-run.sh).
# For testing in-app updates with a copy of its own (never the installed DigUp's settings or updates), these replace
# Info.plist values: BUNDLE_ID, VERSION, BUILD_NUMBER, SPARKLE_FEED (the appcast URL), SPARKLE_KEY (the EdDSA public key).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DigUp"
# ".noindex" keeps Spotlight (and the Apps list) from showing this staging copy.
APP="build.noindex/$APP_NAME.app"

# Use full Xcode's toolchain when it's installed, even if xcode-select points at the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# llama.cpp, the embedding runtime, linked into the helper (only rebuilt when its tag or patch changes).
scripts/build-llama.sh

# App, CLI, and WeChat share-extension binary (nested into PlugIns/ below).
swift build -c release --product DigUpApp
swift build -c release --product digup
swift build -c release --product DigUpShare
BIN_DIR="$(swift build -c release --show-bin-path)"

# DigUp Plus share slots (WeChat 合并转发 → 系统分享菜单). Pattern from Dukou.
# shellcheck source=scripts/share-slots.sh
source scripts/share-slots.sh
APP_GROUP="${APP_GROUP:-3396ALL92C.group.com.yuezheng.digupplus.shared}"

# The app icon ("One space", moss; Resources/AppIcon/README.md): macOS 26 draws the layered AppIcon.icon (compiled into
# Assets.car), older macOS the .icns. Without the former, macOS 26 shows the icon shrunk inside a gray square.
ICON="Resources/AppIcon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
# The binary is DigUpApp in SwiftPM (it can't share a name with the `digup` CLI on a case-insensitive disk).
cp "$BIN_DIR/DigUpApp" "$APP/Contents/MacOS/$APP_NAME"
# The indexing helper lives in Helpers/: next to DigUp in MacOS/ it would collide on a case-insensitive disk.
cp "$BIN_DIR/digup" "$APP/Contents/Helpers/digup"
cp -R "$BIN_DIR/DigUp_DigUpApp.bundle" "$APP/Contents/Resources/"
cp -R Resources/zh-Hans.lproj "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :DUAppGroupIdentifier $APP_GROUP" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :DUAppGroupIdentifier string $APP_GROUP" "$APP/Contents/Info.plist"

# Share extension must enter at NSExtensionMain (Package.swift linker -e). Fail closed if dropped.
# Retry briefly: a just-linked binary can briefly miss the undefined-symbol listing under load.
SHARE_OK=0
for _try in 1 2 3 4 5; do
  if [[ -x "$BIN_DIR/DigUpShare" ]] && nm -u "$BIN_DIR/DigUpShare" 2>/dev/null | grep -F '_NSExtensionMain' >/dev/null; then
    SHARE_OK=1
    break
  fi
  sleep 0.2
done
if [[ "$SHARE_OK" != 1 ]]; then
  echo "DigUpShare is not linked against _NSExtensionMain; check Package.swift linker flags" >&2
  echo "BIN_DIR=$BIN_DIR" >&2
  ls -la "$BIN_DIR/DigUpShare" 2>&1 >&2 || true
  nm -u "$BIN_DIR/DigUpShare" 2>&1 | head -40 >&2 || true
  exit 1
fi

APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER_PLIST="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
APPEX_PATHS=()
for SLOT_ROW in "${SHARE_SLOTS[@]}"; do
  IFS='|' read -r SLOT APPEX_NAME ID_SUFFIX SLOT_ACTION DISPLAY_NAME <<< "$SLOT_ROW"
  SLOT_APPEX="$APP/Contents/PlugIns/$APPEX_NAME.appex"
  mkdir -p "$SLOT_APPEX/Contents/MacOS" "$SLOT_APPEX/Contents/Resources"
  cp "$BIN_DIR/DigUpShare" "$SLOT_APPEX/Contents/MacOS/$APPEX_NAME"
  cp Resources/Share-Info.plist "$SLOT_APPEX/Contents/Info.plist"
  PLIST="$SLOT_APPEX/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APPEX_NAME" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_ID.$ID_SUFFIX" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :DUShareAction $SLOT_ACTION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER_PLIST" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :DUAppGroupIdentifier $APP_GROUP" "$PLIST"
  SLOT_LOCALIZATIONS="Resources/ShareLocalizations/$SLOT"
  if [[ -d "$SLOT_LOCALIZATIONS" ]]; then
    shopt -s nullglob
    for LPROJ in "$SLOT_LOCALIZATIONS"/*.lproj; do
      ditto "$LPROJ" "$SLOT_APPEX/Contents/Resources/$(basename "$LPROJ")"
    done
    shopt -u nullglob
  fi
  APPEX_PATHS+=("$SLOT_APPEX")
done
xcrun actool --compile "$APP/Contents/Resources" --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$(mktemp -d)/AppIcon.plist" --enable-on-demand-resources NO \
  --development-region en "$PWD/Resources/AppIcon/AppIcon.icon" > /dev/null
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"   # over actool's plainer fallback: ours has simplified 16 and 32 px
cp Resources/Acknowledgements.txt "$APP/Contents/Resources/Acknowledgements.txt"
cp Resources/AppIcon/tray.png Resources/AppIcon/tray-dim.png Resources/AppIcon/tray-paused.png "$APP/Contents/Resources/"   # the menubar's logo

# Sparkle (in-app updates): the framework in Frameworks/, where the app's runpath looks. Its XPC services are for
# sandboxed apps and its headers for building against it: left out.
FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$FW"
for part in XPCServices Headers PrivateHeaders Modules; do rm -rf "${FW:?}/$part" "${FW:?}/Versions/B/$part"; done

PLIST="$APP/Contents/Info.plist"
[[ -n "${BUNDLE_ID:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
[[ -n "${SPARKLE_FEED:-}" ]] && /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED" "$PLIST"
[[ -n "${SPARKLE_KEY:-}" ]] && { /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$PLIST" 2>/dev/null || true
                                 /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_KEY" "$PLIST"; }

# Nested code first, then the bundle. The helper needs no entitlements: llama.cpp compiles its Metal shaders at run
# time through Metal's own compiler service, which the hardened runtime allows (checked 2026-10-08). The app's one
# entitlement lets it ask QuickTime Player to open a recording at a moment.
IDENTITY="${SIGN_ID:-$( [[ -f .sign-id ]] && head -1 .sign-id || echo - )}"
TIMESTAMP=$([[ "${RELEASE:-}" == 1 ]] && echo --timestamp || echo --timestamp=none)
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$APP/Contents/Helpers/digup"
# Sparkle comes ad-hoc signed: its helpers, then the framework, with this identity (the app may only load code signed
# by its own team).
for code in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app" "$FW"; do
  codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$code"
done

# Share extensions: sandboxed + App Group. Sign each appex before the outer app.
SHARE_ENTITLEMENTS="$(mktemp -d)/DigUpShare.entitlements"
cp Resources/DigUpShare.entitlements "$SHARE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $APP_GROUP" "$SHARE_ENTITLEMENTS"
for APPEX in "${APPEX_PATHS[@]}"; do
  codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP --entitlements "$SHARE_ENTITLEMENTS" "$APPEX"
done

# An ad-hoc build has no team, so the hardened runtime's library validation would refuse its (ad-hoc) Sparkle: such
# builds (from source, without a signing identity) may load it anyway. Signed builds and releases keep validation.
APP_ENT_COPY="$(mktemp -d)/DigUp.entitlements"
cp Resources/DigUp.entitlements "$APP_ENT_COPY"
if [[ "$IDENTITY" == - ]]; then
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$APP_ENT_COPY"
fi
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $APP_GROUP" "$APP_ENT_COPY"
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP --entitlements "$APP_ENT_COPY" "$APP"
echo "Signed $([[ "$IDENTITY" == - ]] && echo ad-hoc || echo "with \"$IDENTITY\"") (hardened runtime); share slots ${#APPEX_PATHS[@]}"
echo "Built $APP"
