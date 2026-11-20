"""Usage profile: lifetime totals, streaks and the longest turn on GET /usage.

Catches: a profile missing from the answer, totals narrowed by the window or
the provider filter, a streak that does not count today, a failed turn counted
as the longest, and the calendar's year refused by the day cap.
"""

import json
import unittest
import urllib.parse

from harness import Albedo, Provider, Reply, exclusive, latest_user, text

USAGE = {"input_tokens": 100, "output_tokens": 20}


def reply(request):
    if latest_user(request) == "fail this request":
        return Reply("error", "invalid request", status=400)
    return text("done", usage=USAGE)


# exclusive: it reads totals across the whole daemon
@exclusive
class UsageProfileTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(reply)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def usage(self, query=""):
        with self.app.api(f"/usage{query}") as response:
            return json.load(response)

    def test_profile_counts_every_call_whatever_the_window(self):
        empty = self.usage()["profile"]
        self.assertEqual(empty["lifetime_tokens"], 0)
        self.assertIsNone(empty["first_day"])
        self.assertIsNone(empty["longest_turn_ms"])
        for prompt in ("first", "second", "fail this request"):
            session = self.app.session(name="profile fixture")
            self.app.prompt(session, prompt).close()
            self.app.idle(session)
        year = self.usage("?days=371")
        self.assertEqual(len(year["days"]), 371)
        profile = year["profile"]
        self.assertEqual(profile["lifetime_tokens"], 240)
        self.assertEqual(profile["lifetime_calls"], 3)
        self.assertEqual(profile["active_days"], 1)
        self.assertEqual(profile["longest_streak_days"], 1)
        self.assertEqual(profile["current_streak_days"], 1)
        self.assertEqual(profile["peak_day_tokens"], 240)
        self.assertEqual(profile["first_day"], profile["peak_day"])
        self.assertEqual(profile["first_day"][:10], year["days"][-1]["start"][:10])
        self.assertIsInstance(profile["longest_turn_ms"], int)
        # A narrowed read keeps the whole profile.
        other = urllib.parse.quote("responses:https://elsewhere.example", safe="")
        self.assertEqual(self.usage(f"?days=1&provider={other}")["profile"], profile)
