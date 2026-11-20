"""Property-based discovery tests for the suite's Python scripts.

Covers scripts/update-upstream.py (overlay discovery, three-way merge planning,
manifest generation), scripts/albedo-monitor.py (quota row selection, staleness,
privacy) and scripts/test-e2e.py (failed-test retry mapping).

Run with a hypothesis-enabled interpreter:

    python3 test/proptest_scripts_test.py

The oracles below are independent models of the documented contracts; they do
not call the implementation to compute expected values.
"""

import collections
import contextlib
import hashlib
import importlib.util
import io
import json
import math
import re
import tempfile
import traceback
import time
import unittest
from datetime import UTC, datetime
from unittest.mock import patch
from pathlib import Path

from hypothesis import HealthCheck, given, settings, strategies as st
from hypothesis import example

ROOT = Path(__file__).resolve().parents[1]
NOW = 1_800_000_000.0


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


updater = load("suite_updater", "scripts/update-upstream.py")
monitor = load("suite_monitor", "scripts/albedo-monitor.py")
runner = load("suite_e2e_runner", "scripts/test-e2e.py")

QUICK = settings(
    max_examples=200,
    deadline=None,
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.function_scoped_fixture],
)

NAMES = [
    "a",
    "b",
    "c.py",
    "d/e",
    "d/f",
    "g/h/i",
    "l",
    "l/x",
    "m.pyc",
    "__pycache__/n",
    "p",
]

CONTENT = st.binary(max_size=40)


def node():
    return st.one_of(
        st.tuples(st.just("file"), CONTENT),
        st.tuples(st.just("exec"), CONTENT),
        st.tuples(st.just("symlink"), st.sampled_from(["a", "d", "nowhere"])),
        st.tuples(st.just("dir"), st.just(b"")),
    )


SPEC = st.dictionaries(st.sampled_from(NAMES), node(), max_size=6)

# copytree dereferences links, so a suite overlay in these fixtures stays regular.
OVERLAY_SPEC = st.dictionaries(
    st.sampled_from(NAMES),
    st.one_of(
        st.tuples(st.just("file"), CONTENT),
        st.tuples(st.just("exec"), CONTENT),
        st.tuples(st.just("dir"), st.just(b"")),
    ),
    max_size=6,
)


def blocked(path, root):
    """True when a parent of path cannot hold children in this tree."""
    while path != root and path != path.parent:
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            return True
        path = path.parent
    return False


def materialize(root, spec):
    """Create spec entries, skipping any whose path collides with a parent."""
    for name in sorted(spec, key=lambda candidate: candidate.count("/")):
        kind, payload = spec[name]
        path = root / name
        if blocked(path.parent, root) or path.exists() or path.is_symlink():
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        if kind == "dir":
            path.mkdir()
        elif kind == "symlink":
            path.symlink_to(payload)
        else:
            path.write_bytes(payload)
            if kind == "exec":
                path.chmod(0o755)


def snapshot(root):
    """Comparable description of a tree, including modes and link targets."""
    entries = {}
    for path in sorted(root.rglob("*")):
        key = path.relative_to(root).as_posix()
        if path.is_symlink():
            entries[key] = ("link", path.readlink().as_posix())
        elif path.is_dir():
            entries[key] = ("dir", "")
        else:
            entries[key] = ("file", path.read_bytes(), path.stat().st_mode & 0o777)
    return entries


def overlay_files(root):
    """Independent model of the overlay inventory rule."""
    return sorted(
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if (not path.is_dir() or path.is_symlink())
        and "__pycache__" not in path.relative_to(root).parts
        and path.suffix != ".pyc"
    )


def regular(path):
    """Independent model of "a plain file with no symlinked path component"."""
    return path.is_file() and not path.is_symlink()


