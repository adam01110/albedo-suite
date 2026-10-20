"""OpenCode Go routing and discovery against an isolated scripted endpoint."""

import json
import time
import unittest
from urllib.parse import quote

from harness import Albedo, Provider, Reply, error, exclusive, text


def messages_reply(tool=False):
    block = (
        {"type": "tool_use", "id": "go-call", "name": "python", "input": {}}
        if tool
        else {"type": "text", "text": ""}
    )
    delta = (
        {
            "type": "input_json_delta",
            "partial_json": json.dumps({"code": "print('go-tool')"}),
        }
        if tool
        else {"type": "text_delta", "text": "go-reply"}
    )
    return Reply(
        "text",
        events=[
            {
                "type": "message_start",
                "message": {
                    "id": "go-message",
                    "usage": {"input_tokens": 10, "output_tokens": 0},
                },
            },
            {"type": "content_block_start", "index": 0, "content_block": block},
            {"type": "content_block_delta", "index": 0, "delta": delta},
            {"type": "content_block_stop", "index": 0},
            {
                "type": "message_delta",
                "delta": {"stop_reason": "tool_use" if tool else "end_turn"},
                "usage": {"output_tokens": 5},
            },
            {"type": "message_stop"},
        ],
    )


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
    def start(
        self, model, script=None, key="go-test-key", metadata=None, providers=None
    ):
        provider = GoProvider(
            script
            or (
                lambda _: (
                    messages_reply()
                    if model.startswith("minimax")
                    else text("go-reply")
                )
            )
        )
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

    def test_chat_route(self):
        session = self.start("glm-5.2")
        self.assertIn("go-reply", self.turn(session))
        self.assertTrue(
            self.provider.requests[-1]["path"].endswith("/chat/completions")
        )
        self.assertEqual(
            self.provider.requests[-1]["authorization"], "Bearer go-test-key"
        )

        self.assert_session_headers(session)

    def test_responses_route(self):
        session = self.start("gpt-5.6-luna")
        self.assertIn("go-reply", self.turn(session))
        self.assertTrue(self.provider.requests[-1]["path"].endswith("/responses"))
        self.assertIn("go-reply", self.turn(session))
        self.assertEqual(len(self.provider.requests), 2)

        self.assert_session_headers(session)

    def test_messages_route_and_tool_replay(self):
        replies = iter([messages_reply(tool=True), messages_reply(), messages_reply()])
        session = self.start("minimax-m2.7", lambda _: next(replies))
        history = self.turn(session)
        self.assertIn("go-tool", history)
        self.assertIn("go-reply", history)
        self.assertEqual(len(self.provider.requests), 2)
        record = self.provider.requests[-1]
        self.assertTrue(record["path"].endswith("/messages"))
        headers = {k.lower(): v for k, v in self.provider.headers[-1].items()}
        self.assertEqual(headers["x-api-key"], "go-test-key")
        self.assertEqual(headers["anthropic-version"], "2023-06-01")
        self.assertNotIn("anthropic-beta", headers)
        self.assertNotIn("context_management", record["request"])
        self.assertGreater(record["request"]["max_tokens"], 0)
        self.assertNotIn("thinking", record["request"])
        self.assertNotIn("output_config", record["request"])
        self.assertNotIn('"ttl": "1h"', json.dumps(record["request"]))
        blocks = [
            block
            for message in record["request"]["messages"]
            for block in message["content"]
        ]
        self.assertTrue(any(block["type"] == "tool_result" for block in blocks))
        self.assertIn("go-reply", self.turn(session))

        self.assert_session_headers(session)

    def test_distinct_session_headers(self):
        first = self.start("glm-5.2")
        self.assertIn("go-reply", self.turn(first))
        self.assert_session_headers(first)
        self.provider.headers.clear()
        second = self.app.session()
        self.assertNotEqual(first, second)
        self.assertIn("go-reply", self.turn(second))
        self.assert_session_headers(second)

    def test_switching_routes_in_one_profile(self):
        session = self.start(
            "glm-5.2",
            lambda request: (
                messages_reply()
                if request["model"].startswith("minimax")
                else text("go-reply")
            ),
        )
        for model, suffix in [
            ("glm-5.2", "/chat/completions"),
            ("minimax-m2.7", "/messages"),
            ("gpt-5.6-luna", "/responses"),
            ("glm-5.2", "/chat/completions"),
        ]:
            with self.app.api(f"/sessions/{session}?view=configuration") as response:
                json.load(response)
                validator = response.headers["ETag"]
            with self.app.api(
                f"/sessions/{session}?view=configuration",
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

    def test_live_discovery_and_cached_failure(self):
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
        caches = list(self.app.home.glob("opencode-go-models-*.json"))
        self.assertEqual(len(caches), 1)
        cache = json.loads(caches[0].read_text())
        cache["time"] = 0
        caches[0].write_text(json.dumps(cache))
        self.provider.fail_catalog = True
        with self.app.api(path) as response:
            self.assertEqual(json.load(response)["items"], models["items"])
        self.assertEqual(len(self.provider.gets), 2)

    def test_per_model_sdk_overrides_documented_route(self):
        metadata = {
            "opencode-go": {
                "name": "OpenCode Go",
                "npm": "@ai-sdk/openai-compatible",
                "models": {"glm-test": {"provider": {"npm": "@ai-sdk/anthropic"}}},
            }
        }
        session = self.start("glm-test", lambda _: messages_reply(), metadata=metadata)
        self.assertIn("go-reply", self.turn(session))
        self.assertTrue(self.provider.requests[-1]["path"].endswith("/messages"))

    def test_provider_sdk_default_and_unknown_sdk_fallback(self):
        for sdk, model, suffix, reply in [
            ("@ai-sdk/anthropic", "fixture-model", "/messages", messages_reply()),
            ("unknown-sdk", "gpt-fixture", "/responses", text("go-reply")),
        ]:
            with self.subTest(sdk=sdk):
                session = self.start(
                    model,
                    lambda _, reply=reply: reply,
                    metadata={"opencode-go": {"npm": sdk, "models": {}}},
                )
                self.assertIn("go-reply", self.turn(session))
                self.assertTrue(self.provider.requests[-1]["path"].endswith(suffix))

    def test_catalog_caches_and_credentials_are_endpoint_scoped(self):
        self.start("glm-5.2")
        other = GoProvider(lambda _: text("go-reply"))
        self.addCleanup(other.close)
        other.catalog = {"data": [{"id": "other-model"}]}
        path = "/models?provider=opencode-go&endpoint="
        with self.app.api(path + quote(self.provider.url, safe="")) as response:
            first = json.load(response)["items"]
        with self.app.api(path + quote(other.url, safe="")) as response:
            second = json.load(response)["items"]
        self.assertEqual({item["id"] for item in second}, {"other-model"})
        self.assertNotEqual(first, second)
        self.assertEqual(len(list(self.app.home.glob("opencode-go-models-*.json"))), 2)
        self.assertEqual(len(other.gets), 1)
        self.assertNotIn(
            "authorization",
            {key.lower(): value for key, value in other.get_headers[0].items()},
        )
        other.fail_catalog = True
        for cache in self.app.home.glob("opencode-go-models-*.json"):
            contents = json.loads(cache.read_text())
            contents["time"] = 0
            cache.write_text(json.dumps(contents))
        with self.app.api(path + quote(other.url, safe="")) as response:
            self.assertEqual(json.load(response)["items"], second)
        self.assertEqual(len(other.gets), 2)

    def test_same_key_at_two_configured_endpoints_keeps_catalog_auth(self):
        other = GoProvider(lambda _: text("go-reply"))
        self.addCleanup(other.close)
        other.catalog = {"data": [{"id": "custom-model"}]}
        self.start(
            "glm-5.2",
            metadata={
                "opencode-go": {
                    "models": {"custom-model": {"limit": {"context": 12345}}}
                }
            },
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
        path = "/models?provider=opencode-go&endpoint="
        for provider in (self.provider, other):
            with self.app.api(path + quote(provider.url, safe="")) as response:
                items = json.load(response)["items"]
            headers = {
                key.lower(): value for key, value in provider.get_headers[0].items()
            }
            self.assertEqual(headers.get("authorization"), "Bearer go-test-key")
            if provider is other:
                self.assertEqual(items[0]["id"], "custom-model")
                self.assertEqual(items[0]["default_context_tokens"], 12345)
        self.assertEqual(len(list(self.app.home.glob("opencode-go-models-*.json"))), 2)

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
