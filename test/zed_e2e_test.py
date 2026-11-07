"""Native Zed envelopes and chunked NDJSON through an isolated daemon."""

import base64
import json
import time
import unittest
import urllib.error
from urllib.parse import quote

from harness import Albedo, Provider, exclusive, wait_until

# Browser sign-in is Zed's only credential, so the fixtures seed the daemon's
# credential store and no profile carries a key. A seeded inference JWT is
# already fresh, so no test reaches the token service.
EXPIRES = int(time.time()) + 3600


def zed_jwt(account):
    payload = json.dumps({"exp": EXPIRES, "account": account}).encode()
    return "header." + base64.urlsafe_b64encode(payload).rstrip(b"=").decode() + ".signature"


ZED_JWT = zed_jwt("one")
OTHER_ZED_JWT = zed_jwt("two")


def zed_account(account_id, user_id, jwt):
    return {
        "type": "oauth",
        "user_id": user_id,
        "access_token": "browser-sign-in-" + account_id,
        "github_login": "github-" + account_id,
        "username": "user-" + account_id,
        "organization_id": "org-" + account_id,
        "_albedo_account_id": account_id,
        "jwt": jwt,
        "jwt_expires": EXPIRES,
    }


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


def google_messages(tool=False):
    """One GenerateContent candidate with a thought part and a text part."""
    if tool:
        content = {"role": "model", "parts": [
            {"text": "zed-gemini-thought", "thought": True},
            {"functionCall": {"name": "python", "args": {"code": "print('zed-gemini-tool')"}}},
        ]}
        finish = "STOP"
    else:
        content = {"role": "model", "parts": [
            {"text": "zed-gemini-thought", "thought": True},
            {"text": "zed-gemini-reply-é"},
        ]}
        finish = "STOP"
    event = {
        "candidates": [{"content": content, "finishReason": finish}],
        "usageMetadata": {
            "promptTokenCount": 11, "candidatesTokenCount": 5,
            "thoughtsTokenCount": 2, "totalTokenCount": 18,
        },
    }
    return [{"event": event}]


