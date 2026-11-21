"""Shared-worker lifecycle, including deadlines around blocked native calls."""

import json
import os
from pathlib import Path
import re
import select
import subprocess
import tempfile
import unittest

SCRIPT = os.environ.get("ALBEDO_FFF_SCRIPT") or str(
    Path(__file__).resolve().parents[1] / "src/server/python/albedo_fff.mjs"
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
let live = 0;
exports.FileFinder = { create: () => {
  live++;
  return ok({
  getScanProgress: () => ok({ isScanning: false, isWarmupComplete: true }),
  scanFiles: () => ok({}),
  grep: query => {
    if (query === 'hang-destroy') hangDestroy = true;
    if (query === 'hang') Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
    const items = query === 'oversized' ? Array.from({length: 14000}, () => ({
      relativePath: 'file.txt', lineNumber: 1, lineContent: 'x'.repeat(640)
    })) : [];
    return ok({ items, totalFilesSearched: live, nextCursor: null });
  },
  glob: () => ok({ items: [] }),
  destroy: () => {
    live--;
    if (hangDestroy) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
  },
}); } };
""")
        self.env = {
            **os.environ,
            "NODE_PATH": str(modules),
            "HOME": self.temp.name,
            "XDG_CACHE_HOME": str(Path(self.temp.name) / "cache"),
            "ALBEDO_FFF_IDLE_MS": "1500",
            "ALBEDO_FFF_CALL_DEADLINE_MS": "2000",
        }
        self.worker = subprocess.Popen(
            ["node", SCRIPT, "--stdio"],
            cwd=self.temp.name,
            env=self.env,
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

    def send(self, query="needle", protocol=1, root=None, limit=10):
        self.stdin.write(
            json.dumps(
                {
                    "op": "find",
                    "protocol": protocol,
                    "root": root or self.temp.name,
                    "query": query,
                    "filters": [],
                    "hidden": False,
                    "limit": limit,
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
        error = self.reply()
        self.assertFalse(error["ok"])
        self.assertIn("protocol mismatch", error["error"])
        self.send()
        self.assertTrue(self.reply()["ok"])

    def test_four_root_bound_and_eviction(self):
        for number in range(6):
            self.send(root=f"root-{number}")
            self.assertEqual(self.reply()["value"]["searched"], min(number + 1, 4))
        self.send(root="root-0")
        self.assertEqual(self.reply()["value"]["searched"], 4)

    def test_bounds_are_explicit_and_do_not_poison_worker(self):
        cases = (
            ("malformed request", "{", None),
            ("oversized request", "x" * (1048576 + 1), "1 MiB"),
            ("oversized response", None, "response exceeds 8 MiB"),
        )
        for name, line, message in cases:
            with self.subTest(name):
                if line is None:
                    self.send("oversized", limit=14000)
                else:
                    self.stdin.write(line + "\n")
                    self.stdin.flush()
                error = self.reply()
                self.assertFalse(error["ok"])
                if message:
                    self.assertIn(message, error["error"])
                self.send()
                self.assertTrue(self.reply()["ok"])

    def test_stdin_close_ends_worker(self):
        self.send()
        self.reply()
        self.stdin.close()
        self.assertEqual(self.worker.wait(timeout=5), 0)

    def test_native_call_cannot_block_deadline(self):
        self.send("hang")
        self.assertEqual(self.worker.wait(timeout=5), -9)

    def test_native_destroy_cannot_block_shutdown(self):
        self.send("hang-destroy")
        self.reply()
        self.stdin.close()
        self.assertEqual(self.worker.wait(timeout=5), -9)

    def test_idle_worker_exits(self):
        self.send()
        self.reply()
        self.assertEqual(self.worker.wait(timeout=5), 0)


class DefaultsTests(unittest.TestCase):
    """The injectable deadlines keep their production defaults."""

    def test_default_deadlines_stay_a_minute_and_half_a_minute(self):
        defaults = dict(
            re.findall(
                r'"ALBEDO_FFF_(IDLE_MS|CALL_DEADLINE_MS)",\s*(\d+)\)',
                Path(SCRIPT).read_text(),
            )
        )
        self.assertEqual(defaults, {"IDLE_MS": "60000", "CALL_DEADLINE_MS": "30000"})


if __name__ == "__main__":
    unittest.main()
