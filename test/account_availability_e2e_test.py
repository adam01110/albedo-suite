"""Per-account disable: rotation skips one key account, its sibling and setup stay."""

import json
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, operation_id, text


@exclusive
class AccountAvailabilityTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            providers={
                "fixture": {
                    "extension": "openai",
                    "baseUrl": self.provider.url,
                    "model": "fixture-model",
                    "protocol": "chat_completions",
                },
            },
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.first = self.key("key-first", "first")
        self.second = self.key("key-second", "second")
        route = "/settings/providers"
        with self.app.api(route) as response:
            json.load(response)
            etag = response.headers["ETag"]
        with self.app.api(
            route,
            {
                "profiles": {
                    "fixture": {
                        "account_ids": [self.first, self.second],
                        "rotation": "failover",
                    }
                }
            },
            method="PATCH",
            headers={"If-Match": etag},
        ) as response:
            json.load(response)

    def key(self, secret, label):
        account = operation_id()
        with self.app.api(
            f"/auth/keys/{account}",
            {
                "provider": "openai",
                "endpoint": self.provider.url,
                "api_key": secret,
                "label": label,
            },
            method="PUT",
        ) as response:
            self.assertEqual(json.load(response)["id"], account)
        return account

    def patch(self, account, body):
        with self.app.api(
            f"/auth/accounts/{account}", body, method="PATCH"
        ) as response:
            return json.load(response)

    def accounts(self):
        with self.app.api("/auth") as response:
            return {a["id"]: a for a in json.load(response)["accounts"]}

    def used_key(self):
        """The key a new session's first request sends."""
        before = len(self.provider.requests)
        session = self.app.session()
        self.app.prompt(session, "hello").close()
        self.app.idle(session)
        sent = [
            request["authorization"]
            for request in self.provider.requests[before:]
            if request.get("authorization")
        ]
        self.assertTrue(sent, "no model request was sent")
        return sent[0]

    def test_disable_skips_one_account_then_enable_restores_it(self):
        self.assertEqual(self.used_key(), "Bearer key-first")
        config_path = self.app.home / "config.json"
        config = config_path.read_bytes()

        answer = self.patch(self.first, {"enabled": False})
        self.assertFalse(answer["enabled"])
        listed = self.accounts()
        self.assertFalse(listed[self.first]["enabled"])
        self.assertTrue(listed[self.second]["enabled"])
        # The setup and its rotation are untouched; the account is still saved.
        self.assertEqual(config_path.read_bytes(), config)
        self.assertIn("key-first", (self.app.home / "creds.json").read_text())
        self.assertEqual(self.used_key(), "Bearer key-second")

        self.assertTrue(self.patch(self.first, {"enabled": True})["enabled"])
        self.assertEqual(self.used_key(), "Bearer key-first")

    def test_patch_rejects_empty_and_non_boolean_bodies(self):
        for body in ({}, {"enabled": "false"}, {"enabled": False, "other": 1}):
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.patch(self.first, body)
            self.assertEqual(caught.exception.code, 400, body)
        self.assertTrue(self.accounts()[self.first]["enabled"])


if __name__ == "__main__":
    unittest.main()
