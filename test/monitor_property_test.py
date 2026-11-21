"""Property tests for scripts/albedo-monitor.py.

Discovery suite: not wired into the flake checks (it needs hypothesis). The
oracles come from docs/monitor.md (contract version 1): fixed error codes,
`remaining_percent` inversion, the staleness thresholds, the newest-report rule
and the never-crash/json-safe rules for arbitrary daemon payloads.

    python3 test/monitor_property_test.py -v
"""

import importlib.util
import json
import math
import os
import re
import sys
import tempfile
import threading
import time
import unittest
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from hypothesis import HealthCheck, given, settings, strategies as st

SOURCE = os.environ.get(
    "ALBEDO_MONITOR_SOURCE",
    str(Path(__file__).resolve().parents[1] / "scripts/albedo-monitor.py"),
)
spec = importlib.util.spec_from_file_location("monitor_props", SOURCE)
assert spec is not None and spec.loader is not None
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)

SECRET = "credential-canary-secret"
SETTINGS = settings(
    max_examples=150,
    deadline=None,
    suppress_health_check=list(HealthCheck),
)

ACCOUNT_KEYS = {"provider", "account", "windows", "error"}
INVENTORY_ACCOUNT_KEYS = ACCOUNT_KEYS | {"id"}
WINDOW_KEYS = {
    "label",
    "remaining_percent",
    "resets_at",
    "resets_at_epoch",
    "observed_at",
    "observed_at_epoch",
    "stale_reason",
    "status",
    "stale",
}
SESSION_KEYS = {
    "id",
    "title",
    "workspace",
    "model",
    "status",
    "phase",
    "parent_id",
    "clients",
}
SNAPSHOT_KEYS = {
    "version",
    "online",
    "error",
    "sessions",
    "accounts",
    "accounts_error",
}
STALE_REASONS = {"", "observation_missing", "observation_old", "clock_skew", "reset_passed"}
CODE = re.compile(r"[a-z][a-z0-9_]*")
WORKING_PHASES = {"preparing", "generating", "running", "compacting", "interrupting"}


def as_text(value):
    """Strings pass through (bounded); anything else becomes the empty default."""
    return value[:4096] if isinstance(value, str) else ""


def renderable_sessions():
    """Sessions the monitor can render: an object status with a phase."""
    return session_items().filter(
        lambda item: isinstance(item["status"], dict)
    )


def iso(epoch):
    try:
        return datetime.fromtimestamp(epoch, UTC).isoformat()
    except (OSError, OverflowError, ValueError):
        return "out-of-range"


# ---- generators ---------------------------------------------------------


def scalars():
    return st.one_of(
        st.none(),
        st.booleans(),
        st.integers(),
        st.integers(min_value=-10**6, max_value=10**6).map(lambda n: n * 10**380),
        st.floats(),
        st.text(),
    )


def values():
    return st.recursive(
        scalars(),
        lambda child: st.one_of(
            st.lists(child, max_size=3),
            st.dictionaries(st.text(max_size=8), child, max_size=4),
        ),
        max_leaves=6,
    )


def timestamps():
    return st.one_of(
        st.none(),
        st.just(""),
        st.just("not-a-time"),
        st.just("2026-05-02T14:00:00"),  # naive: not a timestamp
        st.just("9999-12-31T23:59:59.999999+14:00"),
        st.just("0001-01-01T00:00:00+00:00"),
        st.integers(min_value=0, max_value=2 * 10**9).map(iso),
        st.floats(allow_nan=False, allow_infinity=False).map(
            lambda n: iso(n) if 0 < n < 2**31 * 10**6 else "x"
        ),
    )


