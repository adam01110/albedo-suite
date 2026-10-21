"""Explicit batch checks: scope, adoption, ordering and post-start conflicts."""

import asyncio
import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from typing import Any
from unittest.mock import patch

sys.path.insert(0, os.environ["ALBEDO_FORMATTER_SOURCE"])
import albedo_formatter as formatter
from albedo_lsp import Lsp

file_plugin: Any = importlib.import_module("albedo_plugins.files")
formatter_plugin: Any = importlib.import_module("albedo_plugins.formatter")
lsp_plugin: Any = importlib.import_module("albedo_plugins.lsp")

FIXTURES = Path(__file__).parent / "fixtures"


class FilesCheckTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.fs = file_plugin.Files()
        self.assertIs(sys.modules["albedo_plugins.formatter"], formatter_plugin)
        self.control = self.root / "control.json"
        self.control.write_text(json.dumps({"mode": "uppercase"}))
        formatter.configure(
            {
                "formatters": {
                    "upper": {
                        "command": [
                            sys.executable,
                            str(FIXTURES / "formatter-unit.py"),
                            str(self.control),
                        ]
                    }
                },
                "chains": {".py": ["upper"]},
                "timeoutMs": 2000,
            },
            str(self.root),
        )
        self.old_manager = lsp_plugin._manager
        lsp_plugin._manager = None
        self.managers = []

    async def asyncTearDown(self):
        for manager in self.managers:
            await manager.close()
        lsp_plugin._manager = self.old_manager
        formatter._root = None
        formatter._pending.clear()
        formatter._versions.clear()
        self.temp.cleanup()

    def write(self, name="a.py", content="lower\n"):
        path = self.root / name
        self.fs.write(str(path), content)
        return path

    def lsp(self):
        self.log = self.root / "lsp.jsonl"
        manager = Lsp(
            {
                "version": 1,
                "servers": [
                    {
                        "id": "fixture",
                        "bin": sys.executable,
                        "args": [
                            str(FIXTURES / "lsp-server.py"),
                            "--log",
                            str(self.log),
                        ],
                        "include": ["**/*.py"],
                        "languageIdByExtension": {".py": "python"},
                        "diagnosticsWaitMs": 100,
                        "startupTimeoutMs": 1000,
                    }
                ],
            },
            self.root,
        )
        self.managers.append(manager)
        lsp_plugin._manager = manager
        return manager

    async def test_completed_manual_formatter_is_adopted(self):
        path = self.write()
        path.write_text("EXTERNALLY FORMATTED\n")
        result = await self.fs.check()
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["formatting"]["changed"])
        self.assertEqual(result["formatting"]["reconciled"], [str(path)])
        self.assertEqual(path.read_text(), "EXTERNALLY FORMATTED\n")
        self.assertEqual((await self.fs.check())["status"], "idle")
        self.assertEqual((await self.fs.check())["formatting"]["status"], "idle")

    async def test_explicit_scope_enrolls_shell_paths_and_leaves_pending(self):
        first = self.write()
        second = self.write("b.py")
        shell = self.root / "shell.py"
        shell.write_text("shell\n")
        result = await self.fs.check(paths=[first, shell])
        self.assertTrue(result["ok"], result)
        self.assertEqual(
            set(result["formatting"]["changed_paths"]), {str(first), str(shell)}
        )
        self.assertEqual(second.read_text(), "lower\n")
        self.assertEqual(result["pending"]["formatting"], [str(second)])
        self.assertEqual(shell.read_text(), "SHELL\n")

    async def test_both_stages_check_formatted_bytes_in_one_call(self):
        self.lsp()
        path = self.write(content="bad\n")
        (self.root / "unrelated.py").write_text("BAD")
        result = await self.fs.check()
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["clean"])
        self.assertEqual(result["diagnostics"]["status"], "findings")
        self.assertTrue(result["formatting"]["changed"])
        self.assertIn("BAD", result["diagnostics"]["feedback"])
        events = [json.loads(line) for line in self.log.read_text().splitlines()]
        opened = [
            e["params"]["textDocument"]
            for e in events
            if e["event"] == "textDocument/didOpen"
        ]
        self.assertEqual([e["text"] for e in opened], ["BAD\n"])
        self.assertEqual(result["diagnostics"]["checked"], [str(path)])
        self.assertEqual((await self.fs.check())["status"], "idle")

    async def test_failed_formatting_skips_diagnostics_and_retains_work(self):
        manager = self.lsp()
        path = self.write()
        self.control.write_text(json.dumps({"mode": "failure", "diagnostic": "failed"}))
        result = await self.fs.check()
        self.assertFalse(result["ok"])
        self.assertEqual(result["diagnostics"]["status"], "skipped")
        self.assertIn(path, formatter._pending)
        self.assertIn(path, manager.pending)
        self.assertFalse(self.log.exists())

    async def test_disabled_remote_and_unmatched_do_not_fabricate_passes(self):
        formatter._root = None
        result = await self.fs.check()
        self.assertEqual(result["status"], "disabled")
        self.assertIsNone(result["ok"])
        self.assertIsNone(result["clean"])
        with patch.dict(os.environ, {"ALBEDO_REMOTE_TARGET": "remote"}):
            self.assertEqual((await self.fs.check())["status"], "unsupported")
        formatter.configure({}, str(self.root))
        self.write("note.txt")
        result = await self.fs.check()
        self.assertEqual(result["status"], "unmatched")
        self.assertIsNone(result["clean"])

    async def test_post_start_external_edit_is_never_overwritten(self):
        path = self.write()

        async def edit(argv, cwd, **kwargs):
            Path(argv[-1]).write_text("FORMATTED")
            path.write_text("USER EDIT")

        with patch.object(formatter, "_run", edit):
            result = await self.fs.check()
        self.assertFalse(result["ok"])
        self.assertEqual(path.read_text(), "USER EDIT")
        self.assertIn(path, formatter._pending)
        self.assertIn(str(path), result["conflicts"])

    async def test_same_bytes_new_edit_generation_is_not_lost(self):
        path = self.write()

        async def record_again(argv, cwd, **kwargs):
            formatter.record(path)

        with patch.object(formatter, "_run", record_again):
            result = await self.fs.check()
        self.assertFalse(result["ok"])
        self.assertIn(path, formatter._pending)
        self.assertIn("edited during", result["formatting"]["error"])

    async def test_two_files_instances_serialize_whole_batches(self):
        self.write()
        entered, release = asyncio.Event(), asyncio.Event()

        async def blocked(argv, cwd, **kwargs):
            entered.set()
            await release.wait()

        with patch.object(formatter, "_run", blocked):
            first = asyncio.create_task(self.fs.check())
            await entered.wait()
            second = asyncio.create_task(file_plugin.Files().check())
            await asyncio.sleep(0)
            self.assertFalse(second.done())
            release.set()
            one, two = await asyncio.gather(first, second)
        self.assertTrue(one["ok"], one)
        self.assertEqual(two["status"], "idle")

    async def test_new_paths_arriving_during_batch_remain_pending(self):
        self.write()
        extra = self.root / "extra.py"

        async def write_extra(argv, cwd, **kwargs):
            self.fs.write(str(extra), "new")

        with patch.object(formatter, "_run", write_extra):
            result = await self.fs.check()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["pending"]["formatting"], [str(extra)])

    async def test_lsp_only_rechecks_entire_batch_stability(self):
        for timing in ("after_first", "before_second"):
            with self.subTest(timing=timing):
                formatter._root = None
                manager = self.lsp()
                first, second = self.write("a.py", "A"), self.write("b.py", "B")
                order = list(manager.pending)
                target = order[0] if timing == "after_first" else order[1]

                async def diagnose(path, **kwargs):
                    if path == (order[1] if timing == "after_first" else order[0]):
                        target.write_text("NEW UNCHECKED")
                    return {"diagnostics": []}

                with patch.object(manager, "diagnostics", diagnose):
                    result = await self.fs.check()
                self.assertFalse(result["ok"], result)
                self.assertFalse(result["clean"])
                self.assertIn(str(target), result["conflicts"])
                self.assertIn(target, manager.pending)
                await manager.close()

    async def test_cancel_after_formatting_requeues_and_cleans_versions(self):
        manager = self.lsp()
        first, second = self.write(), self.write("b.py")
        entered = asyncio.Event()

        async def blocked(path, **kwargs):
            if path == list(manager.pending)[-1]:
                first.write_text("USER CHANGE")
                entered.set()
                await asyncio.Event().wait()
            return {"diagnostics": []}

        with patch.object(manager, "diagnostics", blocked):
            task = asyncio.create_task(self.fs.check())
            await entered.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertEqual(first.read_text(), "USER CHANGE")
        self.assertIn(first, formatter._pending)
        self.assertIn(first, manager.pending)
        self.assertIn(second, manager.pending)
        self.assertTrue(set(formatter._versions) <= set(formatter._pending))

    async def test_capacity_rejection_has_no_tracking_side_effects(self):
        path = self.root / "extra.py"
        path.write_text("extra")
        for index in range(1024):
            formatter._pending[self.root / f"existing{index}.py"] = "pending"
        before = dict(formatter._pending)
        result = await self.fs.check(paths=[path])
        self.assertFalse(result["ok"])
        self.assertIn("capacity", result["error"])
        self.assertEqual(formatter._pending, before)
        self.assertFalse(formatter._overflow)

    async def test_lsp_capacity_rejection_does_not_poison_tracker(self):
        formatter._root = None
        manager = self.lsp()
        path = self.root / "extra.py"
        path.write_text("extra")
        for index in range(1024):
            manager.pending[self.root / f"existing{index}.py"] = index
        before = dict(manager.pending)
        result = await self.fs.check(paths=[path])
        self.assertFalse(result["ok"])
        self.assertIn("capacity", result["error"])
        self.assertEqual(manager.pending, before)
        self.assertFalse(manager.overflow)

    async def test_partial_formatting_success_is_not_lost_on_later_failure(self):
        manager = self.lsp()
        first, second = self.write(), self.write("b.py")

        async def partial(argv, cwd, **kwargs):
            staged = Path(argv[-1])
            if staged.name == "b.py":
                raise ValueError("later formatter failed")
            staged.write_text(staged.read_text().upper())

        with patch.object(formatter, "_run", partial):
            result = await self.fs.check()
        self.assertFalse(result["ok"])
        self.assertEqual(result["formatting"]["changed_paths"], [str(first)])
        self.assertEqual(result["pending"]["formatting"], [str(second)])
        self.assertEqual(result["diagnostics"]["status"], "skipped")
        self.assertEqual(set(manager.pending), {first, second})
        self.assertFalse(self.log.exists())

    async def test_large_unicode_failure_is_a_normal_structured_result(self):
        self.write()

        async def failure(*args, **kwargs):
            raise ValueError("😀" * 20000)

        with patch.object(formatter, "_run", failure):
            result = await self.fs.check()
        self.assertFalse(result["ok"])
        self.assertEqual(result["formatting"]["error"], "😀" * 16384)
        self.assertTrue(result["pending"]["formatting"])

    async def test_invalid_paths_rejected_without_enrollment(self):
        path = self.write()
        link = self.root / "link.py"
        link.symlink_to(path)
        before = dict(formatter._pending)
        for scope in ([link], [self.root / "missing.py"], list(range(1025))):
            result = await self.fs.check(paths=scope)
            self.assertFalse(result["ok"])
            self.assertEqual(formatter._pending, before)


if __name__ == "__main__":
    unittest.main()
