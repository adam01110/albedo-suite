"""Explicit, local-only LSP operations through the real daemon.

Run through scripts/test-e2e.py with the pinned upstream runner and built package.
The provider, homes, workspaces and stdio language servers are all offline fixtures.
"""

import json
from pathlib import Path
import sys
import time
import unittest

from harness import Albedo, Provider, alive, exclusive, python, text


@exclusive
class LspE2ETests(unittest.TestCase):
    control: Path

    def setUp(self):
        self.code = None
        self.replies = []

        def script(_request):
            if self.replies:
                return self.replies.pop(0)
            if self.code is not None:
                code, self.code = self.code, None
                return python(code + "\nprint('LSP_CELL_OK')")
            return text("LSP_FINAL_OK")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)

        def prepare(app):
            self.control = app.root / "lsp-control"
            self.control.mkdir()
            (app.workspace / ".git").mkdir()
            (app.workspace / "note.nix").write_text("BAD\n")
            fixture = Path(__file__).parent / "fixtures" / "lsp-server.py"
            servers = []
            for name in ("fake", "other", "disabled", "timeout", "death"):
                control = self.control / name
                control.mkdir()
                servers.append(
                    {
                        "id": name,
                        "bin": sys.executable,
                        "args": [
                            str(fixture),
                            "--mode",
                            name if name in ("death", "timeout") else "normal",
                            "--log",
                            str(control / "events.jsonl"),
                        ],
                        "enabled": name != "disabled",
                        "include": (
                            ["**/*.nix"]
                            if name in ("fake", "disabled")
                            or (
                                name in ("timeout", "death")
                                and self._testMethodName
                                == "test_server_death_and_startup_timeout_fail_without_reconnect_or_leak"
                            )
                            else [f"**/*.{name}.nix"]
                        ),
                        "languageIdByExtension": {".nix": "nix"},
                        "cwd": "{root}",
                        "rootMarkers": [".git"],
                        "startupTimeoutMs": 1000 if name == "timeout" else 10000,
                        "diagnosticsWaitMs": 1000,
                        "initializationOptions": {},
                        "settings": {},
                    }
                )
            app.write_extensions(
                {
                    "enabled": {
                        "lsp": self._testMethodName != "test_disabled_has_no_namespace"
                    },
                    "lsp": {"version": 1, "servers": servers},
                }
            )

        self.app = Albedo(self.provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def turn(self, code=None):
        self.code = code
        before = len(self.provider.requests)
        self.app.prompt(
            self.session, "run the regression cell" if code else "hello"
        ).close()
        self.app.idle(self.session, timeout=30)
        requests = [entry["request"] for entry in self.provider.requests[before:]]
        self.assertTrue(requests)
        if code is not None:
            self.assertEqual(len(requests), 2)
            outputs = [
                entry["output"]
                for entry in requests[-1]["input"]
                if entry.get("type") == "function_call_output"
            ]
            self.assertTrue(outputs)
            result = json.loads(outputs[-1].split("\n", 1)[0])
            self.assertEqual(result["status"], "ok", outputs[-1])
            self.assertIn("LSP_CELL_OK", outputs[-1])
        self.assertIn("LSP_FINAL_OK", json.dumps(self.app.history(self.session)))
        return requests

    def events(self, name):
        log = self.control / name / "events.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines()]

    def starts(self, name):
        return [
            event["pid"] for event in self.events(name) if event["event"] == "START"
        ]

    def assert_no_starts(self):
        self.assertFalse(
            [
                pid
                for name in ("fake", "other", "disabled", "timeout", "death")
                for pid in self.starts(name)
            ]
        )

    def stopped(self, markers):
        deadline = time.monotonic() + 10
        while any(alive(pid) for pid in markers):
            self.assertLess(time.monotonic(), deadline, "LSP process leaked")
            time.sleep(0.02)

    def reload(self):
        with self.app.api(
            f"/sessions/{self.session}/reload", {"target": "session"}
        ) as response:
            result = json.load(response)
        self.assertEqual(result["session"]["state"], "applied")

    def selection(self, enabled):
        route = f"/sessions/{self.session}/configuration"
        with self.app.api(route) as response:
            json.load(response)
            etag = response.headers["ETag"]
        self.app.api(
            route,
            {"selection": {"extensions": {"lsp": enabled}}},
            method="PATCH",
            headers={"If-Match": etag},
        ).close()

    def test_setup_listing_and_unmatched_edits_never_launch(self):
        self.assert_no_starts()
        self.reload()
        self.turn("""
assert 'lsp' in globals()
servers = lsp.servers()
assert isinstance(servers, list)
assert all(s['state'] == 'unloaded' for s in servers)
assert {'fake', 'other', 'timeout', 'death'} <= {s['id'] for s in servers}
files.write('scratch.txt', 'BAD incomplete')
files.edit('scratch.txt', 'BAD incomplete', 'BAD still incomplete')
""")
        self.assert_no_starts()
        self.assertEqual(
            (self.app.workspace / "scratch.txt").read_text(), "BAD still incomplete"
        )

    def test_explicit_batch_reports_once_and_skips_unrelated_files(self):
        self.replies = [
            python("files.write('scratch.nix', 'BAD incomplete')"),
            python(
                "assert all(s['state'] == 'unloaded' for s in lsp.servers())\nfiles.edit('scratch.nix', 'BAD incomplete', 'BAD completed')\nprint(await files.check())\nassert (await files.check())['status'] == 'idle'"
            ),
            text("LSP_FINAL_OK"),
        ]
        before = len(self.provider.requests)
        self.app.prompt(self.session, "edit then finish").close()
        self.app.idle(self.session, timeout=30)
        requests = [entry["request"] for entry in self.provider.requests[before:]]
        self.assertEqual(len(requests), 3)
        feedback = json.dumps(requests[-1])
        self.assertIn("findings", feedback)
        self.assertIn("BAD completed", feedback)
        history = json.dumps(self.app.history(self.session))
        self.assertNotIn("REJECTED_LSP_CANDIDATE", history)
        self.assertIn("LSP_FINAL_OK", history)
        opened = [
            e["params"]["textDocument"]
            for e in self.events("fake")
            if e["event"] == "textDocument/didOpen"
        ]
        self.assertEqual([d["text"] for d in opened], ["BAD completed"])
        self.assertTrue(all(d["uri"].endswith("scratch.nix") for d in opened))
        self.assertFalse(self.starts("other"))

    def test_explicit_batch_checks_formatted_snapshot(self):
        control = self.app.root / "formatter-control"
        control.mkdir()
        fixture = Path(__file__).parent / "fixtures" / "formatter.py"
        self.app.write_extensions(
            {
                "enabled": {"formatter": True, "lsp": True},
                "formatter": {
                    "formatters": {
                        "fake": {
                            "command": [sys.executable, str(fixture), str(control)]
                        }
                    },
                    "chains": {".nix": ["fake"]},
                },
                "lsp": {
                    "version": 1,
                    "servers": [
                        {
                            "id": "fake",
                            "bin": sys.executable,
                            "args": [
                                str(
                                    Path(__file__).parent / "fixtures" / "lsp-server.py"
                                ),
                                "--log",
                                str(self.control / "fake/events.jsonl"),
                            ],
                            "include": ["**/*.nix"],
                            "languageIdByExtension": {".nix": "nix"},
                            "diagnosticsWaitMs": 1000,
                        }
                    ],
                },
            }
        )
        self.reload()
        self.replies = [
            python(
                "files.write('scratch.nix', '  clean  ')\nresult = await files.check()\nassert result['ok'] and result['formatting']['changed']\nprint(result)"
            ),
            text("LSP_FINAL_OK"),
        ]
        self.app.prompt(self.session, "edit then finish").close()
        self.app.idle(self.session, timeout=30)
        self.assertEqual((self.app.workspace / "scratch.nix").read_text(), "clean\n")
        opened = [
            e["params"]["textDocument"]
            for e in self.events("fake")
            if e["event"] == "textDocument/didOpen"
        ]
        self.assertEqual([d["text"] for d in opened], ["clean\n"])
        self.assertNotIn(
            "REJECTED_FORMAT_CANDIDATE", json.dumps(self.app.history(self.session))
        )

    def test_diagnostics_refresh_after_edit_and_clear_stale_errors(self):
        self.turn("""
await lsp.diagnostics('note.nix', server='fake')
files.edit('note.nix', 'BAD', 'clean')
await lsp.diagnostics('note.nix', server='fake')
""")
        self.assertEqual((self.app.workspace / "note.nix").read_text(), "clean\n")
        events = self.events("fake")
        opened = [
            e["params"]["textDocument"]
            for e in events
            if e["event"] == "textDocument/didOpen"
        ]
        changed = [
            e["params"] for e in events if e["event"] == "textDocument/didChange"
        ]
        self.assertEqual(len(opened), 1)
        self.assertEqual(opened[0]["text"], "BAD\n")
        self.assertEqual(len(changed), 1)
        self.assertEqual(changed[0]["contentChanges"], [{"text": "clean\n"}])

    def test_explicit_close_restarts_only_on_next_operation(self):
        self.turn("assert await lsp.diagnostics('note.nix', server='fake')")
        old = self.starts("fake")
        self.assertEqual(len(old), 1)
        self.turn("await lsp.close(server='fake')\nlsp.servers()")
        self.stopped(old)
        self.turn()
        self.assertEqual(len(self.starts("fake")), 1)
        self.turn("assert await lsp.diagnostics('note.nix', server='fake')")
        self.assertEqual(len(self.starts("fake")), 2)
        current = self.starts("fake")
        self.turn("await lsp.close()")
        self.stopped(current)
        self.assertFalse(self.starts("other"))
        # Idle expiry stops the server and restarts it only on the next operation.
        self.turn("""
import albedo_lsp
albedo_lsp.IDLE_SECONDS = 0.1
await lsp.diagnostics('note.nix', server='fake')
proc = lsp.clients['fake'].proc
await asyncio.wait_for(proc.wait(), 5)
await asyncio.gather(*lsp.idle_tasks)
assert next(s for s in lsp.servers() if s['id'] == 'fake')['state'] == 'unloaded'
await lsp.diagnostics('note.nix', server='fake')
assert lsp.clients['fake'].proc.pid != proc.pid
await lsp.close()
""")
        idle = self.starts("fake")[2:]
        self.assertEqual(len(idle), 2)
        self.stopped(idle)

    def test_composition_disable_reaps_server_and_reenable_is_lazy(self):
        self.turn("assert await lsp.diagnostics('note.nix', server='fake')")
        old = self.starts("fake")
        self.assertEqual(len(old), 1)
        self.selection(False)
        self.reload()
        self.stopped(old)
        self.turn("assert 'lsp' not in globals()")
        self.selection(True)
        self.reload()
        self.turn("assert 'lsp' in globals()\nassert lsp.servers()")
        self.assertEqual(len(self.starts("fake")), 1)

    def test_disabled_has_no_namespace(self):
        self.turn("assert 'lsp' not in globals()")
        self.assert_no_starts()

    def test_ineligible_server_and_unmatched_paths_are_rejected_before_launch(self):
        (self.app.workspace / "note.txt").write_text("BAD\n")
        self.turn("""
for path, server in [('note.txt', 'fake'), ('note.nix', 'disabled'),
                     ('note.nix', 'unknown')]:
    try:
        await lsp.diagnostics(path, server=server)
    except Exception as error:
        assert type(error).__name__ == 'LspError', (type(error), error)
    else:
        raise AssertionError('ineligible request accepted: ' + path + '/' + server)
""")
        self.assert_no_starts()

    def test_navigation_returns_envelopes_without_modifying_document(self):
        (self.app.workspace / "note.nix").write_text('"😀" value\n')
        self.turn("""
hover = await lsp.hover('note.nix', 0, 5, server='fake')
definition = await lsp.definition('note.nix', 0, 5, server='fake')
references = await lsp.references('note.nix', 0, 5, server='fake', include_declaration=False)
symbols = await lsp.symbols('note.nix', server='fake')
assert len({e['version'] for e in (hover, definition, references, symbols)}) == 1
""")
        self.assertEqual(
            (self.app.workspace / "note.nix").read_text(), '"😀" value\n'
        )

    def test_server_death_and_startup_timeout_fail_without_reconnect_or_leak(self):
        self.turn("""
for server in ('death', 'timeout'):
    try:
        await lsp.diagnostics('note.nix', server=server)
    except Exception as error:
        assert type(error).__name__ == 'LspError', (type(error), error)
    else:
        raise AssertionError('broken server returned success: ' + server)
""")
        for name in ("death", "timeout"):
            started = self.starts(name)
            self.assertEqual(len(started), 1)
            self.stopped(started)
        self.turn()
        for name in ("death", "timeout"):
            self.assertEqual(len(self.starts(name)), 1)
        self.assertFalse(self.starts("fake"))

