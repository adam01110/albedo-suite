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

        def script(request):
            if self.code is not None:
                code, self.code = self.code, None
                return python(code)
            return text("Backend checks finished")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.app.write_extensions({"enabled": {"formatter": False, "lsp": False}})
        self.app.restart()
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

    def test_rtk_runs_supported_terminal_command(self):
        self.execute(
            f"job = run('ls', {str(self.root)!r})\n"
            "await job\n"
            "assert job.exit_code == 0\n"
            "assert job.requested_argv[0] == 'ls'\n"
            "assert 'rtk' in job.argv[0] and job.argv[1] == 'ls'\n"
            "assert 'sample.txt' in job.read()\n"
            "print('BACKEND_VERIFIED')"
        )

    def test_rtk_cargo_retains_mbx_and_environment_rules(self):
        binaries = self.root / "bin"
        binaries.mkdir()
        records = self.root / "mbx.jsonl"
        mbx = binaries / "mbx"
        mbx.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"with open({str(records)!r}, 'a') as output:\n"
            "    output.write(json.dumps({'args': sys.argv[1:], 'sdk': os.getenv('SDKROOT'), "
            "'cc': os.getenv('CC'), 'mode': os.getenv('MBX_CARGO_SHIM_MODE'), "
            "'flags': os.getenv('HOST_CFLAGS')}) + '\\n')\n"
            "print('Finished dev profile')\n"
        )
        mbx.chmod(0o755)
        (binaries / "cc").write_text("#!/bin/sh\n")
        (binaries / "cc").chmod(0o755)
        (binaries / "gcc").write_text("#!/bin/sh\n")
        (binaries / "gcc").chmod(0o755)
        (binaries / "clang").symlink_to("cc")
        self.execute(
            "import json\n"
            f"path = {str(binaries)!r} + ':' + os.environ['PATH']\n"
            "for cc, extra in (('clang', {}), ('clang', {'ALBEDO_NIX_ENV': 'abc'}), "
            "('gcc', {'ALBEDO_NIX_ENV': 'abc'})):\n"
            "    job = run('cargo', 'build', env={'PATH': path, 'SDKROOT': '/nix/store/x-sdk', 'CC': cc, **extra})\n"
            "    await job\n"
            "    assert job.routed and job.exit_code == 0\n"
            f"records = [json.loads(line) for line in Path({str(records)!r}).read_text().splitlines()]\n"
            "assert len(records) == 3, records\n"
            "assert all(r['args'] == ['build'] and r['sdk'] is None and r['mode'] == '1' for r in records), records\n"
            "assert [r['cc'] for r in records] == ['clang', None, 'gcc'], records\n"
            "assert [r['flags'] for r in records] == [None, ' -DALBEDO_NIX_ENV_abc', ' -DALBEDO_NIX_ENV_abc'], records\n"
            "print('BACKEND_VERIFIED')"
        )

    def test_fff_searches_and_observes_file_edit(self):
        settled = self.execute(
            f"root = {str(self.root)!r}\n"
            "rows = await files.find('BACKEND_NEEDLE', root, literal=True, context=1)\n"
            "assert len(rows) == 3 and sum(not row.context for row in rows) == 1\n"
            "assert len(await files.paths(path=root, glob='*.txt')) == 1\n"
            "assert len(await files.paths('sampl', path=root)) == 1\n"
            "files.edit(root + '/sample.txt', 'BACKEND_NEEDLE', 'UPDATED_NEEDLE')\n"
            "assert len(await files.find('UPDATED_NEEDLE', root, literal=True)) == 1\n"
            "print('BACKEND_VERIFIED')"
        )

        self.assertEqual(settled["kernel"]["live_job_count"], 0)
        self.assertEqual(settled["kernel"]["running_jobs"], [])
        with self.app.api(f"/extensions/run/sessions/{self.session}/jobs") as response:
            supervised = json.load(response)
        self.assertEqual(supervised["live_job_count"], 0)
        self.assertEqual(supervised["items"], [])

    def test_fff_does_not_hide_real_background_job(self):
        settled = self.execute(
            f"await files.paths(path={str(self.root)!r})\n"
            "job = run(sys.executable, '-c', 'import time; time.sleep(60)')\n"
            "await asyncio.sleep(0.1)\n"
            "print('BACKEND_VERIFIED')"
        )
        self.assertEqual(settled["kernel"]["live_job_count"], 1)
        self.assertEqual(len(settled["kernel"]["running_jobs"]), 1)
        self.assertIn("time.sleep(60)", settled["kernel"]["running_jobs"][0]["command"])
        settled = self.execute("await job.stop()\nprint('BACKEND_VERIFIED')")
        self.assertEqual(settled["kernel"]["live_job_count"], 0)
        self.assertEqual(settled["kernel"]["running_jobs"], [])

    def test_fff_worker_is_shared_between_sessions_and_survives_client_close(self):
        first = self.session
        code = (
            f"assert len(await files.find('BACKEND_NEEDLE', {str(self.root)!r})) == 1\n"
            f"parallel = await asyncio.gather(*(files.paths(path={str(self.root)!r}) for _ in range(8)))\n"
            "assert all(parallel)\n"
            "fff = sys.modules['albedo_plugins.files']._fff\n"
            "assert fff.job is None\n"
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
