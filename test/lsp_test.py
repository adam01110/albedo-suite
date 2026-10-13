"""Targeted subprocess tests for the temporary LSP runtime."""

import asyncio
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import AsyncMock, patch

SOURCE = Path(
    os.environ.get(
        "ALBEDO_LSP_SOURCE",
        Path(__file__).resolve().parents[1] / "src/server/priv/python",
    )
)
sys.path.insert(0, str(SOURCE))
import albedo_lsp
from albedo_lsp import Lsp, LspError

FIXTURE = Path(__file__).resolve().parent / "fixtures/lsp-server.py"


class LspTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = self.root / "test.nix"
        self.path.write_text("BAD😀x\n")
        self.log = self.root / "log"
        self.managers = []

    def manager(self, mode="normal", **overrides):
        server = {
            "id": "fixture",
            "bin": sys.executable,
            "args": [str(FIXTURE), "--mode", mode, "--log", str(self.log)],
            "include": ["**/*.nix"],
            "languageIdByExtension": {".nix": "nix"},
            "startupTimeoutMs": 300,
            "diagnosticsWaitMs": 100,
            "rootMarkers": [".git"],
            "settings": {"fixture": {"hello": True}},
        }
        server.update(overrides)
        manager = Lsp({"version": 1, "servers": [server]}, self.root)
        self.managers.append(manager)
        return manager

    def logs(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    async def asyncTearDown(self):
        for manager in self.managers:
            await manager.close()
        self.temp.cleanup()

    async def test_deferred_diagnostics_and_edit_scope(self):
        manager = self.manager()
        manager.record(self.path)
        self.assertFalse(self.log.exists())
        first = await manager.finish()
        self.assertTrue(first["ok"], first)
        self.assertIn("BAD", first["feedback"])
        self.assertNotIn("stale", first["feedback"])
        self.assertEqual((await manager.finish())["feedback"], "")
        self.path.write_text("clean")
        manager.record(self.path)
        self.assertEqual((await manager.finish())["feedback"], "")
        self.assertEqual(
            len([e for e in self.logs() if e["event"] == "textDocument/didChange"]), 1
        )
        ignored = self.root / "ignored.txt"
        ignored.write_text("BAD")
        manager.record(ignored)
        self.assertTrue((await manager.finish())["ok"])
        self.assertEqual(manager.pending, {})

    async def test_deferred_all_matching_servers(self):
        manager = self.manager()
        manager.config.append({**manager.config[0], "id": "other"})
        manager.record(self.path)
        result = await manager.finish()
        self.assertTrue(result["ok"], result)
        self.assertIn('"server": "fixture"', result["feedback"])
        self.assertIn('"server": "other"', result["feedback"])

    async def test_deferred_failure_retains_edit_and_requires_close(self):
        manager = self.manager("timeout")
        manager.record(self.path)
        result = await manager.finish()
        self.assertFalse(result["ok"])
        self.assertIn(self.path, manager.pending)
        result = await manager.finish()
        self.assertFalse(result["ok"])
        self.assertIn("close explicitly", result["error"])
        await manager.close()
        manager.config[0]["args"][2] = "normal"
        self.assertTrue((await manager.finish())["ok"])

    async def test_failed_retries_preserve_cause_and_do_not_replay(self):
        manager = self.manager("death")
        manager.record(self.path)
        first = await manager.finish()
        self.assertFalse(first["ok"])
        self.assertIn("fixture", first["error"])
        self.assertIn(str(self.path), first["error"])
        self.assertIn("stdout closed (EOF)", first["error"])
        self.assertIn("fixture startup failed", first["error"])
        cause = manager.clients["fixture"].failure
        log_count = len(self.logs())
        reports = [(await manager.finish())["error"] for _ in range(10)]
        self.assertEqual(len(set(reports)), 1)
        self.assertEqual(reports[0].count("close explicitly"), 1)
        self.assertIn("await lsp.close('fixture')", reports[0])
        self.assertEqual(manager.clients["fixture"].failure, cause)
        self.assertEqual(len(self.logs()), log_count)
        self.assertIn(self.path, manager.pending)
        await manager.close("fixture")
        manager.config[0]["args"][2] = "normal"
        self.assertTrue((await manager.finish())["ok"])

    async def test_deferred_busy_and_concurrent_edit(self):
        import types

        manager = self.manager()
        manager.record(self.path)
        task = asyncio.create_task(asyncio.Event().wait())
        stub = types.SimpleNamespace(CELL_TASKS={"busy": task})
        try:
            with patch.dict(sys.modules, {"albedo_cells": stub}):
                self.assertTrue((await manager.finish())["ok"])
                self.assertFalse(self.log.exists())
                self.assertIn(self.path, manager.pending)
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        original = manager.diagnostics

        async def changed(*args, **kwargs):
            result = await original(*args, **kwargs)
            self.path.write_text("clean")
            manager.record(self.path)
            return result

        with patch.object(manager, "diagnostics", changed):
            result = await manager.finish()
        self.assertFalse(result["ok"])
        self.assertIn("changed during", result["error"])
        self.assertIn(self.path, manager.pending)
        self.assertEqual((await manager.finish())["feedback"], "")

    async def test_deferred_tracking_and_feedback_caps(self):
        manager = self.manager()
        with patch.dict(
            sys.modules,
            {
                "albedo_plugins.run": types.SimpleNamespace(
                    jobs={
                        "busy": types.SimpleNamespace(
                            service=False, exit_code=None
                        )
                    }
                )
            },
        ):
            manager.record(self.path)
            self.assertTrue((await manager.finish())["ok"])
            self.assertFalse(self.log.exists())
        report = {
            "server": "fixture",
            "path": str(self.path),
            "version": 1,
            "diagnostics": [{"message": "x" * 100000}],
        }
        with patch.object(manager, "diagnostics", AsyncMock(return_value=report)):
            result = await manager.finish()
        self.assertLessEqual(len(result["feedback"]), 16400)
        self.assertIn("truncated", result["feedback"])
        for index in range(1025):
            manager.record(self.root / f"queued{index}.nix")
        self.assertEqual(len(manager.pending), 1024)
        result = await manager.finish()
        self.assertFalse(result["ok"])
        self.assertIn("1024", result["error"])

    async def test_deferred_disabled_and_scope(self):
        manager = self.manager(enabled=False)
        manager.record(self.path)
        self.assertTrue((await manager.finish())["ok"])
        self.assertFalse(self.log.exists())
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / "outside.nix"
            target.write_text("BAD")
            manager.record(target)
            self.assertEqual(manager.pending, {})
            manager.config[0]["enabled"] = True
            link = self.root / "link.nix"
            link.symlink_to(target)
            manager.record(link)
            self.assertFalse((await manager.finish())["ok"])
            self.assertFalse(self.log.exists())

    async def test_operation_admission_bounds_snapshot_queue(self):
        manager = self.manager()
        await manager.diagnostics("test.nix")
        client = manager.clients["fixture"]
        await client.lock.acquire()
        tasks = []
        try:
            with patch.object(manager, "snapshot", wraps=manager.snapshot) as snapshot:
                tasks = [
                    asyncio.create_task(manager.diagnostics("test.nix"))
                    for _ in range(albedo_lsp.MAX_OPERATIONS)
                ]
                await asyncio.sleep(0)
                self.assertEqual(manager.active_operations, albedo_lsp.MAX_OPERATIONS)
                self.assertEqual(snapshot.call_count, albedo_lsp.MAX_OPERATIONS)
                with self.assertRaisesRegex(LspError, "operation limit"):
                    await manager.diagnostics("test.nix")
                self.assertEqual(snapshot.call_count, albedo_lsp.MAX_OPERATIONS)
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                self.assertEqual(manager.active_operations, 0)
        finally:
            client.lock.release()
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
        self.assertTrue((await manager.diagnostics("test.nix"))["diagnostics"])

    async def test_cancelled_graceful_close_reaps_process(self):
        manager = self.manager("shutdown-timeout")
        await manager.diagnostics("test.nix")
        pid = manager.clients["fixture"].proc.pid
        closing = asyncio.create_task(manager.close())
        try:
            async with asyncio.timeout(2):
                while not any(e["event"] == "shutdown" for e in self.logs()):
                    await asyncio.sleep(0.01)
            closing.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(closing, 4)
            self.assertEqual(manager.clients, {})
            self.assertNotIn(pid, albedo_lsp._PROCESSES)
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        finally:
            if not closing.done():
                closing.cancel()
                await asyncio.gather(closing, return_exceptions=True)

    async def test_lazy_refresh_and_navigation(self):
        manager = self.manager()
        self.assertEqual(manager.servers()[0]["state"], "unloaded")
        self.assertFalse(self.log.exists())
        result = await manager.diagnostics("test.nix")
        self.assertEqual(result["diagnostics"][0]["message"], "BAD😀x\n")
        hover = await manager.hover("test.nix", 0, 5)
        self.assertEqual(hover["result"]["position"]["character"], 5)
        with self.assertRaises(ValueError):
            await manager.hover("test.nix", 0, 4)
        self.assertTrue((await manager.definition("test.nix", 0, 0))["result"])
        self.assertTrue(
            (await manager.references("test.nix", 0, 0, include_declaration=False))[
                "result"
            ]
        )
        self.assertTrue((await manager.symbols("test.nix"))["result"])
        self.path.write_text("clean\n")
        refreshed = await manager.diagnostics("test.nix")
        self.assertEqual(refreshed["version"], 2)
        self.assertEqual(refreshed["diagnostics"], [])
        events = self.logs()
        self.assertEqual(sum(e["event"] == "START" for e in events), 1)
        self.assertEqual(
            next(e for e in events if e["event"] == "START")["cwd"], str(self.root)
        )
        config = next(
            e
            for e in events
            if e["event"] == "response" and e["message"]["id"] == "config"
        )
        self.assertEqual(config["message"]["result"][0], {"hello": True})
        edit = next(
            e
            for e in events
            if e["event"] == "response" and e["message"]["id"] == "edit"
        )
        self.assertFalse(edit["message"]["result"]["applied"])

    async def test_failure_modes_no_replay(self):
        for mode in (
            "death",
            "malformed",
            "oversized",
            "timeout",
            "no-diagnostics",
            "unsupported",
            "error",
        ):
            with self.subTest(mode=mode):
                manager = self.manager(mode)
                with self.assertRaises(LspError):
                    if mode in ("unsupported", "error"):
                        await manager.hover("test.nix", 0, 0)
                    else:
                        await manager.diagnostics("test.nix")
                self.assertEqual(manager.servers()[0]["state"], "failed")
                before = len(self.logs())
                with self.assertRaises(LspError):
                    await manager.diagnostics("test.nix")
                self.assertEqual(len(self.logs()), before)
                await manager.close()

    async def test_cancel_reaps_process(self):
        manager = self.manager("timeout", startupTimeoutMs=5000)
        task = asyncio.create_task(manager.diagnostics("test.nix"))
        # Synchronize on actual process creation, without depending on log flushing.
        for _ in range(1000):
            if manager.clients and manager.clients["fixture"].proc:
                break
            await asyncio.sleep(0.001)
        proc = manager.clients["fixture"].proc
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertIsNotNone(proc.returncode)
        with self.assertRaises(ProcessLookupError):
            os.kill(proc.pid, 0)

    async def test_close_inflight(self):
        manager = self.manager("timeout", startupTimeoutMs=5000)
        task = asyncio.create_task(manager.diagnostics("test.nix"))
        for _ in range(1000):
            if manager.clients and manager.clients["fixture"].proc:
                break
            await asyncio.sleep(0.001)
        await asyncio.wait_for(manager.close(), 2)
        with self.assertRaises(LspError):
            await task
        self.assertEqual(manager.servers()[0]["state"], "unloaded")

    async def test_path_and_config_rejections(self):
        manager = self.manager()
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / "outside.nix"
            target.write_text("BAD")
            (self.root / "link.nix").symlink_to(target)
            for path in (target, "link.nix"):
                with self.assertRaises(LspError):
                    await manager.diagnostics(path)
        self.assertFalse(self.log.exists())
        for config in ([], {"version": True}, {"servers": [None]}, {"servers": [{}]}):
            with self.assertRaises(ValueError):
                Lsp(config, self.root)
        for overrides in (
            {"enabled": 1},
            {"args": "oops"},
            {"diagnosticsWaitMs": 0},
            {"settings": []},
            {"rootMarkers": ["../escape"]},
        ):
            with self.assertRaises(ValueError):
                self.manager(**overrides)

    async def test_caps_ambiguity_and_eviction(self):
        manager = self.manager()
        manager.config.append({**manager.config[0], "id": "other"})
        with self.assertRaisesRegex(LspError, "ambiguous"):
            await manager.diagnostics("test.nix")
        self.assertFalse(self.log.exists())
        manager.config.pop()
        for index in range(34):
            path = self.root / f"file{index}.nix"
            path.write_text("clean")
            await manager.diagnostics(path.name)
        self.assertEqual(len(manager.clients["fixture"].docs), 32)
        self.assertEqual(
            sum(e["event"] == "textDocument/didClose" for e in self.logs()), 2
        )
        big = self.root / "big.nix"
        with big.open("wb") as handle:
            handle.truncate(albedo_lsp.MAX_BYTES + 1)
        with self.assertRaisesRegex(LspError, "8 MiB"):
            await manager.diagnostics(big.name)
        manager.clients.update(
            {f"placeholder{i}": manager.clients["fixture"] for i in range(7)}
        )
        manager.config.append({**manager.config[0], "id": "ninth"})
        with self.assertRaisesRegex(LspError, "limit"):
            await manager.diagnostics("test.nix", server="ninth")
        for key in list(manager.clients):
            if key.startswith("placeholder"):
                del manager.clients[key]

    async def test_root_and_stderr_bound(self):
        nested = self.root / "project"
        nested.mkdir()
        (nested / ".git").mkdir()
        (nested / "inner").mkdir()
        (nested / "inner/test.nix").write_text("clean")
        manager = self.manager("stderr")
        await manager.diagnostics("project/inner/test.nix")
        start = next(e for e in self.logs() if e["event"] == "START")
        initialize = next(e for e in self.logs() if e["event"] == "initialize")
        self.assertEqual(start["cwd"], str(nested))
        self.assertEqual(initialize["params"]["rootUri"], nested.as_uri())
        self.assertLessEqual(len(manager.clients["fixture"].stderr), 16384)

    async def test_other_project_root_requires_close(self):
        manager = self.manager()
        for name in ("first", "second"):
            folder = self.root / name
            folder.mkdir()
            (folder / ".git").mkdir()
            (folder / "file.nix").write_text("clean")
        await manager.diagnostics("first/file.nix")
        with self.assertRaisesRegex(LspError, "different project root"):
            await manager.diagnostics("second/file.nix")
        self.assertEqual(sum(e["event"] == "START" for e in self.logs()), 1)
        await manager.close("fixture")
        await manager.diagnostics("second/file.nix")
        self.assertEqual(sum(e["event"] == "START" for e in self.logs()), 2)

    async def test_request_timeout(self):
        manager = self.manager("request-timeout")
        await manager.diagnostics("test.nix")
        # request's default timeout is bound at definition; patch the operation boundary.
        original = manager.clients["fixture"].request

        async def short(method, params):
            return await original(method, params, timeout=0.05)

        manager.clients["fixture"].request = short
        with self.assertRaisesRegex(LspError, "timed out"):
            await manager.hover("test.nix", 0, 0)

    async def test_plugin_remote_and_cleanup(self):
        spec = importlib.util.spec_from_file_location(
            "temporary_lsp_plugin", SOURCE / "albedo_plugins/lsp.py"
        )
        assert spec is not None and spec.loader is not None
        plugin = importlib.util.module_from_spec(spec)
        # This source overlay may not contain the upstream API; supply only its interface.
        import types

        stub = types.ModuleType("albedo_api")
        setattr(stub, "PythonApi", object)
        with patch.dict(sys.modules, {"albedo_api": stub}):
            spec.loader.exec_module(plugin)

        class Api:
            callbacks = []

            async def host(self, name, _params):
                self.name = name
                return {}

            def on_shutdown(self, callback):
                self.callbacks.append(callback)

        api = Api()
        with patch.dict(os.environ, {"ALBEDO_REMOTE_TARGET": "remote"}):
            self.assertEqual(await plugin.setup(api), {})
        with patch.dict(os.environ, {}, clear=True):
            exports = await plugin.setup(api)
        self.assertEqual(api.name, "lsp.config")
        self.assertIn("lsp", exports)
        self.assertEqual(len(api.callbacks), 1)
        await api.callbacks[0]()


if __name__ == "__main__":
    unittest.main()