class ZedProvider(Provider):
    def __init__(self, script):
        super().__init__(script, catalog={"models": [{
            "id": "claude-sonnet-4-6", "provider": "anthropic",
            "max_token_count": 200000, "max_output_tokens": 64000,
            "supports_images": True,
            "supported_effort_levels": [{"name": "High", "value": "high"}],
        }, {
            "id": "gemini-3.1-pro-preview", "provider": "google",
            "max_token_count": 1000000, "max_output_tokens": 65536,
            "supports_images": True,
            "supported_effort_levels": [{"name": "High", "value": "high"}],
        }]})
        self.headers = []
        self.get_headers = []

    def _get(owner, self):
        owner.get_headers.append(dict(self.headers))
        catalog = owner.catalog
        assert catalog is not None
        if self.headers.get("Authorization") == "Bearer " + OTHER_ZED_JWT:
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
    def start(self, script=None, extra=False, api_key=None, endpoint=None, effort="high", google=False):
        self.provider = ZedProvider(script or (lambda _: messages() + [{"status": "stream_ended"}]))
        self.addCleanup(self.provider.close)

        def prepare(app):
            app.env.pop("ZED_TOKEN", None)
            accounts = [zed_account("zed-one", "41", ZED_JWT)]
            if extra:
                accounts.append(zed_account("zed-two", "42", OTHER_ZED_JWT))
            app.store_secrets("accounts", {"zed": accounts})
            if api_key is not None:
                # A key saved before browser sign-in became the only credential,
                # where a real profile keeps it: creds.json, not config.json.
                app.store_secrets("providers", {"zed": {"apiKey": api_key}})

        profile = {
            "extension": "zed", "baseUrl": self.provider.url,
            "model": "gemini-3.1-pro-preview" if google else "claude-sonnet-4-6",
            "protocol": "chat_completions",
        }
        if effort is not None:
            profile["effort"] = effort
        other = {
            "extension": "zed", "baseUrl": self.provider.url,
            "model": "claude-account-two", "protocol": "chat_completions",
        }
        if extra:
            profile["accountId"] = "zed-one"
            other["accountId"] = "zed-two"
        if endpoint is not None:
            profile["baseUrl"] = endpoint
        self.app = Albedo(
            self.provider,
            prepare=prepare,
            providers={"zed": profile, **({"a-other": other} if extra else {})},
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        return self.app.session()

    def refusal(self, session, *needles):
        """Wait for the daemon to block the prompt with a refusal naming `needles`."""
        def reasons():
            with self.app.api(f"/sessions/{session}?tail=0") as response:
                snapshot = json.load(response)
            found = [line["text"] for line in snapshot["activity"]["lines"]]
            found += [item["blocking_reason"]["detail"] for item in snapshot["pending_inputs"]
                      if item.get("blocking_reason")]
            status = snapshot["status"].get("blocking_reason") or {}
            found.append(status.get("detail", ""))
            return [reason for reason in found if reason and all(needle in reason for needle in needles)]

        found = {}

        def blocked():
            found["reasons"] = reasons()
            return bool(found["reasons"])

        wait_until(blocked, 20, f"the daemon did not refuse this Zed credential: {session}")
        return found["reasons"][0]

    def turn(self, session):
        self.app.prompt(session, "reply").close()
        self.app.idle(session)
        # Unescaped: a mangled multibyte character must fail the assertion, and
        # an escaped history would hide it.
        return json.dumps(self.app.history(session), ensure_ascii=False)

    def test_budget_command_and_endpoint_are_removed(self):
        session = self.start(extra=True)
        self.turn(session)
        with self.app.api(f"/sessions/{session}/catalog") as response:
            commands = json.load(response)["loaded"]["commands"]
        self.assertNotIn("/zed-budget", [entry["slash_name"] for entry in commands])
        before = (len(self.provider.requests), len(self.provider.get_headers))
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.app.api("/extensions/zed/budget")
        self.assertEqual(error.exception.code, 404)
        self.assertEqual(before, (len(self.provider.requests), len(self.provider.get_headers)))

    def test_native_stream_thinking_usage_and_metadata(self):
        session = self.start()
        history = self.turn(session)
        self.assertIn("zed-reply-é", history)
        self.assertIn("zed-thought", history)
        with self.app.api(f"/sessions/{session}?tail=0") as response:
            usage = json.load(response)["usage"]
        self.assertEqual(usage["prompt_tokens"], 11)
        self.assertEqual(usage["completion_tokens"], 9)
        request = self.provider.requests[-1]
        self.assertEqual(request["provider"], "anthropic")
        self.assertIn("messages", request["provider_request"])
        headers = {k.lower(): v for k, v in self.provider.headers[-1].items()}
        self.assertEqual(headers["authorization"], "Bearer " + ZED_JWT)
        self.assertEqual(headers["x-zed-client-supports-status-messages"], "true")
        with self.app.api("/models?provider=zed&endpoint=" + quote(self.provider.url, safe="")) as response:
            catalog = json.load(response)
        self.assertEqual(
            [m["id"] for m in catalog["items"]],
            ["claude-sonnet-4-6", "gemini-3.1-pro-preview"],
        )
        self.assertTrue(self.provider.get_headers)
        for headers in self.provider.get_headers:
            self.assertEqual({k.lower(): v for k, v in headers.items()}["authorization"], "Bearer " + ZED_JWT)

    def test_tool_result_replayed_without_proxy(self):
        replies = iter([messages(tool=True), messages(), messages()])
        session = self.start(lambda _: next(replies) + [{"status": "stream_ended"}])
        history = self.turn(session)
        self.assertIn("zed-tool", history)
        self.assertIn("zed-reply-é", history)
        self.assertEqual(len(self.provider.requests), 2)
        blocks = [b for m in self.provider.requests[-1]["provider_request"]["messages"] for b in m["content"]]
        self.assertTrue(any(b["type"] == "tool_result" for b in blocks))
        self.assertIn("zed-reply-é", self.turn(session))

    def test_profile_api_key_is_refused_and_never_sent(self):
        session = self.start(api_key="leftover-zed-jwt", effort=None)
        self.app.prompt(session, "reply").close()
        reason = self.refusal(session, "apiKey", "/login zed")
        self.assertIn("remove apiKey", reason)
        self.assertNotIn("leftover-zed-jwt", reason)
        self.assertEqual(self.provider.requests, [])
        self.assertEqual(self.provider.get_headers, [])

    def test_browser_sign_in_clears_a_stored_profile_key(self):
        """The recovery the refusal names: after a keyless save it must work."""
        session = self.start(api_key="leftover-zed-jwt", effort=None)
        self.app.prompt(session, "reply").close()
        self.refusal(session, "apiKey", "/login zed")
        route = "/settings?group=providers"
        with self.app.api(route) as response:
            etag = response.headers["ETag"]
            before = json.load(response)["profiles"]["zed"]
        self.assertTrue(before["has_key"], before)
        # What the client sends when a browser sign-in saves this profile: an
        # explicit null, because an omitted api_key keeps the stored one.
        with self.app.api(
            route, {"profiles": {"zed": {"api_key": None}}},
            method="PATCH", headers={"If-Match": etag},
        ) as response:
            saved = json.load(response)
        self.assertFalse(saved["resource"]["value"]["profiles"]["zed"]["has_key"])
        with self.app.api(route) as response:
            after = json.load(response)["profiles"]["zed"]
        self.assertFalse(after["has_key"], after)
        self.assertNotIn("leftover-zed-jwt", (self.app.home / "creds.json").read_text())
        # The profile now runs on the stored browser account, with no refusal.
        self.assertIn("zed-reply-é", self.turn(self.app.session()))
        headers = {k.lower(): v for k, v in self.provider.headers[-1].items()}
        self.assertEqual(headers["authorization"], "Bearer " + ZED_JWT)

    def test_daemon_zed_token_is_refused_and_never_sent(self):
        session = self.start(effort=None)
        # Discovery may run while the daemon has no ZED_TOKEN; none may run after.
        settled = (len(self.provider.requests), len(self.provider.get_headers))
        self.app.env["ZED_TOKEN"] = "environment-zed-jwt"
        self.app.restart()
        self.app.prompt(session, "reply").close()
        reason = self.refusal(session, "ZED_TOKEN", "/login zed")
        self.assertIn("unset it", reason)
        self.assertNotIn("environment-zed-jwt", reason)
        self.assertEqual(settled, (len(self.provider.requests), len(self.provider.get_headers)))

    def test_custom_endpoint_is_refused_instead_of_sent_the_account(self):
        session = self.start(endpoint="https://custom.invalid", effort=None)
        self.app.prompt(session, "reply").close()
        reason = self.refusal(session, "https://cloud.zed.dev", "custom")
        self.assertIn("unsupported", reason)
        self.assertEqual(self.provider.requests, [])

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

    def test_gemini_generate_content_end_to_end(self):
        """The documented GenerateContent route, driven through the daemon."""
        session = self.start(
            lambda _: google_messages() + [{"status": "stream_ended"}], google=True
        )
        history = self.turn(session)
        self.assertIn("zed-gemini-reply-é", history)
        self.assertIn("zed-gemini-thought", history)
        with self.app.api(f"/sessions/{session}?tail=0") as response:
            usage = json.load(response)["usage"]
        self.assertEqual(usage["prompt_tokens"], 11)
        # Thought tokens are part of the output total, not added twice.
        self.assertEqual(usage["completion_tokens"], 7)
        request = self.provider.requests[-1]
        self.assertEqual(request["provider"], "google")
        self.assertEqual(request["model"], "gemini-3.1-pro-preview")
        body = request["provider_request"]
        self.assertEqual(body["model"], "models/gemini-3.1-pro-preview")
        self.assertEqual(body["contents"][0]["role"], "user")
        self.assertEqual(body["contents"][0]["parts"][0]["text"], "reply")
        self.assertEqual(
            body["generationConfig"]["thinkingConfig"]["thinkingLevel"], "HIGH"
        )
        headers = {k.lower(): v for k, v in self.provider.headers[-1].items()}
        self.assertEqual(headers["authorization"], "Bearer " + ZED_JWT)

    def test_removed_budget_route_returns_not_found_for_all_requests(self):
        self.start()
        cases = [
            ("POST", "/extensions/zed/budget", 404, "not_found"),
            ("GET", "/extensions/zed/budget?account=one", 404, "not_found"),
            ("GET", "/extensions/zed/other", 404, "not_found"),
        ]
        for method, path, status, code in cases:
            with self.subTest(method=method, path=path):
                with self.assertRaises(urllib.error.HTTPError) as raised:
                    with self.app.api(path, method=method) as response:
                        response.read()
                self.assertEqual(raised.exception.code, status)
                self.assertIn(code, str(raised.exception))

    def test_selected_account_owns_inference_discovery(self):
        first = self.start(extra=True)
        self.assertIn("zed-reply-é", self.turn(first))
        first_headers = [{k.lower(): v for k, v in h.items()} for h in self.provider.get_headers]
        self.assertTrue(first_headers)
        self.assertEqual({h["authorization"] for h in first_headers}, {"Bearer " + ZED_JWT})
        self.app.profile = "a-other"
        second = self.app.session()
        self.assertIn("zed-reply-é", self.turn(second))
        request = self.provider.requests[-1]
        self.assertEqual(request["model"], "claude-account-two")
        self.assertEqual(
            {k.lower(): v for k, v in self.provider.headers[-1].items()}["authorization"],
            "Bearer " + OTHER_ZED_JWT,
        )
        self.assertEqual(len(list(self.app.home.glob("zed-models-*.json"))), 2)
