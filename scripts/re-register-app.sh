#!/usr/bin/env bash
# Force LaunchServices to forget and re-discover the installed app.
# Useful when ad-hoc resigning has confused macOS about whether GH Notifier
# is a "new" app — which in turn keeps the notification permission prompt
# from re-appearing.

set -euo pipefail

APP_PATH="/Applications/GH Notifier.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Not installed: ${APP_PATH}" >&2
    echo "Run ./build-app.sh --install first." >&2
    exit 1
fi

echo "==> Stopping any running instance"
killall GHNotifier 2>/dev/null || true

echo "==> lsregister -u (unregister)"
"${LSREG}" -u "${APP_PATH}" || true

echo "==> lsregister -f (re-register)"
"${LSREG}" -f "${APP_PATH}"

echo "==> Restarting cfprefsd and usernoted"
killall cfprefsd 2>/dev/null || true
killall usernoted 2>/dev/null || true

echo
echo "Re-registered. Now:"
echo "  1. open -a 'GH Notifier'"
echo "  2. Watch for the macOS notification-permission prompt."
echo "  3. If no prompt appears, open System Settings → Notifications and"
echo "     verify 'GH Notifier' is listed with Allow Notifications = ON."
