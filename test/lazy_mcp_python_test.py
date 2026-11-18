"""Python surface tests; point PYTHONPATH at the integrated server's priv/python."""

import importlib
import unittest
from types import SimpleNamespace
from typing import Any

from albedo_api import Record

mcp_module: Any = importlib.import_module("albedo_plugins.mcp")
Mcp, setup = mcp_module.Mcp, mcp_module.setup


class HostError(RuntimeError):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


class LazyMcpPythonTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = []
        self.operation = {
            "name": "mcp_docs_echo_hash",
            "server": "docs",
            "kind": "tool",
            "tool": "echo",
            "description": "untrusted description",
            "parameters": {
                "type": "object",
                "properties": {"message": {"type": "string"}},
            },
        }
        self.loaded = False
        self.mcp = Mcp(self.host, HostError)

    async def host(self, method, args):
        self.calls.append((method, args))
        if method == "mcp.servers":
            return [{"name": "docs", "loaded": self.loaded}]
        if method == "mcp.list":
            return [self.operation] if self.loaded else []
        if method == "mcp.load":
            self.loaded = True
            return [self.operation]
        if method == "mcp.unload":
            self.loaded = False
            return None
        if method == "mcp.call":
            return {"isError": False, "content": [{"type": "text", "text": "echoed"}]}
        if method == "editor_mcp.list":
            raise HostError("unavailable")
        raise AssertionError(method)

    async def test_setup_and_listing_never_load(self):
        api = SimpleNamespace(host=self.host, HostError=HostError)
        bindings = await setup(api)
        self.assertFalse(hasattr(bindings["mcp"], "docs"))
        self.assertEqual(await self.mcp.tools(), [])
        servers = await self.mcp.servers()
        self.assertIsInstance(servers[0], Record)
        self.assertFalse(servers[0].loaded)
        self.assertEqual(
            [m for m, _ in self.calls],
            [
                "mcp.list",
                "editor_mcp.list",
                "mcp.list",
                "editor_mcp.list",
                "mcp.servers",
            ],
        )

    async def test_tools_load_only_named_server(self):
        tools = await self.mcp.tools("docs")
        self.assertIn(("mcp.load", {"server": "docs"}), self.calls)
        self.assertEqual(tools[0].tool, "echo")

    async def test_describe_requests_schema_on_demand(self):
        schema = await self.mcp.describe("docs/echo")
        self.assertEqual(schema.parameters["type"], "object")
        self.assertIn(("mcp.load", {"server": "docs"}), self.calls)

    async def test_call_loads_and_preserves_result_records(self):
        result = await self.mcp.call("docs/echo", {"message": "old"}, message="new")
        self.assertIn(("mcp.load", {"server": "docs"}), self.calls)
        self.assertFalse(result.isError)

    async def test_unload_and_unknown_name(self):
        await self.mcp.load("docs")
        await self.mcp.unload("docs")
        self.assertEqual(await self.mcp.tools(), [])
        with self.assertRaises(LookupError):
            await self.mcp.describe("unknown_advertised_name")


def operation(server: str, tool: str, name: str) -> dict[str, object]:
    """One advertised operation, as `mcp.list` returns it."""
    return {
        "name": name,
        "server": server,
        "kind": "tool",
        "tool": tool,
        "description": "untrusted description",
        "parameters": {
            "type": "object",
            "properties": {"message": {"type": "string"}},
        },
    }


class Catalogue:
    """A fake host whose catalogue names every operation explicitly."""

    def __init__(self, operations: list[dict[str, object]]) -> None:
        self.operations = operations
        self.calls: list[tuple[str, dict[str, object]]] = []

    async def __call__(self, method: str, args: dict[str, object]) -> object:
        self.calls.append((method, args))
        if method == "mcp.list":
            return self.operations
        if method == "mcp.load":
            return [
                item for item in self.operations if item["server"] == args["server"]
            ]
        if method == "mcp.unload":
            return None
        if method == "mcp.call":
            for item in self.operations:
                if args["name"] in (item["name"], f"{item['server']}/{item['tool']}"):
                    return {
                        "isError": False,
                        "content": [{"type": "text", "text": item["name"]}],
                    }
            raise AssertionError(args)
        if method == "editor_mcp.list":
            raise HostError("unavailable")
        raise AssertionError(method)


class McpSetupTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.catalogue = Catalogue([operation("docs", "echo", "mcp_docs_echo_hash")])
        self.api = SimpleNamespace(host=self.catalogue, HostError=HostError)

    async def minted(self):
        return (await setup(self.api))["mcp"]

    async def test_setup_skips_colliding_servers(self):
        collisions = {
            "shared tool": [
                operation("my-server", "echo", "mcp_my_server_echo_aaa"),
                operation("my_server", "echo", "mcp_my_server_echo_bbb"),
            ],
            "disjoint tools": [
                operation("my-server", "echo", "mcp_my_server_echo_aaa"),
                operation("my_server", "search", "mcp_my_server_search_bbb"),
            ],
        }
        for name, collision in collisions.items():
            with self.subTest(name):
                self.catalogue.operations = [
                    *collision,
                    operation("docs", "echo", "mcp_docs_echo_hash"),
                ]
                mcp = await self.minted()
                self.assertFalse(hasattr(mcp, "my_server"))
                for item in collision:
                    result = await mcp.call(str(item["name"]))
                    self.assertEqual(result.content[0].text, item["name"])
                self.assertEqual(mcp.docs.name, "docs")


class EditorMcpTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = []
        self.editor = operation("editor", "echo", "editor_echo")
        self.failure = "unknown"

        async def host(method, args):
            self.calls.append((method, args))
            if method == "editor_mcp.list":
                return [self.editor]
            if method == "mcp.list":
                return []
            if method == "mcp.call":
                raise HostError(self.failure)
            if method == "editor_mcp.call":
                return {
                    "isError": False,
                    "content": [{"type": "text", "text": "editor"}],
                }
            raise AssertionError(method)

        self.mcp = (await setup(SimpleNamespace(host=host, HostError=HostError)))["mcp"]
        self.calls.clear()

    async def test_editor_discovery_and_minted_call_do_not_load_configured_servers(
        self,
    ):
        self.assertEqual((await self.mcp.tools("editor"))[0].tool, "echo")
        self.assertIn("parameters", await self.mcp.describe("editor/echo"))
        self.assertEqual((await self.mcp.editor.echo()).content[0].text, "editor")
        self.assertEqual((await self.mcp.call("editor/echo")).content[0].text, "editor")
        self.assertNotIn("mcp.load", [method for method, _ in self.calls])

    async def test_search_reads_live_catalog_without_loading(self):
        self.assertEqual((await self.mcp.search("echo"))[0].name, "editor/echo")
        self.assertNotIn("mcp.load", [method for method, _ in self.calls])

    async def test_real_call_failure_does_not_retry_on_editor_route(self):
        self.failure = "mcp"
        with self.assertRaises(HostError):
            await self.mcp.call("editor_echo")
        self.assertEqual([method for method, _ in self.calls], ["mcp.call"])


if __name__ == "__main__":
    unittest.main()
