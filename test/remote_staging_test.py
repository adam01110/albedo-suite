"""Remote bundle publication stays atomic when another connection wins."""

from concurrent.futures import ThreadPoolExecutor
import importlib
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ssh = importlib.import_module("albedo_ssh")


class RemoteStagingTests(unittest.TestCase):
    def archive(self, directory_mode):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            for name in (".", "albedo_bridge.py", "nested", "nested/module.py"):
                entry = tarfile.TarInfo(name)
                if name in (".", "nested"):
                    entry.type = tarfile.DIRTYPE
                    entry.mode = directory_mode
                    archive.addfile(entry)
                else:
                    content = b"bundle source\n"
                    entry.mode = 0o444
                    entry.size = len(content)
                    archive.addfile(entry, io.BytesIO(content))
        return data.getvalue()

    def stage(self, target, archive):
        return subprocess.run(
            ["sh", "-c", ssh.stage_script(str(target))],
            input=archive,
            capture_output=True,
        )

    def assert_complete(self, root, target):
        self.assertEqual(sorted(p.name for p in root.iterdir()), [target.name])
        self.assertEqual(
            sorted(str(p.relative_to(target)) for p in target.rglob("*")),
            ["albedo_bridge.py", "nested", "nested/module.py"],
        )
        self.assertEqual((target / "albedo_bridge.py").read_bytes(), b"bundle source\n")

    def test_duplicate_stages_never_nest_or_fail_cleanup(self):
        for mode in (0o555, 0o755):
            with (
                self.subTest(mode=oct(mode)),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                target = root / "bundle with spaces"
                data = self.archive(mode)
                for _ in range(2):
                    result = self.stage(target, data)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assert_complete(root, target)

    def test_concurrent_readonly_stages_publish_one_complete_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "bundle"
            data = self.archive(0o555)
            with ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(lambda _: self.stage(target, data), range(4)))
            for result in results:
                self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assert_complete(root, target)

    def test_existing_incomplete_bundle_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "bundle"
            target.mkdir()
            (target / "unrelated").write_text("keep")
            result = self.stage(target, self.archive(0o555))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((target / "unrelated").read_text(), "keep")
            self.assertFalse((target / "albedo_bridge.py").exists())


if __name__ == "__main__":
    unittest.main()
