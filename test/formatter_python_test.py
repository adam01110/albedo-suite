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
        self.assertEqual(result, {"ok": True, "changed": True, "error": ""})
        self.assertEqual(path.read_text(), "LOWER\n")
        self.assertEqual(path.stat().st_mode & 0o777, 0o751)
        self.assertFalse(formatter._pending)

    async def test_edit_hook_and_failed_edit(self):
        path = self.write()
        await formatter.finish()
        self.fs.edit(str(path), "LOWER", "other")
        self.assertEqual(path.read_text(), "other\n")
        before = formatter._pending.copy()
        with self.assertRaises(ValueError):
            self.fs.edit(str(path), "absent", "new")
        self.assertEqual(formatter._pending, before)
        self.assertTrue((await formatter.finish())["changed"])
        self.assertEqual(path.read_text(), "OTHER\n")

    async def test_unchanged_and_unsupported(self):
        self.write(text="UPPER\n")
        other = self.write("notes.txt")
        self.assertEqual(
            await formatter.finish(), {"ok": True, "changed": False, "error": ""}
        )
        self.assertEqual(other.read_text(), "lower\n")
        self.assertFalse(formatter._pending)

    async def test_failed_command_keeps_original_and_retry(self):
        path = self.write()
        self.set_fixture("failure", diagnostic="broken", exit_code=2)
        result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertIn("broken", result["error"])
        self.assertEqual(path.read_text(), "lower\n")
        self.assertIn(path, formatter._pending)
        self.set_fixture("write", text="fixed")
        self.assertTrue((await formatter.finish())["ok"])
        self.assertEqual(path.read_text(), "fixed")

    async def test_concurrent_user_change(self):
        path = self.write()
        self.set_fixture("concurrent_change", original=str(path))
        result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertIn("concurrent", result["error"])
        self.assertEqual(path.read_text(), "user change")
        self.assertIn(path, formatter._pending)
        self.assertFalse(list(self.root.glob("albedo-format-*")))
        self.fs.write(str(path), "repair")
        self.set_fixture("write", text="fixed")
        self.assertTrue((await formatter.finish())["ok"])

    async def test_outside_ignored_but_symlink_escape_fails(self):
        with tempfile.TemporaryDirectory() as outside:
            path = Path(outside) / "outside.py"
            self.fs.write(str(path), "outside")
            result = await formatter.finish()
            self.assertTrue(result["ok"])
            self.assertFalse(formatter._pending)
            self.assertEqual(path.read_text(), "outside")
            formatter.configure(self.config, str(self.root))
            link = self.root / "link.py"
            link.symlink_to(path)
            self.fs.write(str(link), "new outside")
            self.assertFalse((await formatter.finish())["ok"])

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
        self.config["treefmt"] = [shutil.which("treefmt")]
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

    @unittest.skipUnless(
        shutil.which("nix") and shutil.which("treefmt") and shutil.which("git"),
        "standalone Nix smoke requires nix, treefmt and git",
    )
    async def test_real_nix_fmt_treefmt_exact_path(self):
        async def command(*argv):
            child = await asyncio.create_subprocess_exec(
                *argv,
                cwd=self.root,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            output, _ = await asyncio.wait_for(child.communicate(), 30)
            self.assertEqual(child.returncode, 0, output.decode())
            return output.decode().strip()

        system = await command(
            "nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"
        )
        treefmt_root = str(Path(shutil.which("treefmt")).resolve().parent.parent)
        for root_flags in ([], ["--tree-root-file", "flake.nix"]):
            wrapper = (
                f"#!{sys.executable}\n"
                "import os, sys\n"
                f"os.execv({treefmt_root + '/bin/treefmt'!r}, "
                f"[{treefmt_root + '/bin/treefmt'!r}, '--no-cache', "
                f"'--config-file', 'project.toml', *{root_flags!r}, *sys.argv[1:]])\n"
            )
            builder = (
                "import os, pathlib\n"
                "p = pathlib.Path(os.environ['out']) / 'bin' / 'formatter'\n"
                "p.parent.mkdir(parents=True)\n"
                f"p.write_text({wrapper!r})\n"
                "p.chmod(0o755)\n"
            )
            (self.root / "flake.nix").write_text(
                "{ outputs = _: { formatter." + system + " = builtins.derivation { "
                'name = "formatter-shadow-smoke"; system = ' + json.dumps(system) + "; "
                'builder = "${builtins.storePath '
                + json.dumps(str(Path(sys.executable).resolve().parent.parent))
                + '}/bin/python3"; '
                'args = [ "-c" ' + json.dumps(builder) + " ]; "
                "treefmt = builtins.storePath " + json.dumps(treefmt_root) + "; "
                '} // { meta.mainProgram = "formatter"; }; }; }'
            )
            (self.root / "project.toml").write_text(
                "[formatter.exact]\n"
                f"command = {json.dumps(sys.executable)}\n"
                'options = ["-c", "import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().upper())"]\n'
                'includes = ["src/example.py"]\n'
            )
            (self.root / "src").mkdir(exist_ok=True)
            path = self.write("src/example.py")
            await command("git", "init", "--quiet")
            await command("git", "add", "flake.nix", "project.toml", "src/example.py")
            self.config["nix"] = [
                shutil.which("nix"),
                "--offline",
                "--option",
                "pure-eval",
                "false",
            ]
            self.config["timeoutMs"] = 30000
            result = await formatter.finish()
            self.assertTrue(result["ok"], result["error"])
            self.assertEqual(result, {"ok": True, "changed": True, "error": ""})
            self.assertEqual(path.read_text(), "LOWER\n")

    async def test_project_snapshot_reused_and_publish_guards(self):
        (self.root / "treefmt.toml").write_text("")
        first = self.write()
        second = self.write("second.py")
        with patch.object(
            formatter, "_snapshot", wraps=formatter._snapshot
        ) as snapshot:
            self.assertTrue((await formatter.finish())["ok"])
            self.assertEqual(snapshot.call_count, 1)
        self.assertEqual(first.read_text(), "LOWER\n")
        self.assertEqual(second.read_text(), "LOWER\n")
        self.fs.write(str(first), "lower again")
        self.set_fixture("concurrent_change", original=str(first))
        result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertIn("concurrent", result["error"])
        self.assertEqual(first.read_text(), "user change")
        self.assertIn(first, formatter._pending)

    async def test_project_cannot_redirect_later_target_reset(self):
        (self.root / "treefmt.toml").write_text("")
        first = self.write()
        second = self.write("second.py")

        async def redirect_later_target(argv, cwd, **kwargs):
            staged_second = Path(argv[-1]).parent / second.name
            staged_second.unlink()
            staged_second.symlink_to(second)

        with patch.object(formatter, "_run", side_effect=redirect_later_target):
            result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertIn("symlink", result["error"])
        self.assertEqual(first.read_text(), "lower\n")
        self.assertEqual(second.read_text(), "lower\n")
        self.assertIn(second, formatter._pending)

    async def test_project_staged_symlink_is_never_published(self):
        (self.root / "treefmt.toml").write_text("")
        path = self.write()

        async def replace_with_symlink(argv, cwd, **kwargs):
            staged = Path(argv[-1])
            staged.unlink()
            staged.symlink_to(path)

        with patch.object(formatter, "_run", side_effect=replace_with_symlink):
            result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertIn("symlink", result["error"])
        self.assertEqual(path.read_text(), "lower\n")
        self.assertIn(path, formatter._pending)

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

    async def test_busy_skips_without_losing_pending(self):
        path = self.write()
        job = types.SimpleNamespace(service=False, exit_code=None)
        with patch.dict(
            sys.modules,
            {"albedo_plugins.run": types.SimpleNamespace(jobs={"job": job})},
        ):
            self.assertFalse((await formatter.finish())["changed"])
            self.assertIn(path, formatter._pending)
            job.service = True
            self.assertTrue((await formatter.finish())["changed"])
        self.write()
        other = asyncio.create_task(asyncio.sleep(20))
        try:
            with patch.dict(
                sys.modules,
                {"albedo_cells": types.SimpleNamespace(CELL_TASKS={"other": other})},
            ):
                self.assertFalse((await formatter.finish())["changed"])
                self.assertTrue(formatter._pending)
        finally:
            other.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await other

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

    async def test_remote_setup_noop(self):
        with (
            patch.dict(os.environ, {"ALBEDO_REMOTE_TARGET": "host"}),
            patch.object(formatter, "configure") as configure,
        ):
            self.assertEqual(await plugin.setup(types.SimpleNamespace()), {})
            configure.assert_not_called()

    async def test_total_budget(self):
        first = self.write()
        second = self.write("second.py")
        self.config["timeoutMs"] = 1000
        self.set_fixture("slow")
        result = await formatter.finish()
        self.assertFalse(result["ok"])
        self.assertTrue(result["changed"])
        self.assertEqual(first.read_text(), "done")
        self.assertEqual(second.read_text(), "lower\n")
        self.assertIn(second, formatter._pending)
        self.assertFalse(list(self.root.glob("albedo-format-*")))

    async def test_setup_empty_exports(self):
        async def host(name, args):
            self.assertEqual(name, "formatter.config")
            self.assertEqual(args, {})
            return self.config

        with patch.object(formatter, "configure") as configure:
            self.assertEqual(await plugin.setup(types.SimpleNamespace(host=host)), {})
            configure.assert_called_once_with(self.config)


if __name__ == "__main__":
    unittest.main()
