"""Questions go through the real daemon, durable store, Python RPC and client page."""

import concurrent.futures
import json
import unittest
from urllib.error import HTTPError
from urllib.parse import urlencode

from harness import Albedo, Provider, exclusive, python, text


@exclusive
class QuestionsTests(unittest.TestCase):
    def setUp(self):
        self.code = None

        def script(request):
            if self.code is not None:
                code, self.code = self.code, None
                return python(code + "\nprint('QUESTION_CELL_OK')")
            return text("Use /questions to answer")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()
        self.route = "/extensions/questions/items?" + urlencode(
            {"session_id": self.session}
        )

    def turn(self, code, session=None):
        self.code = code
        self.app.prompt(session or self.session, "run question cell").close()
        self.app.idle(session or self.session, timeout=30)
        history = self.app.history(session or self.session)
        results = [
            json.loads(part["value"])
            for item in history["items"]
            if item["kind"] == "tool_result"
            for part in item["content"]
            if part["kind"] == "json" and part["field"] == "result"
        ]
        self.assertTrue(results)
        self.assertEqual(results[-1]["status"], "ok", results[-1])
        self.assertIn("QUESTION_CELL_OK", results[-1]["output"])

    def pending(self):
        with self.app.api(self.route) as response:
            return json.load(response)

    def ask(self):
        self.turn(
            "q = await ask_user('Which deployment?', options=['staging', 'production'])\nassert q.status == 'pending'"
        )
        return self.pending()["items"][0]

    def action(self, item, action="answer", answer="staging"):
        url = item["url"].replace("?", "/" + action + "?", 1)
        with self.app.api(
            url,
            {"answer": answer} if action == "answer" else {},
            method="POST",
            headers={"If-Match": item["etag"]},
        ) as response:
            return json.load(response)

    def test_answer_is_durable_and_notifies_asking_session(self):
        item = self.ask()
        page = self.pending()["page"]
        self.assertEqual(page["title"], "questions")
        self.assertEqual({a["id"] for a in page["actions"]}, {"answer", "cancel"})
        result = self.action(item, answer="custom deployment")
        self.assertEqual(result["resource"]["value"]["answer"], "custom deployment")
        self.assertEqual(result["notification"]["state"], "queued")
        self.app.idle(self.session)
        self.assertEqual(self.pending()["items"], [])
        self.assertIn("custom deployment", json.dumps(self.app.history(self.session)))
        self.turn(
            f"saved = await questions.get({item['value']['id']!r})\nassert saved.answer == 'custom deployment'\nassert saved.status == 'answered'"
        )

    def test_pending_survives_restart_and_can_be_dismissed(self):
        item = self.ask()
        self.app.restart()
        self.assertEqual(self.pending()["items"][0], item)
        result = self.action(item, action="cancel")
        self.assertEqual(result["resource"]["value"]["status"], "cancelled")
        self.assertEqual(self.pending()["items"], [])

    def test_invalid_answer_and_stale_or_racing_answers_are_rejected(self):
        item = self.ask()
        with self.assertRaises(HTTPError) as error:
            self.action(item, answer="")
        self.assertEqual(error.exception.code, 409)
        error.exception.close()
        self.assertEqual(self.pending()["items"][0], item)

        def answer(value):
            try:
                return self.action(item, answer=value)["resource"]["value"]["answer"]
            except HTTPError as error:
                status = error.code
                error.close()
                return status

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            replies = list(pool.map(answer, ["staging", "production"]))
        self.assertEqual(sum(isinstance(x, str) for x in replies), 1, replies)
        self.assertTrue(
            any(x in (409, 412) for x in replies if isinstance(x, int)), replies
        )
        with self.assertRaises(HTTPError) as error:
            self.action(item)
        self.assertEqual(error.exception.code, 412)
        error.exception.close()

    def test_origin_scoping_and_model_cannot_answer(self):
        item = self.ask()
        other = self.app.session()
        self.turn(
            f"try:\n    await questions.get({item['value']['id']!r})\nexcept QuestionError:\n    pass\nelse:\n    raise AssertionError('foreign question leaked')\nassert await questions.list() == []",
            session=other,
        )
        self.turn(
            "assert not hasattr(questions, 'answer')\nawait questions.cancel(q.id)\nassert await questions.list() == []"
        )
        self.assertEqual(self.pending()["items"], [])

    def test_authentication_etag_and_disabled_namespace(self):
        item = self.ask()
        with self.assertRaises(HTTPError) as error:
            self.app.api(self.route, headers={"Authorization": "Bearer wrong"})
        self.assertEqual(error.exception.code, 401)
        error.exception.close()
        url = item["url"].replace("?", "/answer?", 1)
        with self.assertRaises(HTTPError) as error:
            self.app.api(url, {"answer": "staging"}, method="POST")
        self.assertEqual(error.exception.code, 428)
        error.exception.close()
        self.assertEqual(self.pending()["items"][0], item)
        self.app.write_extensions({"enabled": {"questions": False}})
        self.app.restart()
        self.turn(
            "assert 'ask_user' not in globals()\nassert 'questions' not in globals()"
        )

    def test_validation_and_pending_bound(self):
        self.turn("""
for question, options in [('', []), ('x' * 4097, []), ('valid', ['x'] * 17), ('valid', [''])]:
    try:
        await ask_user(question, options=options)
    except QuestionError:
        pass
    else:
        raise AssertionError('invalid question accepted')
for i in range(32):
    await ask_user(f'question {i}')
try:
    await ask_user('overflow')
except QuestionError:
    pass
else:
    raise AssertionError('inbox cap ignored')
assert len(await questions.list()) == 32
""")
        self.assertEqual(len(self.pending()["items"]), 32)
