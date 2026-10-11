"""Python surface tests; point PYTHONPATH at the integrated server's priv/python."""

import unittest
from types import SimpleNamespace

from albedo_api import Record
from albedo_plugins.mcp import Mcp, setup


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
        self.mcp = Mcp(self.host)

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
        raise AssertionError(method)

    async def test_setup_and_listing_never_load(self):
        api = SimpleNamespace(host=self.host, HostError=RuntimeError)
        bindings = await setup(api)
        self.assertFalse(hasattr(bindings["mcp"], "docs"))
        self.assertEqual(await self.mcp.tools(), [])
        servers = await self.mcp.servers()
        self.assertIsInstance(servers[0], Record)
        self.assertFalse(servers[0].loaded)
        self.assertEqual(
            [m for m, _ in self.calls], ["mcp.list", "mcp.list", "mcp.servers"]
        )

    async def test_tools_load_only_named_server(self):
        tools = await self.mcp.tools("docs")
        self.assertEqual(self.calls[0], ("mcp.load", {"server": "docs"}))
        self.assertEqual(tools[0].tool, "echo")
        self.assertNotIn("parameters", tools[0])

    async def test_describe_requests_schema_on_demand(self):
        schema = await self.mcp.describe("docs/echo")
        self.assertEqual(schema.parameters["type"], "object")
        self.assertEqual([m for m, _ in self.calls], ["mcp.load", "mcp.list"])

    async def test_call_loads_and_preserves_result_records(self):
        result = await self.mcp.call("docs/echo", {"message": "old"}, message="new")
        self.assertEqual(self.calls[0], ("mcp.load", {"server": "docs"}))
        self.assertEqual(
            self.calls[1],
            ("mcp.call", {"name": "docs/echo", "arguments": {"message": "new"}}),
        )
        self.assertEqual(result.content[0].text, "echoed")
        self.assertFalse(result.isError)

    async def test_unload_and_unknown_name(self):
        await self.mcp.load("docs")
        await self.mcp.unload("docs")
        self.assertEqual(await self.mcp.tools(), [])
        with self.assertRaises(LookupError):
            await self.mcp.describe("unknown_advertised_name")


if __name__ == "__main__":
    unittest.main()
