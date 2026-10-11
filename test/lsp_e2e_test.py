"""Explicit, local-only LSP operations through the real daemon.

Run through scripts/test-e2e.py with the pinned upstream runner and built package.
The provider, homes, workspaces and stdio language servers are all offline fixtures.
"""

import json
from pathlib import Path
import sys
import time
import unittest

from harness import LOOPBACK_REMOTE, Albedo, Provider, alive, exclusive, python, text


@exclusive
class LspE2ETests(unittest.TestCase):
    def setUp(self):
        self.code = None

        def script(request):
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
                        "args": [str(fixture), "--mode", name if name in ("death", "timeout") else "normal", "--log", str(control / "events.jsonl")],
                        "enabled": name != "disabled",
                        "include": ["**/*.nix"],
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
                    "enabled": {"lsp": self._testMethodName != "test_disabled_has_no_namespace"},
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
        self.app.prompt(self.session, "run the regression cell" if code else "hello").close()
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
            result = json.loads(outputs[-1])
            self.assertNotIn("error", result, outputs[-1])
            self.assertIn("LSP_CELL_OK", outputs[-1])
        self.assertIn("LSP_FINAL_OK", json.dumps(self.app.history(self.session)))
        return requests

    def events(self, name):
        log = self.control / name / "events.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines()]

    def starts(self, name):
        return [event["pid"] for event in self.events(name) if event["event"] == "START"]

    def assert_no_starts(self):
        self.assertFalse([pid for name in ("fake", "other", "disabled", "timeout", "death")
                          for pid in self.starts(name)])

    def stopped(self, markers):
        deadline = time.monotonic() + 10
        while any(alive(pid) for pid in markers):
            self.assertLess(time.monotonic(), deadline, "LSP process leaked")
            time.sleep(0.02)

    def reload(self):
        with self.app.api(f"/sessions/{self.session}/reload", {"target": "session"}) as response:
            result = json.load(response)
        self.assertEqual(result["session"]["state"], "applied")

    def selection(self, enabled):
        route = f"/sessions/{self.session}?view=configuration"
        with self.app.api(route) as response:
            json.load(response)
            etag = response.headers["ETag"]
        self.app.api(
            route,
            {"selection": {"extensions": {"lsp": enabled}}},
            method="PATCH",
            headers={"If-Match": etag},
        ).close()

    def test_setup_listing_and_file_edits_never_launch_or_gate_final(self):
        self.assert_no_starts()
        self.reload()
        self.turn("""
assert 'lsp' in globals()
servers = lsp.servers()
assert isinstance(servers, list)
assert all(s['state'] == 'unloaded' for s in servers)
assert {'fake', 'other', 'timeout', 'death'} <= {s['id'] for s in servers}
files.write('scratch.nix', 'BAD incomplete')
files.edit('scratch.nix', 'BAD incomplete', 'BAD still incomplete')
""")
        self.turn()
        self.assert_no_starts()
        self.assertEqual((self.app.workspace / "scratch.nix").read_text(), "BAD still incomplete")

    def test_diagnostics_refresh_after_edit_and_clear_stale_errors(self):
        self.turn("""
first = await lsp.diagnostics('note.nix', server='fake')
assert first['server'] == 'fake'
assert first['path'].endswith('note.nix')
assert first['diagnostics'], first
assert all(d.get('message') != 'stale' for d in first['diagnostics']), first
files.edit('note.nix', 'BAD', 'clean')
second = await lsp.diagnostics('note.nix', server='fake')
assert second['version'] > first['version'], (first, second)
assert second['diagnostics'] == [], second
third = await lsp.diagnostics('note.nix', server='fake')
assert third['version'] == second['version'], (second, third)
assert third['diagnostics'] == []
""")
        self.assertEqual(len(self.starts("fake")), 1)
        self.assertFalse(self.starts("other"))
        self.assertEqual((self.app.workspace / "note.nix").read_text(), "clean\n")
        events = self.events("fake")
        opened = [e["params"]["textDocument"] for e in events if e["event"] == "textDocument/didOpen"]
        changed = [e["params"] for e in events if e["event"] == "textDocument/didChange"]
        self.assertEqual(len(opened), 1)
        self.assertEqual(opened[0]["text"], "BAD\n")
        self.assertEqual(opened[0]["languageId"], "nix")
        self.assertEqual(len(changed), 1)
        self.assertEqual(changed[0]["contentChanges"], [{"text": "clean\n"}])
        self.assertGreater(changed[0]["textDocument"]["version"], opened[0]["version"])

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

    def test_outside_workspace_symlink_and_ineligible_server_are_rejected_before_launch(self):
        outside = self.app.root / "outside.nix"
        outside.write_text("BAD\n")
        (self.app.workspace / "escape.nix").symlink_to(outside)
        (self.app.workspace / "note.txt").write_text("BAD\n")
        self.turn(f"""
for path, server in [({str(outside)!r}, 'fake'), ('escape.nix', 'fake'),
                     ('note.txt', 'fake'), ('note.nix', 'disabled'),
                     ('note.nix', 'unknown')]:
    try:
        await lsp.diagnostics(path, server=server)
    except Exception as error:
        assert type(error).__name__ == 'LspError', (type(error), error)
    else:
        raise AssertionError('ineligible request accepted: ' + path + '/' + server)
""")
        self.assert_no_starts()
        self.assertEqual(outside.read_text(), "BAD\n")

    def test_navigation_returns_envelopes_without_modifying_document(self):
        (self.app.workspace / "note.nix").write_text('"😀" value\n')
        self.turn("""
hover = await lsp.hover('note.nix', 0, 5, server='fake')
definition = await lsp.definition('note.nix', 0, 5, server='fake')
references = await lsp.references('note.nix', 0, 5, server='fake', include_declaration=False)
symbols = await lsp.symbols('note.nix', server='fake')
for envelope in (hover, definition, references, symbols):
    assert envelope['server'] == 'fake', envelope
    assert envelope['path'].endswith('note.nix'), envelope
    assert isinstance(envelope['version'], int), envelope
    assert envelope['result'], envelope
assert len({e['version'] for e in (hover, definition, references, symbols)}) == 1
assert hover['result']['position'] == {'line': 0, 'character': 5}
""")
        self.assertEqual(len(self.starts("fake")), 1)
        self.assertFalse(self.starts("other"))
        self.assertEqual((self.app.workspace / "note.nix").read_text(), '"😀" value\n')

        events = self.events("fake")
        for method in ("textDocument/hover", "textDocument/definition", "textDocument/references"):
            params = next(event["params"] for event in events if event["event"] == method)
            self.assertEqual(params["position"], {"line": 0, "character": 5})
        references = next(event["params"] for event in events if event["event"] == "textDocument/references")
        self.assertFalse(references["context"]["includeDeclaration"])
        self.assertEqual(next(e["cwd"] for e in events if e["event"] == "START"), str(self.app.workspace))

    def test_server_death_and_startup_timeout_fail_without_reconnect_or_leak(self):
        self.turn("""
for server in ('death', 'timeout'):
    try:
        await lsp.diagnostics('note.nix', server=server)
    except Exception as error:
        assert type(error).__name__ == 'LspError', (type(error), error)
    else:
        raise AssertionError('broken server returned success: ' + server)
assert all(s['state'] != 'loaded' for s in lsp.servers())
""")
        for name in ("death", "timeout"):
            started = self.starts(name)
            self.assertEqual(len(started), 1)
            self.stopped(started)
        self.turn()
        for name in ("death", "timeout"):
            self.assertEqual(len(self.starts(name)), 1)
        self.assertFalse(self.starts("fake"))

    def test_remote_connection_does_not_expose_local_lsp_binding(self):
        self.turn(LOOPBACK_REMOTE + """
try:
    assert 'lsp' in globals()
    tools = await rem.tools()
    assert 'degraded' not in tools, tools
    assert 'lsp' not in tools['names'], tools
finally:
    await rem.close()
""")
        self.assert_no_starts()
