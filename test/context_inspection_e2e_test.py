"""Context reads stay ready while a turn rests and after a daemon restart."""

import json
import threading
import unittest

from harness import Albedo, Provider, exclusive, python, system_prompt, text, wait_until


# exclusive: holds a provider reply open longer than the kernel's rest timer
@exclusive
class ContextInspectionTests(unittest.TestCase):
    def setUp(self):
        self.release = threading.Event()
        self.addCleanup(self.release.set)

        def reply(request):
            items = request.get("input", [])
            if items and items[-1].get("type") == "function_call_output":
                # The turn waits on its model past rest_ms with its kernel idle.
                self.release.wait(30)
                return text("done", usage={"input_tokens": 20, "output_tokens": 1})
            if "hold the kernel" in json.dumps(request):
                return python("print('held')")
            return text("done", usage={"input_tokens": 20, "output_tokens": 1})

        self.provider = Provider(reply)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()
        self.route = f"/sessions/{self.session}/context"

    def read(self):
        with self.app.api(self.route) as response:
            return json.load(response)

    def test_a_resting_turn_keeps_its_prepared_request(self):
        self.app.prompt(self.session, "hold the kernel").close()
        wait_until(lambda: len(self.provider.requests) >= 2, 20, "tool result not sent")
        # The idle kernel rests (checkpoints its state) while the reply is held.
        state = self.app.home / "kernels" / f"{self.session}.state"
        wait_until(state.exists, 20, "the kernel never rested during the held reply")
        with self.app.api(f"/sessions/{self.session}?tail=0") as response:
            self.assertNotEqual(json.load(response)["status"]["phase"], "idle")
        snapshot = self.read()
        self.release.set()
        self.app.idle(self.session)
        self.assertEqual(snapshot["state"], "ready", snapshot)
        self.assertIn("history", [section["id"] for section in snapshot["sections"]])

    def test_an_unstarted_session_previews_its_first_request(self):
        wait_until(
            lambda: self.read()["state"] == "ready",
            20,
            "an unstarted session showed no preview",
        )
        sections = {section["id"]: section for section in self.read()["sections"]}
        self.assertIn("instructions", sections)
        self.assertNotIn("history", sections)
        self.assertEqual(self.provider.requests, [])
        self.app.prompt(self.session, "plain turn").close()
        self.app.idle(self.session)
        sent = self.provider.requests[0]["request"]
        snapshot = self.read()
        page = self.app.api(
            f"{self.route}/{snapshot['snapshot_id']}/sections/instructions?page=0"
        )
        with page as response:
            first = json.load(response)["text"]
        self.assertTrue(system_prompt(sent).startswith(first))

    def test_a_restarted_daemon_rebuilds_the_last_request(self):
        self.release.set()
        self.app.prompt(self.session, "plain turn").close()
        self.app.idle(self.session)
        self.assertEqual(self.read()["state"], "ready")
        self.app.restart()
        wait_until(
            lambda: self.read()["state"] == "ready",
            20,
            "context stayed pending after restart",
        )
        self.assertEqual(len(self.provider.requests), 1)


if __name__ == "__main__":
    unittest.main()
