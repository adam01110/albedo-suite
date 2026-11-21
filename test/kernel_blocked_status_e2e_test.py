"""A blocked session clears its blocking reason in the status stream when the
person sends another message."""

import json
import queue
import time
import unittest

from harness import Albedo, Provider, text, wait_until
from session_status_test import Stream


class BlockedStatusTests(unittest.TestCase):
    def setUp(self):
        def script(_request):
            return text("recovered")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.workspace = self.app.workspace / "project"
        self.workspace.mkdir()
        (self.workspace / "project-marker").write_text("original project")
        self.session = self.app.session(self.workspace)

    def api(self, path, body=None, **options):
        with self.app.api(path, body, **options) as response:
            return json.load(response)

    def snapshot(self):
        return self.api(f"/sessions/{self.session}?tail=0")

    def block(self):
        """Blocks the session's inputs by taking its workspace away."""
        with self.app.prompt(self.session, "original input") as response:
            response.read()
        wait_until(
            lambda: self.snapshot()["status"]["blocking_reason"] is not None,
            10,
            "missing workspace did not expose a blocked input",
        )
        blocked = self.snapshot()
        self.assertEqual(blocked["status"]["phase"], "idle", blocked["status"])
        self.assertEqual(blocked["kernel"]["state"], "none", blocked["kernel"])
        self.assertIn(
            str(self.workspace), blocked["status"]["blocking_reason"]["detail"]
        )
        self.assertEqual(self.provider.requests, [])
        return blocked

    def unblocked_status(self, event):
        return event["type"] == "status" and event["data"]["blocking_reason"] is None

    def events_for(self, stream, seconds):
        """Every event the stream pushes in `seconds`, without failing when quiet."""
        seen = []
        deadline = time.monotonic() + seconds
        while True:
            try:
                batch = stream.batches.get_nowait()
            except queue.Empty:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return seen
                time.sleep(min(0.05, remaining))
                continue
            seen.extend(batch["events"])

    def test_the_blocked_status_survives_until_the_person_sends_another_message(self):
        saved = self.workspace.with_name("saved-project")
        self.workspace.rename(saved)
        self.block()
        stream = Stream(self.app, self.session)
        self.addCleanup(stream.close)
        first = stream.batch()
        self.assertIsNotNone(
            first["snapshot"]["status"]["blocking_reason"], first["snapshot"]["status"]
        )
        # A blocked session keeps publishing queue invalidations, so the check
        # reads every event it can for the window instead of asserting silence.
        for event in self.events_for(stream, 1.5):
            self.assertFalse(
                self.unblocked_status(event),
                f"blocked session published an unblocked status: {event}",
            )
        self.assertIsNotNone(self.snapshot()["status"]["blocking_reason"])

    def test_the_person_sending_another_message_drops_the_blocked_status(self):
        saved = self.workspace.with_name("saved-project")
        self.workspace.rename(saved)
        self.block()
        stream = Stream(self.app, self.session)
        self.addCleanup(stream.close)
        self.assertIsNotNone(stream.batch()["snapshot"]["status"]["blocking_reason"])
        saved.rename(self.workspace)
        with self.app.prompt(self.session, "retry after restoring mount") as response:
            response.read()
        event = stream.pushed(self.unblocked_status, 15)
        self.assertIsNone(event["data"]["blocking_reason"])
        self.assertIsNone(self.snapshot()["status"]["blocking_reason"])
        snapshot = self.app.idle(self.session)
        self.assertEqual(
            snapshot["status"]["blocking_reason"], None, snapshot["status"]
        )
        self.assertTrue(
            self.provider.requests, "the released turn never reached the model"
        )


if __name__ == "__main__":
    unittest.main()
