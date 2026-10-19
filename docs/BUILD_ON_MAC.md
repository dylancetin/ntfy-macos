# macOS build and local-agent handoff

Build this fork from reviewed source on the Mac that will run it. The default is
a **LOCAL, ad-hoc signed, unnotarized** app. It is not a Developer ID distribution
build. This guide installs only into `~/Applications` and runs a notification-only
smoke test; it does not configure subscriptions, automation, or a background service.

## 1. Prerequisites and source identity

Use a macOS version supported by your installed **full Xcode 16 or newer**, with
**Swift 6 or newer**. CI uses macOS 15 with Xcode 16.4 (Swift 6.1). Command Line Tools
alone are not the documented toolchain. Open Xcode once and complete its normal
license/component setup. Use an interactive logged-in desktop session for the
notification test.
Python 3 is also used for the five portable example-script security regressions
(standard library only; no pip dependencies).

Run these commands in Terminal (or hand them to a local coding agent):

```bash
git clone --branch main --single-branch https://github.com/dylancetin/ntfy-macos.git
cd ntfy-macos
git remote get-url origin
git rev-parse HEAD
git log -1 --format=fuller
git status --short
```

Record the full commit SHA and review that checkout before building. `main` can
move; the recorded SHA identifies what you actually built. Use a fresh destination
for the clone rather than overwriting an existing working tree.

Select the full Xcode for this shell, adjusting the path if necessary. This does
not change the machine-wide selection and needs no administrator command:

```bash
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
xcode-select --print-path
xcodebuild -version
xcrun --find swift
swift --version
uname -m
```

`DEVELOPER_DIR` overrides the selection printed by `xcode-select`. Confirm that
`swift --version` reports version 6 or newer before continuing. The build is native
architecture, not universal: `arm64` on Apple Silicon, `x86_64` on Intel. Run a
native Terminal on Apple Silicon rather than one launched under Rosetta.

## 2. Resolve locked inputs, test, and build

Yams is pinned in both `Package.swift` and the checked-in `Package.resolved` to
the official stable **5.4.0** commit:

```text
https://github.com/jpsim/Yams.git
3d6871d5b4a5cd519adf233fbb576e0a2af71c17
```

This revision was verified against the upstream tag with `git ls-remote` and the
GitHub commit API. The upstream manifest has no package dependencies and requires
Swift tools 5.7; the release notes document Swift 6.1 compatibility. The tag and
manifest review is not a claim of a complete third-party security audit.

```bash
set -euo pipefail
mkdir -p .build/handoff-logs
swift package resolve --force-resolved-versions 2>&1 | tee .build/handoff-logs/resolve.log
swift test --force-resolved-versions 2>&1 | tee .build/handoff-logs/tests.log
python3 Tests/audited_example_security_test.py 2>&1 | tee .build/handoff-logs/example-tests.log
SIGNING_IDENTITY=- ./build-app.sh 2>&1 | tee .build/handoff-logs/build.log
git diff --exit-code -- Package.swift Package.resolved
```

The script also resolves and builds with `--force-resolved-versions`; missing or
incompatible locked dependencies fail instead of silently selecting new versions.
SwiftPM's sandbox stays enabled. Initial dependency fetching needs network access.
The compatible lockfile v2 format records a revision pin, not a floating branch
or a version range. Do not run `swift package update` as part of this handoff.

Equivalent convenience commands are `make resolve`, `make test`, and `make app`.
The full test suite must pass; use the actual test output for counts. `make build`
produces a bare executable, whereas `make app` produces the signed app bundle
needed for this notification test.

These instructions and dependency metadata were prepared on Linux without Swift;
that preparation is not evidence of macOS compilation or test success. The local
agent and macOS CI must report their actual results.

## 3. Validate and install for the current user

```bash
codesign --verify --deep --strict --verbose=2 ".build/release/ntfy-macos.app"
codesign --display --verbose=4 ".build/release/ntfy-macos.app"
file ".build/release/ntfy-macos.app/Contents/MacOS/ntfy-macos"
shasum -a 256 ".build/release/ntfy-macos.app/Contents/MacOS/ntfy-macos"
```

For the default build, expect `Signature=adhoc` and no Developer ID authority.
Signature verification checks bundle integrity; it does not establish publisher
identity, notarization, or Gatekeeper acceptance. Rebuilding an ad-hoc app changes
its code identity and may affect saved notification or Keychain permissions.

Quit any running copy before installation. Install and recheck the copied bundle:

```bash
mkdir -p "$HOME/Applications"
ditto ".build/release/ntfy-macos.app" "$HOME/Applications/ntfy-macos.app"
codesign --verify --deep --strict --verbose=2 "$HOME/Applications/ntfy-macos.app"
```

Use the same installed path for subsequent testing. No system-wide installation
or `sudo` is needed. Do not disable Gatekeeper, remove quarantine attributes, or
change SIP to make a downloaded/ad-hoc app run. If macOS blocks a build, record the
message and investigate the signing/build provenance; a proper distribution build
requires the credentials described below.

## 4. Normal authorization and notification-only smoke test

Run the executable inside the installed bundle explicitly:

```bash
"$HOME/Applications/ntfy-macos.app/Contents/MacOS/ntfy-macos" \
  test-notify --topic local-smoke 2>&1 | tee .build/handoff-logs/notification-smoke.log
```

Respond to the normal macOS notification dialog. Confirm a **Test Notification**
whose body mentions `local-smoke`. That name is just a local display label: this
command does not publish to or subscribe to an ntfy server and does not execute
automation. Do not substitute `serve`, a bare app launch, or a background service
for this smoke test; those start normal service behavior and may load an existing
configuration.

