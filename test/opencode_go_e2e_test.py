"""OpenCode Go routing and discovery against an isolated scripted endpoint."""

import hashlib
import json
import time
import unittest
from urllib.parse import quote

from harness import Albedo, Provider, error, exclusive, text, wait_until


def saved_list(home, owner, endpoint):
    """The host's saved model list for one catalog and endpoint."""
    listed = endpoint[:-1] if endpoint.endswith("/") else endpoint
    key = owner.encode() + b"\0" + listed.encode()
    return home / "model-lists" / (hashlib.sha256(key).hexdigest() + ".json")


class GoProvider(Provider):
    def __init__(self, script):
        super().__init__(
            script,
            catalog={
                "data": [
                    {"id": name} for name in ["glm-5.2", "minimax-m2.7", "gpt-5.6-luna"]
                ]
            },
        )
        self.headers = []
        self.gets = []
        self.get_headers = []
        self.fail_catalog = False

    def _post(owner, self):
        owner.headers.append(dict(self.headers))
        if not self.headers.get("x-opencode-session"):
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":{"type":"MissingSessionID"}}')
            return
        super()._post(self)

    def _get(owner, self):
        owner.gets.append(self.path)
        owner.get_headers.append(dict(self.headers))
        if owner.fail_catalog:
            self.send_response(503)
            self.end_headers()
        else:
            super()._get(self)


