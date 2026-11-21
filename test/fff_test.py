"""Native FFF integration through the production daemon RPC and stdin boundary.

Set ALBEDO_PYTHON_SOURCE to upstream's python/ directory and
ALBEDO_FFF_COMMAND to a worker launcher when testing outside a packaged kernel.
"""

import asyncio
import importlib.util
import os
import json
import re
import shlex
import shutil
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from typing import Any

CORE = os.environ.get("ALBEDO_FFF_SOURCE") or os.environ.get("ALBEDO_PYTHON_SOURCE")
if CORE:
    sys.path.insert(0, CORE)

SOURCE = (
    Path(os.environ["ALBEDO_FFF_SOURCE"]) / "albedo_plugins/files.py"
    if os.environ.get("ALBEDO_FFF_SOURCE")
    else Path(__file__).resolve().parents[1]
    / "src/server/python/albedo_plugins/files.py"
)
spec = importlib.util.spec_from_file_location("fff_files_tested", SOURCE)
assert spec is not None and spec.loader is not None
module: Any = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


ERLANG = os.environ.get("ALBEDO_FFF_ERLANG") or str(
    Path(__file__).resolve().parents[1]
    / "src/server/extensions/files/src/albedo_fff.erl"
)


class DaemonRpc:
    """Test host bridge to the unchanged production Erlang registry and worker."""

    async def start(self, directory):
        self.directory = directory
        # The registry's search timeout for the next calls.
        self.timeout_ms = 30_000
        self.launcher = directory / "albedo-fff"
        command = os.environ.get("ALBEDO_FFF_COMMAND") or shutil.which("albedo-fff")
        if not command:
            raise RuntimeError("FFF runtime missing for integration tests")
        self.command = shlex.split(command)
        self.configure(self.command)
        stub = directory / "kernel_environment.erl"
        stub.write_text(
            "-module('albedo@kernel@environment'). -export([clean/0]). "
            "clean() -> []."
        )
        bridge = directory / "bridge.escript"
        bridge.write_text("""#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
main([Source, Stub]) ->
    {ok, Environment, StubCode} = compile:file(Stub, [binary]),
    {module, Environment} = code:load_binary(Environment, Stub, StubCode),
    {ok, albedo_fff, Code} = compile:file(Source, [binary]),
    {module, albedo_fff} = code:load_binary(albedo_fff, Source, Code),
    loop().
loop() ->
    case io:get_line(standard_io, "") of
        eof -> halt(0);
        Line ->
            [Timeout, Args] = json:decode(list_to_binary(Line)),
            Result = case albedo_fff:search(local, [], none, Args, Timeout) of
                {ok, Value} -> #{ok => true, value => json:decode(Value)};
                {error, Why} -> #{ok => false, error => Why}
            end,
            io:put_chars([json:encode(Result), "\n"]),
            loop()
    end.
""")
        escript = shutil.which("escript")
        if escript is None:
            raise RuntimeError(
                "Erlang escript missing for production FFF integration tests"
            )
        self.process = await asyncio.create_subprocess_exec(
            escript,
            str(bridge),
            ERLANG,
            str(stub),
            env={
                **os.environ,
                "PATH": str(directory),
                "HOME": str(directory),
                "XDG_CACHE_HOME": str(directory / "cache"),
            },
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=16 * 1024 * 1024,
        )
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self.stdin = self.process.stdin
        self.stdout = self.process.stdout
        self.stderr = self.process.stderr
        self.lock = asyncio.Lock()

    def configure(self, command):
        self.launcher.write_text(
            f"#!{sys.executable}\nimport os\nos.execv({command[0]!r}, {command!r} + __import__('sys').argv[1:])\n"
        )
        self.launcher.chmod(0o700)

    async def __call__(self, method, payload):
        assert method == "files.fff"
        async with self.lock:
            self.stdin.write((json.dumps([self.timeout_ms, payload]) + "\n").encode())
            await self.stdin.drain()
            line = await asyncio.wait_for(self.stdout.readline(), 35)
            if not line:
                raise RuntimeError((await self.stderr.read()).decode())
            result = json.loads(line)
            if not result["ok"]:
                raise ValueError(result["error"])
            return result["value"]

    async def close(self):
        self.stdin.close()
        await asyncio.wait_for(self.process.wait(), 5)


class FffTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
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
        self.rpc_temp = tempfile.TemporaryDirectory()
        self.rpc = DaemonRpc()
        await self.rpc.start(Path(self.rpc_temp.name))
        module._fff = module._FFF(self.rpc)
        self.files = module.Files()

    async def asyncTearDown(self):
        await self.files.close()
        await self.rpc.close()
        self.rpc_temp.cleanup()
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

    async def test_escaped_characters_survive_the_query_rewrite(self):
        target = self.root / "escaped.txt"
        target.write_text('* lead\na/b\nit\'s\nsay "hi"\n7 items\n')
        (self.root / "hex.txt").write_text("a\\x2fb\n")
        # A literal needle starting with a quantifier used to be handed to FFF
        # as a query beginning `\*`, which FFF refuses as an invalid regex.
        rows = await self.files.find("* lead", str(target), literal=True)
        self.assertEqual([row.line for row in rows], [1])
        # An escaped separator means the character. The old rewrite turned
        # `\/` into a literal backslash followed by `\x2f`.
        for pattern, line in ((r"a\/b", 2), (r"it\'s", 3), (r'\"hi\"', 4)):
            with self.subTest(pattern=pattern):
                rows = await self.files.find(pattern, str(target))
                self.assertEqual([row.line for row in rows], [line])
        self.assertEqual(
            [row.path for row in await self.files.find(r"a\/b", str(self.root))],
            [str(target)],
        )
        # Escapes that carry regex meaning are left alone.
        self.assertEqual(
            [row.line for row in await self.files.find(r"\d items", str(target))],
            [5],
        )
        words = self.root / "words.txt"
        words.write_text("<word> here\nwordy\n")
        self.assertEqual(
            [row.line for row in await self.files.find(r"\<wor", str(words))],
            [1, 2],
        )

    async def test_wildcard_paths_match_case_sensitively(self):
        # `files.paths` wildcards are exact globs: case-sensitive, like `glob=`
        # and `files.ls(pattern=)`.
        self.assertEqual(await self.files.paths("*.TXT", str(self.root)), [])
        self.assertEqual(await self.files.paths("SRC/*.txt", str(self.root)), [])
        self.assertEqual(
            set(await self.files.paths("*.txt", str(self.root))),
            {
                str(self.root / "root.txt"),
                str(self.root / "src/main.txt"),
                str(self.root / "src/nested/deep.txt"),
            },
        )

    async def test_non_ascii_whitespace_is_searched_as_itself(self):
        target = self.root / "spaces.txt"
        target.write_text("x\u00a0y\nx y\nx\u2009y\nx\u2028y\n")
        # FFF collapses non-ASCII whitespace into a space, so a no-break space
        # needle used to match the ASCII-space line instead of its own.
        for needle, line in (("x\u00a0y", 1), ("x\u2009y", 3), ("x\u2028y", 4)):
            with self.subTest(needle=needle):
                rows = await self.files.find(needle, str(target), literal=True)
                self.assertEqual([row.line for row in rows], [line])
        rows = await self.files.find("x y", str(target), literal=True)
        self.assertEqual([row.line for row in rows], [2])
        # An escaped no-break space in a regex means the character too.
        # After an escaped backslash it stays a plain no-break space.
        for pattern, lines in (("x\\\u00a0y", [1]), ("x\\\\\u00a0", [])):
            with self.subTest(pattern=pattern):
                rows = await self.files.find(pattern, str(target))
                self.assertEqual([row.line for row in rows], lines)

    async def test_external_changes_edits_deletion_and_index_reuse(self):
        await self.files.paths(path=str(self.root))
        worker_pid = module._fff.worker_pid
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
        self.assertEqual(module._fff.worker_pid, worker_pid)

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

    async def test_missing_runtime_and_startup_timeout(self):
        # A new registry has no live port that could mask a missing executable.
        await self.rpc.close()
        await self.rpc.start(Path(self.rpc_temp.name))
        self.rpc.launcher.unlink()
        with self.assertRaisesRegex(ValueError, "runtime missing"):
            await self.files.paths(path=str(self.root))
        self.rpc.configure(
            [sys.executable, "-c", "import sys; sys.stdin.buffer.read()"]
        )
        self.rpc.timeout_ms = 0
        with self.assertRaisesRegex(ValueError, "invalid FFF arguments"):
            await self.files.paths(path=str(self.root))
        self.rpc.timeout_ms = 1500
        with self.assertRaisesRegex(ValueError, "request timed out"):
            await self.files.paths(path=str(self.root))
        self.rpc.timeout_ms = 30_000
        self.rpc.configure(self.rpc.command)
        self.assertTrue(await self.files.paths(path=str(self.root)))

    async def test_bounded_root_eviction(self):
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

    async def test_requires_daemon_rpc_without_starting_a_kernel_worker(self):
        with (
            patch(
                "albedo_plugins.run.start",
                side_effect=AssertionError("per-kernel worker started"),
            ),
            self.assertRaisesRegex(RuntimeError, "daemon RPC unavailable"),
        ):
            await module._FFF().request({"op": "paths"})

    async def test_remote_target_is_forwarded_without_mutating_payload(self):
        seen = []

        async def host(method, payload):
            seen.append((method, payload))
            return {"workerPid": 42, "items": []}

        with patch.dict(os.environ, {"ALBEDO_REMOTE_TARGET": "local"}):
            adapter = module._FFF(host)
        payload = {"op": "paths"}
        self.assertEqual(await adapter.request(payload), {"items": []})
        self.assertEqual(seen, [("files.fff", {"op": "paths", "_fff_target": "local"})])
        self.assertEqual(payload, {"op": "paths"})
        self.assertEqual(adapter.worker_pid, 42)