@st.composite
def readings(draw, account="a", provider="p"):
    reading = {
        "provider": draw(st.one_of(st.just(provider), st.text(max_size=4), scalars())),
        "account_id": draw(st.one_of(st.just(account), st.text(max_size=4), scalars())),
        "limit_id": draw(st.text(max_size=6)),
        "label": draw(st.one_of(st.text(max_size=6), scalars())),
        "window_label": draw(st.one_of(st.text(max_size=6), st.none(), scalars())),
    }
    for key, strategy in (
        ("used_percent", st.one_of(st.none(), st.floats(), st.integers(), st.text(max_size=3), st.booleans())),
        ("status", st.one_of(st.just("ok"), st.just("error"), st.just("unknown"), st.just("warning"), st.text(max_size=5))),
        ("error", st.one_of(st.none(), st.text(max_size=5), st.dictionaries(st.text(max_size=4), scalars(), max_size=2))),
        ("observed_at", timestamps()),
        ("resets_at", timestamps()),
        ("sequence", st.one_of(st.none(), st.integers(), st.booleans(), st.text(max_size=3))),
    ):
        if draw(st.booleans()):
            reading[key] = draw(strategy)
    if draw(st.booleans()):
        reading["error"] = {"detail": SECRET}
    if draw(st.booleans()):
        reading["preview"] = {"text": SECRET}
    return reading


@st.composite
def session_items(draw):
    item = {
        "id": draw(st.one_of(st.text(max_size=8), scalars())),
        "name": draw(st.one_of(st.text(max_size=8), scalars())),
        "automatic_name": draw(st.one_of(st.text(max_size=8), st.none())),
        "workspace": draw(st.one_of(st.text(max_size=8), scalars())),
        "model": draw(st.one_of(st.text(max_size=8), st.none(), scalars())),
        "parent_id": draw(st.one_of(st.text(max_size=8), st.none(), scalars())),
        "closed": draw(st.booleans()),
        "status": draw(
            st.one_of(
                st.none(),
                st.text(max_size=4),
                st.fixed_dictionaries(
                    {
                        "phase": st.one_of(
                            st.sampled_from(
                                [
                                    "idle",
                                    "preparing",
                                    "interrupting",
                                    "compacting",
                                    "generating",
                                    "running",
                                    "future",
                                    "",
                                ]
                            ),
                            st.text(max_size=5),
                            scalars(),
                        )
                    },
                    optional={
                        "blocking_reason": st.one_of(st.none(), st.text(max_size=5), scalars())
                    },
                ),
            )
        ),
        "preview": {"text": SECRET},
        "transcript": SECRET,
    }
    return item


@st.composite
def accounts_inventory(draw):
    return {
        "accounts": [
            {
                "id": draw(st.one_of(st.text(max_size=8), scalars())),
                "provider": draw(
                    st.sampled_from(
                        ["claude", "codex", "antigravity", "opencode-go", "openai", "", "weird"]
                    )
                ),
                "label": draw(st.text(max_size=8)),
                "kind": draw(st.one_of(st.just("key"), st.just("oauth"), st.none())),
                "selected_by_profiles": draw(
                    st.one_of(st.lists(st.text(max_size=6), max_size=2), scalars())
                ),
                "rotated_by_profiles": draw(
                    st.one_of(st.lists(st.text(max_size=6), max_size=2), scalars())
                ),
            }
            for _ in range(draw(st.integers(min_value=0, max_value=3)))
        ]
    }


@st.composite
def credentials(draw):
    def credential():
        value = {
            "_albedo_account_id": draw(st.one_of(st.text(max_size=6), scalars())),
            "accountId": draw(st.one_of(st.text(max_size=6), scalars())),
            "email": draw(st.one_of(st.text(max_size=8), scalars())),
            "orgName": draw(st.one_of(st.text(max_size=6), scalars())),
            "access": SECRET,
            "refresh": SECRET,
            "apiKey": SECRET,
        }
        return value

    accounts = {}
    for store in ("anthropic", "openai-codex", "google-antigravity", "opencode-go"):
        if draw(st.booleans()):
            accounts[store] = (
                [credential() for _ in range(draw(st.integers(max_value=2)))]
                if draw(st.booleans())
                else credential()
            )
    return {"accounts": accounts, "mcp": {"secret": SECRET}}


@st.composite
def server_payloads(draw):
    payload = {
        "protocol": draw(st.sampled_from([4, 4, 4, 3, "4", None])),
        "state": draw(st.sampled_from(["ready", "ready", "draining", None, 7])),
        "instance_id": draw(st.sampled_from(["fixed", "other", None])),
        "quota": draw(st.lists(readings(), max_size=4)),
    }
    if draw(st.booleans()):
        payload["quota"] = draw(values())
    if draw(st.booleans()):
        payload["build"] = draw(st.one_of(st.text(max_size=6), st.none()))
    return payload


