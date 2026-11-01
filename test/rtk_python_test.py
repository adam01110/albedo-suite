"""RTK argv grammar and supervised-job output regressions."""

import asyncio
from collections import OrderedDict
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(
    0,
    os.environ.get(
        "ALBEDO_RTK_SOURCE",
        str(Path(__file__).resolve().parents[1] / "src/server/priv/python"),
    ),
)
import albedo_rtk


class RtkRoutingTests(unittest.TestCase):
    def test_agent_instructions_do_not_expose_routing(self):
        extension = (
            Path(__file__).resolve().parents[1]
            / "src/server/src/albedo/harness/extensions/run/extension.gleam"
        )
        if not extension.exists():
            self.skipTest("source overlay is unavailable")
        instructions = (
            extension.read_text()
            .split("const instructions =", 1)[1]
            .split("pub fn extension", 1)[0]
        )
        self.assertNotIn("rtk", instructions.lower())

    def test_supported_grammar(self):
        for argv in (
            ["cargo", "test", "a b", "--", "--nocapture"],
            ["go", "build", "./..."],
            ["git", "diff", "--", "a b"],
            ["rg", "-F", "$(touch PWN);*"],
            ["wc", "-l"],
            ["ls", "-lah", "a b"],
            ["pytest", "tests/a b.py"],
        ):
            with self.subTest(argv=argv):
                with patch("albedo_rtk.shutil.which", return_value="/tools/rtk"):
                    self.assertEqual(
                        albedo_rtk.route(argv, None), ["/tools/rtk", *argv]
                    )

    def test_native_identity_and_unsupported_grammar(self):
        for argv in (
            ["rtk", "ls"],
            ["/tools/rtk", "ls"],
            ["/tools/cargo", "test"],
            ["cargo", "+nightly", "test"],
            ["cargo", "metadata"],
            ["git", "-C", "a b", "status"],
            ["jj", "status"],
            ["ls", "--", "-file"],
            ["ls", "--sort", "size"],
            ["pytest", "--", "-file"],
            ["wc", "-"],
            ["rg", "--help"],
            ["ls", "--ultra-compact"],
            ["rg", "--json", "x"],
            ["cargo", "check", "--message-format=json"],
            ["git", "status", "--porcelain"],
        ):
            with (
                self.subTest(argv=argv),
                patch(
                    "albedo_rtk.shutil.which",
                    side_effect=AssertionError("unexpected RTK probe"),
                ),
            ):
                self.assertEqual(albedo_rtk.route(argv, {}), argv)

    def test_missing_required_rtk_is_not_native_fallback(self):
        with patch("albedo_rtk.shutil.which", return_value=None) as which:
            with self.assertRaisesRegex(FileNotFoundError, "no native fallback"):
                albedo_rtk.route(["ls"], {"PATH": "/empty"})
            which.assert_called_once_with("rtk", path="/empty")

    def test_stdin_grammar(self):
        self.assertTrue(albedo_rtk.supported(["rg", "match"], stdin=True))
        self.assertTrue(albedo_rtk.supported(["wc", "-l"], stdin=True))
        for argv in (["cargo", "test"], ["go", "build"], ["ls"], ["pytest"]):
            self.assertFalse(albedo_rtk.supported(argv, stdin=True))


class JobWaitForTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        from rtk_e2e_test import albedo_capture, plugin

        self.plugin = plugin
        state = patch.multiple(
            plugin,
            create=True,
            loop=asyncio.get_running_loop(),
            capture_factory=lambda id: albedo_capture.Capture(id, "job"),
            preview_limit=65536,
            send=lambda _frame: None,
            host=None,
            watch_output=None,
            forget_output=None,
            jobs={},
            active={},
            retained=OrderedDict(),
            owed={},
            announcer=None,
        )
        state.start()
        self.addCleanup(state.stop)

    async def asyncTearDown(self):
        await self.plugin.close()
        if self.plugin.announcer is not None:
            self.plugin.announcer.cancel()
            await asyncio.gather(self.plugin.announcer, return_exceptions=True)

    async def partial_job(self, after):
        job = self.plugin.start(
            [
                sys.executable,
                "-u",
                "-c",
                "import os, time; os.write(1, b'\\xc3'); " + after,
            ],
            timeout=5,
            traced=False,
        )

        async def captured():
            while job.capture.seen == 0:
                await asyncio.sleep(0.001)

        await asyncio.wait_for(captured(), 2)
        self.assertEqual(job.capture.tail(), b"\xc3")
        return job

    async def test_wait_for_partial_utf8_times_out_without_stopping_job(self):
        job = await self.partial_job("time.sleep(3)")
        with self.assertRaisesRegex(TimeoutError, "it is still running"):
            await job.wait_for("ready", timeout=0.02)
        self.assertIsNone(job.exit_code)
        self.assertFalse(job.task.done())
        await job.stop()

    async def test_wait_for_split_utf8_yields_until_character_completes(self):
        job = await self.partial_job("time.sleep(0.2); os.write(1, b'\\xa9 ready\\n')")
        self.assertEqual(await job.wait_for("é ready", timeout=2), "é ready")
        await job
        self.assertEqual(job.exit_code, 0)


class RestoredJobTests(unittest.IsolatedAsyncioTestCase):
    """A finished job that a restarted kernel restored from its spill file."""

    async def asyncSetUp(self):
        from rtk_e2e_test import albedo_capture, plugin

        self.plugin = plugin
        self.temp = tempfile.TemporaryDirectory(prefix="restored job ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # The kernel's own step: job output outlives it in this directory.
        albedo_capture.prune_spills(str(self.root / "spill"))
        self.addCleanup(albedo_capture.prune_spills, "")
        state = patch.multiple(
            plugin,
            create=True,
            loop=asyncio.get_running_loop(),
            capture_factory=lambda id: albedo_capture.Capture(id, "job"),
            preview_limit=65536,
            send=lambda _frame: None,
            host=None,
            watch_output=None,
            forget_output=None,
            jobs={},
            active={},
            retained=OrderedDict(),
            owed={},
            announcer=None,
        )
        state.start()
        self.addCleanup(state.stop)

    async def asyncTearDown(self):
        await self.plugin.close()
        if self.plugin.announcer is not None:
            self.plugin.announcer.cancel()
            await asyncio.gather(self.plugin.announcer, return_exceptions=True)

    async def restored_job(self):
        job = self.plugin.run(
            sys.executable,
            "-u",
            "-c",
            "print('hello')",
            env=dict(os.environ),
            timeout=30,
        )
        await job
        self.assertEqual(job.exit_code, 0, job.tail())
        book = self.plugin.save_jobs(str(self.root / "state"))
        self.assertEqual([saved["id"] for saved in book], [job.id])
        # What a kernel restart does to the finished jobs it kept.
        self.plugin.jobs.clear()
        self.plugin.active.clear()
        self.plugin.retained.clear()
        self.plugin.restore_jobs(book, {})
        restored = self.plugin.jobs[job.id]
        self.assertEqual(restored.exit_code, 0)
        self.assertEqual(restored.tail().strip(), "hello")
        return restored

    async def test_restored_job_keeps_inert_routing_state(self):
        job = await self.restored_job()
        self.assertFalse(job._routed)
        self.assertEqual(job.requested_argv, job.argv)
        self.assertEqual(job.requested_command, job.command)
        self.assertEqual(job._executed_argv, job.argv)

    async def test_restored_job_pipe_reports_retention(self):
        job = await self.restored_job()
        with self.assertRaisesRegex(ValueError, "wrote more than it retains"):
            job.pipe(sys.executable, "-c", "pass", env=dict(os.environ))
        self.assertEqual(list(self.plugin.jobs), [job.id])

    async def test_restored_job_stdin_reports_retention(self):
        job = await self.restored_job()
        with self.assertRaisesRegex(ValueError, "wrote more than it retains"):
            self.plugin.run(
                sys.executable, "-c", "pass", stdin=job, env=dict(os.environ)
            )
        self.assertEqual(list(self.plugin.jobs), [job.id])


if __name__ == "__main__":
    unittest.main()
