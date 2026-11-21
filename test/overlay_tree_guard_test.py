"""The overlay tree must be outside the checkout, also through a symlink."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(
    os.environ.get(
        "ALBEDO_OVERLAY_TREE",
        Path(__file__).resolve().parents[1] / "scripts/overlay-tree.sh",
    )
)


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / "checkout"
        (self.checkout / "scripts").mkdir(parents=True)
        (self.checkout / "src/server").mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.checkout / "scripts/overlay-tree.sh")
        (self.checkout / "src/server/a.txt").write_text("overlay\n")

    def run_script(self, checkout, tree, env=None):
        return subprocess.run(
            ["bash", str(checkout / "scripts/overlay-tree.sh"), "server", str(tree)],
            capture_output=True,
            text=True,
            env=env,
        )

    def fake_nix(self):
        # Stands in for `nix develop`: unpacks an empty tree into its last
        # argument, the tree directory, and writes the pointers the build would.
        bin_temp = tempfile.TemporaryDirectory()
        self.addCleanup(bin_temp.cleanup)
        bin_dir = Path(bin_temp.name)
        nix = bin_dir / "nix"
        nix.write_text(
            f"#!{shutil.which('bash')}\n"
            'dir="${@: -1}"\n'
            'mkdir -p "$dir/source"\n'
            'echo "$dir/source" >"$dir/.tree"\n'
            'echo "$dir/source" >"$dir/.root"\n'
            'echo "$dir/pristine" >"$dir/.src"\n'
        )
        nix.chmod(0o755)
        return {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"}

    def test_tree_inside_the_checkout_is_refused(self):
        tree = self.checkout / "tree"
        result = self.run_script(self.checkout, tree)
        self.assertEqual(result.returncode, 2)
        self.assertIn("outside the checkout", result.stderr)

    def test_tree_inside_a_symlinked_checkout_is_refused(self):
        link = self.root / "link"
        link.symlink_to(self.checkout)
        tree = self.checkout / "tree"
        (tree / "keep").mkdir(parents=True)
        (tree / "keep/keep.txt").write_text("keep\n")
        result = self.run_script(link, link / "tree")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue((tree / "keep/keep.txt").exists())

    def test_tree_containing_the_checkout_is_refused(self):
        result = self.run_script(self.checkout, self.root, self.fake_nix())
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("contain the checkout", result.stderr)
        self.assertEqual((self.checkout / "src/server/a.txt").read_text(), "overlay\n")

    def test_existing_foreign_directory_is_refused(self):
        tree = self.root / "foreign"
        (tree / "docs").mkdir(parents=True)
        (tree / "docs/notes.txt").write_text("notes\n")
        result = self.run_script(self.checkout, tree, self.fake_nix())
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("not an overlay tree", result.stderr)
        self.assertEqual((tree / "docs/notes.txt").read_text(), "notes\n")
        self.assertEqual(sorted(p.name for p in tree.iterdir()), ["docs"])

    def test_existing_tree_is_rebuilt(self):
        tree = self.root / "tree"
        (tree / "source").mkdir(parents=True)
        (tree / "source/stale.txt").write_text("stale\n")
        (tree / ".tree").write_text(f"{tree}/source\n")
        (tree / "shell").write_text("#!/usr/bin/env bash\n")
        result = self.run_script(self.checkout, tree, self.fake_nix())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((tree / "source/stale.txt").exists())
        self.assertEqual((tree / "source/a.txt").read_text(), "overlay\n")
        self.assertTrue(os.access(tree / "shell", os.X_OK))


if __name__ == "__main__":
    unittest.main()
