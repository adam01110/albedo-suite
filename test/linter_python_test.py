"""Read-only linting through files.check(): parsing, scope, failures and conflicts."""

import asyncio
import importlib
import os
from pathlib import Path
import sys
import tempfile
import unittest
from typing import Any
from unittest.mock import patch

sys.path.insert(0, os.environ["ALBEDO_LINTER_SOURCE"])
import albedo_linter as linter

file_plugin: Any = importlib.import_module("albedo_plugins.files")
# Importing the plugin is what enables the linting stage in Files.check().
importlib.import_module("albedo_plugins.linter")

FIXTURE = str(Path(__file__).parent / "fixtures" / "linter-fixture.py")
PATTERN = r"^(?P<path>[^:\n]+):(?P<line>\d+):(?P<column>\d+): (?P<severity>\w+)\[(?P<code>[^\]]+)\]: (?P<message>.*)$"


def fake(mode, **extra):
    return {"command": [sys.executable, FIXTURE, mode], "pattern": PATTERN, **extra}


class LinterTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.fs = file_plugin.Files()

    async def asyncTearDown(self):
        linter._root = None
        linter._pending.clear()
        self.temp.cleanup()

    def configure(self, linters, chains, **extra):
        linter.configure(
            {"linters": linters, "chains": chains, **extra}, str(self.root)
        )

    def write(self, name="a.py", content="good\nbad line\n"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        self.fs.write(str(path), content)
        return path

    async def test_regex_findings_are_reported_for_the_target_only(self):
        self.configure({"fake": fake("regex")}, {".py": ["fake"]})
        path = self.write()
        result = await self.fs.check()
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["clean"])
        self.assertEqual(result["status"], "findings")
        self.assertEqual(result["linting"]["status"], "findings")
        self.assertEqual(
            result["linting"]["findings"],
            [
                {
                    "path": "a.py",
                    "line": 2,
                    "column": 1,
                    "severity": "warning",
                    "code": "no-bad",
                    "message": "bad word",
                    "source": "fake",
                }
            ],
        )
        self.assertEqual(result["pending"]["linting"], [])
        self.assertEqual(path.read_text(), "good\nbad line\n")

    async def test_clean_file_and_disabled_stages(self):
        self.configure({"fake": fake("regex")}, {".py": ["fake"]})
        self.write(content="good\n")
        result = await self.fs.check()
        self.assertEqual(
            (result["ok"], result["clean"], result["status"]), (True, True, "ok")
        )
        self.assertEqual(result["formatting"]["status"], "disabled")
        self.assertEqual(result["diagnostics"]["status"], "disabled")

    async def test_sarif_with_file_uri(self):
        self.configure(
            {
                "sarif": {
                    "command": [sys.executable, FIXTURE, "sarif"],
                    "format": "sarif",
                }
            },
            {".py": ["sarif"]},
        )
        self.write(content="bad\n")
        result = await self.fs.check()
        findings = result["linting"]["findings"]
        self.assertEqual(
            findings,
            [
                {
                    "path": "a.py",
                    "line": 1,
                    "column": 2,
                    "endLine": 1,
                    "severity": "error",
                    "code": "no-bad",
                    "message": "bad word",
                    "source": "sarif",
                }
            ],
        )

    async def test_stdin_and_exact_file_name_chains(self):
        self.configure(
            {"fake": fake("regex", stdin=True)},
            {"Dockerfile": ["fake"], ".py": ["fake"]},
        )
        path = self.write("Dockerfile", "bad\n")
        result = await self.fs.check(paths=[str(path)])
        self.assertEqual([f["line"] for f in result["linting"]["findings"]], [1])

    async def test_unmatched_files_are_not_clean(self):
        self.configure({"fake": fake("regex")}, {".py": ["fake"]})
        self.write("notes.txt", "bad\n")
        result = await self.fs.check()
        self.assertEqual(result["linting"]["status"], "unmatched")
        self.assertIsNone(result["clean"])
        self.assertEqual(result["pending"]["linting"], [])

    async def test_linter_runs_from_nearest_root_marker(self):
        self.configure(
            {"cwd": fake("cwd", rootMarkers=["selene.toml"])}, {".lua": ["cwd"]}
        )
        project = self.root / "project"
        project.mkdir()
        (project / "selene.toml").write_text("")
        self.write("project/src/init.lua", "x\n")
        self.write("loose.lua", "x\n")
        result = await self.fs.check()
        messages = {f["path"]: f["message"] for f in result["linting"]["findings"]}
        self.assertEqual(
            messages,
            {"project/src/init.lua": str(project), "loose.lua": str(self.root)},
        )

    async def test_failure_without_findings_keeps_the_path_pending(self):
        self.configure(
            {"fail": fake("fail"), "fake": fake("regex")},
            {".py": ["fail", "fake"]},
        )
        path = self.write()
        result = await self.fs.check()
        self.assertFalse(result["ok"])
        self.assertEqual(result["linting"]["status"], "failed")
        self.assertIn("fail exited 2: configuration error", result["linting"]["error"])
        self.assertEqual(result["pending"]["linting"], [str(path)])
        # Other linters still report.
        self.assertEqual(len(result["linting"]["findings"]), 1)

    async def test_ignore_exit_code(self):
        self.configure({"fail": fake("fail", ignoreExitCode=True)}, {".py": ["fail"]})
        self.write()
        result = await self.fs.check()
        self.assertEqual(result["linting"]["status"], "ok", result)

    async def test_timeout_kills_the_linter(self):
        self.configure({"slow": fake("sleep")}, {".py": ["slow"]}, timeoutMs=200)
        self.write()
        started = asyncio.get_running_loop().time()
        result = await self.fs.check()
        self.assertLess(asyncio.get_running_loop().time() - started, 5)
        self.assertEqual(result["linting"]["status"], "failed")
        self.assertIn("timed out", result["linting"]["error"])

    async def test_edit_during_linting_is_a_conflict(self):
        self.configure({"slow": fake("regex")}, {".py": ["slow"]})
        path = self.write()
        original = linter._run

        async def edit_then_run(item, target, cwd):
            outcome = await original(item, target, cwd)
            target.write_text("changed\n")
            return outcome

        with patch.object(linter, "_run", edit_then_run):
            result = await self.fs.check()
        self.assertFalse(result["ok"])
        self.assertIn(str(path), result["conflicts"])
        self.assertEqual(result["pending"]["linting"], [str(path)])

    def test_configuration_is_validated(self):
        cases = [
            ({"x": fake("regex")}, {".py": ["missing"]}, "unknown linters"),
            (
                {"x": {"command": ["x"], "pattern": "(?P<line>\\d+)"}},
                {},
                "line and message",
            ),
            (
                {
                    "x": {
                        "command": ["x"],
                        "pattern": "(?P<line>\\d+)(?P<message>.*)(?P<extra>.)",
                    }
                },
                {},
                "line and message",
            ),
            ({"x": {"command": ["x"]}}, {}, "needs a pattern"),
            ({"x": {"command": [], "format": "sarif"}}, {}, "command"),
            ({"x": {"command": ["x"], "format": "xml"}}, {}, "regex or sarif"),
            (
                {"x": {"command": ["x"], "format": "sarif", "args": []}},
                {},
                "unknown keys",
            ),
        ]
        for linters, chains, message in cases:
            with self.subTest(message), self.assertRaisesRegex(ValueError, message):
                self.configure(linters, chains)
        with self.assertRaisesRegex(ValueError, "timeoutMs"):
            self.configure({}, {}, timeoutMs=0)


if __name__ == "__main__":
    unittest.main()