If permission was previously denied, open **System Settings → Notifications →
ntfy-macos → Allow Notifications**. Check Focus settings if banners are suppressed.
The helper `./setup-permissions.sh` runs the same test against the user-installed
app; an optional first argument selects a different bundle. It does not reset TCC
permissions or claim success merely because a command exited.

Inspect captured output and, if useful, the unified log:

```bash
/usr/bin/log show --last 10m --style compact \
  --predicate 'process == "ntfy-macos"' > .build/handoff-logs/unified.log
```

An exit status alone is not proof that a notification was displayed. Record the
observed authorization state and whether the banner/Notification Center entry
appeared. Leave automation and background startup unconfigured for this handoff.

## 5. Optional Developer ID signing and notarization

Only use this section when distribution signing is wanted and credentials are
already provisioned in the local keychain. Nothing in the repository supplies an
Apple developer account, certificate, private key, or notary credentials.

List available local signing identities:

```bash
security find-identity -v -p codesigning
```

Set `SIGNING_IDENTITY` to an existing identity's name or certificate hash. For
distribution, it must be a **Developer ID Application** identity. For example,
replace the descriptive values below with your existing identity/profile:

```bash
SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
NOTARY_PROFILE='YOUR_EXISTING_NOTARYTOOL_KEYCHAIN_PROFILE' \
  ./build-app.sh
```

Non-ad-hoc signing enables hardened runtime and a secure timestamp. Setting
`NOTARY_PROFILE` explicitly opts into uploading the built app to Apple's notary
service using that existing keychain profile. The script requires a Developer ID
signature, waits for notarization, staples and validates the ticket, rechecks the
signature, and runs Gatekeeper assessment. A failure stops the script. No credentials
are embedded, imported, or committed. Leaving `NOTARY_PROFILE` unset performs no
notarization; signing alone is not notarization. An Apple Development or other
non-Developer-ID identity is not a substitute for distribution signing.

For a successful distribution build, independently verify:

```bash
codesign --verify --deep --strict --verbose=2 ".build/release/ntfy-macos.app"
codesign --display --verbose=4 ".build/release/ntfy-macos.app"
xcrun stapler validate ".build/release/ntfy-macos.app"
spctl --assess --type execute --verbose=2 ".build/release/ntfy-macos.app"
```

`APP_VERSION=1.2.3` optionally sets the copied bundle's version. Only stable
`MAJOR.MINOR.PATCH` SemVer without leading zeros is accepted; prerelease/build
metadata is intentionally excluded from the plist version. The tracked source
plist stays unchanged.

## CI, release artifacts, and provenance

The **Build & Test** workflow runs on pushes to `main`, pull requests, and manual
`workflow_dispatch`. It resolves locked inputs, runs the complete suite, builds and
verifies an ad-hoc bundle, and uploads a clearly labeled native-architecture archive.
It does not publish a release.

The **Release** workflow runs only when a user deliberately pushes a tag. It accepts
only `vMAJOR.MINOR.PATCH` stable SemVer tags, with no leading zeros. This handoff does
not create or push tags. Builds/tests have read-only repository permissions; a
separate publishing job receives release-write, attestation-write, and OIDC access.
Checkout does not persist credentials. There is no Homebrew tap write or external
release-status notification integration.

Hosted release artifacts are explicitly named **ad-hoc-unnotarized** and their
release title/notes state the signing limitations. They include `BUILD-INFO.txt`
(source SHA, architecture, toolchain, signing mode), `SHA256SUMS`, and a GitHub
artifact-attestation bundle (`provenance.jsonl`). They are not universal binaries.

After downloading the assets for a chosen release, check their hashes and verify
the archive's GitHub attestation (set `ARCHIVE` to its exact downloaded filename):

```bash
shasum -a 256 --check SHA256SUMS
gh attestation verify "$ARCHIVE" --repo dylancetin/ntfy-macos
```

Inspect the verified workflow/ref and source SHA against the release you intended
to download. GitHub provenance identifies the producing workflow; it is separate
from Apple's signing/notarization trust and does not make an ad-hoc app pass
Gatekeeper.

### Reviewed immutable action pins

Each pin was verified against the official action repository's exact release tag
using `git ls-remote --tags`; update only after reviewing a new upstream release.

| Action | Release | Commit |
| --- | --- | --- |
| `actions/checkout` | `v7.0.1` | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `actions/upload-artifact` | `v7.0.2` | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| `actions/download-artifact` | `v8.0.2` | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
| `actions/attest-build-provenance` | `v4.2.2` | `4d101475d8b20a2381f78447822ac1eab6504dd8` |

The provenance action itself pins `actions/attest` to
`508db95dd578ae2727ebd6217d5ba78e4fbda05d` (`v4.2.1`), also verified upstream.
Action pins and dependency revisions do not freeze the hosted runner OS image,
all Apple tools, or make these builds byte-for-byte reproducible.

## Local agent completion report

Return the fork URL and full source SHA, macOS/Xcode/Swift versions, native
architecture, exact resolve/test/build commands and actual outcomes, code-signing
mode and verification output, installed path, and observed notification result.
Attach or summarize `.build/handoff-logs/` as needed after checking for private
data. Report any unavailable signing/notarization credentials or failed checks
accurately. Do not commit/push, publish releases, install a service, enable
automation, or change system security settings as part of this handoff.
