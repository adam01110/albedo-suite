"""Property tests for the suite's api_docs Python surface.

`api_docs.read` must return the complete reference text on every read, and
`api_docs.catalog` must list the daemon's topics, with unknown topics raised as
host errors. The fake host below answers from the documented contract.

Run with the pinned kernel Python plus this tree's plugin directory:

    PYTHONPATH=<upstream python>:src/server/python \
      python -m unittest test/api_docs_property_test.py -v
"""

from __future__ import annotations

import asyncio
import importlib
import unittest
from typing import Any

from hypothesis import given, settings, strategies as st

api_docs_module: Any = importlib.import_module("albedo_plugins.api_docs")
ApiDocs = api_docs_module.ApiDocs
ApiDocsSetup = api_docs_module.setup


class HostError(RuntimeError):
    """What `api.HostError` looks like from a plugin."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


class ApiDocsWrapperTests(unittest.IsolatedAsyncioTestCase):
    """`api_docs.read`/`catalog` keep the text while removing prompt duplication."""

    async def asyncSetUp(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []

    async def host(self, method: str, args: dict[str, object]) -> object:
        self.calls.append((method, args))
        if method == "api_docs.catalog":
            return ["agents", "mail"]
        reference = {"agents": "AGENTS REFERENCE", "mail": "MAIL REFERENCE"}
        if method == "api_docs.read":
            topic = str(args["topic"])
            if topic not in reference:
                raise HostError("unavailable")
            return reference[topic]
        raise HostError("unavailable")

    @settings(max_examples=100, deadline=None)
    @given(topic=st.sampled_from(["agents", "mail"]), repeats=st.integers(1, 3))
    def test_read_returns_complete_text_every_time(self, topic: str, repeats: int) -> None:
        async def drive() -> list[Any]:
            api = ApiDocs(self.host)
            return [await api.read(topic) for _ in range(repeats)]

        answers = asyncio.run(drive())
        for answer in answers:
            self.assertEqual(str(answer), {"agents": "AGENTS REFERENCE", "mail": "MAIL REFERENCE"}[topic])
            self.assertEqual(answer.content, str(answer))
            self.assertEqual(answer.text, str(answer))

    def test_catalog_lists_topics_and_errors_are_host_errors(self) -> None:
        async def drive() -> tuple[list[str], int]:
            api = ApiDocs(self.host)
            topics = await api.catalog()
            raised = 0
            for topic in ["browser", "", "AGENTS"]:
                try:
                    await api.read(topic)
                except HostError:
                    raised += 1
            bindings = ApiDocsSetup(type("Api", (), {"host": self.host, "HostError": HostError})())
            assert bindings["ApiDocsError"] is HostError
            assert isinstance(bindings["api_docs"], ApiDocs)
            return topics, raised

        topics, raised = asyncio.run(drive())
        self.assertEqual(topics, ["agents", "mail"])
        self.assertEqual(raised, 3)
        self.assertEqual(self.calls[0], ("api_docs.catalog", {}))


if __name__ == "__main__":
    unittest.main()
