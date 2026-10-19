#!/bin/bash

# Example ntfy-macos notification handler script
# This script receives the notification message as the first argument
# and ntfy message metadata as environment variables.

# First argument (legacy, still supported)
MESSAGE="${1:-}"

# Environment variables set by ntfy-macos
# NTFY_ID       - Unique message ID
# NTFY_TOPIC    - Topic name
# NTFY_TIME     - Message timestamp (Unix epoch)
# NTFY_EVENT    - Event type (usually "message")
# NTFY_TITLE    - Notification title (if set)
# NTFY_MESSAGE  - Notification message
# NTFY_PRIORITY - Priority level 1-5 (if set)
# NTFY_TAGS     - Comma-separated tags (if set)
# NTFY_CLICK    - Click URL (if set)

# Do not persist notification content or metadata in handler logs.
echo 'Notification handler started'

# Example: Different behavior based on priority
if [[ "${NTFY_PRIORITY:-3}" =~ ^[45]$ ]] && [ -n "${NTFY_LOCAL_TOKEN:-}" ]; then
    # High priority: send follow-up notification via local server
    # Set NTFY_LOCAL_TOKEN to the configured local_server_token. Fixed JSON avoids
    # interpolating remote topic text into JSON; never follow authenticated redirects.
    case "$NTFY_LOCAL_TOKEN" in *[!A-Za-z0-9_-]*) exit 1 ;; esac
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$NTFY_LOCAL_TOKEN" |
        curl --disable --silent --fail --max-time 5 --max-redirs 0 --noproxy '*' \
            --request POST http://127.0.0.1:9292/notify --header @- \
            --data '{"title":"Script completed","message":"Handled high-priority alert"}' \
            > /dev/null 2>&1
fi

# Example: Different behavior based on topic
case "${NTFY_TOPIC:-}" in
    "backup-trigger")
        /usr/local/bin/run-backup.sh
        ;;
    "deploy")
        /usr/local/bin/deploy.sh
        ;;
    *)
        echo 'No specific topic handler configured'
        ;;
esac

exit 0