def write_baseline(suite, component, baseline, old):
    lines = []
    for name in sorted(baseline):
        source = old / name
        if baseline[name] == "wrong":
            checksum = hashlib.sha256(b"wrong").hexdigest()
        elif source.is_file() and not source.is_symlink():
            checksum = hashlib.sha256(source.read_bytes()).hexdigest()
        else:
            checksum = hashlib.sha256(b"missing").hexdigest()
        lines.append(f"{checksum}  {name}\n")
    (suite / "upstream" / f"{component}.sha256").write_text("".join(lines))


class Tree:
    """One generated (old, new, overlay, baseline) fixture on disk."""

    def __init__(self, directory, old, new, overlay, baseline, component):
        self.root = Path(directory)
        self.suite = self.root / "suite"
        self.old = self.root / "old"
        self.new = self.root / "new"
        self.component = component
        for path in (
            self.suite / "src/server",
            self.suite / "src/client",
            self.suite / "upstream",
            self.old,
            self.new,
        ):
            path.mkdir(parents=True)
        materialize(self.old, old)
        materialize(self.new, new)
        materialize(self.suite / "src" / component, overlay)
        for name in ("server", "client"):
            (self.suite / "upstream" / f"{name}.sha256").write_text("")
        write_baseline(self.suite, component, baseline, self.old)

    @property
    def overlay(self):
        return self.suite / "src" / self.component

    @property
    def manifests(self):
        return {
            self.suite / "upstream/server.sha256",
            self.suite / "upstream/client.sha256",
        }

    def plan(self, details=None):
        return updater.merge_overlay(self.suite, self.old, self.new, details)


def parse_manifest(data):
    lines = data.decode().splitlines()
    parsed = []
    for line in lines:
        checksum, name = line.split("  ", 1)
        parsed.append((checksum, name))
    return parsed


class OverlayDiscoveryTests(unittest.TestCase):
    @QUICK
    @given(spec=SPEC)
    def test_inventory_matches_the_documented_rule(self, spec):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            materialize(root, spec)
            self.assertEqual(updater.files(root), overlay_files(root))

    @QUICK
    @given(spec=SPEC)
    def test_inventory_is_sorted_and_unique(self, spec):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            materialize(root, spec)
            names = updater.files(root)
            self.assertEqual(names, sorted(set(names)))
            for name in names:
                self.assertTrue((root / name).exists() or (root / name).is_symlink())

    @QUICK
    @given(old=SPEC, new=SPEC)
    def test_upstream_changes_match_set_differences(self, old, new):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "t"
            root.mkdir()
            before, after = root / "old", root / "new"
            before.mkdir()
            after.mkdir()
            materialize(before, old)
            materialize(after, new)
            changes = updater.upstream_changes(before, after)
            old_names, new_names = set(overlay_files(before)), set(overlay_files(after))
            self.assertEqual(changes["added"], sorted(new_names - old_names))
            self.assertEqual(changes["removed"], sorted(old_names - new_names))
            expected = []
            for name in sorted(old_names & new_names):
                left, right = before / name, after / name
                if left.is_symlink() or right.is_symlink():
                    expected.append(name)
                elif left.read_bytes() != right.read_bytes():
                    expected.append(name)
            self.assertEqual(changes["modified"], expected)
            self.assertEqual(
                set(changes), {"added", "removed", "modified"}
            )


