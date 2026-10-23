"""Read a bounded, non-attaching snapshot from an already running daemon."""

import argparse
import http.client
import json
import math
import os
import signal
import stat
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import urlencode


class MonitorError(Exception):
    pass


def text(value, fallback=""):
    return value[:4096] if isinstance(value, str) else fallback


def object_value(value):
    if not isinstance(value, dict):
        raise MonitorError("invalid_response")
    return value


def array(value):
    if not isinstance(value, list):
        raise MonitorError("invalid_response")
    return value


class Client:
    def __init__(self, discovery, timeout):
        self.discovery = discovery
        self.deadline = time.monotonic() + timeout

    def get(self, path):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise MonitorError("timeout")
        conn = http.client.HTTPConnection(
            "127.0.0.1", self.discovery["port"], timeout=remaining
        )
        try:
            conn.request(
                "GET",
                path,
                headers={
                    "Authorization": "Bearer " + self.discovery["token"],
                    "Accept": "application/json",
                },
            )
            response = conn.getresponse()
            if response.status in (401, 403):
                raise MonitorError("authentication_failed")
            if response.status != 200:
                raise MonitorError("http_" + str(response.status))
            chunks = []
            size = 0
            while True:
                remaining = self.deadline - time.monotonic()
                if remaining <= 0:
                    raise MonitorError("timeout")
                if conn.sock is not None:
                    conn.sock.settimeout(remaining)
                chunk = response.read1(65536)
                if not chunk:
                    break
                size += len(chunk)
                if size > 8 * 1024 * 1024:
                    raise MonitorError("response_too_large")
                chunks.append(chunk)
            return object_value(json.loads(b"".join(chunks)))
        except TimeoutError:
            raise MonitorError("timeout") from None
        except (OSError, http.client.HTTPException):
            raise MonitorError("daemon_unreachable") from None
        except (ValueError, UnicodeError, RecursionError, OverflowError):
            raise MonitorError("invalid_response") from None
        finally:
            conn.close()


