"""Real RTK plus real supervised subprocess integration (isolated HOME).

ALBEDO_RTK_SOURCE is the integrated priv/python tree; RTK must be on PATH.
For overlay-only testing set ALBEDO_RTK_UPSTREAM to pinned upstream priv/python.
No daemon/network/provider/build required.
"""

import asyncio
from collections import OrderedDict
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
from typing import Any
import unittest
from unittest.mock import patch

SOURCE = Path(
    os.environ.get(
        "ALBEDO_RTK_SOURCE",
        Path(__file__).resolve().parents[1] / "src/server/priv/python",
    )
)
if "ALBEDO_RTK_UPSTREAM" in os.environ:
    sys.path.insert(0, os.environ["ALBEDO_RTK_UPSTREAM"])
sys.path.insert(0, str(SOURCE))
import albedo_capture

spec = importlib.util.spec_from_file_location(
    "rtk_run_under_test", SOURCE / "albedo_plugins/run.py"
)
assert spec is not None and spec.loader is not None
plugin: Any = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = plugin
spec.loader.exec_module(plugin)


class RtkExecutionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rtk tests ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        homes = patch.dict(
            os.environ,
            {
                "HOME": str(self.root),
                "ALBEDO_HOME": str(self.root / "albedo"),
                "XDG_CONFIG_HOME": str(self.root / "config"),
                "XDG_DATA_HOME": str(self.root / "data"),
            },
        )
        homes.start()
        self.addCleanup(homes.stop)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.env = {
            "HOME": str(self.root),
            "XDG_CONFIG_HOME": str(self.root / "config"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "RTK_TELEMETRY_DISABLED": "1",
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "LOG": str(self.log),
            "ALBEDO_NO_MBX": "1",
        }
        self.assertIsNotNone(
            shutil.which("rtk"), "RTK must be on PATH for real integration tests"
        )
        plugin.loop = asyncio.get_running_loop()
        plugin.capture_factory = lambda id: albedo_capture.Capture(id, "job")
        plugin.preview_limit = 65536
        plugin.send = lambda frame: None
        plugin.host = None
        plugin.watch_output = None
        plugin.forget_output = None
        plugin.jobs, plugin.active, plugin.retained, plugin.owed = (
            {},
            {},
            OrderedDict(),
            {},
        )
        plugin.announcer = None

    async def asyncTearDown(self):
        await plugin.close()
        if plugin.announcer is not None:
            plugin.announcer.cancel()
            await asyncio.gather(plugin.announcer, return_exceptions=True)

    def fixture(self, name="cargo"):
        path = self.bin / name
        path.write_text(
            "#!"
            + sys.executable
            + "\n"
            + r"""
import json, os, sys, time
with open(os.environ['LOG'], 'a') as log:
    log.write(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd(), 'marker': os.environ.get('MARKER')}) + '\n')
if os.environ.get('SLOW'):
    time.sleep(30)
print('error: fixture failure' if os.environ.get('FAIL') else 'Finished fixture successfully')
sys.exit(int(os.environ.get('FAIL', '0')))
"""
        )
        path.chmod(0o755)
        return path

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    async def test_literal_arguments_cwd_environment_and_failure_once(self):
        self.fixture()
        args = [
            "test",
            "literal ; $(touch PWN) | > *",
            "--manifest-path",
            "path with spaces/Cargo.toml",
            "--",
            "--nocapture",
        ]
        job = plugin.run(
            "cargo",
            *args,
            cwd=self.root,
            env={**self.env, "MARKER": "literal value", "FAIL": "7"},
        )
        self.assertTrue(job.routed)
        self.assertEqual(job.requested_argv, ["cargo", *args])
        self.assertEqual(job.argv[1:], ["cargo", *args])
        await job
        self.assertEqual(job.exit_code, 7, job.tail())
        self.assertEqual(
            self.calls(),
            [{"argv": args, "cwd": str(self.root), "marker": "literal value"}],
        )
        self.assertFalse((self.root / "PWN").exists())
        self.assertIn("error", job.tail())

    async def test_hook_rewrite_is_routed_before_dispatch(self):
        self.fixture()
        hooked = plugin.hook.Call("run", {"command": "cargo check"})
        with patch.object(plugin.hook, "before", return_value=hooked):
            job = plugin.run("true", env=self.env)
        await job
        self.assertEqual(job.exit_code, 0, job.tail())
        self.assertTrue(job.routed)
        self.assertEqual(job.requested_argv, ["cargo", "check"])
        self.assertEqual([call["argv"] for call in self.calls()], [["check"]])

    async def test_hook_block_prevents_dispatch(self):
        self.fixture()
        with patch.object(
            plugin.hook, "before", side_effect=PermissionError("blocked by a hook")
        ):
            with self.assertRaisesRegex(PermissionError, "blocked by a hook"):
                plugin.run("cargo", "check", env=self.env)
        self.assertFalse(self.log.exists())
        self.assertFalse(plugin.active)

    async def test_success_and_explicit_rtk_not_double_wrapped(self):
        self.fixture()
        job = plugin.run("cargo", "check", env=self.env)
        await job
        self.assertEqual(job.exit_code, 0, job.tail())
        explicit = plugin.run("rtk", "cargo", "check", env=self.env)
        self.assertFalse(explicit.routed)
        await explicit
        self.assertEqual(explicit.exit_code, 0, explicit.tail())
        self.assertEqual(len(self.calls()), 2)

    async def test_absolute_executable_identity_and_unsupported(self):
        path = self.fixture()
        job = plugin.run(path, "test", env=self.env)
        self.assertFalse(job.routed)
        await job
        other = plugin.run("cargo", "metadata", env=self.env)
        self.assertFalse(other.routed)
        await other
        self.assertEqual(len(self.calls()), 2)

    async def test_missing_rtk_fails_before_any_native_dispatch(self):
        self.fixture()
        real_which = shutil.which
        with patch(
            "albedo_rtk.shutil.which",
            side_effect=lambda program, **kwargs: (
                None if program == "rtk" else real_which(program, **kwargs)
            ),
        ):
            with self.assertRaisesRegex(FileNotFoundError, "rtk is required"):
                plugin.run(
                    str(self.bin / "cargo").replace(str(self.bin) + "/", ""),
                    "test",
                    env=self.env,
                )
        self.assertFalse(self.log.exists())
        self.assertFalse(plugin.active)

    async def test_real_ls_spaces_literal_metacharacters_and_nonzero_exit(self):
        name = "literal ; $() [x] space"
        (self.root / name).write_text("hello\n")
        job = plugin.run("ls", name, cwd=self.root, env=self.env)
        self.assertTrue(job.routed)
        await job
        self.assertEqual(job.exit_code, 0, job.tail())
        self.assertIn(name, job.tail())
        bad = plugin.run("ls", "missing-file", cwd=self.root, env=self.env)
        await bad
        self.assertEqual(bad.exit_code, 2, bad.tail())

    async def test_stdin_bytes_path_and_pipeline_dataflow(self):
        for stdin in (b"one\ntwo\n", "one\ntwo\n"):
            job = plugin.run("wc", "-l", stdin=stdin, env=self.env)
            await job
            self.assertEqual(job.exit_code, 0, job.tail())
            self.assertEqual(job.tail().strip(), "2")
        path = self.root / "input file"
        path.write_text("one\ntwo\n")
        job = plugin.run("wc", "-l", stdin=path, env=self.env)
        await job
        self.assertEqual(job.tail().strip(), "2")
        # First wc would emit a filtered count; a producer instead runs native.
        producer = plugin.run("wc", "-l", stdin=b"one\ntwo\n", env=self.env)
        consumer = producer.pipe("wc", "-c", env=self.env)
        self.assertFalse(producer.routed)
        self.assertEqual(producer.argv, producer.requested_argv)
        self.assertTrue(consumer.routed)
        await consumer
        self.assertEqual(consumer.exit_code, 0, consumer.tail())
        self.assertEqual(consumer.tail().strip(), "2")
        self.assertIn(" | ", consumer.pipeline)

    async def test_late_pipe_refused_without_replay(self):
        self.fixture()
        job = plugin.run("cargo", "check", env=self.env)
        await job
        with self.assertRaisesRegex(RuntimeError, "attach the pipe before launch"):
            job.pipe("wc", "-l", env=self.env)
        self.assertEqual(len(self.calls()), 1)

    async def test_internal_start_is_raw_even_for_supported_argv(self):
        self.fixture()
        job = plugin.start(
            ["cargo", "check"], 10, env={**os.environ, **self.env}, traced=False
        )
        await job
        self.assertFalse(job.routed)
        self.assertEqual(job.argv, ["cargo", "check"])
        self.assertIn("Finished fixture successfully", job.tail())

    async def test_immediate_start_timeout_and_cancellation(self):
        self.fixture()
        started = time.monotonic()
        job = plugin.run("cargo", "check", env={**self.env, "SLOW": "1"}, timeout=0.1)
        self.assertLess(time.monotonic() - started, 0.1)
        await job
        self.assertTrue(job.timed_out)
        self.assertTrue(job.termination.gone)
        other = plugin.run("cargo", "check", env={**self.env, "SLOW": "1"})
        await asyncio.wait_for(asyncio.shield(other.spawning), 3)
        await other.stop()
        self.assertTrue(other.termination.gone)

    async def test_real_rg_stdin_literal_pattern_and_pipeline(self):
        payload = b"literal ; $(touch PWN) *\nother\n"
        job = plugin.run(
            "rg", "-F", "literal ; $(touch PWN) *", stdin=payload, env=self.env
        )
        self.assertTrue(job.routed)
        await job
        self.assertEqual(job.exit_code, 0, job.tail())
        self.assertIn("literal", job.tail())
        missing = plugin.run("rg", "not-here", stdin=payload, env=self.env)
        await missing
        self.assertEqual(missing.exit_code, 1, missing.tail())
        producer = plugin.run("rg", "-F", "literal", stdin=payload, env=self.env)
        consumer = producer.pipe("wc", "-l", env=self.env)
        self.assertFalse(producer.routed)
        await consumer
        self.assertEqual(consumer.tail().strip(), "1")

    async def test_degraded_remote_refuses_before_dispatch(self):
        spec = importlib.util.spec_from_file_location(
            "rtk_remote_under_test", SOURCE / "albedo_plugins/remote.py"
        )
        assert spec is not None and spec.loader is not None
        remote: Any = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = remote
        spec.loader.exec_module(remote)
        connection = remote.RemoteConnection({"host": "fixture", "remote_cwd": None})
        connection.degraded = "fixture no Python"
        with patch.object(remote, "FallbackJob") as fallback:
            with self.assertRaisesRegex(remote.RemoteError, "no native fallback"):
                connection.run("ls", "a b")
            fallback.assert_not_called()
            connection.run("echo", "literal ; *")
            fallback.assert_called_once()
            fallback.reset_mock()
            hooked = remote.hook.Call("run", {"command": "ls"})
            with patch.object(remote.hook, "before", return_value=hooked):
                with self.assertRaisesRegex(remote.RemoteError, "no native fallback"):
                    connection.run("echo", "rewritten")
            fallback.assert_not_called()

    async def test_real_pytest_success_and_failure(self):
        if shutil.which("pytest") is None:
            self.skipTest("pytest required for pytest filter integration")
        path = self.root / "test_space case.py"
        path.write_text("def test_ok(): assert True\n")
        job = plugin.run("pytest", str(path), cwd=self.root, env=self.env)
        await job
        self.assertEqual(job.exit_code, 0, job.tail())
        path.write_text("def test_fail(): assert False\n")
        job = plugin.run("pytest", str(path), cwd=self.root, env=self.env)
        await job
        self.assertEqual(job.exit_code, 1, job.tail())
        self.assertIn("fail", job.tail().lower())


if __name__ == "__main__":
    unittest.main()