@st.composite
def collection_pages(draw):
    items = [draw(session_items()) for _ in range(draw(st.integers(max_value=3)))]
    next_cursor = draw(st.one_of(st.none(), st.text(max_size=4), st.integers(), st.just("")))
    page = {"items": items, "next": next_cursor}
    if draw(st.booleans()):
        page["items"] = draw(values())
    return page


def assert_json_default(value):
    json.dumps(value, allow_nan=False)


def assert_code(value):
    assert isinstance(value, str), value
    assert value == "" or CODE.fullmatch(value), value


# ---- pure functions -----------------------------------------------------


class AccountRowsPropertyTests(unittest.TestCase):
    @SETTINGS
    @given(st.lists(readings(), max_size=5))
    def test_never_crashes_and_keeps_the_documented_schema(self, rows):
        try:
            accounts = monitor.account_rows(rows)
        except monitor.MonitorError as error:
            self.assertEqual(str(error), "invalid_response")
            return
        assert_json_default(accounts)
        for account in accounts:
            self.assertEqual(set(account), ACCOUNT_KEYS)
            self.assertTrue(account["provider"] and account["account"])
            assert_code(account["error"])
            for window in account["windows"]:
                self.assertEqual(set(window), WINDOW_KEYS)
                self.assertIn(window["stale_reason"], STALE_REASONS)
                self.assertIs(window["stale"], bool(window["stale_reason"]))
                self.assertIsInstance(window["status"], str)
                self.assertIsInstance(window["label"], str)
                self.assertTrue(window["resets_at"] is None or isinstance(window["resets_at"], str))
                self.assertTrue(window["observed_at"] is None or isinstance(window["observed_at"], str))
                for key in ("resets_at_epoch", "observed_at_epoch", "remaining_percent"):
                    value = window[key]
                    self.assertTrue(value is None or math.isfinite(value), (key, value))

    @SETTINGS
    @given(st.lists(readings(), max_size=5))
    def test_rows_are_a_function_of_their_inputs(self, rows):
        try:
            first = monitor.account_rows(rows)
        except monitor.MonitorError as error:
            self.assertEqual(str(error), "invalid_response")
            return
        second = monitor.account_rows(list(rows))
        self.assertEqual(first, second)
        self.assertEqual(
            sorted(json.dumps(a, sort_keys=True) for a in first),
            sorted(
                json.dumps(a, sort_keys=True)
                for a in monitor.account_rows(list(reversed(rows)))
            ),
        )

    @SETTINGS
    @given(st.lists(readings(), max_size=5))
    def test_incomplete_account_keys_are_rejected_together(self, rows):
        try:
            monitor.account_rows(rows)
        except monitor.MonitorError:
            return
        for row in rows:
            if not isinstance(row, dict):
                self.fail("non-object reading accepted")
        # A rejected set must be rejected whichever order it arrives in.
        try:
            monitor.account_rows(list(reversed(rows)))
        except monitor.MonitorError:
            self.fail("order changed acceptance of an incomplete account key")

    @SETTINGS
    @given(st.lists(readings(), max_size=5))
    def test_no_secret_reaches_the_output(self, rows):
        try:
            accounts = monitor.account_rows(rows)
        except monitor.MonitorError:
            return
        self.assertNotIn(SECRET, json.dumps(accounts))

    @SETTINGS
    @given(
        used=st.one_of(
            st.none(),
            st.booleans(),
            st.just(0),
            st.just(0.0),
            st.just(100),
            st.just(100.0),
            st.just(-0.0),
            st.just(99.999),
            st.just(0.001),
            st.just(-1),
            st.just(101),
            st.just(float("nan")),
            st.just(float("inf")),
            st.just("50"),
            st.just(10**400),
            st.floats(allow_nan=False, allow_infinity=False, min_value=0, max_value=100),
            st.floats(allow_nan=False, allow_infinity=False, min_value=-2, max_value=102),
        )
    )
    def test_remaining_percent_is_an_exact_inversion_in_range(self, used):
        rows = monitor.account_rows([{"provider": "p", "account_id": "a", "used_percent": used}])
        window = rows[0]["windows"][0]
        documented = (
            type(used) in (int, float)
            and 0 <= used <= 100
            and math.isfinite(used)
        )
        if documented:
            self.assertEqual(window["remaining_percent"], 100 - used)
            self.assertEqual(window["remaining_percent"] + used, 100)
        else:
            self.assertIsNone(window["remaining_percent"])
        assert_json_default(rows)

    @SETTINGS
    @given(
        observed=st.one_of(
            st.none(),
            st.just(-1800.0),
            st.just(-1800.000001),
            st.just(-1799.999999),
            st.just(-60.0),
            st.just(0.0),
            st.just(60.0),
            st.just(60.000001),
            st.just(59.999999),
            st.floats(allow_nan=False, allow_infinity=False, min_value=-10**6, max_value=10**6),
        ),
        resets=st.one_of(
            st.none(),
            st.just(0.0),
            st.just(-0.000001),
            st.just(0.000001),
            st.floats(allow_nan=False, allow_infinity=False, min_value=-10**6, max_value=10**6),
        ),
    )
    def test_stale_reason_thresholds_are_exact(self, observed, resets):
        now = 1_800_000_000.0
        reason = monitor.stale_reason(observed, resets, now)
        if resets is not None and resets <= now:
            self.assertEqual(reason, "reset_passed")
        elif observed is None:
            self.assertEqual(reason, "observation_missing")
        elif observed > now + 60:
            self.assertEqual(reason, "clock_skew")
        elif now - observed > 1800:
            self.assertEqual(reason, "observation_old")
        else:
            self.assertEqual(reason, "")
        self.assertIs(monitor.stale_window(observed, resets, now), bool(reason))

    def test_staleness_boundaries_at_the_documented_edges(self):
        now = 1_800_000_000.0
        # Older than 30 minutes is stale; exactly 30 minutes is not.
        self.assertEqual(monitor.stale_reason(now - 1800, None, now), "")
        self.assertEqual(monitor.stale_reason(now - 1800 - 0.001, None, now), "observation_old")
        # A minute of future skew is tolerated; more is not.
        self.assertEqual(monitor.stale_reason(now + 60, None, now), "")
        self.assertEqual(monitor.stale_reason(now + 60.001, None, now), "clock_skew")
        # An elapsed reset outranks every observation reason.
        self.assertEqual(monitor.stale_reason(None, now, now), "reset_passed")
        self.assertEqual(monitor.stale_reason(None, now + 0.001, now), "observation_missing")

    @SETTINGS
    @given(
        older=st.lists(readings(), max_size=3),
        fresh_used=st.one_of(st.none(), st.integers(min_value=0, max_value=100)),
    )
    def test_only_the_newest_report_contributes_windows(self, older, fresh_used):
        now = time.time()
        epochs = [now - 600 - index for index in range(len(older))]
        for row, epoch in zip(older, epochs):
            row["provider"] = "p"
            row["account_id"] = "a"
            row["observed_at"] = iso(epoch)
            row.pop("sequence", None)
        fresh = {
            "provider": "p",
            "account_id": "a",
            "limit_id": "",
            "label": "fresh",
            "used_percent": fresh_used,
            "status": "ok",
            "observed_at": iso(now),
        }
        rows = monitor.account_rows(older + [fresh])
        self.assertEqual([window["label"] for window in rows[0]["windows"]], ["fresh"])

    @SETTINGS
    @given(
        older=st.lists(readings(), max_size=3),
        sequence=st.integers(min_value=0, max_value=10**6),
    )
    def test_a_newer_sequence_outranks_a_rolled_back_clock(self, older, sequence):
        now = time.time()
        for row in older:
            row["provider"] = "p"
            row["account_id"] = "a"
            row["sequence"] = sequence - 1
            row["observed_at"] = iso(now + 1000)
        fresh = {
            "provider": "p",
            "account_id": "a",
            "label": "fresh",
            "used_percent": 5,
            "status": "ok",
            "sequence": sequence,
            "observed_at": iso(now - 10**6),
        }
        rows = monitor.account_rows(older + [fresh])
        self.assertEqual([window["label"] for window in rows[0]["windows"]], ["fresh"])


