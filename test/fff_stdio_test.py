"""Shared-worker lifecycle, including deadlines around blocked native calls."""

import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import unittest

SCRIPT = os.environ.get("ALBEDO_FFF_SCRIPT") or str(
    Path(__file__).resolve().parents[1] / "src/server/priv/python/albedo_fff.mjs"
)


class StdioTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        modules = Path(self.temp.name) / "node_modules"
        package = modules / "@ff-labs/fff-node"
        package.mkdir(parents=True)
        (package / "index.js").write_text("""
const ok = value => ({ ok: true, value });
let hangDestroy = false;
exports.FileFinder = { create: () => ok({
  getScanProgress: () => ok({ isScanning: false, isWarmupComplete: true }),
  scanFiles: () => ok({}),
  grep: query => {
    if (query === 'hang-destroy') hangDestroy = true;
    if (query === 'hang') Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
    return ok({ items: [], totalFilesSearched: 0, nextCursor: null });
  },
  glob: () => ok({ items: [] }),
  destroy: () => {
    if (hangDestroy) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
  },
}) };
""")
        self.worker = subprocess.Popen(
            ["node", SCRIPT, "--stdio"],
            cwd=self.temp.name,
            env={**os.environ, "NODE_PATH": str(modules)},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert self.worker.stdin is not None
        assert self.worker.stdout is not None
        self.stdin = self.worker.stdin
        self.stdout = self.worker.stdout
        self.addCleanup(self.stop)

    def stop(self):
        if self.worker.poll() is None:
            self.worker.kill()
        self.worker.wait(timeout=5)
        for stream in (self.worker.stdin, self.worker.stdout, self.worker.stderr):
            if stream is not None:
                stream.close()

    def send(self, query="needle", protocol=1):
        self.stdin.write(
            json.dumps(
                {
                    "op": "find",
                    "protocol": protocol,
                    "root": self.temp.name,
                    "query": query,
                    "filters": [],
                    "hidden": False,
                    "limit": 10,
                    "context": 0,
                }
            )
            + "\n"
        )
        self.stdin.flush()

    def reply(self):
        ready, _, _ = select.select([self.stdout], [], [], 5)
        self.assertTrue(ready, "worker did not reply")
        return json.loads(self.stdout.readline())

    def test_reuses_worker_after_requests_and_protocol_errors(self):
        self.send()
        first = self.reply()
        self.assertTrue(first["ok"])
        self.send(protocol=99)
        self.assertFalse(self.reply()["ok"])
        self.send()
        self.assertEqual(
            self.reply()["value"]["workerPid"], first["value"]["workerPid"]
        )

    def test_stdin_close_ends_worker(self):
        self.send()
        self.reply()
        self.stdin.close()
        self.assertEqual(self.worker.wait(timeout=5), 0)

    def test_native_call_cannot_block_deadline(self):
        self.send("hang")
        self.assertEqual(self.worker.wait(timeout=33), -9)

    def test_native_destroy_cannot_block_shutdown(self):
        self.send("hang-destroy")
        self.reply()
        self.stdin.close()
        self.assertEqual(self.worker.wait(timeout=5), -9)

    def test_idle_worker_exits(self):
        self.send()
        self.reply()
        self.assertEqual(self.worker.wait(timeout=65), 0)


if __name__ == "__main__":
    unittest.main()
