"""Presentation changes retain original records and complete documentation."""

import asyncio
import json
import importlib
import os
from pathlib import Path
import sys
import unittest
from types import SimpleNamespace

sys.path.insert(
    0,
    os.environ.get(
        "ALBEDO_PYTHON_SOURCE",
        str(Path(__file__).resolve().parents[1] / "src/server/priv/python"),
    ),
)
import albedo_plugins

albedo_plugins.__path__.insert(
    0,
    str(
        Path(
            os.environ.get(
                "ALBEDO_PYTHON_SOURCE",
                Path(__file__).resolve().parents[1] / "src/server/priv/python",
            )
        )
        / "albedo_plugins"
    ),
)
setup = importlib.import_module("albedo_plugins.api_docs").setup
from albedo_plugins.skills import SkillPage


class ContextPresentationTests(unittest.TestCase):
    def test_documentation_read_returns_full_text_without_rewriting_it(self):
        original = 'full reference\n"quotes" and 秘密' * 10000
        calls = []

        async def host(method, args):
            calls.append((method, args))
            return original if method.endswith("read") else ["fixture"]

        docs = setup(SimpleNamespace(host=host, HostError=RuntimeError))["api_docs"]
        self.assertEqual(asyncio.run(docs.catalog()), ["fixture"])
        self.assertEqual(asyncio.run(docs.read("fixture")), original)
        self.assertEqual(
            calls, [("api_docs.catalog", {}), ("api_docs.read", {"topic": "fixture"})]
        )

    def test_page_print_is_readable_without_changing_mapping_or_json(self):
        values = dict(
            path="/skills/a/SKILL.md",
            encoding="utf-8",
            content='first\n"quoted" 秘密',
            next_offset=22,
            truncated=False,
            size=22,
        )
        page = SkillPage(values)
        self.assertEqual(dict(page), values)
        self.assertEqual(json.loads(json.dumps(page)), values)
        self.assertIn(values["content"], str(page))
        self.assertIn(values["path"], repr(page))
        self.assertNotIn("\\n", repr(page))
        self.assertNotIn("continued", str(page))
        page["truncated"] = True
        self.assertIn("continued at offset=22", str(page))
        self.assertEqual(page.content, values["content"])


if __name__ == "__main__":
    unittest.main()