class MergePlanTests(unittest.TestCase):
    outcomes = collections.Counter()

    @classmethod
    def tearDownClass(cls):
        print("\nmerge plan outcomes:", dict(cls.outcomes))
        for wanted in ("clean", "conflict"):
            assert cls.outcomes[wanted] > 0, (wanted, dict(cls.outcomes))

    @QUICK
    @given(
        old=SPEC,
        new=SPEC,
        overlay=SPEC,
        baseline=st.dictionaries(
            st.sampled_from(NAMES), st.sampled_from(["hash", "wrong"]), max_size=6
        ),
        component=st.sampled_from(["server", "client"]),
    )
    def test_plan_invariants(self, old, new, overlay, baseline, component):
        with tempfile.TemporaryDirectory() as directory:
            tree = Tree(directory, old, new, overlay, baseline, component)
            before = snapshot(tree.root)
            details = {}
            writes, merged, unresolved = tree.plan(details)
            self.outcomes["conflict" if details["conflicts"] else "clean"] += 1
            self.assertEqual(before, snapshot(tree.root), "planning wrote to disk")
            names = overlay_files(tree.overlay)
            manifest = tree.suite / "upstream" / f"{component}.sha256"
            self.assertIn(manifest, writes)
            for path in set(writes) - tree.manifests:
                self.assertTrue(path.is_relative_to(tree.overlay), path)
                self.assertIn(path.relative_to(tree.overlay).as_posix(), names)
            self.assertEqual(tree.plan(), (writes, merged, unresolved))
            written = parse_manifest(writes[manifest])
            listed = [name for _, name in written]
            self.assertEqual(listed, sorted(set(listed)))
            for checksum, name in written:
                self.assertIn(name, baseline)
                source = tree.new / name
                self.assertTrue(regular(source), name)
                self.assertEqual(
                    checksum, hashlib.sha256(source.read_bytes()).hexdigest()
                )
            # Each manifest line hashes the pristine upstream file it names.
            self.assertEqual(
                [name for _, name in written],
                [
                    name
                    for name in listed
                    if hashlib.sha256((tree.new / name).read_bytes()).hexdigest()
                    == {entry: value for value, entry in written}[name]
                ],
            )
            labels = {text.split(": ", 1)[0] for text in unresolved}
            self.assertEqual(set(merged) & labels, set())
            for label in merged:
                component_name, name = label.split("/", 1)
                self.assertEqual(component_name, component)
                self.assertIn(name, baseline)
                self.assertIn(name, names)
            for path in details["conflicts"]:
                self.assertIn(path, {tree.overlay / name for name in names})
            for path, reference in details["setAside"].items():
                self.assertIn(path, {tree.overlay / name for name in names})
                self.assertTrue(regular(reference))
            for path in details["setAside"]:
                self.assertNotIn(f"  {path.name}\n", writes[manifest].decode())

    @QUICK
    @given(
        lines=st.integers(min_value=1, max_value=4),
        name=st.sampled_from(["a", "b", "d/e", "g/h/i"]),
    )
    def test_overlapping_deltas_are_withheld(self, lines, name):
        tail = b"base\n" * (lines - 1)
        tree_spec = {
            "old": {name: ("file", b"base\n" + tail)},
            "new": {name: ("file", b"upstream\n" + tail)},
            "overlay": {name: ("file", b"suite\n" + tail)},
        }
        with tempfile.TemporaryDirectory() as directory:
            tree = Tree(
                directory,
                tree_spec["old"],
                tree_spec["new"],
                tree_spec["overlay"],
                {name: "hash"},
                "server",
            )
            before = snapshot(tree.root)
            details = {}
            writes, merged, unresolved = tree.plan(details)
            self.outcomes["conflict"] += 1
            path = tree.overlay / name
            self.assertEqual(merged, [])
            self.assertEqual(list(details["conflicts"]), [path])
            marked = details["conflicts"][path]
            self.assertIn(b"<<<<<<< suite", marked)
            self.assertIn(b"||||||| old-upstream", marked)
            self.assertIn(b">>>>>>> new-upstream", marked)
            self.assertNotIn(path, writes)
            self.assertEqual(len(unresolved), 1, unresolved)
            self.assertTrue(unresolved[0].startswith(f"server/{name}: "), unresolved)
            self.assertIn("overlapping three-way conflict", unresolved[0])
            self.assertEqual(before, snapshot(tree.root))
            self.assertEqual(tree.plan()[0], writes)

    @QUICK
    @given(
        names=st.lists(
            st.sampled_from(["a", "b", "c.py", "d/e", "d/f", "g/h/i", "p"]),
            unique=True,
            max_size=5,
        ),
        base=st.lists(CONTENT, min_size=1, max_size=5),
        ours=st.lists(CONTENT, min_size=1, max_size=5),
        theirs=st.lists(CONTENT, min_size=1, max_size=5),
        modes=st.lists(st.sampled_from(["file", "exec"]), min_size=1, max_size=5),
    )
    def test_clean_merge_then_repin_is_a_no_op(self, names, base, ours, theirs, modes):
        old, new, overlay, baseline = {}, {}, {}, {}
        for index, name in enumerate(names):
            mode = modes[index % len(modes)]
            old[name] = (mode, base[index % len(base)].replace(b"\0", b""))
            new[name] = (mode, theirs[index % len(theirs)].replace(b"\0", b""))
            overlay[name] = ("file", ours[index % len(ours)].replace(b"\0", b""))
            baseline[name] = "hash"
        with tempfile.TemporaryDirectory() as directory:
            tree = Tree(directory, old, new, overlay, baseline, "server")
            details = {}
            writes, merged, unresolved = tree.plan(details)
            # Every refusal here is the three-way merge itself, never a
            # classification surprise: identical baselines and modes.
            self.assertTrue(
                all("overlapping three-way conflict" in text for text in unresolved),
                unresolved,
            )
            self.assertEqual(
                sorted(details["conflicts"]),
                sorted(
                    tree.overlay / text.split(": ", 1)[0].split("/", 1)[1]
                    for text in unresolved
                ),
            )
            for name in names:
                path = tree.overlay / name
                if old[name][1] == overlay[name][1] != new[name][1]:
                    # An unmodified suite copy adopts the upstream file.
                    self.assertEqual(writes[path], new[name][1])
                if path in writes:
                    self.assertNotIn(b"<<<<<<<", writes[path])
            if unresolved:
                return
            self.assertEqual(
                merged,
                [
                    f"server/{name}"
                    for name in sorted(names)
                    if old[name][1] != new[name][1]
                ],
            )
            repinned = Path(directory) / "repinned"
            (repinned / "upstream").mkdir(parents=True)
            (repinned / "src/server").mkdir(parents=True)
            for name in names:
                target = repinned / "src/server" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                source = tree.overlay / name
                target.write_bytes(
                    writes[source] if source in writes else source.read_bytes()
                )
            for component in ("server", "client"):
                (repinned / "upstream" / f"{component}.sha256").write_bytes(
                    writes[tree.suite / "upstream" / f"{component}.sha256"]
                )
            again = updater.merge_overlay(repinned, tree.new, tree.new, {})
            self.assertEqual(again[2], [], "repin after a clean merge reported work")
            self.assertEqual(again[1], [], "repin after a clean merge rewrote a file")
            self.assertEqual(
                {path.relative_to(repinned).as_posix(): text for path, text in again[0].items()},
                {
                    path.relative_to(tree.suite).as_posix(): text
                    for path, text in writes.items()
                    if "upstream/" in path.as_posix()
                },
            )


