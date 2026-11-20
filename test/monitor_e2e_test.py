"""albedo-monitor reads a real packaged daemon's discovery, server and sessions."""

import importlib.util
import unittest
from pathlib import Path

from harness import Albedo

# The runner copies scripts/albedo-monitor.py beside the cases under this name.
spec = importlib.util.spec_from_file_location(
    "albedo_monitor", Path(__file__).with_name("albedo_monitor.py")
)
assert spec is not None and spec.loader is not None
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    def test_snapshot_reads_the_running_daemon(self):
        with Albedo() as app:
            session = app.session(name="monitored")
            snapshot = monitor.snapshot(app.home, timeout=10)
        self.assertEqual(snapshot["error"], "", snapshot)
        self.assertTrue(snapshot["online"], snapshot)
        row = next(row for row in snapshot["sessions"] if row["id"] == session)
        self.assertEqual(row["title"], "monitored")
        self.assertEqual(row["status"], "idle")
        self.assertIsInstance(snapshot["accounts"], list)


if __name__ == "__main__":
    unittest.main()
