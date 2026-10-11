"""Native FFF integration through the production supervised job boundary.

Set ALBEDO_PYTHON_SOURCE to upstream's priv/python directory and
ALBEDO_FFF_COMMAND to a worker launcher when testing outside a packaged kernel.
"""

import asyncio
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

CORE = os.environ.get("ALBEDO_FFF_SOURCE") or os.environ.get("ALBEDO_PYTHON_SOURCE")
if CORE:
    sys.path.insert(0, CORE)
from albedo_plugins import run as jobs

SOURCE = (
    Path(os.environ["ALBEDO_FFF_SOURCE"]) / "albedo_plugins/files.py"
    if os.environ.get("ALBEDO_FFF_SOURCE")
    else Path(__file__).resolve().parents[1]
    / "src/server/priv/python/albedo_plugins/files.py"
)
spec = importlib.util.spec_from_file_location("fff_files_tested", SOURCE)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class Capture:
    def __init__(self):
        self.data = bytearray()
        self.seen = 0

    @property
    def retained(self):
        return len(self.data)

    def write_bytes(self, data):
        self.data.extend(data)
        self.seen += len(data)

    def write(self, text):
        self.write_bytes(text.encode())

    def tail(self, limit=65536):
        return bytes(self.data[-limit:])

    def read_bytes(self, offset, limit):
        return bytes(self.data[offset : offset + limit])

    def end_spill(self):
        pass


class FffTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        jobs.loop = asyncio.get_running_loop()
        jobs.capture_factory = lambda _: Capture()
        jobs.send = lambda _: None
        jobs.preview_limit = 65536
        module._fff = module._FFF()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        (self.root / "src/nested").mkdir()
        (self.root / ".git").mkdir()
        (self.root / ".gitignore").write_text("ignored.txt\n")
        (self.root / "ignored.txt").write_text("needle\n")
        (self.root / ".secret").write_text("needle\n")
        (self.root / "src/main.txt").write_text(
            "before\nneedle one\nneedle TWO\nafter\n"
        )
        (self.root / "src/nested/deep.txt").write_text("needle deep\n")
        (self.root / "root.txt").write_text("other\n")
        self.files = module.Files()

    async def asyncTearDown(self):
        await self.files.close()
        await jobs.close()
        self.temp.cleanup()

    async def test_content_context_counts_ignore_case_and_truncation(self):
        rows = await self.files.find("needle", str(self.root), literal=True, context=1)
        self.assertEqual(sum(not r.context for r in rows), 3)
        self.assertEqual(
            [(r.line, r.context) for r in rows if r.path.endswith("main.txt")],
            [(1, True), (2, False), (3, False), (4, True)],
        )
        limited = await self.files.find("needle", str(self.root), max_results=2)
        self.assertEqual(len(limited), 2)
        self.assertTrue(limited.truncated)
        insensitive = await self.files.find("two", str(self.root), case_sensitive=False)
        self.assertEqual(len(insensitive), 1)
        sensitive = await self.files.find("two", str(self.root))
        self.assertFalse(sensitive)
        self.assertIn("files searched", sensitive.note)
        self.assertIn("hidden files", sensitive.note)

    async def test_globs_root_relative_paths_and_fuzzy(self):
        self.assertFalse(hasattr(self.files, "fuzzy"))
        rows = await self.files.paths("src/*.txt", str(self.root))
        self.assertEqual(rows, [str(self.root / "src/main.txt")])
        recursive = await self.files.paths(path=str(self.root), glob="src/**/*.txt")
        self.assertEqual(
            set(recursive),
            {str(self.root / "src/main.txt"), str(self.root / "src/nested/deep.txt")},
        )
        rows = await self.files.find("needle", str(self.root), glob="src/*.txt")
        self.assertEqual(len(rows), 2)
        fuzzy = await self.files.paths("mn", str(self.root))
        self.assertEqual(fuzzy[0], str(self.root / "src/main.txt"))
        self.assertEqual(
            await self.files.paths("deep", str(self.root)),
            [str(self.root / "src/nested/deep.txt")],
        )
        (self.root / "src/root.txt").write_text("nested duplicate\n")
        for rooted_glob in ("/root.txt", "./root.txt"):
            self.assertEqual(
                await self.files.paths(path=str(self.root), glob=rooted_glob),
                [str(self.root / "root.txt")],
            )
        ordered = await self.files.paths(
            path=str(self.root), glob=["*.txt", "!src/**", "src/main.txt"]
        )
        self.assertEqual(
            set(ordered), {str(self.root / "root.txt"), str(self.root / "src/main.txt")}
        )

    async def test_external_changes_edits_deletion_and_index_reuse(self):
        await self.files.paths(path=str(self.root))
        job = module._fff.job
        self.files.write(str(self.root / "new.txt"), "brand new\n")
        self.assertEqual(
            len(await self.files.find("brand new", str(self.root), literal=True)), 1
        )
        self.files.edit(str(self.root / "new.txt"), "brand new", "replacement")
        self.assertEqual(len(await self.files.find("replacement", str(self.root))), 1)
        (self.root / "new.txt").write_text("external update\n")
        self.assertEqual(
            len(await self.files.find("external update", str(self.root), literal=True)),
            1,
        )
        (self.root / "new.txt").unlink()
        self.assertFalse(
            await self.files.find("external update", str(self.root), literal=True)
        )
        self.assertIs(module._fff.job, job)

    async def test_unsupported_flags_regex_and_missing_root(self):
        for flag in ("hidden", "ignored"):
            with self.assertRaisesRegex(ValueError, "unsupported"):
                await self.files.find("needle", str(self.root), **{flag: True})
        with self.assertRaisesRegex(ValueError, "Unsupported regex"):
            await self.files.find("(?=needle)", str(self.root))
        with self.assertRaises(FileNotFoundError):
            await self.files.paths(path=str(self.root / "absent"))
        with self.assertRaisesRegex(ValueError, "hidden=True"):
            await self.files.paths(path=str(self.root), hidden=True)
        for name in ("ignored.txt", ".secret"):
            with self.assertRaisesRegex(ValueError, "excluded from the FFF index"):
                await self.files.find("needle", str(self.root / name))

    async def test_close_death_missing_runtime_and_startup_timeout(self):
        await self.files.paths(path=str(self.root))
        directory = Path(module._fff.directory.name)
        job = module._fff.job
        await self.files.close()
        self.assertFalse(directory.exists())
        self.assertNotIn(job.id, jobs.active)
        await self.files.paths(path=str(self.root))
        await module._fff.job.stop()
        with self.assertRaisesRegex(RuntimeError, "worker died"):
            await self.files.paths(path=str(self.root))
        with (
            patch.dict(os.environ, {"ALBEDO_FFF_COMMAND": ""}),
            patch.object(module.shutil, "which", return_value=None),
        ):
            with self.assertRaisesRegex(RuntimeError, "runtime missing"):
                await self.files.paths(path=str(self.root))
        with (
            patch.dict(
                os.environ,
                {
                    "ALBEDO_FFF_COMMAND": f'{sys.executable} -c "import time; time.sleep(10)"'
                },
            ),
            patch.object(module, "SEARCH_TIMEOUT", 0.15),
        ):
            with self.assertRaises(asyncio.TimeoutError):
                await self.files.paths(path=str(self.root))
        self.assertIsNone(module._fff.job)
        self.assertIsNone(module._fff.directory)

    async def test_bounded_root_eviction_and_concurrent_requests(self):
        roots = []
        for n in range(6):
            root = self.root / f"project{n}"
            root.mkdir()
            (root / "note.txt").write_text(f"token{n}\n")
            roots.append(root)
        results = await asyncio.gather(
            *(self.files.find(f"token{n}", str(root)) for n, root in enumerate(roots))
        )
        self.assertEqual([len(rows) for rows in results], [1] * 6)
        self.assertEqual(len(await self.files.find("token0", str(roots[0]))), 1)
        payload = {
            **module._fff_scope(roots[0], None, False, 10),
            "op": "paths",
            "query": "",
            "name": None,
        }
        await module._fff.request(payload)
        reader, writer = await asyncio.open_unix_connection(module._fff.socket)
        import json

        writer.write(
            (
                json.dumps({**payload, "secret": module._fff.secret, "protocol": 99})
                + "\n"
            ).encode()
        )
        await writer.drain()
        reply = json.loads(await reader.readline())
        writer.close()
        await writer.wait_closed()
        self.assertFalse(reply["ok"])
        self.assertIn("protocol mismatch", reply["error"])

    async def test_large_corpus_native_offset_pagination(self):
        corpus = self.root / "large"
        corpus.mkdir()
        for n in range(1500):
            (corpus / f"module_{n:04}.py").write_text(f"native_token_{n:04}\n")
        root = str(corpus)
        early = str(corpus / "module_0000.py")
        late = str(corpus / "module_1499.py")
        for name, expected in (("module_0000.py", early), ("module_1499.py", late)):
            with self.subTest(name=name):
                rows = await asyncio.wait_for(
                    self.files.paths(path=root, glob=name), 10
                )
                self.assertEqual(rows, [expected])
                self.assertFalse(rows.truncated)
        self.assertEqual(
            await asyncio.wait_for(self.files.paths("absent", root), 10), []
        )
        all_paths = await asyncio.wait_for(
            self.files.paths(path=root, max_results=2000), 10
        )
        self.assertEqual(len(all_paths), 1500)
        self.assertEqual(len(set(all_paths)), 1500)
        self.assertFalse(all_paths.truncated)
        fuzzy = await asyncio.wait_for(
            self.files.paths("module", root, max_results=2000), 10
        )
        self.assertEqual(len(fuzzy), 1500)
        self.assertEqual(len(set(fuzzy)), 1500)
        for limit in (1, 50):
            with self.subTest(limit=limit):
                bounded_paths = await asyncio.wait_for(
                    self.files.paths(path=root, max_results=limit), 10
                )
                bounded_fuzzy = await asyncio.wait_for(
                    self.files.paths("module", root, max_results=limit), 10
                )
                self.assertEqual(bounded_paths, all_paths[:limit])
                self.assertEqual(bounded_fuzzy, fuzzy[:limit])
                self.assertTrue(bounded_paths.truncated)
                self.assertTrue(bounded_fuzzy.truncated)
        filtered_fuzzy = await asyncio.wait_for(
            self.files.paths("module", root, glob="module_1499.py"), 10
        )
        self.assertEqual(filtered_fuzzy, [late])
        named = await asyncio.wait_for(self.files.find("native_token_1499", late), 10)
        self.assertEqual(len(named), 1)
        self.assertEqual(named[0].path, late)
        (corpus / ".secret").write_text("hidden\n")
        with self.assertRaisesRegex(ValueError, "excluded from the FFF index"):
            await asyncio.wait_for(
                self.files.find("hidden", str(corpus / ".secret")), 10
            )

    async def test_regex_and_query_parser_metacharacters(self):
        target = self.root / "patterns.txt"
        target.write_text('aZZb\na/b\nfile*.txt\n#tag\n[abc]\nx\tY\n"quoted"\n')
        for pattern in ("a/b", "file*.txt", "#tag", "[abc]", "x\tY", '"quoted"'):
            with self.subTest(pattern=pattern):
                self.assertEqual(
                    len(await self.files.find(pattern, str(target), literal=True)), 1
                )
        self.assertEqual(len(await self.files.find("a.*b|#tag", str(target))), 4)

    async def test_multiple_roots_paging_literal_spaces_and_single_file(self):
        (self.root / "src/main.txt").write_text("phrase with spaces\n" * 300)
        rows = await self.files.find(
            "phrase with spaces",
            str(self.root / "src/main.txt"),
            literal=True,
            max_results=400,
        )
        self.assertEqual(len(rows), 300)
        self.assertFalse(rows.truncated)
        rows = await self.files.find(
            "phrase with spaces",
            [str(self.root / "src"), str(self.root / "root.txt")],
            literal=True,
            max_results=10,
        )
        self.assertEqual(len(rows), 10)
        self.assertTrue(rows.truncated)
        self.assertIn(
            "phrase with spaces",
            str(self.files.read(str(self.root / "src/main.txt"), limit=1)),
        )


if __name__ == "__main__":
    unittest.main()