@exclusive
class OpenCodeGoE2ETests(unittest.TestCase):
    def start(self, model, script=None, key="go-test-key", metadata=None, providers=None, effort=None):
        provider = GoProvider(script or (lambda _: text("go-reply")))
        self.addCleanup(provider.close)

        def prepare(app):
            if metadata is not None:
                (app.home / "models.json").write_text(json.dumps(metadata))

        app = Albedo(
            provider,
            prepare=prepare,
            providers={
                "go": {
                    "extension": "opencode-go",
                    "baseUrl": provider.url,
                    "apiKey": key,
                    "model": model,
                    "protocol": "chat_completions",
                    **({"effort": effort} if effort else {}),
                },
                **(providers or {}),
            },
        )
        app.__enter__()
        self.addCleanup(app.__exit__, None, None, None)
        self.app, self.provider = app, provider
        return app.session()

    def turn(self, session):
        self.app.prompt(session, "reply").close()
        self.app.idle(session)
        return json.dumps(self.app.history(session))

    def assert_session_headers(self, session):
        self.assertTrue(self.provider.headers)
        for headers in self.provider.headers:
            headers = {k.lower(): v for k, v in headers.items()}
            self.assertEqual(headers.get("x-opencode-session"), session)

    def listed(self, endpoint):
        with self.app.api(
            "/models?provider=opencode-go&endpoint=" + quote(endpoint, safe="")
        ) as response:
            return json.load(response)["items"]

    def test_switching_routes_in_one_profile(self):
        # Chat, Responses and Messages families through a real /model switch,
        # the documented route for each, and one session on every request.
        session = self.start("glm-5.2")
        for model, suffix in [
            ("glm-5.2", "/chat/completions"),
            ("minimax-m2.7", "/messages"),
            ("gpt-5.6-luna", "/responses"),
            ("glm-5.2", "/chat/completions"),
        ]:
            with self.app.api(f"/sessions/{session}/configuration") as response:
                json.load(response)
                validator = response.headers["ETag"]
            with self.app.api(
                f"/sessions/{session}/configuration",
                {"model": model},
                method="PATCH",
                headers={"If-Match": validator},
            ) as response:
                response.read()
            self.assertIn("go-reply", self.turn(session))
            self.assertTrue(
                self.provider.requests[-1]["path"].endswith(suffix),
                self.provider.requests,
            )
            with self.app.api(f"/sessions/{session}?tail=0") as response:
                snapshot = json.load(response)
            self.assertFalse(
                [
                    line
                    for line in snapshot["activity"]["lines"]
                    if line["kind"] == "error"
                ],
                snapshot["activity"],
            )
        self.assert_session_headers(session)

    def test_messages_route_omits_claude_effort_fields(self):
        # A non-Claude model on Go's Messages route gets no adaptive effort.
        session = self.start("minimax-m2.7")
        self.assertIn("go-reply", self.turn(session))
        record = self.provider.requests[-1]
        self.assertTrue(record["path"].endswith("/messages"))
        self.assertNotIn("thinking", record["request"])
        self.assertNotIn("output_config", record["request"])

    def test_per_model_sdk_overrides_documented_route(self):
        metadata = {
            "opencode-go": {
                "name": "OpenCode Go",
                "npm": "@ai-sdk/openai-compatible",
                "models": {"glm-test": {"provider": {"npm": "@ai-sdk/anthropic"}}},
            }
        }
        session = self.start("glm-test", metadata=metadata)
        self.assertIn("go-reply", self.turn(session))
        self.assertTrue(self.provider.requests[-1]["path"].endswith("/messages"))

    def test_unlisted_model_keeps_family_route(self):
        # A provider-wide SDK must not capture models the catalog does not list.
        metadata = {
            "opencode-go": {
                "name": "OpenCode Go",
                "npm": "@ai-sdk/openai-compatible",
                "models": {"glm-5.2": {}},
            }
        }
        session = self.start("gpt-5.7-unlisted", metadata=metadata)
        self.assertIn("go-reply", self.turn(session))
        self.assertTrue(self.provider.requests[-1]["path"].endswith("/responses"))

    def test_catalog_caches_and_credentials_are_endpoint_scoped(self):
        # Each endpoint keeps its own list, and only a profile's own endpoint
        # may spend its key: an endpoint no profile names is fetched keyless.
        other = GoProvider(lambda _: text("go-reply"))
        self.addCleanup(other.close)
        other.catalog = {"data": [{"id": "custom-model"}]}
        stranger = GoProvider(lambda _: text("go-reply"))
        self.addCleanup(stranger.close)
        stranger.catalog = {"data": [{"id": "other-model"}]}
        self.start(
            "glm-5.2",
            providers={
                "other": {
                    "extension": "opencode-go",
                    "baseUrl": other.url,
                    "apiKey": "go-test-key",
                    "model": "custom-model",
                    "protocol": "chat_completions",
                }
            },
        )
        first = {item["id"] for item in self.listed(self.provider.url)}
        self.assertEqual(first, {"glm-5.2", "minimax-m2.7", "gpt-5.6-luna"})
        self.assertEqual({item["id"] for item in self.listed(other.url)}, {"custom-model"})
        self.assertEqual({item["id"] for item in self.listed(stranger.url)}, {"other-model"})
        for provider in (self.provider, other):
            headers = {
                key.lower(): value for key, value in provider.get_headers[0].items()
            }
            self.assertEqual(headers.get("authorization"), "Bearer go-test-key")
        self.assertNotIn(
            "authorization",
            {key.lower() for key in stranger.get_headers[0]},
        )

    def test_live_discovery_and_saved_list(self):
        self.start("glm-5.2")
        path = "/models?provider=opencode-go&endpoint=" + quote(
            self.provider.url, safe=""
        )
        with self.app.api(path) as response:
            models = json.load(response)
        self.assertEqual(
            {row["id"] for row in models["items"]},
            {"glm-5.2", "minimax-m2.7", "gpt-5.6-luna"},
        )
        self.assertEqual(len(self.provider.gets), 1)
        saved = saved_list(self.app.home, "opencode-go", self.provider.url)
        contents = json.loads(saved.read_text())
        self.assertEqual(contents["owner"], "opencode-go")
        self.assertIsInstance(contents["fetched"], int)
        self.assertEqual(
            set(contents["ids"]), {"glm-5.2", "minimax-m2.7", "gpt-5.6-luna"}
        )
        # A saved list answers for five minutes without asking the endpoint.
        self.provider.catalog = {"data": [{"id": "newer-model"}]}
        with self.app.api(path) as response:
            self.assertEqual(json.load(response)["items"], models["items"])
        self.assertEqual(len(self.provider.gets), 1)
        # An old list is refetched behind the caller, and a failed fetch keeps it.
        saved.write_text(json.dumps({**contents, "fetched": 0}))
        self.app.restart()
        self.provider.fail_catalog = True
        asked = len(self.provider.gets)
        with self.app.api(path) as response:
            self.assertEqual(json.load(response)["items"], models["items"])
        wait_until(
            lambda: len(self.provider.gets) == asked + 1,
            10,
            "the saved list was never refetched",
        )
        with self.app.api(path) as response:
            self.assertEqual(json.load(response)["items"], models["items"])

    def test_rejected_key_is_explained(self):
        session = self.start("glm-5.2", lambda _: error(401, "bad key"))
        self.app.prompt(session, "reply").close()
        snapshot = self.app.idle(session)
        self.assertIn(
            "OpenCode Go rejected the credential", json.dumps(snapshot["activity"])
        )

    def test_missing_key_stops_before_provider_request(self):
        session = self.start("glm-5.2", key="")
        self.app.prompt(session, "reply").close()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with self.app.api(f"/sessions/{session}?tail=0") as response:
                snapshot = json.load(response)
            if snapshot["status"]["blocking_reason"]:
                break
            time.sleep(0.05)
        self.assertIn(
            "OpenCode Go is not authenticated",
            json.dumps(snapshot["status"]["blocking_reason"]),
        )
        self.assertTrue(snapshot["pending_inputs"])
        self.assertEqual(self.provider.requests, [])