class GlobCharacterClassTests(unittest.TestCase):
    """Glob classes follow shell member rules and never reach the worker invalid."""

    def matches(self, pattern, name):
        return re.fullmatch(module._path_regex(pattern), name) is not None

    def test_class_members_follow_shell_rules(self):
        self.assertTrue(self.matches("[]]", "]"))
        self.assertFalse(self.matches("[]]", "a"))
        self.assertTrue(self.matches("[]a]", "]"))
        self.assertTrue(self.matches("[]a]", "a"))
        self.assertFalse(self.matches("[]a]", "b"))
        self.assertTrue(self.matches("[!]]", "a"))
        self.assertFalse(self.matches("[!]]", "]"))

    def test_negated_class_stays_inside_one_segment(self):
        self.assertFalse(self.matches("0[!0]0", "0/0"))
        self.assertTrue(self.matches("0[!0]0", "040"))

    def test_escapes_inside_a_class_are_refused(self):
        for pattern in ("[\\d]", "[a\\-z]", "[{]"):
            with self.subTest(pattern=pattern):
                with self.assertRaisesRegex(
                    ValueError, "braces and escapes are unsupported"
                ):
                    module._path_regex(pattern)

    def test_class_patterns_stay_compilable(self):
        for pattern in ("[]]", "[]a]", "[!]]", "[[]", "[a-z]", "[!a-z]", "[a-]"):
            with self.subTest(pattern=pattern):
                re.compile(module._path_regex(pattern))
        for pattern in ("[9-0]", "[z-a]"):
            with self.subTest(pattern=pattern):
                with self.assertRaisesRegex(ValueError, "invalid glob character class"):
                    module._path_regex(pattern)



if __name__ == "__main__":
    unittest.main()
