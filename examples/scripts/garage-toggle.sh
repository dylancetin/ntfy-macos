#!/bin/bash
# Toggle garage door via Home Assistant. Set HA_URL=https://... and HA_TOKEN in
# the launch environment. No plaintext fallback, curlrc overrides or redirects.
set -eu
: "${HA_URL:?Set HA_URL to your HTTPS Home Assistant URL}"
: "${HA_TOKEN:?Set HA_TOKEN to your Home Assistant token}"
case "$HA_URL" in https://?*) ;; *) echo 'HA_URL must use HTTPS' >&2; exit 1 ;; esac
case "$HA_URL$HA_TOKEN" in *$'\r'*|*$'\n'*) echo 'Invalid Home Assistant configuration' >&2; exit 1 ;; esac

# Headers travel on stdin rather than exposing the token in process arguments.
# No --location: even an HTTPS redirect to a different host must not get the token.
if ! STATUS=$(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$HA_TOKEN" |
    curl --disable --silent --fail --globoff --proto '=https' --proto-redir '=https' \
        --max-redirs 0 --connect-timeout 5 --max-time 20 --request POST --header @- \
        --data '{"entity_id":"cover.garage_door"}' --output /dev/null --write-out '%{http_code}' \
        --url "${HA_URL%/}/api/services/cover/toggle"); then
    echo 'Home Assistant request failed' >&2
    exit 1
fi
case "$STATUS" in 2??) echo 'Garage command sent' ;; *) echo 'Home Assistant response rejected' >&2; exit 1 ;; esac
