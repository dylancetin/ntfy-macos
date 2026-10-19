#!/bin/bash
# Update yt-dlp to the latest version
# Triggered by: yt-dlp-releases topic
# Requires: local_server_port and local_server_token in config; set NTFY_LOCAL_TOKEN
# to the same token in the launch environment for follow-up notifications.

# Do not persist command output in a shared /tmp log.
LOG_FILE="/dev/null"
LOCAL_SERVER="http://127.0.0.1:9292/notify"

notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-3}"
    local tags="${4:-}"
    case "${NTFY_LOCAL_TOKEN:-}" in ''|*[!A-Za-z0-9_-]*) return ;; esac
    # All arguments below are fixed local strings/numbers, never notification text.
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$NTFY_LOCAL_TOKEN" |
        curl --disable --silent --fail --max-time 5 --max-redirs 0 --noproxy '*' \
            --request POST "$LOCAL_SERVER" --header @- \
            --data "{\"title\": \"$title\", \"message\": \"$message\", \"priority\": $priority, \"tags\": [\"$tags\"]}" \
            > /dev/null 2>&1
}

echo "$(date): Starting yt-dlp update..." >> "$LOG_FILE"

OLD_VERSION=$(yt-dlp --version 2>/dev/null || echo "not installed")

if command -v brew &> /dev/null && brew list yt-dlp &> /dev/null; then
    brew upgrade yt-dlp > /dev/null 2>&1
elif command -v pipx &> /dev/null && pipx list 2>/dev/null | grep -q yt-dlp; then
    pipx upgrade yt-dlp > /dev/null 2>&1
elif command -v pip3 &> /dev/null; then
    pip3 install --user --upgrade yt-dlp > /dev/null 2>&1
else
    echo "$(date): No package manager found to update yt-dlp" >> "$LOG_FILE"
    notify "yt-dlp Update Failed" "No package manager found (pip3/brew)" 4 "x"
    exit 1
fi

EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "$(date): Update failed with exit code $EXIT_CODE" >> "$LOG_FILE"
    notify "yt-dlp Update Failed" "Update command failed (exit $EXIT_CODE)" 4 "x"
    exit 1
fi

NEW_VERSION=$(yt-dlp --version 2>/dev/null || echo "unknown")

if [ "$OLD_VERSION" = "$NEW_VERSION" ]; then
    echo "$(date): yt-dlp already at latest version" >> "$LOG_FILE"
    notify "yt-dlp" "Already at latest version" 2 "white_check_mark"
else
    echo "$(date): yt-dlp updated" >> "$LOG_FILE"
    notify "yt-dlp Updated" "Update completed" 3 "tada"
fi
