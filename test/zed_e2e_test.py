"""Native Zed envelopes and chunked NDJSON through an isolated daemon."""

import json
import unittest
from urllib.parse import quote

from harness import Albedo, Provider, exclusive


def messages(tool=False):
    events = [
        {"type": "message_start", "message": {"id": "zed-message", "usage": {"input_tokens": 11, "output_tokens": 0}}},
        {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "zed-thought"}},
        {"type": "content_block_stop", "index": 0},
        {"type": "content_block_start", "index": 1, "content_block": (
            {"type": "tool_use", "id": "zed-call", "name": "python", "input": {}}
            if tool else {"type": "text", "text": ""})},
        {"type": "content_block_delta", "index": 1, "delta": (
            {"type": "input_json_delta", "partial_json": json.dumps({"code": "print('zed-tool')"})}
            if tool else {"type": "text_delta", "text": "zed-reply-é"})},
        {"type": "content_block_stop", "index": 1},
        {"type": "message_delta", "delta": {"stop_reason": "tool_use" if tool else "end_turn"}, "usage": {"output_tokens": 9}},
        {"type": "message_stop"},
    ]
    return [{"event": event} for event in events]


class ZedProvider(Provider):
    def __init__(self, script):
        super().__init__(script, catalog={"models": [{
            "id": "claude-sonnet-4-6", "provider": "anthropic",
            "max_token_count": 200000, "max_output_tokens": 64000,
            "supports_images": True,
            "supported_effort_levels": [{"name": "High", "value": "high"}],
        }]})
        self.headers = []
        self.get_headers = []

    def _get(owner, self):
        owner.get_headers.append(dict(self.headers))
        catalog = owner.catalog
        assert catalog is not None
        if self.headers.get("Authorization") == "Bearer other-zed-jwt":
            catalog = {"models": [dict(catalog["models"][0], id="claude-account-two")]}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(catalog).encode())

    def _post(owner, self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        owner.requests.append(request)
        owner.headers.append(dict(self.headers))
        events = owner.script(request)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("x-zed-server-supports-status-messages", "true")
        self.end_headers()
        # Small writes split JSON and multibyte text; no newline on the last record.
        payload = "\r\n".join(json.dumps(e, ensure_ascii=False) for e in events).encode()
        for start in range(0, len(payload), 7):
            self.wfile.write(payload[start:start + 7])
            self.wfile.flush()


@exclusive
class ZedE2ETests(unittest.TestCase):
    def start(self, script=None, extra=False):
        self.provider = ZedProvider(script or (lambda _: messages() + [{"status": "stream_ended"}]))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, providers={"zed": {
            "extension": "zed", "baseUrl": self.provider.url,
            "apiKey": "fake-zed-jwt", "model": "claude-sonnet-4-6",
            "protocol": "chat_completions", "effort": "high",
        }, **({"a-other": {
            "extension": "zed", "baseUrl": self.provider.url,
            "apiKey": "other-zed-jwt", "model": "claude-account-two",
            "protocol": "chat_completions",
        }} if extra else {})})
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        return self.app.session()

    def turn(self, session):
        self.app.prompt(session, "reply").close()
        self.app.idle(session)
        return json.dumps(self.app.history(session))

    def test_native_stream_thinking_usage_and_metadata(self):
        session = self.start()
        history = self.turn(session)
        self.assertIn("zed-reply-", history)
        self.assertIn("zed-thought", history)
        with self.app.api(f"/sessions/{session}?tail=0") as response:
            usage = json.load(response)["usage"]
        self.assertEqual(usage["prompt_tokens"], 11)
        self.assertEqual(usage["completion_tokens"], 9)
        request = self.provider.requests[-1]
        self.assertEqual(request["provider"], "anthropic")
        self.assertIn("messages", request["provider_request"])
        headers = {k.lower(): v for k, v in self.provider.headers[-1].items()}
        self.assertEqual(headers["authorization"], "Bearer fake-zed-jwt")
        self.assertEqual(headers["x-zed-client-supports-status-messages"], "true")
        with self.app.api("/models?provider=zed&endpoint=" + quote(self.provider.url, safe="")) as response:
            catalog = json.load(response)
        self.assertEqual([m["id"] for m in catalog["items"]], ["claude-sonnet-4-6"])
        self.assertTrue(self.provider.get_headers)
        for headers in self.provider.get_headers:
            self.assertEqual({k.lower(): v for k, v in headers.items()}["authorization"], "Bearer fake-zed-jwt")

    def test_tool_result_replayed_without_proxy(self):
        replies = iter([messages(tool=True), messages(), messages()])
        session = self.start(lambda _: next(replies) + [{"status": "stream_ended"}])
        history = self.turn(session)
        self.assertIn("zed-tool", history)
        self.assertIn("zed-reply-", history)
        self.assertEqual(len(self.provider.requests), 2)
        blocks = [b for m in self.provider.requests[-1]["provider_request"]["messages"] for b in m["content"]]
        self.assertTrue(any(b["type"] == "tool_result" for b in blocks))
        self.assertIn("zed-reply-", self.turn(session))

    def test_failure_after_message_stop_is_not_success(self):
        session = self.start(lambda _: messages() + [{"status": {"failed": {"code": "quota", "message": "zed-quota-exhausted"}}}])
        self.assertIn("zed-quota-exhausted", self.turn(session))

    def test_missing_stream_ended_is_not_success(self):
        attempts = iter([messages(), [{"status": {"failed": {"message": "zed-retry-stopped"}}}]])
        session = self.start(lambda _: next(attempts))
        history = self.turn(session)
        self.assertEqual(len(self.provider.requests), 2)
        self.assertIn("transient provider request failure", history)
        with self.app.api(f"/sessions/{session}?tail=0") as response:
            snapshot = json.load(response)
        self.assertTrue(any(line["kind"] == "error" and "zed-retry-stopped" in line["text"] for line in snapshot["activity"]["lines"]), snapshot["activity"])

    def test_selected_account_owns_inference_discovery(self):
        first = self.start(extra=True)
        self.assertIn("zed-reply-", self.turn(first))
        first_headers = [{k.lower(): v for k, v in h.items()} for h in self.provider.get_headers]
        self.assertTrue(first_headers)
        self.assertEqual({h["authorization"] for h in first_headers}, {"Bearer fake-zed-jwt"})
        self.app.profile = "a-other"
        second = self.app.session()
        self.assertIn("zed-reply-", self.turn(second))
        request = self.provider.requests[-1]
        self.assertEqual(request["model"], "claude-account-two")
        self.assertEqual({k.lower(): v for k, v in self.provider.headers[-1].items()}["authorization"], "Bearer other-zed-jwt")
        self.assertEqual(len(list(self.app.home.glob("zed-models-*.json"))), 2)