TOKENS = st.text(alphabet="abcdef0123456789", min_size=4, max_size=8)


def reading():
    stamp = st.one_of(
        st.none(),
        st.just("2026-01-01T00:00:00Z"),
        st.just("2026-01-01T00:30:00+00:00"),
        st.just("bad"),
        st.just("2026-01-01T00:00:00"),
        st.integers(),
    )
    return st.fixed_dictionaries(
        {
            "provider": st.sampled_from(["p", "anthropic", "q"]),
            "account_id": st.sampled_from(["a", "b", "c"]),
        },
        optional={
            "used_percent": st.one_of(
                st.none(),
                st.floats(allow_nan=True, allow_infinity=True),
                st.integers(min_value=-5, max_value=105),
                st.just(10**400),
                st.just("50"),
                st.booleans(),
            ),
            "status": st.sampled_from(["ok", "warning", "error", "unsupported", "other"]),
            "error": st.one_of(st.none(), st.builds(lambda raw: "ERR" + raw, TOKENS)),
            "observed_at": stamp,
            "resets_at": stamp,
            "sequence": st.one_of(st.none(), st.integers(-3, 5), st.just("7")),
            "limit_id": st.one_of(st.none(), st.sampled_from(["primary", "weekly", ""])),
            "window_label": st.one_of(st.none(), st.sampled_from(["Daily", ""])),
            "label": st.one_of(st.none(), st.sampled_from(["Daily", ""])),
        },
    )


