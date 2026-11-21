"""Property tests for the suite's upstream-update and overlay-tree tooling.

Run with hypothesis available, for example:

    python -m unittest discover -s test -p proptest_tooling_test.py -v

The oracle is an independent model of the documented contract: each overlay
path's classification comes from the plan that built the fixtures, and the
manifests are recomputed from the candidate pristine tree instead of from the
code under test.

test_retired_overlay_files_fall_back_to_pristine encodes the equality that the
script header promises: the materialised tree must be pristine plus the overlay.
It fails until overlay-tree.sh drops or restores files that an earlier overlay
added and the current one no longer has.
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import hypothesis.strategies as st
from hypothesis import given, settings

SPEC = importlib.util.spec_from_file_location(
    "updater",
    Path(
        os.environ.get(
            "ALBEDO_UPDATER", Path(__file__).parents[1] / "scripts/update-upstream.py"
        )
    ),
)
assert SPEC is not None and SPEC.loader is not None
u = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(u)

IDENTITIES = [{"rev": char * 40, "narHash": f"sha256-{char}"} for char in ("a", "b")]
MARKERS = (b"<<<<<<<", b"|||||||", b">>>>>>>")
K = 8  # base line count, wide enough to keep edits out of one merge hunk

ROLES = [
    "pristine",
    "passthrough",
    "clean",
    "nochange",
    "adopted",
    "conflict",
    "drift",
    "deleted",
    "typechange",
    "mode",
    "binary",
    "addition",
    "collision",
    "unbaselined",
    "stale",
    "symlinked",
]

# Model reason for each unresolved class, keyed by the diagnostic the code emits.
REASONS = {
    "conflict": "overlapping three-way conflict",
    "drift": "old pristine baseline mismatch",
    "deleted": "deletion, rename",
    "typechange": "type change",
    "mode": "executable mode change",
    "binary": "binary change",
    "collision": "collides",
    "unbaselined": "missing old baseline",
    "stale": "baseline has no suite replacement",
    "symlinked": "symlink or non-regular",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def base(name):
    return "".join(f"{name}:{index}\n" for index in range(K)).encode()


def patched(name, index, marker):
    lines = [f"{name}:{line}\n" for line in range(K)]
    lines[index] = marker
    return "".join(lines).encode()


def clash(name, target, other):
    """Two fixture paths may not be equal or nest inside each other."""
    return (
        name == other
        or name.startswith(f"{other}/")
        or other.startswith(f"{name}/")
        or target == other
        or target.startswith(f"{other}/")
    )


def path_segment():
    return st.text(alphabet="abcXYZ0189_- .éλ日", min_size=1, max_size=9).filter(
        lambda segment: segment.strip() == segment
        and segment not in {".", ".."}
        and "__pycache__" not in segment
        and not segment.endswith(".pyc")
        and "/" not in segment
    )


def plan_strategy():
    return st.lists(
        st.tuples(
            st.sampled_from(["server", "client"]),
            st.lists(path_segment(), min_size=1, max_size=2).map("/".join),
            st.sampled_from(ROLES),
        ),
        min_size=1,
        max_size=6,
    )


class Fixture:
    """Materialize a generated plan and derive the expected classification."""

    def __init__(self, root, plan, apply_conflicts=False):
        self.root = root
        self.suite = root / "suite"
        self.old = root / "old"
        self.new = root / "new"
        self.apply_conflicts = apply_conflicts
        self.identities = list(IDENTITIES)
        for path in (
            self.suite / "src/server",
            self.suite / "src/client",
            self.suite / "upstream",
            self.old,
            self.new,
        ):
            path.mkdir(parents=True)
        (self.suite / "upstream/pin.json").write_text(json.dumps(self.identities[0]))
        self.lock = {
            "nodes": {
                "nur": {
                    "inputs": {},
                    "locked": {"rev": "c" * 40},
                    "original": {"repo": "NUR"},
                },
                "nixpkgs": {"locked": {"rev": "fixed"}},
            }
        }
        (self.suite / "flake.lock").write_text(json.dumps(self.lock))
        self.baselines = {"server": {}, "client": {}}
        self.plan = {}
        self.writes = {}
        self.merged = set()
        self.no_delta = set()
        self.conflicts = set()
        self.set_aside = set()
        self.unresolved = {}
        reserved = set()
        for component, name, role in plan:
            # One name is used once, and no name may be a directory of another:
            # the old and new pristine trees are shared by both components.
            if any(clash(name, name, other) for other in reserved):
                continue
            reserved.add(name)
            if role == "typechange":
                reserved.add(f"{name}~target")
            self.plan[name] = (component, role)
            self.materialize(component, name, role)
        for component in ("server", "client"):
            (self.suite / f"upstream/{component}.sha256").write_text(
                "".join(
                    f"{checksum}  {name}\n"
                    for name, checksum in sorted(self.baselines[component].items())
                )
            )

    def write(self, root, name, content, mode=0o644):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, tuple):
            path.symlink_to(content[1])
        else:
            path.write_bytes(content)
            path.chmod(mode)
        return path

    def overlay(self, component, name, content):
        return self.write(self.suite / "src" / component, name, content)

    def materialize(self, component, name, role):
        label = f"{component}/{name}"
        pristine = base(name)
        ours = patched(name, 0, f"suite:{name}\n")
        upstream = patched(name, K - 1, f"upstream:{name}\n")
        if role == "pristine":
            self.write(self.old, name, pristine)
            self.write(self.new, name, pristine)
        elif role == "passthrough":
            self.write(self.old, name, pristine)
            middle = patched(name, K // 2, f"upstream:{name}\n")
            self.write(self.new, name, middle)
            self.overlay(component, name, pristine)
            self.baselines[component][name] = digest(pristine)
            self.writes[label] = middle
            self.merged.add(label)
            self.no_delta.add(label)
        elif role == "clean":
            self.write(self.old, name, pristine)
            self.write(self.new, name, upstream)
            self.overlay(component, name, ours)
            self.baselines[component][name] = digest(pristine)
            lines = [f"{name}:{index}\n" for index in range(K)]
            lines[0] = f"suite:{name}\n"
            lines[K - 1] = f"upstream:{name}\n"
            self.writes[label] = "".join(lines).encode()
            self.merged.add(label)
        elif role == "nochange":
            self.write(self.old, name, pristine)
            self.write(self.new, name, pristine)
            self.overlay(component, name, ours)
            self.baselines[component][name] = digest(pristine)
        elif role == "adopted":
            self.write(self.old, name, pristine)
            self.write(self.new, name, upstream)
            self.overlay(component, name, upstream)
            self.baselines[component][name] = digest(pristine)
            self.writes[label] = upstream
            self.merged.add(label)
            self.no_delta.add(label)
        elif role == "conflict":
            self.write(self.old, name, pristine)
            self.write(self.new, name, patched(name, K // 2, f"upstream:{name}\n"))
            self.conflicts.add(self.overlay(component, name, patched(name, K // 2, f"suite:{name}\n")))
            self.baselines[component][name] = digest(pristine)
            self.unresolved[label] = "conflict"
        elif role == "drift":
            self.write(self.old, name, patched(name, 1, f"tampered:{name}\n"))
            self.write(self.new, name, upstream)
            self.overlay(component, name, ours)
            self.baselines[component][name] = digest(pristine)
            self.unresolved[label] = "drift"
        elif role == "deleted":
            self.write(self.old, name, pristine)
            self.baselines[component][name] = digest(pristine)
            self.set_aside.add(self.overlay(component, name, ours))
            self.unresolved[label] = "deleted"
        elif role == "typechange":
            self.write(self.old, name, pristine)
            target = f"{name}~target"
            self.write(self.new, target, f"target:{name}\n".encode())
            self.write(self.new, name, (None, target))
            self.overlay(component, name, ours)
            self.baselines[component][name] = digest(pristine)
            self.unresolved[label] = "typechange"
        elif role == "mode":
            self.write(self.old, name, pristine)
            self.write(self.new, name, upstream, mode=0o755)
            self.overlay(component, name, ours)
            self.baselines[component][name] = digest(pristine)
            self.unresolved[label] = "mode"
        elif role == "binary":
            self.write(self.old, name, pristine + b"\0")
            self.write(self.new, name, pristine[:-1] + b"\0x")
            self.overlay(component, name, pristine[:-1] + b"\0y")
            self.baselines[component][name] = digest(pristine + b"\0")
            self.unresolved[label] = "binary"
        elif role == "addition":
            self.overlay(component, name, ours)
        elif role == "collision":
            self.set_aside.add(self.overlay(component, name, ours))
            self.write(self.new, name, upstream)
            self.unresolved[label] = "collision"
        elif role == "stale":
            self.write(self.old, name, pristine)
            self.write(self.new, name, upstream)
            self.baselines[component][name] = digest(pristine)
            self.unresolved[label] = "stale"
        elif role == "symlinked":
            self.write(self.old, name, pristine)
            self.write(self.new, name, upstream)
            self.write(self.suite / "src" / component, name, (None, self.old / name))
            self.baselines[component][name] = digest(pristine)
            self.unresolved[label] = "symlinked"
        elif role == "unbaselined":
            self.write(self.old, name, pristine)
            self.write(self.new, name, upstream)
            self.overlay(component, name, ours)
            self.unresolved[label] = "unbaselined"
        else:  # pragma: no cover - ROLES is exhaustive
            raise AssertionError(role)

    def manifest_names(self, component):
        """Overlay paths whose pristine baseline is valid and usable."""
        return sorted(
            name
            for name, (owner, role) in self.plan.items()
            if owner == component
            and role
            in {"passthrough", "clean", "nochange", "adopted", "conflict", "binary"}
        )

    def inventory_names(self):
        """Server overlay paths that survive a fully applied update."""
        return sorted(
            name
            for name, (owner, role) in self.plan.items()
            if owner == "server"
            and role not in {"pristine", "stale"}
            and name not in self.retired()
        )

    def retired(self):
        return {
            name for name, (_, role) in self.plan.items() if role in {"deleted", "collision"}
        }

    def writes_as_paths(self):
        return {
            self.suite / "src" / label.split("/", 1)[0] / label.split("/", 1)[1]: content
            for label, content in self.writes.items()
        }

    def unresolved_count(self):
        return len(self.unresolved)

    def in_place(self):
        """Only text conflicts and set-aside replacements need no human review."""
        return (
            self.apply_conflicts
            and len(self.conflicts) + len(self.set_aside) == len(self.unresolved)
        )

    def status(self):
        if not self.unresolved:
            return "updated"
        return "conflicts-written" if self.in_place() else "review-required"

    def snapshot(self):
        return {
            path.relative_to(self.suite).as_posix(): path.read_bytes()
            for path in self.suite.rglob("*")
            if path.is_file() and not path.is_symlink()
        }

    def execute(self):
        report = self.root / "report.json"

        def fake_run(*args, cwd=None):
            if args[:2] in (("git", "status"), ("jj", "diff")):
                return ""
            if args[:3] == ("nix", "flake", "update"):
                assert cwd is not None
                lock_path = Path(cwd) / "flake.lock"
                lock = json.loads(lock_path.read_text())
                lock["nodes"]["nur"]["locked"]["rev"] = "d" * 40
                lock_path.write_text(json.dumps(lock))
                return ""
            raise AssertionError(args)

        with (
            patch.object(
                u,
                "source",
                side_effect=[(self.identities[0], self.old)]
                + [(self.identities[1], self.new)] * 4,
            ),
            patch.object(u, "run", side_effect=fake_run),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            result = u.update(self.suite, None, report, self.apply_conflicts)
        return result, json.loads(report.read_text())


class UpdateModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    @given(plan_strategy())
    @settings(max_examples=200, deadline=None)
    def test_classification_matches_the_plan(self, plan):
        fixture = Fixture(Path(tempfile.mkdtemp(dir=self.temp.name)), plan)
        before = fixture.snapshot()
        details = {}
        writes, merged, unresolved = u.merge_overlay(
            fixture.suite, fixture.old, fixture.new, details
        )
        self.assertEqual(before, fixture.snapshot())
        merged_writes = {
            path: content for path, content in writes.items() if "sha256" not in path.name
        }
        self.assertEqual(merged_writes, fixture.writes_as_paths())
        self.assertEqual(sorted(merged), sorted(fixture.merged))
        self.assertEqual(set(details["noDelta"]), fixture.no_delta)
        self.assertEqual(set(details["conflicts"]), fixture.conflicts)
        self.assertEqual(set(details["setAside"]), fixture.set_aside)
        self.assertEqual(len(unresolved), fixture.unresolved_count())
        for message in unresolved:
            label, reason = message.split(": ", 1)
            self.assertIn(REASONS[fixture.unresolved[label]], reason)

    @given(plan_strategy(), st.booleans())
    @settings(max_examples=100, deadline=None)
    def test_update_transaction_matches_the_plan(self, plan, apply_conflicts):
        fixture = Fixture(
            Path(tempfile.mkdtemp(dir=self.temp.name)), plan, apply_conflicts
        )
        before = fixture.snapshot()
        result, report = fixture.execute()
        self.assertEqual(report["status"], fixture.status())
        self.assertEqual(result, 2 if fixture.unresolved_count() else 0)
        if fixture.status() == "review-required":
            self.assertEqual(before, fixture.snapshot())
            return

        after = fixture.snapshot()
        changed = {
            name for name in set(before) | set(after) if before.get(name) != after.get(name)
        }
        expected_changed = {
            "upstream/server.sha256",
            "upstream/client.sha256",
            "upstream/pin.json",
            "flake.lock",
        }
        for label, content in fixture.writes.items():
            component, name = label.split("/", 1)
            path = f"src/{component}/{name}"
            self.assertEqual(after[path], content)
            expected_changed.add(path)
        for path in fixture.conflicts:
            name = path.relative_to(fixture.suite).as_posix()
            self.assertTrue(any(marker in after[name] for marker in MARKERS))
            expected_changed.add(name)
        for path in fixture.set_aside:
            name = path.relative_to(fixture.suite).as_posix()
            self.assertNotIn(name, after)
            expected_changed.add(name)
        self.assertLessEqual(changed, expected_changed)

        for component in ("server", "client"):
            expected = "".join(
                f"{digest((fixture.new / name).read_bytes())}  {name}\n"
                for name in fixture.manifest_names(component)
            )
            self.assertEqual(after[f"upstream/{component}.sha256"], expected.encode())
        pin = json.loads(after["upstream/pin.json"])
        self.assertEqual(pin["rev"], fixture.identities[1]["rev"])
        self.assertEqual(pin["sourceFiles"], fixture.inventory_names())
        self.assertEqual(
            json.loads(after["flake.lock"])["nodes"]["nur"]["locked"]["rev"], "d" * 40
        )
        # A second plan against the same pristine tree has nothing left to write.
        writes, merged, unresolved = u.merge_overlay(fixture.suite, fixture.new, fixture.new)
        self.assertEqual([path for path in writes if "sha256" not in path.name], [])
        self.assertEqual(merged, [])
        self.assertEqual(unresolved, [])


def nested(name, other):
    """One path is a directory of the other; equal names are allowed."""
    return name.startswith(f"{other}/") or other.startswith(f"{name}/")


def normalize(overlay, pristine):
    """Drop entries that would nest a file inside another, keeping both sides."""
    kept_pristine = {}
    for name, content in pristine.items():
        if any(nested(name, other) for other in kept_pristine):
            continue
        kept_pristine[name] = content
    kept_overlay = {}
    for name, content in overlay.items():
        if any(nested(name, other) for other in (*kept_pristine, *kept_overlay)):
            continue
        kept_overlay[name] = content
    return kept_overlay, kept_pristine


def contents_strategy():
    return st.sampled_from([b"pristine\n", b"overlay\n", b"", b"a\nb\n", "é\n".encode()])


def file_map():
    return st.dictionaries(
        st.lists(path_segment(), min_size=1, max_size=2).map("/".join),
        contents_strategy(),
        max_size=4,
    )


class ManifestTests(unittest.TestCase):
    """--sync-manifests must describe exactly the overlay it is given."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    @given(overlay=file_map(), pristine=file_map(), again=st.booleans())
    @settings(max_examples=100, deadline=None)
    def test_sync_manifests_describes_exactly_the_overlay(self, overlay, pristine, again):
        overlay, pristine = normalize(overlay, pristine)
        root = Path(tempfile.mkdtemp(dir=self.temp.name))
        suite = root / "suite"
        identity = IDENTITIES[1]
        (suite / "upstream").mkdir(parents=True)
        for component in ("server", "client"):
            (suite / "src" / component).mkdir(parents=True)
        (suite / "upstream/pin.json").write_text(json.dumps(identity))
        for name, content in pristine.items():
            path = root / "pristine" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        for name, content in overlay.items():
            path = suite / "src/server" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        before = {
            path.relative_to(suite).as_posix(): path.read_bytes()
            for path in suite.rglob("*")
            if path.is_file()
        }
        with (
            patch.object(u, "source", return_value=(identity, root / "pristine")),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(u.sync_manifests(suite), 0)
            first = {
                path.relative_to(suite).as_posix(): path.read_bytes()
                for path in suite.rglob("*")
                if path.is_file()
            }
            if again:
                self.assertEqual(u.sync_manifests(suite), 0)
        after = {
            path.relative_to(suite).as_posix(): path.read_bytes()
            for path in suite.rglob("*")
            if path.is_file()
        }
        self.assertEqual(after, first)
        expected = "".join(
            f"{digest(pristine[name])}  {name}\n" for name in sorted(set(overlay) & set(pristine))
        )
        self.assertEqual(after["upstream/server.sha256"], expected.encode())
        self.assertEqual(after["upstream/client.sha256"], b"")
        pin = json.loads(after["upstream/pin.json"])
        self.assertEqual(pin["sourceFiles"], sorted(overlay))
        self.assertEqual(pin["rev"], identity["rev"])
        self.assertEqual(
            set(before) | {"upstream/server.sha256", "upstream/client.sha256"},
            set(after),
        )


class OverlayTree:
    """A suite checkout, a pristine tree and an overlay-tree.sh state directory."""

    def __init__(self, root, overlay, pristine, component="server"):
        self.root = root
        self.suite = root / "suite"
        self.pristine = root / "pristine"
        self.tree = root / "tree"
        self.state = root / "state"
        for path in (self.suite / "scripts", self.pristine, self.tree, self.state):
            path.mkdir(parents=True)
        shutil.copy(
            Path(
                os.environ.get(
                    "ALBEDO_OVERLAY_TREE",
                    Path(__file__).parents[1] / "scripts/overlay-tree.sh",
                )
            ),
            self.suite / "scripts/overlay-tree.sh",
        )
        self.component = component
        for name, content in overlay.items():
            self.write(self.suite / "src" / component, name, content)
        (self.suite / "src" / component).mkdir(parents=True, exist_ok=True)
        for name, content in pristine.items():
            # unpackPhase leaves the pristine sources in the build tree.
            self.write(self.pristine, name, content)
            self.write(self.tree, name, content)
        (self.state / ".root").write_text(f"{self.tree}\n")
        (self.state / ".src").write_text(f"{self.pristine}\n")
        (self.state / ".tree").write_text(f"{self.tree}\n")

    def write(self, root, name, content):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def sync(self):
        result = subprocess.run(
            [
                "bash",
                str(self.suite / "scripts/overlay-tree.sh"),
                "sync",
                self.component,
                str(self.state),
            ],
            capture_output=True,
        )
        return result.returncode

    def contents(self):
        return {
            path.relative_to(self.tree).as_posix(): path.read_bytes()
            for path in self.tree.rglob("*")
            if path.is_file()
        }


class OverlayTreeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    @given(overlay=file_map(), pristine=file_map())
    @settings(max_examples=100, deadline=None)
    def test_copied_overlay_matches_the_named_files(self, overlay, pristine):
        overlay, pristine = normalize(overlay, pristine)
        root = Path(tempfile.mkdtemp(dir=self.temp.name))
        tree = OverlayTree(root, overlay, pristine)
        self.assertEqual(tree.sync(), 0)
        expected = dict(pristine) | dict(overlay)
        self.assertEqual(tree.contents(), expected)

    @given(
        overlay=file_map(),
        pristine=file_map(),
        retired=st.lists(st.integers(min_value=0, max_value=3), max_size=3, unique=True),
    )
    @settings(max_examples=100, deadline=None)
    def test_retired_overlay_files_fall_back_to_pristine(self, overlay, pristine, retired):
        """A file removed from the overlay must not survive in the tree."""
        overlay, pristine = normalize(overlay, pristine)
        root = Path(tempfile.mkdtemp(dir=self.temp.name))
        tree = OverlayTree(root, overlay, pristine)
        self.assertEqual(tree.sync(), 0)
        names = sorted(overlay)
        retired = [names[index] for index in sorted(set(retired)) if index < len(names)]
        for name in retired:
            (tree.suite / "src" / "server" / name).unlink()
        self.assertEqual(tree.sync(), 0)
        expected = dict(pristine)
        for name, content in overlay.items():
            if name not in retired:
                expected[name] = content
        self.assertEqual(tree.contents(), expected)


if __name__ == "__main__":
    unittest.main()
