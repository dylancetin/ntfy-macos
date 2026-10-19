# Security changes and migration

This fork addresses the static-review findings in upstream commit
`f7b77f3e19caa4a1a9197b0ef1bb775bdc6806b5`. The review found security defects, not
evidence of deliberate malware. These changes are hardening and regression fixes,
not a certification that the program or user-supplied automation is risk-free.

For a fresh local installation, follow [BUILD_ON_MAC.md](BUILD_ON_MAC.md). The
original Homebrew tap and upstream release downloads do not include this fork's changes.

## Changes

1. **Server/topic isolation.** Message topics are checked against their originating
   subscription. Automation, stored notification actions, and URL policies use the
   originating server together with the topic. A notification's click URL is not
   trusted as its origin identity. Legacy notifications without origin metadata
   cannot dispatch privileged actions. Ambiguous topic-only configuration lookups
   return no result.
2. **Action policy.** Publisher-supplied HTTP actions require an explicitly
   configured, nonempty `allowed_domains` list and permitted HTTP/HTTPS scheme.
   Requests use isolated networking and reject redirects. Browser-opening actions
   use their originating server's policy. Incoming script/file action resolution
   is disabled, including in the formerly unused resolver helper.
3. **Settings/config integrity.** Settings preserves `allowed_schemes`,
   `allowed_domains`, and the local API token, including empty deny-all lists.
   Saving, reloading, and opening the config honor the active custom path.
   Production loading and saving now invoke configuration validation.
4. **Literal Shortcut text.** Notification text is supplied as literal input through
   a private temporary file, rather than interpreting the text itself as a local
   filename. Temporary data is cleaned up after execution.
5. **Execution and resource limits.** Automation has bounded execution slots and
   time budgets. Output pipes are drained without logging potentially private
   contents. Incoming stream records, HTTP work, and retained notification
   categories are bounded. Log rotation runs during writes, not only at startup.
6. **Private diagnostics/storage.** Routine logs omit message bodies, action URLs,
   script arguments, and script output. Logs and configuration use private storage.
   Config reads reject symlinks, nonregular files, wrong ownership, unsafe directory
   ancestry, group/other access, and files above 1 MiB. Writes use a mode-0600
   temporary file and atomic replacement; sample creation will not overwrite an
   existing file. YAML decoding errors do not echo secret configuration contents.
7. **Authenticated local notifications.** The optional server stays loopback-only
   and notification-only. It now requires bearer authentication, exact loopback
   Host, and JSON content type, rejects browser origins and ambiguous HTTP framing,
   and limits connections, request time, and request rate.
8. **Example scripts.** The SSH example validates an explicit host allowlist and
   passes arguments instead of embedding notification text into executable
   AppleScript/shell source. Home Assistant examples require HTTPS and credentials
   supplied through the local environment.
9. **Supply chain.** Yams and GitHub Actions are pinned to verified upstream
   revisions. The dependency lockfile is tracked; builds fail rather than silently
   selecting new dependencies. SwiftPM sandboxing stays enabled. Fork releases use
   validated tags, least-privilege build/publish jobs, checksums, and provenance,
   without writing to the original author's tap or notifying external release channels.

## Existing configuration: required migration

Quit the running app or stop its old Homebrew service before switching binaries.
Back up your configuration privately. Do not overwrite it with a sample.

### Configuration file permissions

For the default path:

```bash
chmod 700 "$HOME/.config/ntfy-macos"
chmod 600 "$HOME/.config/ntfy-macos/config.yml"
```

For a custom `--config` path, apply private permissions to that file and its
dedicated directory. Config paths must be owned by your account, without a
group/world-writable ancestor (root-owned sticky system temp directories are an
exception). Symlink config files are rejected; use a regular private copy instead.
New files are created privately automatically. Prefer Keychain for subscription
tokens. Only edit permissions on directories you own and intend to use for this app.

Server URLs must be HTTP/HTTPS URLs without embedded credentials, query strings,
or fragments. Topic names use ASCII letters, digits, `_` or `-` (1–256 bytes).
Duplicate topic names across different servers are supported and now isolated;
duplicate server URLs or duplicate topics within one server are rejected.

### Local API token

If the local server is unused, omit `local_server_port`. If it is enabled, either:

- Enable/configure its port and Save in Settings; a private random token is generated.
  The Copy button then supplies an authenticated curl command. That command contains
  a credential: keep it private.
- Generate a token locally with `openssl rand -hex 32`, then add its output as
  `local_server_token` next to `local_server_port` in the private YAML file.

Tokens must be 32–256 ASCII letters, digits, `_` or `-`. Do not copy a token from a
documentation example, commit it, or send it to a remote ntfy topic. Both `/notify`
and `/health` require `Authorization: Bearer <token>`. POST requires
`Content-Type: application/json`. The old unauthenticated curl command will return
401. The token is not automatically exported to arbitrary automation scripts;
provision it privately only to scripts that need local notification access.

Limits: 4 KiB headers, 4 KiB body, 16 connections, five-second connection deadline,
and 60 authenticated requests per minute. No CORS access is provided. The API
never dispatches notification actions or topic-configured scripts.

### URL policies and actions

For a server whose publishers may offer an HTTP action button:

```yaml
allowed_schemes: [https]
allowed_domains: [api.your-domain.example]
```

Replace the example with the exact destinations you trust. `allowed_domains: []`
denies all destinations. Omitting it disables HTTP action execution; it retains
unrestricted host behavior for ordinary browser-opening actions. An allowlisted
hostname is not an IP/network sandbox: DNS and the explicitly trusted service
remain part of the trust boundary. Redirecting endpoints must be replaced by their
final allowed URL. Requests do not inherit subscription tokens.

Existing delivered notifications lack the new origin metadata; clear them and use
new notifications after upgrading. Shortcuts that accidentally relied on message
text being interpreted as a file path must be updated to accept literal text.

### Logs and automation

Old log files/backups may already contain sensitive content. New logging cannot
erase copies previously retained elsewhere. Review your existing logs privately.

Configured shell commands, AppleScripts, and Shortcuts are still trusted local
programs with your user privileges. A local config command may intentionally use
shell syntax; it is not an executable allowlist. Message input remains untrusted,
even with correct quoting at the app boundary. Avoid `eval` and constructing another
shell/AppleScript command from that input. Review optional examples before enabling
their real operations. Application execution budgets do not provide an OS sandbox
or guarantee containment of descendants that deliberately daemonize.

## Signing and remaining verification boundaries

Local builds default to **ad-hoc signing**. Developer ID signing/notarization requires
your own already-provisioned Apple signing identity and notary keychain profile;
the build guide documents the optional path. No signing identity was invented or
committed. Automated release assets are explicitly labeled ad-hoc and unnotarized;
checksums and GitHub provenance are not substitutes for Apple notarization.

The Linux editing host cannot exercise macOS notification authorization, GUI
behavior, Keychain prompts, or Shortcut privacy permissions. Use the fork's actual
macOS CI results for compile/test evidence and the local-agent guide for an
interactive notification smoke test. Pinned third-party sources and trusted local
automation still require their own review.
