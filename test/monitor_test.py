import importlib.util
import json
import os
import tempfile
import threading
import time
import unittest
from datetime import UTC
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

SOURCE = os.environ.get(
    "ALBEDO_MONITOR_SOURCE",
    str(Path(__file__).resolve().parents[1] / "scripts/albedo-monitor.py"),
)
spec = importlib.util.spec_from_file_location("monitor", SOURCE)
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.requests = []
        self.server_value = {
            "protocol": 3,
            "state": "ready",
            "instance_id": "test",
            "quota": [],
        }
        self.auth_value = {"accounts": []}
        self.sessions = {"items": [], "next": None}
        self.status = 200
        self.delay = 0
        self.raw = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append(
                    (self.command, self.path, self.headers.get("Authorization"))
                )
                if owner.delay:
                    threading.Event().wait(owner.delay)
                value = (
                    owner.server_value
                    if self.path == "/server"
                    else owner.auth_value
                    if self.path == "/auth"
                    else owner.sessions
                )
                data = (
                    owner.raw if owner.raw is not None else json.dumps(value).encode()
                )
                self.send_response(owner.status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except BrokenPipeError:
                    pass

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(
            target=self.server.serve_forever,
            kwargs={"poll_interval": 0.01},
            daemon=True,
        )
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.discovery = {
            "version": 3,
            "pid": os.getpid(),
            "port": self.server.server_port,
            "token": "credential-canary",
            "instance_id": "test",
        }
        self.write("daemon.json", self.discovery)
        self.write("creds.json", {"accounts": {}})

    def write(self, name, value):
        (self.home / name).write_text(json.dumps(value))

    def snapshot(self, **kwargs):
        return monitor.snapshot(self.home, **kwargs)

    def test_discovery_absent_and_invalid(self):
        (self.home / "daemon.json").unlink()
        self.assertEqual(self.snapshot()["error"], "daemon_not_running")
        for value in (
            {},
            {**self.discovery, "port": True},
            {**self.discovery, "token": "secret\nheader"},
            {**self.discovery, "version": 2},
        ):
            self.write("daemon.json", value)
            self.assertEqual(self.snapshot()["error"], "invalid_discovery")
        (self.home / "daemon.json").write_text("{broken credential-canary")
        self.assertEqual(self.snapshot()["error"], "invalid_discovery")
        self.assertEqual(self.requests, [])

    def test_discovery_fifo_and_oversize(self):
        (self.home / "daemon.json").unlink()
        os.mkfifo(self.home / "daemon.json")
        self.assertEqual(self.snapshot()["error"], "invalid_discovery")
        (self.home / "daemon.json").unlink()
        (self.home / "daemon.json").write_bytes(b"x" * 65537)
        self.assertEqual(self.snapshot()["error"], "invalid_discovery")

    def test_authentication_and_body_redaction(self):
        for status in (401, 403, 500, 302):
            self.status = status
            self.raw = b"credential-canary prompt transcript"
            result = self.snapshot()
            self.assertFalse(result["online"])
            self.assertNotIn("credential-canary", json.dumps(result))
            self.assertEqual(
                result["error"],
                "authentication_failed"
                if status in (401, 403)
                else "http_" + str(status),
            )
        self.assertTrue(
            all(row[2] == "Bearer credential-canary" for row in self.requests)
        )

    def test_identity_mismatch(self):
        self.server_value["instance_id"] = "other"
        self.assertEqual(self.snapshot()["error"], "daemon_identity_changed")
        self.assertEqual(len(self.requests), 1)

    def test_invalid_json(self):
        self.raw = b"credential-canary"
        self.assertEqual(self.snapshot()["error"], "invalid_response")

    def test_sessions_subagents_and_privacy(self):
        self.sessions["items"] = [
            {
                "id": str(i),
                "name": "Agent",
                "workspace": "/workspace",
                "model": "test",
                "parent_id": "root",
                "status": {"phase": phase, "blocking_reason": blocked},
                "preview": {"text": "secret-prompt"},
                "transcript": "secret-prompt",
            }
            for i, (phase, blocked) in enumerate(
                (
                    ("running", None),
                    ("idle", {"detail": "secret-prompt"}),
                    ("idle", None),
                    ("future", None),
                )
            )
        ]
        result = self.snapshot()
        self.assertEqual(
            [row["status"] for row in result["sessions"]],
            ["working", "waiting", "idle", "unknown"],
        )
        self.assertTrue(
            all(
                row["clients"] is None and row["parent_id"] == "root"
                for row in result["sessions"]
            )
        )
        self.assertNotIn("secret-prompt", json.dumps(result))
        self.assertIn("scope=all", self.requests[-1][1])
        self.assertTrue(all(row[0] == "GET" for row in self.requests))
        self.assertEqual(
            [row[1].split("?")[0] for row in self.requests],
            ["/server", "/auth", "/sessions"],
        )

    def test_multiaccount_exact_join(self):
        self.auth_value["accounts"] = [
            {"id": "one", "provider": "claude", "label": "Claude Pro/Max"},
            {"id": "two", "provider": "claude", "label": "Claude Pro/Max"},
            {"id": "three", "provider": "colab", "label": "GPU"},
        ]
        self.write(
            "creds.json",
            {
                "accounts": {
                    "anthropic": [
                        {
                            "_albedo_account_id": "one",
                            "accountId": "a",
                            "access": "credential-canary",
                        },
                        {
                            "_albedo_account_id": "two",
                            "accountId": "b",
                            "refresh": "credential-canary",
                        },
                    ]
                },
                "mcp": {"secret": "credential-canary"},
            },
        )
        self.server_value["quota"] = [
            {
                "provider": "anthropic",
                "account_id": identity,
                "used_percent": used,
                "status": "ok",
                "label": "Daily",
                "observed_at": "2099-01-01T00:00:00Z",
                "resets_at": None,
            }
            for identity, used in (("a", 20), ("b", 70), ("disconnected", 90))
        ]
        result = self.snapshot()
        self.assertEqual(
            [a["windows"][0]["remaining_percent"] for a in result["accounts"][:2]],
            [80, 30],
        )
        self.assertEqual(result["accounts"][2]["error"], "quota_unavailable")
        self.assertEqual(len(result["accounts"]), 3)
        self.assertNotIn("credential-canary", json.dumps(result))
        self.assertNotIn("disconnected", json.dumps(result))
        self.assertEqual(result["accounts_error"], "")

    def test_ambiguous_and_missing_identity(self):
        auth = {
            "accounts": [
                {"id": "one", "provider": "claude", "label": "same"},
                {"id": "two", "provider": "claude", "label": "same"},
            ]
        }
        reading = [
            {"provider": "anthropic", "account_id": "shared", "used_percent": 20}
        ]
        rows = monitor.connected_accounts(
            auth,
            reading,
            {("anthropic", "one"): "shared", ("anthropic", "two"): "shared"},
        )
        self.assertTrue(all(row["error"] == "quota_unavailable" for row in rows))
        (self.home / "creds.json").write_text("credential-canary")
        self.assertEqual(
            monitor.identity_index(self.home), ({}, "account_identity_unavailable")
        )

    def test_remaining_unknown_errors_and_staleness(self):
        for used in (None, "50", -1, 101, float("nan"), True):
            row = monitor.account_rows(
                [{"provider": "p", "account_id": "a", "used_percent": used}]
            )[0]
            self.assertIsNone(row["windows"][0]["remaining_percent"])
            self.assertTrue(row["windows"][0]["stale"])
        row = monitor.account_rows(
            [
                {
                    "provider": "p",
                    "account_id": "a",
                    "used_percent": 20,
                    "error": {"detail": "credential-canary"},
                }
            ]
        )[0]
        self.assertIsNone(row["windows"][0]["remaining_percent"])
        self.assertNotIn("credential-canary", json.dumps(row))
        now = time.time()
        from datetime import datetime

        stamp = lambda n: datetime.fromtimestamp(n, UTC).isoformat()
        self.assertFalse(monitor.stale_window(stamp(now - 60), stamp(now + 60), now))
        self.assertTrue(monitor.stale_window(stamp(now - 1801), None, now))
        self.assertTrue(monitor.stale_window(stamp(now - 60), stamp(now - 1), now))

    def test_timeout_and_unreachable(self):
        self.delay = 0.2
        started = time.monotonic()
        self.assertEqual(self.snapshot(timeout=0.03)["error"], "timeout")
        self.assertLess(time.monotonic() - started, 0.18)
        self.write("daemon.json", {**self.discovery, "port": 1})
        self.assertEqual(self.snapshot()["error"], "daemon_unreachable")

    def test_pagination_cycle_and_partial(self):
        self.sessions["next"] = "again"
        result = self.snapshot()
        self.assertTrue(result["online"])
        self.assertEqual(result["error"], "invalid_pagination")
        self.assertEqual(len(self.requests), 4)

    def test_deep_json_and_large_numbers(self):
        self.raw = b"[" * 2000 + b"0" + b"]" * 2000
        self.assertEqual(self.snapshot()["error"], "invalid_response")
        (self.home / "creds.json").write_bytes(self.raw)
        self.assertEqual(
            monitor.identity_index(self.home), ({}, "account_identity_unavailable")
        )
        row = monitor.account_rows(
            [{"provider": "p", "account_id": "a", "used_percent": 10**400}]
        )[0]
        self.assertIsNone(row["windows"][0]["remaining_percent"])
        self.assertTrue(monitor.stale_window("9999-99-99", None, time.time()))

    def test_provider_identity_formats(self):
        self.write(
            "creds.json",
            {
                "accounts": {
                    "openai-codex": {"_albedo_account_id": "codex", "email": "email"},
                    "google-antigravity": {
                        "_albedo_account_id": "google",
                        "email": "google-email",
                    },
                    "opencode-go": {
                        "_albedo_account_id": "go",
                        "email": "go-email",
                        "orgName": "org",
                    },
                }
            },
        )
        index, error = monitor.identity_index(self.home)
        self.assertEqual(error, "")
        self.assertEqual(
            index,
            {
                ("openai-codex", "codex"): "email",
                ("google-antigravity", "google"): "google-email",
                ("opencode-go", "go"): "go-email · org",
            },
        )

    def test_auth_failure_preserves_sessions(self):
        with patch.object(
            monitor.Client,
            "get",
            side_effect=[
                self.server_value,
                monitor.MonitorError("authentication_failed"),
                self.sessions,
            ],
        ):
            result = self.snapshot()
        self.assertTrue(result["online"])
        self.assertEqual(result["error"], "")
        self.assertEqual(result["accounts_error"], "authentication_failed")
        self.assertEqual(result["accounts"], [])

    def test_local_files_unchanged(self):
        before = {path.name: path.read_bytes() for path in self.home.iterdir()}
        self.snapshot()
        self.assertEqual(
            before, {path.name: path.read_bytes() for path in self.home.iterdir()}
        )


if __name__ == "__main__":
    unittest.main()