class SessionRowPropertyTests(unittest.TestCase):
    @SETTINGS
    @given(session_items())
    def test_status_follows_the_documented_mapping(self, item):
        if not isinstance(item["status"], dict):
            with self.assertRaises(monitor.MonitorError):
                monitor.session_row(item)
            return
        row = monitor.session_row(item)
        assert_json_default(row)
        self.assertEqual(set(row), SESSION_KEYS)
        phase = item["status"].get("phase")
        phase = phase if isinstance(phase, str) else "unknown"
        self.assertEqual(row["phase"], phase)
        if phase in WORKING_PHASES:
            expected = "working"
        elif phase == "idle":
            expected = "waiting" if item["status"].get("blocking_reason") else "idle"
        else:
            expected = "unknown"
        self.assertEqual(row["status"], expected)
        self.assertIsNone(row["clients"])
        title = monitor.text(item["name"]) or monitor.text(item["automatic_name"])
        self.assertEqual(row["title"], title)
        self.assertNotIn(SECRET, json.dumps(row))


class ConnectedAccountsPropertyTests(unittest.TestCase):
    @SETTINGS
    @given(accounts_inventory(), st.lists(readings(), max_size=4), credentials())
    def test_join_keeps_inventory_order_and_never_crashes(self, auth, rows, creds_doc):
        identities = {}
        for store, value in creds_doc["accounts"].items():
            for credential in value if isinstance(value, list) else [value]:
                public_id = credential["_albedo_account_id"]
                identity = credential["accountId"] or credential["email"] or credential["orgName"]
                if isinstance(public_id, str) and public_id and isinstance(identity, str) and identity:
                    identities.setdefault((store, public_id), []).append(identity)
        unique = {key: values[0] for key, values in identities.items() if len(values) == 1}
        try:
            accounts = monitor.connected_accounts(auth, rows, unique)
        except monitor.MonitorError as error:
            self.assertEqual(str(error), "invalid_response")
            return
        assert_json_default(accounts)
        self.assertEqual(len(accounts), len(auth["accounts"]))
        for source, account in zip(auth["accounts"], accounts):
            self.assertEqual(set(account), INVENTORY_ACCOUNT_KEYS)
            self.assertIsInstance(account["id"], str)
            self.assertIsInstance(account["provider"], str)
            self.assertIsInstance(account["account"], str)
            assert_code(account["error"])
            for window in account["windows"]:
                self.assertEqual(set(window), WINDOW_KEYS)
            if account["windows"]:
                self.assertEqual(account["error"], "")
        self.assertNotIn(SECRET, json.dumps(accounts))

    @SETTINGS
    @given(accounts_inventory(), st.lists(readings(), max_size=4))
    def test_identity_error_codes_are_fixed_codes(self, auth, rows):
        try:
            accounts = monitor.connected_accounts(auth, rows, {})
        except monitor.MonitorError:
            return
        for account in accounts:
            self.assertIn(
                account["error"],
                {
                    "",
                    "quota_unavailable",
                    "quota_identity_unavailable",
                    "quota_identity_ambiguous",
                    "quota_error",
                    "quota_unsupported",
                    "quota_unknown",
                },
            )
            if account["error"]:
                self.assertEqual(account["windows"], [])

    @SETTINGS
    @given(credentials())
    def test_identity_index_is_total_and_secret_free(self, creds_doc):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "creds.json").write_text(json.dumps(creds_doc))
            index, error = monitor.identity_index(Path(directory))
        assert_code(error)
        self.assertIsInstance(index, dict)
        for key, identity in index.items():
            self.assertEqual(len(key), 2)
            self.assertIsInstance(identity, str)
        self.assertNotIn(
            SECRET,
            json.dumps(sorted(f"{key}: {identity}" for key, identity in index.items())),
        )


