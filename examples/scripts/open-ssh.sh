#!/bin/bash
# Open SSH session in Terminal
# Triggered by: server-alerts topic action button

set -eu
export LC_ALL=C
SERVER="${1:-}"

# Edit this explicit local allowlist before use. The entire message must be a host.
# Do not permit user@host, SSH flags, whitespace or shell/AppleScript metacharacters.
case "$SERVER" in
    ''|*[!A-Za-z0-9.-]*|-*) printf '%s\n' 'SSH host rejected' >&2; exit 1 ;;
esac
case "$SERVER" in
    myserver.example.com|backup.example.com) ;;
    *) printf '%s\n' 'SSH host rejected' >&2; exit 1 ;;
esac

# Source is constant. Remote text is argv data, then shell-quoted by AppleScript.
osascript - "$SERVER" <<'APPLESCRIPT'
on run argv
    set serverName to item 1 of argv
    tell application "Terminal"
        activate
        do script ("/usr/bin/ssh -- " & quoted form of serverName)
    end tell
end run
APPLESCRIPT
