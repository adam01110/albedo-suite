"""Reversible profile disable: no deletion, discovery, routing, or secret leakage."""

import json
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, latest_user, python, text


@exclusive
class ProviderAvailabilityTests(unittest.TestCase):
    def setUp(self):
        self.outputs = []

        def script(request):
            last = request["messages"][-1]
            if last.get("role") == "tool":
                self.outputs.append(json.loads(last["content"])["output"])
                return text("checked")
            prompt = latest_user(request)
            if prompt == "inspect models":
                return python("assert not hasattr(commands, 'providers')\nprint(await agents.models())")
            if prompt == "reject disabled":
                return python(
                    "try:\n"
                    "    await agents.self.spawn('no', name='disabled', model='openrouter/router-model')\n"
                    "except AgentsError as error:\n"
                    "    print('REFUSED', error)"
                )
            return text("ok")

        self.provider = Provider(script)
        self.gateway = Provider(lambda _: text("unused"), catalog={"data": [{"id": "router-model"}]})
        self.addCleanup(self.provider.close)
        self.addCleanup(self.gateway.close)
        self.app = Albedo(self.provider, providers={
            "fixture": {"extension": "openai", "baseUrl": self.provider.url, "apiKey": "fixture-key", "model": "fixture-model", "protocol": "chat_completions"},
            "openrouter": {"extension": "openai", "baseUrl": self.gateway.url, "apiKey": "router-secret", "model": "router-model", "protocol": "chat_completions", "custom": "preserve"},
        })
        self.app.__enter__()
        self.session = self.app.session()

    def turn(self, prompt):
        self.app.prompt(self.session, prompt).close()
        self.app.idle(self.session)
        return self.outputs[-1]

    def toggle(self, enabled, profile="openrouter", etag=None):
        route = "/settings?group=providers"
        if etag is None:
            with self.app.api(route) as response:
                json.load(response)
                etag = response.headers["ETag"]
        with self.app.api(route, {"profiles": {profile: {"enabled": enabled}}},
                          method="PATCH", headers={"If-Match": etag}) as response:
            return json.load(response)

    def test_disable_hides_and_blocks_then_enable_restores_without_deletion(self):
        self.assertIn("openrouter/router-model", self.turn("inspect models"))
        path = self.app.home / "config.json"
        before = json.loads(path.read_text())
        creds_path = self.app.home / "creds.json"
        creds = creds_path.read_bytes() if creds_path.exists() else None
        self.toggle(False)
        saved = json.loads(path.read_text())
        self.assertFalse(saved["providers"]["openrouter"]["enabled"])
        expected = dict(before["providers"]["openrouter"], enabled=False)
        self.assertEqual(saved["providers"]["openrouter"], expected)
        self.assertEqual(creds_path.read_bytes() if creds_path.exists() else None, creds)
        self.assertNotIn("openrouter/", self.turn("inspect models"))
        self.assertIn("disabled", self.turn("reject disabled"))
        self.app.restart()
        self.assertNotIn("openrouter/", self.turn("inspect models"))
        self.toggle(True)
        self.assertIn("openrouter/router-model", self.turn("inspect models"))
        self.assertNotIn("router-secret", json.dumps(self.provider.requests))

    def test_toggle_rejects_stale_validator_and_non_boolean(self):
        with self.app.api("/settings?group=providers") as response:
            json.load(response)
            etag = response.headers["ETag"]
        self.toggle(False, etag=etag)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.toggle(True, etag=etag)
        self.assertEqual(caught.exception.code, 412)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.toggle("false")
        self.assertEqual(caught.exception.code, 400)

    def test_unknown_profile_does_not_mutate_config(self):
        path = self.app.home / "config.json"
        before = path.read_bytes()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.toggle(False, "missing")
        self.assertEqual(caught.exception.code, 400)
        self.assertEqual(path.read_bytes(), before)
