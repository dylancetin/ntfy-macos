#!/bin/bash
set -euo pipefail

APP_BUNDLE="${1:-$HOME/Applications/ntfy-macos.app}"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Notification authorization requires an interactive macOS session." >&2
    exit 1
fi
if [[ ! -x "$APP_BUNDLE/Contents/MacOS/ntfy-macos" ]]; then
    echo "App not found at $APP_BUNDLE. Follow docs/BUILD_ON_MAC.md first." >&2
    exit 1
fi

echo "Requesting normal macOS notification authorization for a local-only test."
echo "Respond to the permission dialog. If permission was previously denied, use"
echo "System Settings → Notifications → ntfy-macos → Allow Notifications."
"$APP_BUNDLE/Contents/MacOS/ntfy-macos" test-notify --topic local-smoke
echo "Check the notification and command output to confirm the result."
