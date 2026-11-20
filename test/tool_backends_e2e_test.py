"""Verify replacement backends through a real packaged daemon kernel."""

import json
import os
import signal
import sys
import tempfile
from pathlib import Path
import unittest

from harness import (
    Albedo,
    Provider,
    exclusive,
    python,
    text,
    wait_until,
    _LOOPBACK_SSH,
    _LOOPBACK_LOGIN,
)


@exclusive
class ToolBackendsTests(unittest.TestCase):
    def setUp(self):
        self.code = None

        def script(_request):
            if self.code is not None:
                code, self.code = self.code, None
                return python(code)
            return text("Backend checks finished")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            protocol="responses",
            prepare=lambda app: app.write_extensions(
                {"enabled": {"formatter": False, "lsp": False}}
            ),
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "sample.txt").write_text("before\nBACKEND_NEEDLE\nafter\n")

    def execute(self, code):
        self.code = code
        self.app.prompt(self.session, "Check replacement tool backends").close()
        settled = self.app.idle(self.session, timeout=30)
        history = self.app.history(self.session)
        results = [
            json.loads(part["value"])
            for item in history["items"]
            if item["kind"] == "tool_result"
            for part in item["content"]
            if part["kind"] == "json" and part["field"] == "result"
        ]
        self.assertTrue(results)
        self.assertEqual(results[-1]["status"], "ok", results[-1])
        self.last_output = results[-1]["output"]
        self.assertIn("BACKEND_VERIFIED", self.last_output)
        return settled

    def test_rtk_routes_supported_commands_in_the_packaged_daemon(self):
        # The built package, not a PATH override, must resolve RTK and mbx.
        binaries = self.root / "bin"
        binaries.mkdir()
        (binaries / "mbx").write_text("#!/bin/sh\nexit 0\n")
        (binaries / "mbx").chmod(0o755)
        self.execute(
            "import os\n"
            f"path = {str(binaries)!r} + ':' + os.environ['PATH']\n"
            f"job = run('ls', {str(self.root)!r})\n"
            "await job\n"
            "assert job._routed and job.exit_code == 0\n"
            "assert 'sample.txt' in job.read()\n"
            "job = run('cargo', 'build', env={'PATH': path})\n"
            "await job\n"
            "assert job._routed and job.exit_code == 0\n"
            "print('BACKEND_VERIFIED')"
        )

    def test_fff_searches_without_hiding_real_background_jobs(self):
        settled = self.execute(
            f"root = {str(self.root)!r}\n"
            "rows = await files.find('BACKEND_NEEDLE', root, literal=True, context=1)\n"
            "assert len(rows) == 3 and sum(not row.context for row in rows) == 1\n"
            "assert len(await files.paths(path=root, glob='*.txt')) == 1\n"
            "assert len(await files.paths('sampl', path=root)) == 1\n"
            "job = run(sys.executable, '-c', 'import time; time.sleep(60)')\n"
            "print('BACKEND_VERIFIED')"
        )
        # The search used the daemon worker, and one real job is still one job.
        self.assertEqual(settled["kernel"]["live_job_count"], 1)
        self.assertEqual(len(settled["kernel"]["running_jobs"]), 1)
        settled = self.execute("await job.stop()\nprint('BACKEND_VERIFIED')")
        self.assertEqual(settled["kernel"]["live_job_count"], 0)
        self.assertEqual(settled["kernel"]["running_jobs"], [])
        with self.app.api(f"/extensions/run/sessions/{self.session}/jobs") as response:
            supervised = json.load(response)
        self.assertEqual(supervised["live_job_count"], 0)
        self.assertEqual(supervised["items"], [])

    def test_fff_worker_is_shared_between_sessions_and_survives_client_close(self):
        first = self.session
        code = (
            f"assert len(await files.find('BACKEND_NEEDLE', {str(self.root)!r})) == 1\n"
            "fff = sys.modules['albedo_plugins.files']._fff\n"
            "print('BACKEND_VERIFIED', fff.worker_pid)"
        )
        self.execute(code)
        pid = self.last_output.split("BACKEND_VERIFIED ")[1].strip()
        self.execute("await files.close()\nprint('BACKEND_VERIFIED')")
        self.code = "os._exit(0)"
        self.app.prompt(first, "Release first kernel").close()
        self.app.idle(first)
        self.session = self.app.session()
        self.execute(code)
        self.assertEqual(self.last_output.split("BACKEND_VERIFIED ")[1].strip(), pid)
        self.session = first
        self.execute(code)
        self.assertEqual(self.last_output.split("BACKEND_VERIFIED ")[1].strip(), pid)

    def test_fff_worker_recovers_after_crash(self):
        code = (
            f"await files.paths(path={str(self.root)!r})\n"
            "print('BACKEND_VERIFIED', sys.modules['albedo_plugins.files']._fff.worker_pid)"
        )
        self.execute(code)
        old_pid = int(self.last_output.split("BACKEND_VERIFIED ")[1].strip())
        os.kill(old_pid, signal.SIGKILL)
        wait_until(
            lambda: not Path(f"/proc/{old_pid}").exists(), 5, "FFF worker not reaped"
        )
        self.execute(code)
        self.assertNotEqual(
            int(self.last_output.split("BACKEND_VERIFIED ")[1].strip()), old_pid
        )

    def test_fff_remote_worker_is_shared(self):
        binaries = self.root / "bin"
        binaries.mkdir()
        ssh = binaries / "ssh"
        ssh.write_text(_LOOPBACK_SSH)
        ssh.chmod(0o755)
        login = binaries / "loginsh"
        login.write_text(_LOOPBACK_LOGIN)
        login.chmod(0o755)
        self.app.env["SHELL"] = str(login)
        self.app.env["PATH"] = str(binaries) + os.pathsep + os.environ["PATH"]
        self.app.restart()
        code = (
            f"await files.paths(path={str(self.root)!r})\n"
            "local_pid = sys.modules['albedo_plugins.files']._fff.worker_pid\n"
            "rem = await remote.connect('local')\n"
            f"assert len(await rem.files.find('BACKEND_NEEDLE', {str(self.root)!r})) == 1\n"
            "plugin = sys.modules['albedo_plugins.files']\n"
            f"payload = {{**plugin._fff_scope(Path({str(self.root)!r}), None, False, 10), 'op': 'paths', 'query': '', 'name': None, '_fff_target': 'local'}}\n"
            "result = await plugin._fff.host('files.fff', payload)\n"
            "assert result['workerPid'] != local_pid\n"
            "print('BACKEND_VERIFIED', result['workerPid'])"
        )
        self.execute(code)
        pid = self.last_output.split("BACKEND_VERIFIED ")[1].strip()
        self.session = self.app.session()
        self.execute(code)
        self.assertEqual(self.last_output.split("BACKEND_VERIFIED ")[1].strip(), pid)


if __name__ == "__main__":
    unittest.main()