class DiscoverPropertyTests(unittest.TestCase):
    @SETTINGS
    @given(values())
    def test_acceptance_is_the_documented_record_shape(self, document):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "daemon.json").write_text(json.dumps(document))
            try:
                accepted = monitor.discover(Path(directory))
            except monitor.MonitorError:
                accepted = None
            except Exception as error:  # noqa: BLE001 - the property is totality
                self.fail(f"discover raised {type(error).__name__}: {error}")
        valid = (
            isinstance(document, dict)
            and type(document.get("port")) is int
            and 1 <= document["port"] <= 65535
            and type(document.get("pid")) is int
            and document["pid"] > 0
            and type(document.get("version")) is int
            and document["version"] == 4
            and isinstance(document.get("token"), str)
            and 0 < len(document["token"]) <= 4096
            and document["token"].isascii()
            and all(32 < ord(character) < 127 for character in document["token"])
        )
        if valid:
            self.assertEqual(accepted, document)
        else:
            self.assertIsNone(accepted)

    def test_file_level_limits_are_enforced(self):
        base = {"version": 4, "pid": 1, "port": 8080, "token": "t"}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "daemon.json"
            path.write_text(json.dumps(base))
            self.assertEqual(monitor.discover(Path(directory))["port"], 8080)
            path.write_text(json.dumps({**base, "token": "t" * 4096}))
            self.assertEqual(len(monitor.discover(Path(directory))["token"]), 4096)
            path.write_text(json.dumps({**base, "token": "t" * 4097}))
            with self.assertRaises(monitor.MonitorError):
                monitor.discover(Path(directory))
            path.write_bytes(b" " * 65536)
            with self.assertRaises(monitor.MonitorError):
                monitor.discover(Path(directory))
            path.write_text(json.dumps({**base, "port": 0}))
            with self.assertRaises(monitor.MonitorError):
                monitor.discover(Path(directory))
            path.write_text(json.dumps({**base, "port": 65535}))
            self.assertEqual(monitor.discover(Path(directory))["port"], 65535)


