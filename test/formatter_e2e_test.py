"""Explicit formatter trigger tests.

Run through scripts/test-e2e.py, which copies these cases and their fixtures
into the pinned upstream test tree and uses the supplied runtime binaries.
"""

import json
from pathlib import Path
import sys
import unittest

from harness import Albedo, Provider, exclusive, python, text


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
                    "enabled": {"formatter": enabled},
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

        self.app = Albedo(self.provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def runs(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def finish(self, final):
        self.app.prompt(self.session, "make the requested edit then finish").close()
        self.app.idle(self.session, timeout=35)
        self.assertIn(final, json.dumps(self.app.history(self.session)))

    def test_explicit_check_is_the_only_formatter_trigger(self):
        self.replies = [
            python(
                "files.write('note.txt', ' raw  ')\n"
                "files.write('note.md', ' unsupported  ')\n"
                "job = run('" + sys.executable + "', '-c', "
                "\"from pathlib import Path; Path('shell.txt').write_text(' shell  ')\")\n"
                "await job\nassert job.exit_code == 0\n"
                f"import pathlib\nassert not pathlib.Path({str(self.log)!r}).exists()\n"
                "print(await files.check())"
            ),
            python("files.write('note.txt', ' unchecked  ')"),
            text("EXPLICIT_TRIGGER_FINAL"),
        ]
        self.finish("EXPLICIT_TRIGGER_FINAL")
        self.assertEqual([run["input"] for run in self.runs()], [" raw  "])
        self.assertEqual(len(self.seen), 3)
        self.assertIn("changed_paths", json.dumps(self.seen[1]))
        workspace = self.app.workspace
        self.assertEqual((workspace / "note.txt").read_text(), " unchecked  ")
        self.assertEqual((workspace / "note.md").read_text(), " unsupported  ")
        self.assertEqual((workspace / "shell.txt").read_text(), " shell  ")

    def test_disabled_keeps_streamed_final(self):
        self.replies = [
            python(
                "files.write('note.txt', ' unformatted  ')\n"
                "assert (await files.check())['status'] == 'disabled'"
            ),
            text("DISABLED_STREAMED_FINAL"),
        ]
        self.finish("DISABLED_STREAMED_FINAL")
        self.assertEqual(self.runs(), [])
        self.assertEqual(
            (self.app.workspace / "note.txt").read_text(), " unformatted  "
        )
