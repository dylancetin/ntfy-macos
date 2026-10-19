#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Build on macOS with Xcode 16 or newer (Swift 6+)." >&2
    exit 1
fi

# '-' is deliberately LOCAL ad-hoc signing, not Developer ID or notarization.
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP_VERSION="${APP_VERSION:-}"
VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ -n "$APP_VERSION" && ! "$APP_VERSION" =~ $VERSION_PATTERN ]]; then
    echo "APP_VERSION must be stable SemVer MAJOR.MINOR.PATCH (no leading zeros)." >&2
    exit 1
fi
if [[ -n "$NOTARY_PROFILE" && "$SIGNING_IDENTITY" == "-" ]]; then
    echo "NOTARY_PROFILE requires a Developer ID Application signing identity." >&2
    exit 1
fi
if [[ ! -f Package.resolved ]]; then
    echo "Package.resolved is required; restore the reviewed lockfile before building." >&2
    exit 1
fi

echo "Building ntfy-macos for the current Mac architecture with locked dependencies..."
# Keep SwiftPM's sandbox enabled and fail rather than updating the lockfile.
swift package resolve --force-resolved-versions
swift build -c release --force-resolved-versions

APP_NAME="ntfy-macos"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/"
cp "Resources/ntfy-macos.icns" "$APP_BUNDLE/Contents/Resources/"

# Change only the copied plist, never the tracked source plist.
if [[ -n "$APP_VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
    echo "LOCAL build: ad-hoc signed, NOT notarized."
else
    # The certificate/private key must already exist in the user's keychain.
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
    echo "Identity-signed build; notarization requires NOTARY_PROFILE."
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign --display --verbose=2 "$APP_BUNDLE"

if [[ -n "$NOTARY_PROFILE" ]]; then
    SIGNATURE_DETAILS="$(codesign --display --verbose=2 "$APP_BUNDLE" 2>&1)"
    if ! grep -q '^Authority=Developer ID Application:' <<< "$SIGNATURE_DETAILS"; then
        echo "Notarization requires a Developer ID Application certificate." >&2
        exit 1
    fi
    NOTARY_DIR="$(mktemp -d "$PWD/.build/notarize.XXXXXX")"
    trap 'rm -rf "$NOTARY_DIR"' EXIT
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_DIR/ntfy-macos.zip"
    xcrun notarytool submit "$NOTARY_DIR/ntfy-macos.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
    echo "Developer ID build: notarization accepted and ticket stapled."
fi

printf '\nApp bundle: %s\n' "$APP_BUNDLE"
echo 'User install (quit any running copy first):'
echo '  mkdir -p "$HOME/Applications"'
echo '  ditto ".build/release/ntfy-macos.app" "$HOME/Applications/ntfy-macos.app"'
echo 'Notification-only smoke test:'
echo '  "$HOME/Applications/ntfy-macos.app/Contents/MacOS/ntfy-macos" test-notify --topic local-smoke'
echo 'See docs/BUILD_ON_MAC.md for permissions, logs, and signing limitations.'
