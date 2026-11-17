"""Offline fixtures for sparse upstream merges and the complete pin transaction."""

import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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


def suite_root():
    """The checkout, when the runner copied only this file into a store path."""
    return Path(os.environ.get("ALBEDO_SUITE_SOURCE", Path(__file__).resolve().parents[1]))


class ManifestTests(unittest.TestCase):
    """The committed pin has to be what its own updater would write."""

    def test_committed_inventory_is_the_server_overlay(self):
        root = suite_root()
        pin = json.loads((root / "upstream/pin.json").read_text())
        self.assertEqual(pin["sourceFiles"], u.files(root / "src/server"))
        # A client replacement belongs in the client manifest, not in this one.
        baselines = {
            line.split("  ", 1)[1]
            for line in (root / "upstream/client.sha256").read_text().splitlines()
        }
        self.assertTrue(baselines)
        self.assertFalse(baselines & set(pin["sourceFiles"]))


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.suite, self.old, self.new = [
            self.root / name for name in ("suite", "old", "new")
        ]
        for path in (
            self.suite / "src/server",
            self.suite / "src/client",
            self.suite / "upstream",
            self.old,
            self.new,
        ):
            path.mkdir(parents=True)
        self.identities = [
            {"rev": char * 40, "narHash": f"sha256-{char}"} for char in ("a", "b")
        ]
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
        for component in ("server", "client"):
            (self.suite / f"upstream/{component}.sha256").write_text("")

    def write(self, root, name, content):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def replacement(
        self,
        ours=b"suite\n",
        base=b"base\n",
        theirs=b"new\n",
        name="file",
        component="server",
    ):
        self.write(self.old, name, base)
        self.write(self.new, name, theirs)
        p = self.write(self.suite / f"src/{component}", name, ours)
        with (self.suite / f"upstream/{component}.sha256").open("a") as file:
            file.write(f"{hashlib.sha256(base).hexdigest()}  {name}\n")
        return p

    def plan(self):
        return u.merge_overlay(self.suite, self.old, self.new)

    def test_clean_three_way_and_repeat(self):
        base = b"one\ntwo\nthree\nfour\nfive\n"
        p = self.replacement(
            b"suite\ntwo\nthree\nfour\nfive\n",
            base,
            b"one\ntwo\nthree\nfour\nupstream\n",
        )
        first = self.plan()
        self.assertEqual(first, self.plan())
        writes, merged, conflicts = first
        self.assertFalse(conflicts)
        self.assertEqual(merged, ["server/file"])
        self.assertEqual(writes[p], b"suite\ntwo\nthree\nfour\nupstream\n")
        self.assertIn(
            hashlib.sha256((self.new / "file").read_bytes()).hexdigest().encode(),
            writes[self.suite / "upstream/server.sha256"],
        )
        self.assertEqual(p.read_bytes(), b"suite\ntwo\nthree\nfour\nfive\n")

    def test_overlapping_conflict_never_writes(self):
        p = self.replacement()
        writes, _, conflicts = self.plan()
        self.assertTrue(conflicts)
        self.assertNotIn(p, writes)
        self.assertEqual(p.read_bytes(), b"suite\n")

    def test_upstream_only_changes_remain_sparse(self):
        p = self.replacement(ours=b"base\n")
        self.write(self.new, "unrelated", b"new upstream file")
        writes, _, conflicts = self.plan()
        self.assertFalse(conflicts)
        self.assertEqual(writes[p], b"new\n")
        self.assertFalse((self.suite / "src/server/unrelated").exists())

    def test_generated_bytecode_is_not_an_overlay_addition(self):
        self.write(
            self.suite / "src/server", "priv/python/__pycache__/file.pyc", b"bytecode"
        )
        self.write(self.suite / "src/server", "priv/python/legacy.pyc", b"bytecode")
        self.replacement(ours=b"base\n")
        self.assertEqual(self.execute()[1]["status"], "updated")
        pin = json.loads((self.suite / "upstream/pin.json").read_text())
        self.assertEqual(pin["sourceFiles"], ["file"])

    def test_suite_only_addition_is_preserved(self):
        p = self.write(self.suite / "src/server", "addition", b"suite")
        writes, _, conflicts = self.plan()
        self.assertFalse(conflicts)
        self.assertNotIn(p, writes)

    def test_collision_even_when_content_identical(self):
        self.write(self.suite / "src/client", "addition", b"suite")
        self.write(self.new, "addition", b"suite")
        self.assertIn("collides", self.plan()[2][0])

    def test_directory_and_parent_collisions(self):
        for name in ("dir", "parent/child"):
            self.write(self.suite / "src/server", name, b"suite")
        self.write(self.new, "dir/child", b"upstream")
        self.write(self.new, "parent", b"upstream")
        self.assertEqual(len(self.plan()[2]), 2)

    def test_deletion_or_rename_requires_review(self):
        self.replacement()
        (self.new / "file").rename(self.new / "renamed")
        self.assertIn("deletion, rename", self.plan()[2][0])

    def test_binary_and_mode_changes_require_review(self):
        self.replacement(base=b"base\0", theirs=b"new\0")
        self.assertIn("binary", self.plan()[2][0])
        (self.new / "file").chmod(0o755)
        self.assertIn("mode change", self.plan()[2][0])

    def test_bad_baseline_and_symlink_fail_closed(self):
        self.replacement()
        (self.old / "file").write_bytes(b"wrong")
        self.assertIn("baseline mismatch", self.plan()[2][0])
        (self.new / "file").unlink()
        (self.new / "file").symlink_to(self.old / "file")
        (self.old / "file").write_bytes(b"base\n")
        self.assertIn("type change", self.plan()[2][0])

    def test_lock_rejects_unrelated_updates(self):
        other = json.loads(json.dumps(self.lock))
        other["nodes"]["nixpkgs"]["locked"]["rev"] = "changed"
        with self.assertRaises(ValueError):
            u.check_lock(self.lock, other)

    def test_conflict_details_and_no_delta(self):
        conflicted = self.replacement()
        self.replacement(ours=b"new\n", name="adopted")
        self.replacement(ours=b"base\n", theirs=b"base\n", name="pristine")
        details = {}
        _, _, unresolved = u.merge_overlay(self.suite, self.old, self.new, details)
        self.assertEqual(len(unresolved), 1)
        marked = details["conflicts"][conflicted]
        self.assertIn(b"<<<<<<< suite", marked)
        self.assertIn(b"||||||| old-upstream", marked)
        self.assertIn(b">>>>>>> new-upstream", marked)
        self.assertEqual(details["noDelta"], ["server/adopted", "server/pristine"])

    def test_sync_manifests_hashes_pristine_files_for_the_overlay(self):
        self.write(self.new, "ported.gleam", b"pristine\n")
        self.write(self.suite / "src/server", "ported.gleam", b"suite edit\n")
        self.write(self.suite / "src/server", "suite_only.gleam", b"suite\n")
        self.write(self.suite / "src/client", "cli/x.go", b"suite\n")
        self.write(self.new, "cli/x.go", b"pristine go\n")
        (self.suite / "upstream/pin.json").write_text(json.dumps(self.identities[1]))
        with patch.object(u, "source", return_value=(self.identities[1], self.new)):
            self.assertEqual(u.sync_manifests(self.suite), 0)
        server = (self.suite / "upstream/server.sha256").read_text()
        expected = hashlib.sha256(b"pristine\n").hexdigest()
        self.assertEqual(server, f"{expected}  ported.gleam\n")
        self.assertIn("  cli/x.go\n", (self.suite / "upstream/client.sha256").read_text())
        pin = json.loads((self.suite / "upstream/pin.json").read_text())
        self.assertEqual(pin["sourceFiles"], ["ported.gleam", "suite_only.gleam"])

    def test_rename_hints_follow_rare_identifiers_across_languages(self):
        base = self.write(self.old, "legacy.erl", b"lazy_catalogue_entry(X) -> discover_operations(X).")
        self.write(self.new, "ported.gleam", b"fn lazy_catalogue_entry(x) { discover_operations(x) }")
        self.write(self.new, "other.gleam", b"fn unrelated_function() { 1 }")
        hints = u.rename_hints([("server/legacy.erl", base)], self.new)
        self.assertEqual(hints["server/legacy.erl"][0], [1.0, "ported.gleam"])

    def test_upstream_changes_list_added_removed_modified(self):
        self.write(self.old, "same", b"x")
        self.write(self.new, "same", b"x")
        self.write(self.old, "gone", b"x")
        self.write(self.new, "added", b"x")
        self.write(self.old, "edited", b"x")
        self.write(self.new, "edited", b"y")
        self.assertEqual(
            u.upstream_changes(self.old, self.new),
            {"added": ["added"], "removed": ["gone"], "modified": ["edited"]},
        )

    def test_apply_conflicts_writes_markers_pin_and_review(self):
        p = self.replacement()
        clean = self.replacement(ours=b"base\n", name="clean")
        result, report = self.execute(apply_conflicts=True)
        self.assertEqual(result, 2)
        self.assertEqual(report["status"], "conflicts-written")
        self.assertIn(b"<<<<<<< suite", p.read_bytes())
        self.assertEqual(clean.read_bytes(), b"new\n")
        self.assertEqual(
            json.loads((self.suite / "upstream/pin.json").read_text())["rev"], "b" * 40
        )
        review = Path(report["review"])
        self.assertIn(b"<<<<<<< suite", (review / "src/server/file").read_bytes())
        self.assertEqual(report["conflicts"], ["src/server/file"])

    def test_apply_conflicts_sets_aside_vanished_and_colliding_files(self):
        gone = self.replacement(ours=b"base\nsuite delta\n")
        (self.new / "file").rename(self.new / "renamed")
        addition = self.write(self.suite / "src/client", "added.go", b"suite\n")
        self.write(self.new, "added.go", b"upstream\n")
        kept = self.replacement(ours=b"base\n", name="kept")
        result, report = self.execute(apply_conflicts=True)
        self.assertEqual((result, report["status"]), (2, "conflicts-written"))
        self.assertFalse(gone.exists())
        self.assertFalse(addition.exists())
        self.assertEqual(kept.read_bytes(), b"new\n")
        self.assertEqual(
            sorted(report["setAside"]), ["src/client/added.go", "src/server/file"]
        )
        review = Path(report["review"]) / "set-aside"
        patch = (review / "src/server/file.patch").read_text()
        self.assertIn("+suite delta", patch)
        self.assertEqual((review / "src/server/file").read_bytes(), b"base\nsuite delta\n")
        pin = json.loads((self.suite / "upstream/pin.json").read_text())
        self.assertEqual(pin["sourceFiles"], ["kept"])
        manifest = (self.suite / "upstream/server.sha256").read_text()
        self.assertNotIn("  file\n", manifest)

    def test_apply_conflicts_still_refuses_non_text_review(self):
        self.replacement()
        (self.new / "file").chmod(0o755)
        before = {p: p.read_bytes() for p in self.suite.rglob("*") if p.is_file()}
        result, report = self.execute(apply_conflicts=True)
        self.assertEqual((result, report["status"]), (2, "review-required"))
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def execute(self, candidate_identity=None, apply_conflicts=False):
        report = self.root / "report.json"

        def fake_run(*args, cwd=None):
            if args[:2] == ("git", "status") or args[:2] == ("jj", "diff"):
                return ""
            if args[:3] == ("nix", "flake", "update"):
                assert cwd is not None
                self.assertFalse((cwd / ".jj").exists())
                lock = json.loads((cwd / "flake.lock").read_text())
                lock["nodes"]["nur"]["locked"]["rev"] = "d" * 40
                (cwd / "flake.lock").write_text(json.dumps(lock))
                return ""
            raise AssertionError(args)

        with (
            patch.object(
                u,
                "source",
                side_effect=[
                    (self.identities[0], self.old),
                    (candidate_identity or self.identities[1], self.new),
                ],
            ),
            patch.object(u, "run", side_effect=fake_run),
        ):
            result = u.update(self.suite, None, report, apply_conflicts)
        return result, json.loads(report.read_text())

    def test_transaction_conflict_preserves_pin_lock_and_other_clean_files(self):
        self.replacement()
        self.replacement(ours=b"base\n", name="clean")
        before = {p: p.read_bytes() for p in self.suite.rglob("*") if p.is_file()}
        result, report = self.execute()
        self.assertEqual(result, 2)
        self.assertEqual(report["status"], "review-required")
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_success_and_noop_repeat(self):
        p = self.replacement(ours=b"base\n")
        self.assertEqual(self.execute()[1]["status"], "updated")
        self.assertEqual(p.read_bytes(), b"new\n")
        pin = json.loads((self.suite / "upstream/pin.json").read_text())
        self.assertEqual(pin["rev"], "b" * 40)
        self.assertEqual(pin["sourceFiles"], ["file"])
        self.identities[0] = self.identities[1]
        before = (self.suite / "flake.lock").read_bytes()
        self.assertEqual(self.execute()[1]["status"], "no-change")
        self.assertEqual((self.suite / "flake.lock").read_bytes(), before)

    def test_clean_jj_checkout_updates_without_copying_metadata(self):
        (self.suite / ".jj").mkdir()
        (self.suite / ".jj" / "metadata").write_text("private")
        self.replacement(ours=b"base\n")
        self.assertEqual(self.execute()[1]["status"], "updated")
        self.assertTrue((self.suite / ".jj" / "metadata").exists())

    def test_noop_does_not_advance_nur(self):
        before = (self.suite / "flake.lock").read_bytes()
        result, report = self.execute(self.identities[0])
        self.assertEqual(result, 0)
        self.assertEqual(report["status"], "no-change")
        self.assertEqual((self.suite / "flake.lock").read_bytes(), before)

    def test_report_cannot_overwrite_checkout(self):
        report = self.suite / "flake.lock"
        before = report.read_bytes()
        with (
            patch.object(u, "source") as source,
            self.assertRaisesRegex(ValueError, "outside"),
        ):
            u.update(self.suite, None, report)
        source.assert_not_called()
        self.assertEqual(report.read_bytes(), before)

    def test_report_symlink_cannot_overwrite_checkout(self):
        report = self.root / "linked-report"
        report.symlink_to(self.suite / "flake.lock")
        with self.assertRaisesRegex(ValueError, "outside"):
            u.update(self.suite, None, report)

    def test_dirty_jj_checkout_is_rejected_without_git(self):
        (self.suite / ".jj").mkdir()
        with (
            patch.object(u, "run", return_value="M src/server/file") as run,
            self.assertRaisesRegex(ValueError, "clean"),
        ):
            u.update(self.suite, None, self.root / "report.json")
        run.assert_called_once_with("jj", "diff", "--summary", cwd=self.suite)

    def test_apply_rolls_back_on_failure(self):
        p = self.write(self.suite, "one", b"before")
        q = self.write(self.suite, "two", b"before")
        original = Path.write_bytes
        calls = 0

        def fail_once(path, data):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("fixture disk error")
            return original(path, data)

        with patch.object(Path, "write_bytes", fail_once), self.assertRaises(OSError):
            u.apply({p: None, q: b"after", self.suite / "three": b"new"})
        self.assertEqual(p.read_bytes(), b"before")
        self.assertEqual(q.read_bytes(), b"before")
        self.assertFalse((self.suite / "three").exists())


if __name__ == "__main__":
    unittest.main()
