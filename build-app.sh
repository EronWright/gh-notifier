#!/usr/bin/env bash
# Builds the SwiftPM executable in release mode and wraps it in a proper
# `.app` bundle so macOS Notification Center will accept banners from it.
#
# Usage:
#   ./build-app.sh              # builds GH\ Notifier.app/ in the repo root
#   ./build-app.sh --install    # also copies it to /Applications

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="GH Notifier"
BUNDLE_DIR="${APP_NAME}.app"
EXEC_NAME="GHNotifier"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${EXEC_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "Built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${BUNDLE_DIR}"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"
cp "${BIN_PATH}"            "${BUNDLE_DIR}/Contents/MacOS/${EXEC_NAME}"
cp "Resources/Info.plist"   "${BUNDLE_DIR}/Contents/Info.plist"

# Ad-hoc sign so notifications and login-item entitlements work locally.
# (No paid developer ID required for personal use.)
if command -v codesign >/dev/null 2>&1; then
    echo "==> codesign --force --deep --sign -"
    codesign --force --deep --sign - "${BUNDLE_DIR}" >/dev/null
fi

echo
echo "Built ${BUNDLE_DIR}"
echo

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/${BUNDLE_DIR}"
    echo "==> Installing to ${DEST}"
    rm -rf "${DEST}"
    cp -R "${BUNDLE_DIR}" "${DEST}"
    echo "Installed."
    echo "Launch with: open -a \"${APP_NAME}\""
else
    echo "Launch with: open \"${BUNDLE_DIR}\""
    echo "Or install:  ./build-app.sh --install"
fi
