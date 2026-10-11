"""Binding contracts need deterministic fake-host errors independent of daemon E2E."""

import importlib
import os
import sys
import types
import unittest

sys.path.insert(0, os.environ["ALBEDO_QUESTIONS_SOURCE"])
plugin = importlib.import_module("albedo_plugins.questions")


class QuestionsPythonTests(unittest.IsolatedAsyncioTestCase):
    async def test_ask_records_without_waiting_and_bindings_are_session_local(self):
        calls = []

        async def host(method, args):
            calls.append((method, args))
            return {
                "id": "1",
                "status": "pending",
                "question": args.get("question", ""),
            }

        api = types.SimpleNamespace(host=host, HostError=RuntimeError)
        bindings = plugin.setup(api)
        result = await bindings["ask_user"]("Continue?", options=["yes", "no"])
        self.assertEqual(result.id, "1")
        self.assertEqual(result.status, "pending")
        self.assertEqual(
            calls,
            [("questions.ask", {"question": "Continue?", "options": ["yes", "no"]})],
        )
        other_calls = []

        async def other_host(method, args):
            other_calls.append(method)
            return {"id": "2", "status": "pending"}

        plugin.setup(types.SimpleNamespace(host=other_host, HostError=RuntimeError))
        await bindings["questions"].get(1)
        await bindings["questions"].cancel("1")
        self.assertEqual(
            calls[-2:],
            [("questions.get", {"id": "1"}), ("questions.cancel", {"id": "1"})],
        )
        self.assertEqual(other_calls, [])
        self.assertFalse(hasattr(bindings["questions"], "answer"))

    async def test_errors_propagate_and_list_returns_records(self):
        async def host(method, args):
            if method == "questions.list":
                return [{"id": "3", "status": "pending"}]
            raise RuntimeError("refused")

        questions = plugin.Questions(host)
        self.assertEqual((await questions.list())[0].id, "3")
        with self.assertRaisesRegex(RuntimeError, "refused"):
            await questions.ask("blocked")
