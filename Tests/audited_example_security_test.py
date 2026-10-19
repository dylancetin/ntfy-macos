#!/usr/bin/env python3
"""Harmless regression stubs: never invoke Terminal, SSH, HA, or cleanup examples."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class AuditedExampleSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ntfy-example-tests-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.args_file = self.directory / "arguments"
        self.stdin_file = self.directory / "stdin"
        self.calls_file = self.directory / "calls"
        self.env = os.environ.copy()
        for key in ("HA_URL", "HA_TOKEN", "NTFY_LOCAL_TOKEN", "NTFY_TOPIC", "NTFY_PRIORITY"):
            self.env.pop(key, None)
        self.env.update({
            "PATH": str(self.directory) + os.pathsep + os.defpath,
            "HOME": str(self.directory),
            "CAPTURE_ARGS": str(self.args_file),
            "CAPTURE_STDIN": str(self.stdin_file),
            "CAPTURE_CALLS": str(self.calls_file),
        })
        stub = """#!/bin/sh
printf '%s\\0' "$@" > "$CAPTURE_ARGS"
cat > "$CAPTURE_STDIN"
printf 'called\\n' >> "$CAPTURE_CALLS"
printf '%s' "${STUB_HTTP_STATUS:-204}"
"""
        for name in ("osascript", "curl"):
            executable = self.directory / name
            executable.write_text(stub)
            executable.chmod(0o700)

    def run_example(self, name, *args, extra_env=None):
        env = dict(self.env, **(extra_env or {}))
        return subprocess.run(
            ["/bin/bash", str(ROOT / "examples" / name), *args],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
        )

    def captured_arguments(self):
        return self.args_file.read_bytes().rstrip(b"\0").decode().split("\0")

    def test_ssh_only_accepts_exact_local_allowlisted_hosts_as_argv(self):
        for host in ("myserver.example.com", "backup.example.com"):
            with self.subTest(host=host):
                result = self.run_example("scripts/open-ssh.sh", host)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.captured_arguments(), ["-", host])
                source = self.stdin_file.read_text()
                self.assertNotIn(host, source)
                self.assertIn("item 1 of argv", source)
                self.assertIn("quoted form of serverName", source)

    def test_ssh_rejects_unlisted_hosts_options_and_injection(self):
        payloads = (
            "", "unlisted.example.com", "user@myserver.example.com", "-oProxyCommand=anything",
            "myserver.example.com; touch marker", "myserver.example.com$(touch marker)",
            "myserver.example.com`touch marker`", 'myserver.example.com"', "myserver.example.com'",
            "myserver.example.com\nbackup.example.com", "myserver.example.com && true",
            "myserver.example.com\\", "myserver.example.com ", " myserver.example.com",
        )
        for payload in payloads:
            with self.subTest(payload=payload):
                result = self.run_example("scripts/open-ssh.sh", payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls_file.exists())
                if payload:
                    self.assertNotIn(payload.encode(), result.stderr)

    def test_home_assistant_requires_https_and_environment_token(self):
        for name in ("garage-toggle.sh", "unlock-door.sh"):
            for env in ({}, {"HA_URL": "https://ha.example"},
                        {"HA_URL": "http://ha.example", "HA_TOKEN": "secret"},
                        {"HA_URL": "https://ha.example", "HA_TOKEN": "bad\nheader"}):
                with self.subTest(name=name, env=env):
                    result = self.run_example("scripts/" + name, extra_env=env)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(self.calls_file.exists())

    def test_home_assistant_does_not_expose_token_in_argv_or_follow_redirects(self):
        for name, endpoint in (("garage-toggle.sh", "cover/toggle"), ("unlock-door.sh", "lock/unlock")):
            for status in ("204", "302", "307"):
                with self.subTest(name=name, status=status):
                    self.calls_file.unlink(missing_ok=True)
                    result = self.run_example("scripts/" + name, extra_env={
                        "HA_URL": "https://ha.example/", "HA_TOKEN": "PRIVATE-test-token",
                        "STUB_HTTP_STATUS": status,
                    })
                    self.assertEqual(result.returncode == 0, status == "204")
                    arguments = self.captured_arguments()
                    self.assertEqual(arguments[0], "--disable")
                    for forbidden in ("--insecure", "-k", "--location", "-L", "--location-trusted"):
                        self.assertNotIn(forbidden, arguments)
                    for flag, value in (("--proto", "=https"), ("--proto-redir", "=https"),
                                        ("--max-redirs", "0"), ("--header", "@-"), ("--max-time", "20")):
                        self.assertEqual(arguments[arguments.index(flag) + 1], value)
                    self.assertEqual(arguments[arguments.index("--url") + 1],
                                     "https://ha.example/api/services/" + endpoint)
                    self.assertNotIn("PRIVATE-test-token", " ".join(arguments))
                    self.assertIn("Authorization: Bearer PRIVATE-test-token", self.stdin_file.read_text())
                    self.assertNotIn(b"PRIVATE-test-token", result.stdout + result.stderr)
                    self.assertEqual(self.calls_file.read_text(), "called\n")

    def test_sample_handler_uses_fixed_json_and_never_logs_remote_content(self):
        remote = 'REMOTE-SECRET-"},"injected":true,"x":"'
        result = self.run_example("sample-handler.sh", remote, extra_env={
            "NTFY_TOPIC": remote, "NTFY_MESSAGE": remote, "NTFY_PRIORITY": "4",
            "NTFY_LOCAL_TOKEN": "a" * 32,
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = self.captured_arguments()
        body = json.loads(arguments[arguments.index("--data") + 1])
        self.assertEqual(body, {"title": "Script completed", "message": "Handled high-priority alert"})
        self.assertNotIn(remote.encode(), result.stdout + result.stderr)
        self.assertFalse((self.directory / ".ntfy-macos-handler.log").exists())


if __name__ == "__main__":
    unittest.main()
