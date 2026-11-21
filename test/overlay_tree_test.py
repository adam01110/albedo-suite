"""The overlay tree must equal pristine plus the overlay after every sync."""

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


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / "suite"
        self.pristine = self.root / "pristine"
        self.tree = self.root / "tree"
        self.state = self.root / "state"
        for path in (
            self.checkout / "scripts",
            self.checkout / "src/server",
            self.pristine,
            self.tree,
            self.state,
        ):
            path.mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.checkout / "scripts/overlay-tree.sh")
        # unpackPhase leaves the pristine sources in the build tree.
        for name, content in (("a.txt", "pristine a\n"), ("sub/b.txt", "pristine b\n")):
            self.write(self.pristine, name, content)
            self.write(self.tree, name, content)
        (self.state / ".root").write_text(f"{self.tree}\n")
        (self.state / ".src").write_text(f"{self.pristine}\n")
        (self.state / ".tree").write_text(f"{self.tree}\n")

    def write(self, root, name, content):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def overlay(self, name, content):
        return self.write(self.checkout / "src/server", name, content)

    def sync(self, component="server"):
        result = subprocess.run(
            [
                "bash",
                str(self.checkout / "scripts/overlay-tree.sh"),
                "sync",
                component,
                str(self.state),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def contents(self):
        return {
            path.relative_to(self.tree).as_posix(): path.read_text()
            for path in self.tree.rglob("*")
            if path.is_file()
        }

    def test_sync_copies_the_overlay_onto_pristine(self):
        self.overlay("a.txt", "overlay a\n")
        self.overlay("sub/b.txt", "overlay b\n")
        self.sync()
        self.assertEqual(
            self.contents(), {"a.txt": "overlay a\n", "sub/b.txt": "overlay b\n"}
        )

    def test_sync_restores_pristine_for_a_retired_replacement(self):
        self.overlay("sub/b.txt", "overlay b\n")
        self.sync()
        (self.checkout / "src/server/sub/b.txt").unlink()
        self.sync()
        self.assertEqual(self.contents()["sub/b.txt"], "pristine b\n")

    def test_sync_removes_a_retired_suite_only_file(self):
        self.overlay("added.txt", "suite only\n")
        self.sync()
        self.assertEqual(self.contents()["added.txt"], "suite only\n")
        (self.checkout / "src/server/added.txt").unlink()
        self.sync()
        self.assertNotIn("added.txt", self.contents())

    def test_sync_keeps_unrelated_build_output(self):
        self.overlay("a.txt", "overlay a\n")
        self.write(self.tree, "build/out.o", "object\n")
        self.sync()
        self.assertEqual(self.contents()["build/out.o"], "object\n")

    def test_client_sync_reinstalls_the_vendored_renderer(self):
        renderer = "cli/third_party/bubbletea/cursed_renderer.go"
        vendored = self.tree / "cli/vendor/charm.land/bubbletea/v2"
        self.write(self.checkout / "src/client", renderer, "renderer v2\n")
        self.write(vendored, "cursed_renderer.go", "renderer v1\n")
        # Vendored module directories are read-only, as configurePhase leaves them.
        vendored.chmod(0o555)
        self.addCleanup(vendored.chmod, 0o755)
        self.sync("client")
        self.assertEqual(
            (vendored / "cursed_renderer.go").read_text(), "renderer v2\n"
        )


if __name__ == "__main__":
    unittest.main()
