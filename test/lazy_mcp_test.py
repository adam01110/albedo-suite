"""Lazy MCP daemon tests.

Run through scripts/test-e2e.py, which copies these cases and their fixtures
into the pinned upstream test tree and uses the supplied runtime binaries.
"""

import json
import os
from pathlib import Path
import sys
import time
import unittest

from harness import Albedo, Provider, exclusive, python, text, alive

SERVER = Path(__file__).with_name("fake_mcp_server.py")
REMOTE = "REMOTE_SCHEMA_SENTINEL"


@exclusive
class LazyMcpTests(unittest.TestCase):
    def setUp(self):
        self.code = None
        self.lazy = self._testMethodName != "test_eager_default_is_unchanged"

        def script(request):
            if self.code is not None:
                code, self.code = self.code, None
                return python(code + "\nprint('LAZY_CELL_OK')")
            return text("done")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)

        def prepare(app):
            self.markers = app.root / "mcp-markers"
            self.markers.mkdir()
            servers = {}
            for name in ("fake", "other", "disabled", "excluded", "filtered", "broken"):
                control = self.markers / name
                control.mkdir()
                tools = [
                    {
                        "name": tool,
                        "description": REMOTE + " " + tool,
                        "inputSchema": {
                            "type": "object",
                            "properties": {"message": {"type": "string"}},
                        },
                    }
                    for tool in ("echo", "denied", "unlisted")
                ]
                (control / "tools").write_text(json.dumps(tools))
                wrapper = Path(__file__).parent / "fixtures" / "mcp-server.py"
                servers[name] = {
                    "type": "stdio",
                    "command": sys.executable,
                    "args": [str(wrapper), str(control), str(SERVER)],
                    "startupTimeoutMs": 10000,
                }
            servers["disabled"]["enabled"] = False
            servers["filtered"].update(
                enabledTools=["echo", "denied"], disabledTools=["denied"]
            )
            servers["broken"]["startupTimeoutMs"] = 1000
            (self.markers / "broken" / "delay").write_text("5")
            settings = {"mcp": {"servers": servers, "retryMs": 1}}
            if (
                self._testMethodName
                == "test_idle_cleanup_retains_schemas_and_reconnects_once"
            ):
                settings["mcp"]["idleTimeoutMs"] = 200
            if self.lazy:
                settings["mcp"]["lazy"] = True
            app.write_extensions(settings)

        self.app = Albedo(self.provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()
        self.selection({"extensions": {"mcp": True}, "mcp": {"excluded": False}})

    def selection(self, value):
        route = f"/sessions/{self.session}?view=configuration"
        with self.app.api(route) as response:
            json.load(response)
            etag = response.headers["ETag"]
        self.app.api(
            route, {"selection": value}, method="PATCH", headers={"If-Match": etag}
        ).close()

    def reload(self):
        with self.app.api(
            f"/sessions/{self.session}/reload", {"target": "session"}
        ) as response:
            result = json.load(response)
        self.assertEqual(result["session"]["state"], "applied")

    def starts(self, name):
        return sorted((self.markers / name).glob("pid-*"))

    def stopped(self, markers):
        deadline = time.monotonic() + 10
        while any(alive(int(path.name[4:])) for path in markers):
            self.assertLess(time.monotonic(), deadline, "MCP process leaked")
            time.sleep(0.02)

    def turn(self, code=None):
        self.code = code
        before = len(self.provider.requests)
        self.app.prompt(
            self.session, "run the regression cell" if code else "hello"
        ).close()
        self.app.idle(self.session, timeout=60)
        requests = [item["request"] for item in self.provider.requests[before:]]
        self.assertTrue(requests)
        if code is not None:
            self.assertEqual(len(requests), 2)
            outputs = [
                item["output"]
                for item in requests[-1]["input"]
                if item.get("type") == "function_call_output"
            ]
            self.assertTrue(outputs)
            result = json.loads(outputs[-1])
            self.assertNotIn("error", result, outputs[-1])
            self.assertIn("LAZY_CELL_OK", outputs[-1])
        if self.lazy:
            for request in requests:
                self.assertFalse(
                    any(
                        tool["name"].startswith("mcp_")
                        for tool in request.get("tools", [])
                    )
                )
                self.assertNotIn(REMOTE, request.get("instructions", ""))
                self.assertNotIn(REMOTE, json.dumps(request.get("tools", [])))
        return requests[0]

    def test_boot_listing_and_repeated_activity_never_dial(self):
        self.assertFalse(list(self.markers.glob("*/pid-*")))
        self.reload()
        baseline = self.turn("""
servers = await mcp.servers()
assert {'fake', 'other', 'filtered', 'broken'} <= {s.name for s in servers}
assert all(not s.loaded for s in servers)
assert await mcp.tools() == []
""")
        for _ in range(3):
            current = self.turn()
            self.assertEqual(current["tools"], baseline["tools"])
        self.assertFalse(list(self.markers.glob("*/pid-*")))

    def test_concurrent_first_load_unload_and_reload_are_explicit(self):
        baseline = self.turn()
        self.turn("""
import asyncio
results = await asyncio.gather(mcp.load('fake'), mcp.tools('fake'),
                               mcp.describe('fake/echo'),
                               mcp.call('fake/echo', message='concurrent'))
assert results[0] and results[1]
assert results[2].parameters['type'] == 'object'
assert 'concurrent' in results[3].content[0].text
assert [s.name for s in await mcp.servers() if s.loaded] == ['fake']
""")
        self.assertEqual(len(self.starts("fake")), 1)
        self.assertFalse(self.starts("other"))
        current = self.turn()
        self.assertEqual(current["tools"], baseline["tools"])
        self.assertEqual(current["instructions"], baseline["instructions"])
        old = self.starts("fake")
        self.turn("""
await mcp.unload('fake')
assert await mcp.tools() == []
assert all(not s.loaded for s in await mcp.servers())
""")
        self.stopped(old)
        self.turn("assert await mcp.tools('fake')")
        self.assertEqual(len(self.starts("fake")), 2)
        self.assertFalse(self.starts("other"))

    def test_describe_and_call_load_only_the_requested_server(self):
        self.turn("""
schema = await mcp.describe('fake/echo')
assert schema.parameters['type'] == 'object'
assert 'REMOTE_SCHEMA_SENTINEL' in schema.description
result = await mcp.call('other/echo', message='direct call')
assert 'direct call' in result.content[0].text
assert {s.name for s in await mcp.servers() if s.loaded} == {'fake', 'other'}
""")
        self.assertEqual(len(self.starts("fake")), 1)
        self.assertEqual(len(self.starts("other")), 1)
        self.assertFalse(self.starts("filtered"))

    def test_filters_and_disabled_or_excluded_servers_cannot_be_bypassed(self):
        self.turn("""
ops = await mcp.load('filtered')
assert [op.tool for op in ops] == ['echo']
for name in ('disabled', 'excluded'):
    for action in (lambda: mcp.load(name), lambda: mcp.tools(name),
                   lambda: mcp.describe(name + '/echo'),
                   lambda: mcp.call(name + '/echo', message='must not start')):
        try:
            await action()
        except Exception:
            pass
        else:
            raise AssertionError('ineligible server was accepted: ' + name)
for tool in ('denied', 'unlisted'):
    try:
        await mcp.call('filtered/' + tool, message='must be rejected')
    except Exception:
        pass
    else:
        raise AssertionError('filter bypass: ' + tool)
assert 'echo' in [op.tool for op in await mcp.tools()]
""")
        self.assertFalse(self.starts("disabled"))
        self.assertFalse(self.starts("excluded"))
        self.assertEqual(len(self.starts("filtered")), 1)

    def test_failed_load_can_retry_and_composition_teardown_closes_clients(self):
        self.turn("""
try:
    await mcp.load('broken')
except Exception:
    pass
else:
    raise AssertionError('held handshake should time out')
assert all(not s.loaded for s in await mcp.servers())
assert await mcp.tools() == []
""")
        failed = self.starts("broken")
        self.assertTrue(failed)
        self.stopped(failed)
        (self.markers / "broken" / "delay").unlink()
        self.turn("assert await mcp.load('broken')")
        self.assertEqual(len(self.starts("broken")), 2)
        active = self.starts("broken")
        self.selection({"extensions": {"mcp": False}})
        self.reload()
        self.stopped(active)
        self.selection({"extensions": {"mcp": True}})
        self.reload()
        self.turn("assert await mcp.tools() == []")
        self.assertEqual(len(self.starts("broken")), 2)

    def test_idle_cleanup_retains_schemas_and_reconnects_once(self):
        self.turn("""
import asyncio
schemas = await mcp.load('fake')
await asyncio.sleep(0.4)
servers = await mcp.servers()
fake = next(s for s in servers if s.name == 'fake')
assert fake.loaded and not fake.connected
assert await mcp.tools()
""")
        old = self.starts("fake")
        self.assertEqual(len(old), 1)
        self.stopped(old)
        self.turn("""
assert schemas == await mcp.load('fake')
result = await mcp.call('fake/echo', message='after idle')
assert 'after idle' in result.content[0].text
""")
        self.assertEqual(len(self.starts("fake")), 2)
        self.assertFalse(self.starts("other"))

    def test_eager_default_is_unchanged(self):
        request = self.turn()
        self.assertTrue(
            any(tool["name"].startswith("mcp_fake_echo_") for tool in request["tools"])
        )
        self.assertIn(REMOTE, request["instructions"])
        self.assertTrue(self.starts("fake"))
        self.assertTrue(self.starts("other"))
        self.assertFalse(self.starts("disabled"))
        self.assertFalse(self.starts("excluded"))
