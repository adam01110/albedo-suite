"""Remote path mapping: workspace membership is a path boundary, not a string prefix."""

import os
from pathlib import Path
import sys
import tempfile
import unittest

SOURCE = Path(
    os.environ.get("ALBEDO_REMOTE_SOURCE")
    or os.environ.get("ALBEDO_PYTHON_SOURCE")
    or Path(__file__).resolve().parents[1] / "src/server/priv/python"
)
sys.path.insert(0, str(SOURCE))
from albedo_plugins import remote


class RemotePathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        (self.root / "ws").mkdir()
        self.previous = Path.cwd()
        os.chdir(self.root / "ws")
        self.workspace = Path.cwd()
        self.connection = remote.RemoteConnection(
            {"host": "example.test", "remote_cwd": "/srv/app"}
        )

    def tearDown(self):
        os.chdir(self.previous)
        self.temp.cleanup()

    def test_workspace_file_maps_to_remote_path(self):
        self.assertEqual(
            remote._remote_path(self.connection, str(self.workspace / "a.txt")),
            "/srv/app/a.txt",
        )

    def test_workspace_directory_maps_to_remote_cwd(self):
        self.assertEqual(
            remote._remote_path(self.connection, str(self.workspace)), "/srv/app"
        )

    def test_nested_directory_keeps_its_relative_shape(self):
        self.assertEqual(
            remote._remote_path(self.connection, str(self.workspace / "src/a/b.py")),
            "/srv/app/src/a/b.py",
        )

    def test_sibling_with_prefixed_name_passes_through(self):
        sibling = self.workspace.parent / f"{self.workspace.name}2" / "b.txt"
        self.assertEqual(
            remote._remote_path(self.connection, str(sibling)), str(sibling)
        )

    def test_redundant_segments_inside_the_workspace_normalize(self):
        noisy = f"{self.workspace}/tmp/../a.txt"
        self.assertEqual(remote._remote_path(self.connection, noisy), "/srv/app/a.txt")

    def test_unrelated_absolute_path_passes_through(self):
        self.assertEqual(
            remote._remote_path(self.connection, "/etc/hostname"), "/etc/hostname"
        )

    def test_traversal_out_of_the_workspace_passes_through(self):
        escaped = str(self.workspace / ".." / "outside" / "b.txt")
        self.assertEqual(remote._remote_path(self.connection, escaped), escaped)

    def test_relative_path_passes_through(self):
        self.assertEqual(
            remote._remote_path(self.connection, "notes/a.txt"), "notes/a.txt"
        )

    def test_root_workspace_maps_nothing(self):
        os.chdir("/")
        self.assertEqual(
            remote._remote_path(self.connection, "/etc/hostname"), "/etc/hostname"
        )

    def test_no_remote_cwd_passes_everything_through(self):
        connection = remote.RemoteConnection(
            {"host": "example.test", "remote_cwd": None}
        )
        path = str(self.workspace / "a.txt")
        self.assertEqual(remote._remote_path(connection, path), path)


if __name__ == "__main__":
    unittest.main()