def read_local_json(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise ValueError("not a regular file")
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise ValueError("file too large")
    try:
        return object_value(json.loads(data))
    except RecursionError:
        raise ValueError("invalid JSON") from None


def discover(home):
    try:
        value = read_local_json(Path(home) / "daemon.json", 65536)
        if (
            type(value.get("port")) is not int
            or not 1 <= value["port"] <= 65535
            or type(value.get("pid")) is not int
            or value["pid"] <= 0
            or value.get("version") != 3
            or type(value.get("version")) is not int
            or not isinstance(value.get("token"), str)
            or not value["token"]
            or len(value["token"]) > 4096
            or not value["token"].isascii()
            or any(ord(c) < 33 or ord(c) == 127 for c in value["token"])
        ):
            raise MonitorError("invalid_discovery")
        return value
    except FileNotFoundError:
        raise MonitorError("daemon_not_running") from None
    except (OSError, ValueError, UnicodeError):
        raise MonitorError("invalid_discovery") from None


def session_row(item):
    item = object_value(item)
    state = object_value(item.get("status"))
    phase = text(state.get("phase"), "unknown")
    status = "unknown"
    if phase in {"preparing", "generating", "running", "compacting", "interrupting"}:
        status = "working"
    elif phase == "idle":
        status = "waiting" if state.get("blocking_reason") else "idle"
    return {
        "id": text(item.get("id")),
        "title": text(item.get("name")) or text(item.get("automatic_name")),
        "workspace": text(item.get("workspace")),
        "model": text(item.get("model"), None),
        "status": status,
        "phase": phase,
        "parent_id": text(item.get("parent_id"), None),
        "clients": None,
    }


def stale_window(observed, resets, now):
    def stamp(value):
        try:
            parsed = datetime.fromisoformat(value)
            return parsed.timestamp() if parsed.tzinfo is not None else None
        except (AttributeError, ValueError, TypeError, OverflowError, OSError):
            return None

    observed_at = stamp(observed)
    resets_at = stamp(resets)
    return (
        observed_at is None
        or observed_at > now + 60
        or now - observed_at > 1800
        or (resets_at is not None and resets_at <= now)
    )


def account_rows(readings):
    accounts = {}
    now = time.time()
    for reading in array(readings):
        reading = object_value(reading)
        key = (text(reading.get("provider")), text(reading.get("account_id")))
        if not all(key):
            raise MonitorError("invalid_response")
        account = accounts.setdefault(
            key, {"provider": key[0], "account": key[1], "windows": [], "error": ""}
        )
        status = text(reading.get("status"), "unknown")
        if reading.get("error") is not None or status in {
            "error",
            "unsupported",
            "unknown",
        }:
            account["error"] = (
                "quota_" + status
                if status in {"error", "unsupported", "unknown"}
                else "quota_unavailable"
            )
        used = reading.get("used_percent")
        remaining = None
        if (
            reading.get("error") is None
            and type(used) in (int, float)
            and 0 <= used <= 100
            and math.isfinite(used)
        ):
            remaining = 100 - used
        account["windows"].append(
            {
                "label": text(reading.get("window_label"))
                or text(reading.get("label"))
                or text(reading.get("limit_id")),
                "remaining_percent": remaining,
                "resets_at": text(reading.get("resets_at"), None),
                "observed_at": text(reading.get("observed_at"), None),
                "status": status,
                "stale": stale_window(
                    reading.get("observed_at"), reading.get("resets_at"), now
                ),
            }
        )
    for account in accounts.values():
        if not account["error"] and not any(
            window["remaining_percent"] is not None for window in account["windows"]
        ):
            account["error"] = "quota_unavailable"
    return list(accounts.values())


def identity_index(home):
    try:
        accounts = object_value(
            read_local_json(Path(home) / "creds.json", 1024 * 1024).get("accounts", {})
        )
        index = {}
        stores = {
            "anthropic": "anthropic",
            "openai-codex": "openai-codex",
            "google-antigravity": "google-antigravity",
            "opencode-go": "opencode-go",
        }
        for store, provider in stores.items():
            stored = accounts.get(store, [])
            for credential in stored if isinstance(stored, list) else [stored]:
                if not isinstance(credential, dict):
                    continue
                public_id = text(credential.get("_albedo_account_id"))
                identity = ""
                if provider == "anthropic":
                    identity = text(
                        credential.get("accountId", credential.get("email"))
                    )
                elif provider == "openai-codex":
                    identity = text(credential.get("email")) or text(
                        credential.get("accountId")
                    )
                elif provider == "google-antigravity":
                    identity = text(credential.get("email"))
                elif provider == "opencode-go":
                    email = text(credential.get("email"))
                    org = text(credential.get("orgName"))
                    identity = (
                        email + " · " + org
                        if email and org
                        else email
                        or org
                        or text(credential.get("accountId"))
                        or "OpenCode Go"
                    )
                if public_id and identity:
                    index.setdefault((provider, public_id), []).append(identity)
        return {key: values[0] for key, values in index.items() if len(values) == 1}, ""
    except (OSError, ValueError, UnicodeError, MonitorError):
        return {}, "account_identity_unavailable"


def connected_accounts(auth, readings, identities):
    samples = {(row["provider"], row["account"]): row for row in account_rows(readings)}
    aliases = {
        "claude": "anthropic",
        "codex": "openai-codex",
        "antigravity": "google-antigravity",
    }
    inventory = array(auth.get("accounts"))
    keys = []
    for raw in inventory:
        raw = object_value(raw)
        provider = text(raw.get("provider"))
        canonical = aliases.get(provider, provider)
        keys.append((canonical, identities.get((canonical, text(raw.get("id"))))))
    result = []
    for raw, key in zip(inventory, keys):
        provider = text(raw.get("provider"))
        label = text(raw.get("label"))
        public_id = text(raw.get("id"))
        if not provider or not public_id:
            raise MonitorError("invalid_response")
        sample = samples.get(key) if key[1] and keys.count(key) == 1 else None
        result.append(
            {
                "id": public_id,
                "provider": key[0],
                "account": label or public_id,
                "windows": sample["windows"] if sample else [],
                "error": sample["error"] if sample else "quota_unavailable",
            }
        )
    return result


def snapshot(home, timeout=5.0):
    result = {
        "version": 1,
        "online": False,
        "error": "",
        "sessions": [],
        "accounts": [],
        "accounts_error": "",
    }
    try:
        discovery = discover(home)
        client = Client(discovery, timeout)
        server = client.get("/server")
        if server.get("protocol") != 3 or server.get("state") != "ready":
            raise MonitorError("incompatible_daemon")
        for saved, observed in (
            ("instance_id", "instance_id"),
            ("build", "build"),
            ("digest", "digest"),
        ):
            if discovery.get(saved) and discovery[saved] != server.get(observed):
                raise MonitorError("daemon_identity_changed")
        result["online"] = True
        try:
            auth = client.get("/auth")
            identities, identity_error = identity_index(home)
            result["accounts_error"] = identity_error
            result["accounts"] = connected_accounts(
                auth, server.get("quota"), identities
            )
            if len(server["quota"]) >= 200:
                result["accounts_error"] = "quota_may_be_truncated"
        except MonitorError as exc:
            result["accounts_error"] = str(exc)
        cursor = None
        seen = set()
        for _ in range(20):
            query = {"scope": "all", "archived": "false", "limit": 100}
            if cursor:
                query["next"] = cursor
            page = client.get("/sessions?" + urlencode(query))
            rows = [
                session_row(row)
                for row in array(page.get("items"))
                if not object_value(row).get("closed", False)
            ]
            result["sessions"].extend(rows)
            cursor = page.get("next")
            if cursor is None:
                break
            if not isinstance(cursor, str) or not cursor or cursor in seen:
                raise MonitorError("invalid_pagination")
            seen.add(cursor)
        else:
            raise MonitorError("sessions_truncated")
    except MonitorError as exc:
        result["error"] = str(exc)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--home", default=os.environ.get("ALBEDO_HOME") or str(Path.home() / ".albedo")
    )
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 30:
        parser.error("--timeout must be greater than zero and at most 30 seconds")

    def timed_out(_signum, _frame):
        raise MonitorError("timeout")

    signal.signal(signal.SIGALRM, timed_out)
    signal.setitimer(signal.ITIMER_REAL, args.timeout)
    try:
        result = snapshot(args.home, args.timeout)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    print(json.dumps(result, allow_nan=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