READINGS = st.lists(reading(), max_size=6)


def independent_timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except (ValueError, TypeError):
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.timestamp()


def rank(item):
    sequence = item.get("sequence")
    observed = independent_timestamp(item.get("observed_at"))
    if type(sequence) is int and sequence >= 0:
        return (1, sequence)
    return (0, observed if observed is not None else float("-inf"))


def latest_observed(items):
    newest = {}
    for item in items:
        key = (monitor.text(item.get("provider")), monitor.text(item.get("account_id")))
        current = newest.get(key)
        if current is None or rank(item) > current[0]:
            newest[key] = (rank(item), independent_timestamp(item.get("observed_at")))
    return {key: pair[1] for key, pair in newest.items()}


class QuotaRowTests(unittest.TestCase):
    @QUICK
    @given(readings=READINGS)
    def test_account_rows_follow_the_documented_selection(self, readings):
        with patch.object(monitor.time, "time", return_value=NOW):
            rows = monitor.account_rows(readings)
        expected = latest_observed(readings)
        seen = {}
        for reading_item in readings:
            key = (
                monitor.text(reading_item.get("provider")),
                monitor.text(reading_item.get("account_id")),
            )
            if expected.get(key) != independent_timestamp(
                reading_item.get("observed_at")
            ):
                continue
            seen[key] = seen.get(key, 0) + 1
        for row in rows:
            key = (row["provider"], row["account"])
            self.assertLessEqual(len(row["windows"]), seen.get(key, 0))
            self.assertGreater(len(row["windows"]), 0)
            for window in row["windows"]:
                self.assertEqual(window["stale"], bool(window["stale_reason"]))
                self.assertEqual(
                    window["stale_reason"],
                    model_stale_reason(
                        window["observed_at_epoch"], window["resets_at_epoch"], NOW
                    ),
                )
                if window["remaining_percent"] is not None:
                    self.assertGreaterEqual(window["remaining_percent"], 0)
                    self.assertLessEqual(window["remaining_percent"], 100)
                self.assertNotIn("1e400", repr(window["remaining_percent"]))
            if not row["error"]:
                self.assertTrue(
                    any(w["remaining_percent"] is not None for w in row["windows"]),
                    row,
                )
            else:
                self.assertTrue(row["error"].startswith("quota_"), row)
        json.dumps(rows, allow_nan=False)

    @QUICK
    @given(item=reading())
    def test_single_reading_maps_to_one_window(self, item):
        with patch.object(monitor.time, "time", return_value=NOW):
            rows = monitor.account_rows([item])
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(rows[0]["windows"]), 1)
        window = rows[0]["windows"][0]
        self.assertEqual(window["remaining_percent"], expected_remaining(item))
        self.assertEqual(
            window["label"],
            monitor.text(item.get("window_label"))
            or monitor.text(item.get("label"))
            or monitor.text(item.get("limit_id")),
        )
        self.assertEqual(window["observed_at_epoch"], expected_timestamp(item))
        self.assertEqual(
            rows[0]["error"],
            model_account_error(item, window["remaining_percent"]),
        )

    @QUICK
    @given(readings=READINGS)
    def test_emitted_timestamps_are_rfc3339_or_null(self, readings):
        """docs/monitor.md: "Timestamps are RFC3339 strings or null"."""
        with patch.object(monitor.time, "time", return_value=NOW):
            rows = monitor.account_rows(readings)
        for row in rows:
            for window in row["windows"]:
                for field, epoch in (
                    ("observed_at", "observed_at_epoch"),
                    ("resets_at", "resets_at_epoch"),
                ):
                    value = window[field]
                    if value is None:
                        continue
                    self.assertIsInstance(value, str)
                    self.assertIsNotNone(window[epoch], (field, value))
                    self.assertEqual(
                        monitor.timestamp(value), window[epoch], (field, value)
                    )

    @QUICK
    @given(readings=READINGS)
    def test_reading_errors_never_reach_the_snapshot(self, readings):
        secrets = [
            item["error"] for item in readings if isinstance(item.get("error"), str)
        ]
        rows = monitor.account_rows(readings)
        rendered = json.dumps(rows, allow_nan=False)
        for secret in secrets:
            self.assertNotIn(secret, rendered)

    @QUICK
    @given(
        readings=READINGS,
        identities=st.dictionaries(
            st.tuples(st.sampled_from(["anthropic", "openai-codex", "q"]), TOKENS),
            TOKENS,
            max_size=3,
        ),
        inventory=st.lists(
            st.fixed_dictionaries(
                {
                    "id": TOKENS,
                    "provider": st.sampled_from(["claude", "codex", "q", ""]),
                },
                optional={
                    "label": st.one_of(st.none(), TOKENS),
                    "kind": st.one_of(st.none(), st.sampled_from(["key", "oauth"])),
                    "selected_by_profiles": st.lists(TOKENS, max_size=2),
                    "rotated_by_profiles": st.lists(TOKENS, max_size=2),
                },
            ),
            max_size=4,
        ),
    )
    def test_connected_accounts_keep_one_row_per_inventory_entry(
        self, readings, identities, inventory
    ):
        try:
            rows = monitor.connected_accounts(
                {"accounts": inventory}, readings, identities
            )
        except monitor.MonitorError as error:
            self.assertEqual(str(error), "invalid_response")
            self.assertTrue(
                any(
                    not item["provider"] or not item["id"]
                    for item in inventory
                    if isinstance(item, dict)
                ),
                inventory,
            )
            return
        self.assertEqual(len(rows), len(inventory))
        for row in rows:
            self.assertTrue(row["error"] or row["windows"], row)
        rendered = json.dumps(rows, allow_nan=False)
        self.assertNotIn("ERR", rendered)

    @QUICK
    @given(
        observed=st.one_of(st.none(), st.integers(-10**6, 10**6)),
        resets=st.one_of(st.none(), st.integers(-10**6, 10**6)),
        now=st.integers(0, 10**6),
    )
    def test_stale_reason_is_a_total_order(self, observed, resets, now):
        reason = monitor.stale_reason(observed, resets, now)
        self.assertEqual(reason, model_stale_reason(observed, resets, now))
        self.assertEqual(
            monitor.stale_window(
                iso(observed), iso(resets), now
            ),
            bool(reason),
        )

    @QUICK
    @given(value=st.one_of(st.none(), st.text(max_size=5000), st.binary(max_size=100)))
    def test_text_is_bounded_and_total(self, value):
        result = monitor.text(value, "fallback")
        self.assertIsInstance(result, str)
        self.assertLessEqual(len(result), 4096)


