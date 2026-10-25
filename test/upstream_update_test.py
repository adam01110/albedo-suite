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

    def execute(self, candidate_identity=None):
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
            result = u.update(self.suite, None, report)
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
            u.apply({p: b"after", q: b"after"})
        self.assertEqual(p.read_bytes(), b"before")
        self.assertEqual(q.read_bytes(), b"before")


if __name__ == "__main__":
    unittest.main()