# ---- snapshot end to end ------------------------------------------------


class SnapshotHarness(unittest.TestCase):
    """One fake daemon per test, answering from the test's own payloads."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.owner = self
        self.server_value = {"protocol": 4, "state": "ready", "quota": []}
        self.auth_value = {"accounts": []}
        self.sessions_value = {"items": [], "next": None}
        self.pages = None
        self.raw = None
        self.raw_paths = {}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if owner.raw is not None:
                    data = owner.raw
                elif self.path.split("?")[0] in owner.raw_paths:
                    data = owner.raw_paths[self.path.split("?")[0]]
                elif self.path == "/server":
                    data = json.dumps(owner.server_value).encode()
                elif self.path == "/auth":
                    data = json.dumps(owner.auth_value).encode()
                elif owner.pages is not None:
                    from urllib.parse import parse_qs, urlsplit

                    query = urlsplit(self.path).query
                    cursor = parse_qs(query).get("next", [None])[0]
                    data = json.dumps(owner.pages[cursor]).encode()
                else:
                    data = json.dumps(owner.sessions_value).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        ).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        (self.home / "daemon.json").write_text(
            json.dumps(
                {
                    "version": 4,
                    "pid": os.getpid(),
                    "port": self.server.server_port,
                    "token": SECRET,
                }
            )
        )
        (self.home / "creds.json").write_text(json.dumps({"accounts": {}}))

class SnapshotPropertyTests(SnapshotHarness):
    @SETTINGS
    @given(server=server_payloads(), auth=accounts_inventory(), page=collection_pages())
    def test_snapshot_is_total_json_safe_and_fixed_code(self, server, auth, page):
        self.server_value = server
        self.auth_value = auth
        self.sessions_value = page
        snapshot = monitor.snapshot(self.home)
        json.dumps(snapshot, allow_nan=False)
        self.assertEqual(set(snapshot), SNAPSHOT_KEYS)
        self.assertEqual(snapshot["version"], 1)
        self.assertIsInstance(snapshot["online"], bool)
        assert_code(snapshot["error"])
        assert_code(snapshot["accounts_error"])
        # A ready server stays online even when a later request fails.
        if not snapshot["online"]:
            self.assertNotEqual(snapshot["error"], "")
        for row in snapshot["sessions"]:
            self.assertEqual(set(row), SESSION_KEYS)
            assert_code(row["phase"])
        for account in snapshot["accounts"]:
            self.assertEqual(set(account), ACCOUNT_KEYS)
        self.assertNotIn(SECRET, json.dumps(snapshot))

    @SETTINGS
    @given(server=server_payloads())
    def test_later_failures_keep_a_ready_server_online(self, server):
        self.server_value = server
        self.auth_value = {"accounts": 5}  # inventory shape the monitor must reject
        self.sessions_value = {"items": [], "next": None}
        snapshot = monitor.snapshot(self.home)
        self.assertIsInstance(snapshot["online"], bool)
        if snapshot["online"]:
            assert_code(snapshot["accounts_error"])
        json.dumps(snapshot, allow_nan=False)

    @SETTINGS
    @given(raw=st.one_of(
        st.binary(max_size=64),
        st.text(max_size=64).map(str.encode),
        st.just(b"[" * 2000 + b"0" + b"]" * 2000),
    ))
    def test_malformed_bodies_never_escape(self, raw):
        self.raw = raw
        snapshot = monitor.snapshot(self.home)
        self.assertFalse(snapshot["online"])
        self.assertEqual(snapshot["error"], "invalid_response")
        json.dumps(snapshot, allow_nan=False)


class PaginationPropertyTests(SnapshotHarness):
    """The documented 20-page collection cap and its cursor validation."""

    @SETTINGS
    @given(
        length=st.integers(min_value=1, max_value=3),
        rows=st.lists(renderable_sessions(), min_size=0, max_size=6),
    )
    def test_all_pages_are_collected_in_order(self, length, rows):
        self.pages: dict[str | None, dict] = {}
        cursors = [f"page-{index}" for index in range(length)]
        offsets = [0]
        collected = []
        for index in range(length):
            taken = rows[offsets[-1]:][:2]
            collected.append(taken)
            offsets.append(offsets[-1] + len(taken))
            self.pages[cursors[index - 1] if index else None] = {
                "items": taken,
                "next": cursors[index] if index + 1 < length else None,
            }
        snapshot = monitor.snapshot(self.home)
        self.assertEqual(snapshot["error"], "")
        self.assertTrue(snapshot["online"])
        expected = [
            as_text(row["id"])
            for page in collected
            for row in page
            if not row["closed"]
        ]
        self.assertEqual([row["id"] for row in snapshot["sessions"]], expected)

    @SETTINGS
    @given(rows=st.lists(renderable_sessions(), min_size=0, max_size=4))
    def test_a_cursor_cycle_is_reported_and_partial_rows_kept(self, rows):
        self.pages = {
            None: {"items": rows, "next": "again"},
            "again": {"items": [], "next": "again"},
        }
        snapshot = monitor.snapshot(self.home)
        self.assertTrue(snapshot["online"])
        self.assertEqual(snapshot["error"], "invalid_pagination")
        self.assertEqual(
            [row["id"] for row in snapshot["sessions"]],
            [as_text(row["id"]) for row in rows if not row["closed"]],
        )

    @SETTINGS
    @given(rows=st.lists(renderable_sessions(), min_size=0, max_size=3), bad=st.one_of(
        st.integers(), st.just(""), st.just(0), st.lists(st.text(max_size=2), max_size=1)
    ))
    def test_a_cursor_that_is_not_a_usable_token_is_reported(self, rows, bad):
        self.pages = {None: {"items": rows, "next": bad}}
        snapshot = monitor.snapshot(self.home)
        self.assertEqual(snapshot["error"], "invalid_pagination")
        json.dumps(snapshot, allow_nan=False)

    def test_the_collection_stops_at_twenty_pages(self):
        # Every page offers another cursor: twenty are read, then truncated.
        rows = [
            {"id": str(index), "name": "n", "status": {"phase": "idle"}}
            for index in range(20)
        ]
        pages = {
            None: {"items": [rows[0]], "next": "page-1"},
        }
        for index in range(1, 40):
            pages[f"page-{index}"] = {"items": [rows[index % 20]], "next": f"page-{index + 1}"}
        self.pages = pages
        snapshot = monitor.snapshot(self.home)
        self.assertTrue(snapshot["online"])
        self.assertEqual(snapshot["error"], "sessions_truncated")
        self.assertEqual(len(snapshot["sessions"]), 20)

    def test_the_response_body_cap_is_exactly_eight_mebibytes(self):
        limit = 8 * 1024 * 1024
        prefix = b'{"protocol":4,"state":"ready","quota":[],"padding":"'
        body = prefix + b"a" * (limit - len(prefix) - 2) + b'"}'
        self.assertEqual(len(body), limit)
        self.raw_paths = {"/server": body}
        snapshot = monitor.snapshot(self.home)
        self.assertTrue(snapshot["online"], snapshot["error"])
        self.assertEqual(snapshot["error"], "")
        self.raw_paths = {"/server": body[:-2] + b'x"}'}
        snapshot = monitor.snapshot(self.home)
        self.assertFalse(snapshot["online"])
        self.assertEqual(snapshot["error"], "response_too_large")


if __name__ == "__main__":
    unittest.main()