def iso(epoch):
    return None if epoch is None else datetime.fromtimestamp(epoch, UTC).isoformat()


def model_stale_reason(observed, resets, now):
    """Documented priority: a passed reset beats every other staleness cause."""
    if resets is not None and resets <= now:
        return "reset_passed"
    if observed is None:
        return "observation_missing"
    if observed > now + 60:
        return "clock_skew"
    if now - observed > 1800:
        return "observation_old"
    return ""


def expected_timestamp(item):
    return independent_timestamp(item.get("observed_at"))


def expected_remaining(item):
    """`100 - used` for finite in-range percentages, otherwise null."""
    used = item.get("used_percent")
    if item.get("error") is not None:
        return None
    if type(used) not in (int, float):
        return None
    if isinstance(used, float) and not math.isfinite(used):
        return None
    if not 0 <= used <= 100:
        return None
    return 100 - used


def model_account_error(item, remaining):
    """Fixed error codes only; raw provider text is never echoed."""
    status = item.get("status", "unknown")
    status_text = status if isinstance(status, str) else ""
    if status_text in {"error", "unsupported", "unknown"}:
        return "quota_" + status_text
    if item.get("error") is not None:
        return "quota_unavailable"
    return "" if remaining is not None else "quota_unavailable"


def resolvable_refusal(report, new):
    """Whether --apply-conflicts can finish this refusal without a human.

    Conflicts are written with diff3 markers; vanished or replaced upstream
    paths can be set aside. A colliding non-file upstream path cannot.
    """
    if "overlapping three-way conflict" in report:
        return True
    name = report.split(": ", 1)[0].split("/", 1)[1]
    source = new / name
    if "deletion, rename or type change" in report:
        return not (source.exists() or source.is_symlink())
    if "upstream collides with suite-only addition" in report:
        return regular(source)
    return False


