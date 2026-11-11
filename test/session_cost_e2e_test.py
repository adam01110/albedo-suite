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

    def listed_cost(self):
        with self.app.api("/sessions?scope=all") as response:
            items = json.load(response)["items"]
        return next(item for item in items if item["id"] == self.session)["session_cost_usd"]

    def archive(self, session):
        route = f"/sessions/{session}?view=configuration"
        with self.app.api(route) as response:
            response.read()
            etag = response.headers["ETag"]
        self.app.api(
            route,
            {"preferences": {"archived": True}},
            method="PATCH",
            headers={"If-Match": etag, "Content-Type": "application/merge-patch+json"},
        ).close()

    def total_cost(self, query="scope=roots&archived=false"):
        with self.app.api(f"/sessions?{query}") as response:
            return json.load(response)["total_cost"]

    def test_total_stream_status_and_restart(self):
        self.assertEqual(self.cost(), 0)
        self.assertEqual(self.listed_cost(), 0)
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
        self.assertAlmostEqual(self.listed_cost(), 0.00022)
        self.app.prompt(self.session, "two").close()
        self.app.idle(self.session)
        self.assertAlmostEqual(self.cost(), 0.00044)
        self.app.restart()
        self.assertAlmostEqual(self.cost(), 0.00044)
        self.assertAlmostEqual(self.cost(status=True), 0.00044)
        self.assertAlmostEqual(self.listed_cost(), 0.00044)
        # The first page totals every stored session, archived ones included.
        self.archive(self.session)
        other = self.app.session()
        self.app.prompt(other, "three").close()
        self.app.idle(other)
        for query in ("scope=roots&archived=false", "scope=all&archived=true", "search=no-such-session"):
            total = self.total_cost(query)
            self.assertAlmostEqual(total["usd"], 0.00066, msg=query)
            self.assertFalse(total["partial"], query)
        self.failed = True
        stream = Stream(self.app, self.session)
        try:
            self.app.prompt(self.session, "failed attempt").close()
            self.app.idle(self.session)
            event = stream.pushed(lambda e: e["type"] == "usage")
            # An unmetered rejection is not billed and keeps the known total.
            self.assertAlmostEqual(event["data"]["session_cost_usd"], 0.00044)
            self.assertAlmostEqual(self.cost(), 0.00044)
        finally:
            stream.close()

    def test_catalog_change_reprices_cached_estimate(self):
        self.app.prompt(self.session, "one").close()
        self.app.idle(self.session)
        self.assertAlmostEqual(self.cost(), 0.00022)
        self.assertAlmostEqual(self.listed_cost(), 0.00022)
        (self.app.home / "models.json").write_text(json.dumps({
            "openai": {"models": {"fixture-model": {
                "id": "fixture-model", "limit": {"context": 1000000},
                "cost": {"input": 4, "output": 20}
            }}}
        }))
        self.assertAlmostEqual(self.cost(), 0.00044)
        self.assertAlmostEqual(self.listed_cost(), 0.00044)

    def test_missing_usage_is_not_free(self):
        self.metered = False
        self.app.prompt(self.session, "one").close()
        self.app.idle(self.session)
        self.assertEqual(len(self.provider.requests), 1, self.app.history(self.session))
        self.assertIsNone(self.cost())
        self.assertIsNone(self.cost(status=True))
        self.assertIsNone(self.listed_cost())
        self.assertEqual(self.total_cost(), {"usd": 0, "partial": True})
