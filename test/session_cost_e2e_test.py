"""Session cost uses durable requests and the same wire field on every view."""

import json
import unittest

from harness import Albedo, Provider, Reply, error, exclusive, text
from session_status_test import Stream


@exclusive
class SessionCostTests(unittest.TestCase):
    def setUp(self):
        self.metered = True
        self.failed = False
        def reply(_):
            if self.failed:
                return error(400)
            return text("ok") if self.metered else Reply("text", "ok", usage=None)
        self.provider = Provider(reply)
        self.addCleanup(self.provider.close)

        def prepare(app):
            app.write_extensions({"models": {"refreshHours": 0}})
            (app.home / "models.json").write_text(json.dumps({
                "openai": {"models": {"fixture-model": {
                    "id": "fixture-model", "limit": {"context": 1000000},
                    "cost": {"input": 2, "output": 10}
                }}}
            }))

        self.app = Albedo(self.provider, prepare=prepare, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def cost(self, status=False):
        query = "view=status" if status else "tail=0"
        with self.app.api(f"/sessions/{self.session}?{query}") as response:
            return json.load(response)["usage"]["session_cost_usd"]

    def test_total_stream_status_and_restart(self):
        self.assertEqual(self.cost(), 0)
        stream = Stream(self.app, self.session)
        try:
            self.app.prompt(self.session, "one").close()
            self.app.idle(self.session)
            self.assertEqual(len(self.provider.requests), 1, self.app.history(self.session))
            event = stream.pushed(lambda e: e["type"] == "usage")
            self.assertAlmostEqual(event["data"]["session_cost_usd"], 0.00022)
        finally:
            stream.close()
        self.assertAlmostEqual(self.cost(), 0.00022)
        self.assertAlmostEqual(self.cost(status=True), 0.00022)
        self.app.prompt(self.session, "two").close()
        self.app.idle(self.session)
        self.assertAlmostEqual(self.cost(), 0.00044)
        self.app.restart()
        self.assertAlmostEqual(self.cost(), 0.00044)
        self.assertAlmostEqual(self.cost(status=True), 0.00044)
        self.failed = True
        stream = Stream(self.app, self.session)
        try:
            self.app.prompt(self.session, "failed attempt").close()
            self.app.idle(self.session)
            event = stream.pushed(lambda e: e["type"] == "usage")
            self.assertIsNone(event["data"]["session_cost_usd"])
            self.assertIsNone(self.cost())
        finally:
            stream.close()

    def test_missing_usage_is_not_free(self):
        self.metered = False
        self.app.prompt(self.session, "one").close()
        self.app.idle(self.session)
        self.assertEqual(len(self.provider.requests), 1, self.app.history(self.session))
        self.assertIsNone(self.cost())
        self.assertIsNone(self.cost(status=True))