class UpdateTransactionTests(unittest.TestCase):
    outcomes = collections.Counter()

    @classmethod
    def tearDownClass(cls):
        print("\ntransaction outcomes:", dict(cls.outcomes))
        for wanted in ("no-change", "review-required", "updated", "conflicts-written"):
            assert cls.outcomes[wanted] > 0, (wanted, dict(cls.outcomes))

    IDENTITIES = [
        {"rev": "a" * 40, "narHash": "sha256-one"},
        {"rev": "b" * 40, "narHash": "sha256-two"},
    ]

    def prepare(self, tree, same_revision=False):
        (tree.suite / "upstream/pin.json").write_text(
            json.dumps(self.IDENTITIES[0])
        )
        (tree.suite / "flake.lock").write_text(
            json.dumps(
                {
                    "nodes": {
                        "nur": {
                            "inputs": {},
                            "locked": {"rev": "c" * 40},
                            "original": {"repo": "NUR"},
                        },
                        "nixpkgs": {"locked": {"rev": "fixed"}},
                    }
                }
            )
        )
        return self.IDENTITIES[0 if same_revision else 1]

    def execute(self, tree, candidate, apply_conflicts):
        report = tree.root / "report.json"

        def fake_run(*args, cwd: Path | str | None = None):
            if args[:2] in {("git", "status"), ("jj", "diff")}:
                return ""
            if args[:3] == ("nix", "flake", "update"):
                lock_file = Path(str(cwd)) / "flake.lock"
                lock = json.loads(lock_file.read_text())
                lock["nodes"]["nur"]["locked"]["rev"] = "d" * 40
                lock_file.write_text(json.dumps(lock))
                return ""
            raise AssertionError(args)

        with (
            patch.object(
                updater,
                "source",
                side_effect=[(self.IDENTITIES[0], tree.old), (candidate, tree.new)],
            ),
            patch.object(updater, "run", side_effect=fake_run),
        ):
            with contextlib.redirect_stdout(io.StringIO()):
                status = updater.update(tree.suite, None, report, apply_conflicts)
        return status, json.loads(report.read_text())

    @QUICK
    @given(
        overlay=OVERLAY_SPEC,
        baseline=st.dictionaries(
            st.sampled_from(NAMES), st.sampled_from(["hash", "wrong"]), max_size=4
        ),
        old=SPEC,
        new=SPEC,
        apply_conflicts=st.booleans(),
        same_revision=st.booleans(),
    )
    @example(
        overlay={"a": ("file", b"O\n")},
        baseline={"a": "hash"},
        old={"a": ("file", b"B\n")},
        new={"a": ("file", b"T\n")},
        apply_conflicts=True,
        same_revision=False,
    )
    def test_update_is_atomic_and_idempotent(
        self, overlay, baseline, old, new, apply_conflicts, same_revision
    ):
        with tempfile.TemporaryDirectory() as directory:
            tree = Tree(directory, old, new, overlay, baseline, "server")
            candidate = self.prepare(tree, same_revision)
            details = {}
            _writes, _merged, unresolved = updater.merge_overlay(
                tree.suite, tree.old, tree.new, details
            )
            before = snapshot(tree.suite)
            status, report = self.execute(tree, candidate, apply_conflicts)
            self.outcomes[report["status"]] += 1
            after = snapshot(tree.suite)
            resolvable = all(resolvable_refusal(text, tree.new) for text in unresolved)
            if same_revision:
                self.assertEqual((status, report["status"]), (0, "no-change"))
                self.assertEqual(before, after)
                return
            self.assertEqual(status, 2 if unresolved else 0)
            if unresolved and not (apply_conflicts and resolvable):
                self.assertEqual(report["status"], "review-required")
                self.assertEqual(before, after, "a refused update touched the tree")
                return
            pin = json.loads((tree.suite / "upstream/pin.json").read_text())
            self.assertEqual(pin["rev"], candidate["rev"])
            lock = json.loads((tree.suite / "flake.lock").read_text())
            self.assertEqual(lock["nodes"]["nur"]["locked"]["rev"], "d" * 40)
            self.assertEqual(lock["nodes"]["nur"]["original"], {"repo": "NUR"})
            for path, content in details["conflicts"].items():
                self.assertEqual((tree.suite / path.relative_to(tree.suite)).read_bytes(), content)
            for path in details["setAside"]:
                self.assertFalse(path.exists(), "set-aside file was not removed")
            self.assertEqual(
                report["status"],
                "conflicts-written" if details["conflicts"] or details["setAside"] else "updated",
            )
            self.assertLessEqual(
                sum(1 for name in overlay_files(tree.overlay) if not (tree.overlay / name).exists()),
                len(details["setAside"]),
            )


