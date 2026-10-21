"""Explicit formatter batch and ordinary final-streaming tests.

Run through scripts/test-e2e.py, which copies these cases and their fixtures
into the pinned upstream test tree and uses the supplied runtime binaries.
"""

import json
import shlex
from pathlib import Path
import sys
import threading
import time
import unittest

from harness import Albedo, Provider, alive, exclusive, operation_id, python, text


@exclusive
class FormatterE2ETests(unittest.TestCase):
    control: Path
    log: Path

    def setUp(self):
        self.replies = []
        self.seen = []

        def script(request):
            self.seen.append(request)
            index = len(self.seen) - 1
            return self.replies[min(index, len(self.replies) - 1)]

        self.provider = Provider(script, chunk_size=5)
        self.addCleanup(self.provider.close)

        def prepare(app):
            self.control = app.root / "formatter-control"
            self.control.mkdir()
            self.log = self.control / "runs.jsonl"
            fixture = Path(__file__).parent / "fixtures" / "formatter.py"
            enabled = self._testMethodName != "test_disabled_keeps_streamed_final"
            app.write_extensions(
                {
                    "enabled": {
                        "formatter": enabled,
                        "hooks": "stop_hook" in self._testMethodName,
                    },
                    "formatter": {
                        "formatters": {
                            "fake": {
                                "command": [
                                    sys.executable,
                                    str(fixture),
                                    str(self.control),
                                ]
                            }
                        },
                        "chains": {".txt": ["fake"]},
                        "timeoutMs": 45000,
                    },
                }
            )

        protocol = "chat_completions" if "chat" in self._testMethodName else "responses"
        self.app = Albedo(self.provider, protocol=protocol, prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def runs(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def wait_for(self, predicate, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail("fixture handshake did not complete")

    def history(self):
        return json.dumps(self.app.history(self.session))

    def finish(self, capture=False):
        # Subscribe before prompting and reconstruct actual live text deltas.
        live_text, events, errors = [], [], []
        ready = threading.Event()
        if capture:

            def reader():
                try:
                    with self.app.api(
                        f"/sessions/{self.session}?tail=0",
                        headers={"Accept": "text/event-stream"},
                    ) as response:
                        for line in response:
                            if not line.startswith(b"data: "):
                                continue
                            batch = json.loads(line[6:])
                            ready.set()
                            for event in batch["events"]:
                                events.append(event)
                                if event["type"] == "text":
                                    live_text.append(event["data"]["text"])
                                if event["type"] == "turn_completed":
                                    return
                except Exception as error:
                    errors.append(error)
                    ready.set()

            thread = threading.Thread(target=reader, daemon=True)
            thread.start()
            self.assertTrue(ready.wait(10), "HTTP subscriber did not attach")
            self.assertFalse(errors)
        self.app.prompt(self.session, "make the requested edit then finish").close()
        self.app.idle(self.session, timeout=35)
        if capture:
            thread.join(timeout=10)
            self.assertFalse(
                thread.is_alive(), "HTTP subscriber did not see completion"
            )
            self.assertFalse(errors)
            replay = json.dumps(self.app.stream_page(self.session))
            self.live_text = "".join(live_text)
            self.live_events = events
            return (
                self.live_text + "\nLIVE\n" + json.dumps(events) + "\nREPLAY\n" + replay
            )
        return ""

    def assert_final(self, accepted, rejected=()):
        history = self.history()
        self.assertIn(accepted, history)
        for candidate in rejected:
            self.assertNotIn(candidate, history)
        return history

    def test_intermediate_invalid_edit_is_not_formatted_and_paths_are_isolated(self):
        other = self.app.workspace / "unrelated.txt"
        other.write_text(" untouched  ")
        escaped = self.app.root / "outside.txt"
        escaped.write_text(" outside  ")
        self.replies = [
            python("files.write('note.txt', 'BAD incomplete')"),
            python(
                f"import pathlib\nassert not pathlib.Path({str(self.log)!r}).exists()\n"
                "files.edit('note.txt', 'BAD incomplete', ' valid  ')\nprint(await files.check())"
            ),
            text("INVALID_REGENERATED_FINAL"),
        ]
        self.finish()
        self.assert_final("INVALID_REGENERATED_FINAL")
        runs = self.runs()
        self.assertEqual(len(runs), 1, runs)
        self.assertEqual(runs[0]["input"], " valid  ")
        self.assertNotEqual(Path(runs[0]["path"]), self.app.workspace / "note.txt")
        self.assertEqual((self.app.workspace / "note.txt").read_text(), "valid\n")
        self.assertEqual(other.read_text(), " untouched  ")
        self.assertEqual(escaped.read_text(), " outside  ")

    def test_chat_explicit_changed_bytes_preserve_live_http_and_replay(self):
        self.check_changed_bytes_in_live_http_and_replay()

    def test_responses_explicit_changed_bytes_preserve_live_http_and_replay(self):
        self.check_changed_bytes_in_live_http_and_replay()

    def check_changed_bytes_in_live_http_and_replay(self):
        self.replies = [
            python("files.write('note.txt', ' raw  ')\nprint(await files.check())"),
            text("CHECKED_STREAMED_FINAL"),
        ]
        wire = self.finish(capture=True)
        self.assert_final("CHECKED_STREAMED_FINAL")
        self.assertIn("CHECKED_STREAMED_FINAL", wire)
        self.assertEqual(len(self.runs()), 1)
        self.assertEqual(len(self.seen), 2)
        self.assertEqual(self.live_text, "CHECKED_STREAMED_FINAL")
        self.assertNotIn("formatter/pre-final", wire)
        feedback = json.dumps(self.seen[-1])
        self.assertIn("changed_paths", feedback)
        self.assertIn("note.txt", feedback)

    def test_failure_feedback_allows_agent_repair_then_final(self):
        self.replies = [
            python("files.write('note.txt', 'BAD')\nprint(await files.check())"),
            python(
                "files.edit('note.txt', 'BAD', 'fixed\\n')\nprint(await files.check())"
            ),
            text("REPAIRED_FINAL"),
        ]
        self.finish()
        self.assert_final("REPAIRED_FINAL")
        self.assertIn("FORMATTER_FIXTURE_BAD", json.dumps(self.seen[1]))
        self.assertEqual([r["input"] for r in self.runs()], ["BAD", "fixed\n"])
        self.assertEqual((self.app.workspace / "note.txt").read_text(), "fixed\n")

    def configure_stop_hook(self, continue_once=False):
        log = self.control / "stop-inputs.jsonl"
        script = self.control / "stop.py"
        script.write_text(
            "import json, pathlib, sys\n"
            f"log = pathlib.Path({str(log)!r})\n"
            "first = not log.exists()\n"
            "event = json.load(sys.stdin)\n"
            "event['file_text'] = pathlib.Path('note.txt').read_text()\n"
            "with log.open('a') as output:\n"
            "    output.write(json.dumps(event) + '\\n')\n"
            f"if first and {continue_once!r}:\n"
            "    print('STOP_CONTINUE', file=sys.stderr)\n"
            "    sys.exit(2)\n"
        )
        (self.app.home / "hooks.json").write_text(
            json.dumps(
                {
                    "hooks": {
                        "Stop": [
                            {
                                "matcher": "",
                                "hooks": [
                                    {
                                        "type": "command",
                                        "command": shlex.join(
                                            [sys.executable, str(script)]
                                        ),
                                        "timeout": 5,
                                    }
                                ],
                            }
                        ]
                    }
                }
            )
        )
        return log

    def test_stop_hook_sees_only_repaired_accepted_final(self):
        log = self.configure_stop_hook()
        self.replies = [
            python("files.write('note.txt', 'BAD')\nprint(await files.check())"),
            python(
                "files.edit('note.txt', 'BAD', 'fixed\\n')\nprint(await files.check())"
            ),
            text("STOP_HOOK_ACCEPTED_FINAL"),
        ]
        wire = self.finish(capture=True)
        self.assert_final("STOP_HOOK_ACCEPTED_FINAL")
        self.assertIn("STOP_HOOK_ACCEPTED_FINAL", wire)
        self.assertEqual(len(self.seen), 3)
        self.assertEqual([r["input"] for r in self.runs()], ["BAD", "fixed\n"])
        stops = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(stops), 1, stops)
        self.assertEqual(stops[0]["last_assistant_message"], "STOP_HOOK_ACCEPTED_FINAL")
        self.assertEqual(stops[0]["file_text"], "fixed\n")
        self.assertFalse(stops[0]["stop_hook_active"])

    def test_stop_hook_continuation_preserves_native_semantics(self):
        log = self.configure_stop_hook(continue_once=True)
        self.replies = [
            python("files.write('note.txt', ' first  ')\nprint(await files.check())"),
            text("STOP_ACCEPTED_INTERIM"),
            python("files.write('note.txt', ' second  ')\nprint(await files.check())"),
            python("files.write('note.txt', ' third  ')\nprint(await files.check())"),
            text("STOP_ACCEPTED_FINAL"),
        ]
        self.finish()
        self.assert_final("STOP_ACCEPTED_FINAL")
        self.assertEqual(len(self.seen), 5)
        self.assertIn("STOP_CONTINUE", json.dumps(self.seen[2]))
        self.assertEqual(
            [r["input"] for r in self.runs()], [" first  ", " second  ", " third  "]
        )
        stops = [json.loads(line) for line in log.read_text().splitlines()]
        self.assertEqual(len(stops), 2, stops)
        self.assertEqual(
            [row["last_assistant_message"] for row in stops],
            ["STOP_ACCEPTED_INTERIM", "STOP_ACCEPTED_FINAL"],
        )
        self.assertEqual([row["file_text"] for row in stops], ["first\n", "third\n"])
        self.assertEqual((self.app.workspace / "note.txt").read_text(), "third\n")

    def test_repeated_explicit_failures_do_not_veto_final(self):
        self.replies = [
            python(
                "files.write('note.txt', 'BAD')\nfor _ in range(4):\n    result = await files.check()\n    assert not result['ok']\n    print(result)"
            ),
            text("CHECK_FAILURE_REPORTED"),
        ]
        wire = self.finish(capture=True)
        self.assertEqual(len(self.runs()), 4)
        self.assertEqual(len(self.seen), 2)
        self.assertIn("CHECK_FAILURE_REPORTED", self.history())
        self.assertEqual(self.live_text, "CHECK_FAILURE_REPORTED")
        self.assertNotIn("formatter/pre-final", wire)
        self.assertEqual((self.app.workspace / "note.txt").read_text(), "BAD")

    def test_no_implicit_check_or_final_interception(self):
        self.replies = [
            python("files.write('note.txt', ' raw  ')"),
            text("EXPLICIT_CHECK_NOT_REQUESTED"),
        ]
        wire = self.finish(capture=True)
        self.assertEqual(self.live_text, "EXPLICIT_CHECK_NOT_REQUESTED")
        self.assertEqual(len(self.seen), 2)
        self.assertEqual(self.runs(), [])
        self.assertEqual((self.app.workspace / "note.txt").read_text(), " raw  ")
        self.assertNotIn("formatter/pre-final", wire)

    def test_shell_formatting_is_reconciled_and_explicit_paths_enrolled(self):
        self.replies = [
            python(
                "from pathlib import Path\nfiles.write('note.txt', ' first  ')\nPath('note.txt').write_text('first\\n')\nPath('shell.txt').write_text(' shell  ')\na = await files.check()\nassert a['ok'] and a['formatting']['reconciled']\nb = await files.check(paths='shell.txt')\nassert b['ok'] and b['formatting']['changed']\nprint(a, b)"
            ),
            text("SHELL_CHECKED_FINAL"),
        ]
        self.finish()
        self.assertEqual(len(self.runs()), 2)
        self.assertEqual((self.app.workspace / "note.txt").read_text(), "first\n")
        self.assertEqual((self.app.workspace / "shell.txt").read_text(), "shell\n")

    def test_unsupported_and_shell_writes_do_not_start_formatter(self):
        self.replies = [
            python(
                "files.write('note.md', ' unchanged  ')\n"
                "job = run('" + sys.executable + "', '-c', "
                "\"from pathlib import Path; Path('shell.txt').write_text(' shell  ')\")\n"
                "await job\nassert job.exit_code == 0\nprint(await files.check())"
            ),
            text("NO_FORMAT_WORK_FINAL"),
        ]
        self.finish()
        self.assert_final("NO_FORMAT_WORK_FINAL")
        self.assertEqual(self.runs(), [])
        self.assertEqual((self.app.workspace / "shell.txt").read_text(), " shell  ")

    def test_already_formatted_file_accepts_first_candidate(self):
        self.replies = [
            python("files.write('note.txt', 'clean\\n')\nprint(await files.check())"),
            text("CLEAN_FINAL"),
        ]
        self.finish()
        self.assert_final("CLEAN_FINAL")
        self.assertEqual(len(self.runs()), 1)
        self.assertEqual(len(self.seen), 2)

    def test_cancel_blocked_formatter_reaps_process_and_never_applies_stage(self):
        (self.control / "block").touch()
        self.replies = [
            python("files.write('note.txt', ' original  ')\nawait files.check()"),
            text("CANCELLED_CANDIDATE"),
        ]
        input_id = operation_id()
        self.app.api(
            f"/sessions/{self.session}/inputs/{input_id}",
            {"kind": "message", "text": "edit then finish"},
            method="PUT",
        ).close()
        # The formatter has already changed its staged copy before this marker.
        self.wait_for(lambda: (self.control / "started").exists())
        pid = int((self.control / "started").read_text())
        self.assertTrue(alive(pid))
        self.assertEqual((self.app.workspace / "note.txt").read_text(), " original  ")
        self.app.api(f"/sessions/{self.session}/inputs/{input_id}/cancel", {}).close()
        self.wait_for(lambda: not alive(pid))
        self.app.idle(self.session)
        self.assertEqual((self.app.workspace / "note.txt").read_text(), " original  ")
        self.assertNotIn("CANCELLED_CANDIDATE", self.history())
        self.assertEqual(len(self.runs()), 1)

    def test_disabled_keeps_streamed_final(self):
        self.replies = [
            python(
                "files.write('note.txt', ' unformatted  ')\nassert (await files.check())['status'] == 'disabled'"
            ),
            text("DISABLED_STREAMED_FINAL"),
        ]
        wire = self.finish(capture=True)
        self.assert_final("DISABLED_STREAMED_FINAL")
        self.assertIn("DISABLED_STREAMED_FINAL", wire)
        self.assertEqual(self.live_text, "DISABLED_STREAMED_FINAL")
        self.assertEqual(self.runs(), [])
        self.assertEqual(
            (self.app.workspace / "note.txt").read_text(), " unformatted  "
        )
