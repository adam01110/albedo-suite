"""Deterministic subprocess races and caps not reliably driven through model E2E.

Set ALBEDO_FORMATTER_SOURCE to the integrated upstream priv/python directory.
"""

import asyncio
import importlib
import json
import os
import signal
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.environ["ALBEDO_FORMATTER_SOURCE"])
formatter = importlib.import_module("albedo_formatter")
plugin = importlib.import_module("albedo_plugins.formatter")
files_plugin = importlib.import_module("albedo_plugins.files")


class FormatterTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.script = Path(__file__).parent / "fixtures" / "formatter-unit.py"
        self.control = self.root / "formatter-state.json"
        self.set_fixture("uppercase")
        self.config = {
            "formatters": {
                "upper": {
                    "command": [sys.executable, str(self.script), str(self.control)]
                }
            },
            "chains": {".py": ["upper"]},
            "timeoutMs": 2000,
            "treefmt": [sys.executable, str(self.script), str(self.control)],
            "nix": [sys.executable, str(self.script), str(self.control)],
        }
        formatter.configure(self.config, str(self.root))
        self.fs = files_plugin.Files()

    def set_fixture(self, mode, *, control=None, **parameters):
        state_file = control or self.control
        state_file.write_text(json.dumps({"mode": mode, **parameters}))

    def write(self, name="example.py", text="lower\n"):
        path = self.root / name
        self.fs.write(str(path), text)
        return path

    async def test_no_immediate_formatting_and_mode(self):
        path = self.write()
        path.chmod(0o751)
        formatter.record(path)
        self.assertEqual(path.read_text(), "lower\n")
        result = await formatter.finish()
        self.assertTrue(result["ok"], result["error"])
        self.assertTrue(result["changed"])
        self.assertEqual(path.read_text(), "LOWER\n")
        self.assertEqual(path.stat().st_mode & 0o777, 0o751)
        self.assertFalse(formatter._pending)

    async def test_outside_workspace_paths_are_ignored(self):
        with tempfile.TemporaryDirectory() as outside:
            path = Path(outside) / "outside.py"
            self.fs.write(str(path), "outside")
            result = await formatter.finish()
            self.assertTrue(result["ok"])
            self.assertFalse(formatter._pending)
            self.assertEqual(path.read_text(), "outside")

    async def test_replaced_original_identity_rejected(self):
        path = self.write()
        path.unlink()
        path.write_text("lower\n")
        self.assertFalse((await formatter.finish())["ok"])
        self.assertEqual(path.read_text(), "lower\n")

    async def test_limits_and_output(self):
        with patch.object(formatter, "MAX_FILES", 1):
            self.write()
            self.write("other.py")
            self.assertEqual(len(formatter._pending), 1)
            self.assertFalse((await formatter.finish())["ok"])
            self.assertFalse((await formatter.finish())["ok"])
        formatter.configure(self.config, str(self.root))
        with patch.object(formatter, "MAX_BYTES", 3):
            self.write()
            self.assertFalse((await formatter.finish())["ok"])
        formatter.configure(self.config, str(self.root))
        self.write()
        self.set_fixture("verbose_failure")
        result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertLessEqual(len(result["error"]), 16384)

    async def test_timeout_cleanup(self):
        path = self.write()
        self.config["timeoutMs"] = 50
        self.set_fixture("timeout")
        result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertIn("timed out", result["error"])
        self.assertEqual(path.read_text(), "lower\n")
        self.assertFalse(list(self.root.glob("albedo-format-*")))
        # A batch-level timeout keeps the work it already published.
        formatter.configure(self.config, str(self.root))
        self.config["timeoutMs"] = 1000
        first, second = self.write(), self.write("second.py")
        self.set_fixture("slow", fast="example.py", seconds=20)
        result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertTrue(result["changed"])
        self.assertEqual(first.read_text(), "done")
        self.assertEqual(second.read_text(), "lower\n")
        self.assertIn(second, formatter._pending)
        self.assertFalse(list(self.root.glob("albedo-format-*")))

    async def test_cancellation_kills_group_and_preserves_original(self):
        path = self.write()
        started = self.root / "started"
        self.set_fixture("blocked", started=str(started))
        task = asyncio.create_task(formatter.finish())
        async with asyncio.timeout(2):
            while not started.exists():
                await asyncio.sleep(0.005)
        pid = int(started.read_text())
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, signal.SIGCONT)
        self.assertEqual(path.read_text(), "lower\n")
        self.assertIn(path, formatter._pending)
        self.assertFalse(list(self.root.glob("albedo-format-*")))

    async def test_project_scope_treefmt_and_flake(self):
        for project in ("treefmt.toml", ".treefmt.toml", "flake.nix"):
            with self.subTest(project=project):
                formatter.configure(self.config, str(self.root))
                marker = self.root / project
                marker.write_text("")
                self.addCleanup(marker.unlink, missing_ok=True)
                path = self.write()
                log = self.root / "argv.json"
                self.set_fixture("project", log=str(log))
                self.assertTrue((await formatter.finish())["ok"])
                argv = json.loads(log.read_text())
                self.assertIn("--", argv)
                staged = Path(argv[-1])
                self.assertEqual(staged.name, path.name)
                self.assertEqual(staged.parent.name, "workspace")
                self.assertNotEqual(staged, path)
                if project == "flake.nix":
                    self.assertEqual(argv[:2], ["fmt", "--"])
                else:
                    self.assertIn("--no-cache", argv)
                    self.assertIn(str(staged.parent / project), argv)
                marker.unlink()

    @unittest.skipUnless(shutil.which("treefmt"), "standalone test requires treefmt")
    async def test_real_treefmt_exact_paths_and_config_context(self):
        treefmt = shutil.which("treefmt")
        assert treefmt is not None
        self.config["treefmt"] = [treefmt]
        (self.root / "src").mkdir()
        (self.root / "src" / "style.txt").write_text("context-formatted\n")
        (self.root / "config").mkdir()
        (self.root / "config" / "style.txt").write_text("context-formatted\n")
        script = self.root / "config" / "format.py"
        script.write_text(
            "import pathlib, sys\n"
            "for name in sys.argv[1:]:\n"
            " p = pathlib.Path(name)\n"
            " assert (p.parent / 'style.txt').read_text() == 'context-formatted\\n'\n"
            " p.write_text(pathlib.Path('config/style.txt').read_text())\n"
        )
        (self.root / "treefmt.toml").write_text(
            "[formatter.exact]\n"
            f"command = {json.dumps(sys.executable)}\n"
            'options = ["config/format.py"]\n'
            'includes = ["src/example.py", "src/excluded.py"]\n'
            'excludes = ["src/excluded.py"]\n'
        )
        # Unrelated development/dependency trees must not be traversed.
        (self.root / ".direnv").symlink_to("/nix/store", target_is_directory=True)
        (self.root / "node_modules").mkdir()
        (self.root / "node_modules" / "cycle").symlink_to(".", target_is_directory=True)
        path = self.write("src/example.py")
        excluded = self.write("src/excluded.py")
        unrelated = self.root / "src" / "dirty.py"
        unrelated.write_text("unrelated dirty\n")
        result = await formatter.finish()
        self.assertEqual(result, {"ok": True, "changed": True, "error": ""})
        self.assertEqual(path.read_text(), "context-formatted\n")
        self.assertEqual(excluded.read_text(), "lower\n")
        self.assertEqual(unrelated.read_text(), "unrelated dirty\n")
        self.assertFalse(formatter._pending)
        # A successful no-op for an already formatted file is accepted.
        formatter.record(path)
        self.assertFalse((await formatter.finish())["changed"])
        config = self.root / "treefmt.toml"
        config.rename(self.root / "shared.toml")
        config.symlink_to("shared.toml")
        self.fs.write(str(path), "lower again\n")
        self.assertTrue((await formatter.finish())["changed"])
        self.assertEqual(path.read_text(), "context-formatted\n")

    async def test_project_snapshot_reused_and_publish_guards(self):
        (self.root / "treefmt.toml").write_text("")
        first = self.write()
        second = self.write("second.py")
        self.assertTrue((await formatter.finish())["ok"])
        self.assertEqual(first.read_text(), "LOWER\n")
        self.assertEqual(second.read_text(), "LOWER\n")
        self.fs.write(str(first), "lower again")
        self.set_fixture("concurrent_change", original=str(first))
        result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertIn("concurrent", result["error"])
        self.assertEqual(first.read_text(), "user change")
        self.assertIn(first, formatter._pending)

    async def test_project_staged_symlink_is_never_published(self):
        (self.root / "treefmt.toml").write_text("")
        # The escaping symlink can replace the staged copy a project formatter is
        # about to publish or one a later target still needs.
        for redirect in ("current", "later"):
            with self.subTest(redirect=redirect):
                formatter.configure(self.config, str(self.root))
                first, second = self.write(), self.write("second.py")
                target = first if redirect == "current" else second

                async def replace_with_symlink(argv, cwd, **kwargs):
                    staged = Path(argv[-1]).parent / target.name
                    staged.unlink()
                    staged.symlink_to(target)

                with patch.object(formatter, "_run", side_effect=replace_with_symlink):
                    result = await formatter.finish()
                self.assertFalse(result["ok"])
                self.assertIn("symlink", result["error"])
                self.assertEqual(first.read_text(), "lower\n")
                self.assertEqual(second.read_text(), "lower\n")
                self.assertIn(target, formatter._pending)

    async def test_project_snapshot_limits_and_config_symlink_escape(self):
        (self.root / "treefmt.toml").write_text("")
        path = self.write()
        with patch.object(formatter, "MAX_CONTEXT_FILES", 1):
            self.assertIn("context exceeds", (await formatter.finish())["error"])
        self.assertEqual(path.read_text(), "lower\n")
        self.assertIn(path, formatter._pending)
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside) / "treefmt.toml"
            external.write_text("")
            (self.root / "treefmt.toml").unlink()
            (self.root / "treefmt.toml").symlink_to(external)
            self.assertIn("outside workspace", (await formatter.finish())["error"])
        self.assertEqual(path.read_text(), "lower\n")

    async def test_unrelated_work_does_not_suppress_explicit_checks(self):
        path = self.write()
        other = asyncio.create_task(asyncio.sleep(20))
        try:
            self.assertTrue((await formatter.finish())["changed"])
            self.assertFalse(formatter._pending)
        finally:
            other.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await other
        self.assertEqual(path.read_text(), "LOWER\n")

    async def test_nix_missing_formatter_falls_back_not_build_failure(self):
        path = self.write()
        (self.root / "flake.nix").write_text("")
        nix_control = self.root / "nix-state.json"
        diagnostic = (
            "error: flake 'path:/workspace' does not provide attribute "
            "'packages.x86_64-linux.formatter', 'legacyPackages.x86_64-linux.formatter' "
            "or 'formatter.x86_64-linux'"
        )
        self.config["nix"] = [sys.executable, str(self.script), str(nix_control)]
        self.set_fixture("failure", control=nix_control, diagnostic=diagnostic)
        result = await formatter.finish()
        self.assertTrue(result["ok"])
        self.assertTrue(result["changed"])
        self.assertEqual(path.read_text(), "LOWER\n")
        self.write(text="lower again")
        single = "error: flake 'path:/workspace' does not provide attribute 'formatter.x86_64-linux'"
        self.set_fixture("failure", control=nix_control, diagnostic=single)
        self.assertTrue((await formatter.finish())["ok"])
        self.assertEqual(path.read_text(), "LOWER AGAIN")
        self.write(text="lower again")
        self.set_fixture(
            "failure", control=nix_control, diagnostic="error: builder failed"
        )
        result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertEqual(path.read_text(), "lower again")

    async def test_setup_empty_exports(self):
        with (
            patch.dict(os.environ, {"ALBEDO_REMOTE_TARGET": "host"}),
            patch.object(formatter, "configure") as configure,
        ):
            self.assertEqual(await plugin.setup(types.SimpleNamespace()), {})
            configure.assert_not_called()

        async def host(name, args):
            self.assertEqual(name, "formatter.config")
            self.assertEqual(args, {})
            return self.config

        with patch.object(formatter, "configure") as configure:
            self.assertEqual(await plugin.setup(types.SimpleNamespace(host=host)), {})
            configure.assert_called_once_with(self.config)


if __name__ == "__main__":
    unittest.main()