class RetryTests(unittest.TestCase):
    MODULES = ["python_test", "mcp_test", "zed_e2e_test", "a_b", "x9"]
    NAMES = ["Tests.test_one", "Tests.test_two", "C.m", "Suite.test_x"]

    @QUICK
    @given(
        lines=st.lists(
            st.one_of(
                st.tuples(st.sampled_from(MODULES), st.sampled_from(NAMES)),
                st.just(("fixture", "setUpClass")),
                st.tuples(st.just("text"), st.text(max_size=20)),
            ),
            max_size=6,
        )
    )
    def test_failed_lines_map_to_targets(self, lines):
        log = ""
        expected = []
        targetable = True
        for module, name in lines:
            if module == "fixture":
                log += f"FAILED setUpClass (mcp_test.McpTests) (0.1s)\n"
                targetable = False
            elif module == "text":
                log += name + "\n"
            elif "." in name and module.isidentifier():
                log += f"FAILED {module}.{name} (1.0s)\n"
                expected.append(f"{module}.py:{name}")
            else:
                log += f"{module} {name}\n"
        self.assertEqual(runner.retry_targets(log), expected if targetable else [])
        for target in runner.retry_targets(log):
            module, _, rest = target.partition(".py:")
            self.assertIn(module, self.MODULES)
            self.assertIn(rest, self.NAMES)

    def test_regression_shapes(self):
        self.assertEqual(runner.retry_targets(""), [])
        self.assertEqual(
            runner.retry_targets("FAILED x9.C.m (0s)\n"), ["x9.py:C.m"]
        )
        self.assertEqual(
            runner.retry_targets("FAILED x9.C.m (1.0s) - boom\n"), []
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
