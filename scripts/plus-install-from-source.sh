#!/bin/bash
# DigUp Plus — install by building on this Mac (no paid Apple Developer account needed).
# Gatekeeper treats a locally built app differently from a browser-downloaded binary.
#
#   ./scripts/plus-install-from-source.sh
#   INSTALL_DIR="$HOME/Applications" APP_NAME="DigUp Plus.app" ./scripts/plus-install-from-source.sh
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
APP_NAME="${APP_NAME:-DigUp Plus.app}"
SRC_APP="build.noindex/DigUp.app"
DEST="$INSTALL_DIR/$APP_NAME"

echo "== DigUp Plus · install from source =="
echo "Repo: $(pwd)"
echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown) @ $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

if ! command -v swift >/dev/null 2>&1; then
  echo "FAIL: swift not found. Install Xcode or Command Line Tools first." >&2
  exit 1
fi

echo "Building (./build.sh)…"
./build.sh

if [[ ! -d "$SRC_APP" ]]; then
  echo "FAIL: missing $SRC_APP after build" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
# Replace previous copy atomically-ish
if [[ -d "$DEST" ]]; then
  rm -rf "$DEST"
fi
ditto "$SRC_APP" "$DEST"

# Local builds usually have no download quarantine; clear if present anyway.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo
echo "Installed: $DEST"
echo "Open:     open \"$DEST\""
echo
echo "Next (once):"
echo "  系统设置 → 通用 → 登录项与扩展 → 分享 → 勾选 DigUp Plus 各项"
echo "  读微信历史另需本机 wx；合并转发分享可不依赖 wx"
echo
echo "This path does not require a paid Apple Developer Program membership."
