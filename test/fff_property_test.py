"""Property oracles for FFF-backed search.

Drives the real worker through the production Erlang registry (the same bridge
as test/fff_test.py) and compares `files.find` / `files.paths` against
independent Python models of the documented contract:

- a literal/regex find reports exactly the matching lines it is asked for,
  bounded by max_results, ordered by (path, line), with context only around
  reported matches and text that is a prefix of the real line;
- wildcard patterns and `glob=` keep exact, case-sensitive glob filtering, with
  `*`/`?` inside one segment and `**` crossing directory boundaries;
- a pattern without `/` is a glob over names at any depth;
- fuzzy path matching only returns existing files;
- results describe the current disk after create/modify/delete/rename, with a
  bounded number of cached root indexes;
- the stdio worker answers every frame it accepts exactly once, keeps its
  protocol version, and stays usable after malformed or oversized input.

Set ALBEDO_PYTHON_SOURCE to upstream's python/ directory and
ALBEDO_FFF_COMMAND to a worker launcher when testing outside a packaged kernel.
"""

import asyncio
import fnmatch
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

from hypothesis import HealthCheck, given, settings, strategies as st

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fff_test  # noqa: E402  (same loader, bridge and production registry)

module = fff_test.module
DaemonRpc = fff_test.DaemonRpc
SLOW = [HealthCheck.too_slow, HealthCheck.function_scoped_fixture]


# --- independent models -----------------------------------------------------

def glob_match(pattern, relpath):
    """Documented glob: a pattern without `/` matches names at any depth; one
    with `/` is anchored at the search root; `*` and `?` stay inside a segment;
    `**` spans zero or more segments; matching is case-sensitive."""
    if "/" not in pattern:
        return fnmatch.fnmatchcase(relpath.rsplit("/", 1)[-1], pattern)
    return _segments(pattern.split("/"), relpath.split("/"))


def _segments(parts, path):
    if not parts:
        return not path
    head, rest = parts[0], parts[1:]
    if head == "**":
        if not rest:
            return True
        return any(_segments(rest, path[index:]) for index in range(len(path) + 1))
    if not path:
        return False
    return fnmatch.fnmatchcase(path[0], head) and _segments(rest, path[1:])


def tree_files(root):
    """Every regular file under root, as sorted root-relative paths."""
    found = []
    for directory, _, names in os.walk(root):
        for name in names:
            found.append(str((Path(directory) / name).relative_to(root)))
    return sorted(found)


def tree_lines(root):
    """{(absolute path, line number): text} for every line of every file."""
    lines = {}
    for relative in tree_files(root):
        body = (Path(root) / relative).read_text(encoding="utf-8")
        for number, text in enumerate(body.split("\n"), 1):
            lines[(str(Path(root) / relative), number)] = (
                text[: -1] if text.endswith("\r") else text
            )
    return lines


_COMPILED = {}


def matches(line, pattern, literal, case_sensitive):
    if literal:
        return (
            pattern.lower() in line.lower()
            if case_sensitive is False
            else pattern in line
        )
    key = (pattern, case_sensitive is False)
    compiled = _COMPILED.get(key)
    if compiled is None:
        compiled = re.compile(pattern, re.IGNORECASE if case_sensitive is False else 0)
        _COMPILED[key] = compiled
    return compiled.search(line) is not None


def oracle_find(root, pattern, literal=True, case_sensitive=True, glob=None):
    """Sorted (relative path, line number) of every line the contract matches."""
    rows = []
    for relative in tree_files(root):
        if glob is not None and not glob_match(glob, relative):
            continue
        body = (Path(root) / relative).read_text(encoding="utf-8")
        lines = body.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        lines = [line[: -1] if line.endswith("\r") else line for line in lines]
        for number, line in enumerate(lines, 1):
            if matches(line, pattern, literal, case_sensitive):
                rows.append((relative, number))
    return rows


# --- generators -------------------------------------------------------------

LOWER_NAMES = ["alpha", "beta", "main", "notes", "a b", "\u00e9t\u00e9", "\u6f22\u5b57"]
LOWER_EXTENSIONS = ["", ".txt", ".md", ".py"]
MIXED_NAMES = LOWER_NAMES + ["UPPER", "ReadMe", "x"]
MIXED_EXTENSIONS = LOWER_EXTENSIONS + [".MD", ".Txt"]
LINE_TOKENS = [
    "needle",
    "NEEDLE",
    "Needle up",
    "n33dle",
    "nee dle",
    "a/b",
    "tab\there",
    "alpha beta",
    "#hash",
    "[br]",
    "star*",
    "q'uote d\"ouble",
    "\u03b1\u03b2\u03b3",
    "",
    "   ",
    "x" * 640,
]
DIRS = ["sub", "deep dir", "\u00fcn\u00ef"]


@st.composite
def trees(draw, names=MIXED_NAMES, extensions=MIXED_EXTENSIONS):
    """(relative path, lines) pairs: no hidden names and no ignore files.

    A file is written with `\n` endings, with `\r\n` endings, or without a
    final newline, since all three change the line model a search sees."""
    dirs = draw(st.lists(st.sampled_from(DIRS), max_size=2, unique=True))
    files = {}
    for _ in range(draw(st.integers(min_value=1, max_value=5))):
        word = draw(st.sampled_from(names))
        extension = draw(st.sampled_from(extensions))
        parent = draw(st.sampled_from([""] + dirs)) if dirs else ""
        relative = f"{parent}/{word}{extension}" if parent else f"{word}{extension}"
        lines = draw(st.lists(st.sampled_from(LINE_TOKENS), max_size=5))
        style = draw(st.sampled_from(["lf", "crlf", "no-final-newline"]))
        files[relative] = (lines, style)
    return files


LITERAL_PATTERNS = [
    "needle",
    "NEEDLE",
    "n33dle",
    "nee dle",
    "a/b",
    "tab\there",
    "star*",
    "[br]",
    "alpha",
    "alpha beta",
    "#hash",
    "\u03b1\u03b2\u03b3",
    "\u6f22\u5b57",
    "q'uote d\"ouble",
    "e",
]
# no `$`-anchored patterns: whether `$` matches before a CRLF line ending is
# an engine detail, not part of the search contract this suite models
REGEXES = ["nee.*le", "alpha|beta", "[Nn]eedle", r"n\d+dle", "nee+dl", "a.b",
           "^needle", "e{2}", "\\balpha\\b"]


def write_tree(root, files):
    for relative, (lines, style) in files.items():
        target = Path(root) / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        ending = "\r\n" if style == "crlf" else "\n"
        body = "".join(line + ending for line in lines)
        if style == "no-final-newline" and body:
            body = body[: -len(ending)]
        target.write_text(body, encoding="utf-8")


# --- async harness ----------------------------------------------------------

class Harness:
    """One event loop and one production registry bridge for the whole class."""

    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        self.directory = tempfile.mkdtemp(prefix="fff-property-rpc-")
        self.rpc = DaemonRpc()
        self.run(self.rpc.start(Path(self.directory)))
        module._fff = module._FFF(self.rpc)
        self.files = module.Files()

    def run(self, coro):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(300)

    async def stop(self):
        await self.files.close()
        await self.rpc.close()

    def shutdown(self):
        try:
            self.run(self.stop())
        finally:
            self.loop.call_soon_threadsafe(self.loop.stop)
            self.thread.join(10)
            self.loop.close()
            shutil.rmtree(self.directory, ignore_errors=True)


class PropertyTests(unittest.TestCase):
    harness = None

    @classmethod
    def setUpClass(cls):
        cls.harness = Harness()

    @classmethod
    def tearDownClass(cls):
        cls.harness.shutdown()

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="fff-property-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.cases = 0

    def case_root(self):
        """A fresh root per example, so a previous example's files cannot be
        seen by either the search or the oracle."""
        self.cases += 1
        root = self.root / f"case{self.cases}"
        root.mkdir()
        return root

    def find(self, *args, **kwargs):
        async def search():
            return await self.harness.files.find(*args, **kwargs)

        return self.harness.run(search())

    def paths(self, *args, **kwargs):
        async def search():
            return await self.harness.files.paths(*args, **kwargs)

        return self.harness.run(search())

    def check_rows(self, root, rows, expected, max_results, context, pattern):
        root = str(root)
        reported = [(row.path, row.line) for row in rows if not row.context]
        expected_keys = [(f"{root}/{relative}", number) for relative, number in expected]
        self.assertLessEqual(set(reported), set(expected_keys),
                             f"false positive for {pattern!r}")
        self.assertEqual(reported, sorted(set(reported)),
                         f"order and duplicates for {pattern!r}")
        self.assertLessEqual(len(reported), max_results, f"max_results for {pattern!r}")
        if len(expected_keys) <= max_results:
            self.assertEqual(reported, expected_keys, f"missing matches for {pattern!r}")
        else:
            self.assertTrue(rows.truncated, f"truncation flag for {pattern!r}")
        if len(expected_keys) <= max_results:
            self.assertFalse(rows.truncated, f"spurious truncation for {pattern!r}")
        lines = tree_lines(root)
        for row in rows:
            key = (row.path, row.line)
            self.assertIn(key, lines, f"row outside the tree for {pattern!r}: {key}")
            self.assertTrue(lines[key].startswith(row.text),
                            f"text mismatch for {pattern!r} at {key}")
        reported_set = set(reported)
        for row in rows:
            if row.context:
                near = any(
                    path == row.path and 0 < abs(line - row.line) <= context
                    for path, line in reported_set
                )
                self.assertTrue(near, f"stray context row {row.path}:{row.line}")

    # --- content oracle -----------------------------------------------------

    @settings(max_examples=250, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(),
           pattern=st.sampled_from(LITERAL_PATTERNS),
           insensitive=st.booleans(),
           max_results=st.integers(min_value=1, max_value=8),
           context=st.integers(min_value=0, max_value=2))
    def test_literal_find_matches_oracle(self, files, pattern, insensitive,
                                         max_results, context):
        root = self.case_root()
        write_tree(root, files)
        # non-ASCII case folding differs between the engines; keep it sensitive
        case_sensitive = False if insensitive and pattern.isascii() else True
        rows = self.find(pattern, str(root), literal=True,
                         case_sensitive=case_sensitive,
                         max_results=max_results, context=context)
        expected = oracle_find(str(root), pattern, True, case_sensitive)
        self.check_rows(root, rows, expected, max_results, context, pattern)

    @settings(max_examples=150, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(),
           pattern=st.sampled_from(REGEXES),
           max_results=st.integers(min_value=1, max_value=8),
           context=st.integers(min_value=0, max_value=2))
    def test_regex_find_matches_oracle(self, files, pattern, max_results, context):
        root = self.case_root()
        write_tree(root, files)
        rows = self.find(pattern, str(root), max_results=max_results, context=context)
        expected = oracle_find(str(root), pattern, False, True)
        self.check_rows(root, rows, expected, max_results, context, pattern)

    @settings(max_examples=100, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(),
           glob=st.sampled_from(["*.txt", "sub/*.txt", "**/*.md", "alpha*", "*.py"]),
           max_results=st.integers(min_value=1, max_value=6))
    def test_find_glob_filters_the_oracle(self, files, glob, max_results):
        root = self.case_root()
        write_tree(root, files)
        rows = self.find("needle", str(root), literal=True, glob=glob,
                         max_results=max_results)
        expected = oracle_find(str(root), "needle", True, True, glob=glob)
        self.check_rows(root, rows, expected, max_results, 0, "needle")

    @settings(max_examples=60, deadline=None, suppress_health_check=SLOW)
    @given(left=trees(), right=trees(), max_results=st.integers(min_value=1, max_value=6))
    def test_multiple_roots_report_each_match_once(self, left, right, max_results):
        root = self.case_root()
        first = root / "first"
        second = root / "second"
        first.mkdir()
        second.mkdir()
        write_tree(first, left)
        write_tree(second, right)
        rows = self.find("needle", [str(first), str(second)], literal=True,
                         max_results=max_results)
        expected = [
            (str(first), relative, number)
            for relative, number in oracle_find(str(first), "needle", True, True)
        ] + [
            (str(second), relative, number)
            for relative, number in oracle_find(str(second), "needle", True, True)
        ]
        expected_keys = [(f"{base}/{relative}", number)
                         for base, relative, number in expected]
        reported = [(row.path, row.line) for row in rows if not row.context]
        self.assertLessEqual(set(reported), set(expected_keys), "false positive")
        self.assertEqual(reported, sorted(set(reported)), "order and duplicates")
        self.assertLessEqual(len(reported), max_results)
        if len(expected_keys) <= max_results:
            self.assertEqual(set(reported), set(expected_keys), "missing matches")
        else:
            self.assertTrue(rows.truncated)

    # --- exact glob filtering ----------------------------------------------

    @settings(max_examples=200, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(names=LOWER_NAMES, extensions=LOWER_EXTENSIONS),
           name=st.sampled_from(["*.txt", "*.md", "alpha*", "a b*", "sub/*.txt",
                                 "**/*.txt", "sub/**/*.md", "sub/**", "**/main*",
                                 "deep dir/*", "*"]),
           use_glob_parameter=st.booleans())
    def test_paths_wildcards_are_exact_globs(self, files, name, use_glob_parameter):
        root = self.case_root()
        write_tree(root, files)
        if use_glob_parameter:
            rows = self.paths(path=str(root), glob=name)
        else:
            rows = self.paths(name, str(root))
        expected = {
            f"{root}/{relative}"
            for relative in tree_files(str(root))
            if glob_match(name, relative)
        }
        self.assertEqual(set(rows), expected,
                         f"glob {name!r} (glob= {use_glob_parameter})")
        self.assertFalse(rows.truncated, f"spurious truncation for glob {name!r}")

    @settings(max_examples=30, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(),
           name=st.sampled_from(["*.MD", "*.Txt", "UPPER*", "ReadMe*"]),
           use_glob_parameter=st.booleans())
    def test_wildcards_do_not_ignore_case(self, files, name, use_glob_parameter):
        """`exact glob filtering` is case-sensitive, as `files.ls(pattern=)` and
        `glob=` already are."""
        root = self.case_root()
        write_tree(root, files)
        if use_glob_parameter:
            rows = self.paths(path=str(root), glob=name)
        else:
            rows = self.paths(name, str(root))
        expected = {
            f"{root}/{relative}"
            for relative in tree_files(str(root))
            if glob_match(name, relative)
        }
        self.assertEqual(set(rows), expected,
                         f"glob {name!r} (glob= {use_glob_parameter})")

    @settings(max_examples=100, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(),
           query=st.sampled_from(["alp", "ma", "UPP", "n", "\u00e9t", "sub", "x"]))
    def test_fuzzy_paths_only_return_existing_files(self, files, query):
        root = self.case_root()
        write_tree(root, files)
        rows = self.paths(query, str(root), max_results=50)
        existing = {f"{root}/{relative}" for relative in tree_files(str(root))}
        self.assertLessEqual(set(rows), existing, "ranked result is not an existing file")
        self.assertEqual(len(rows), len(set(rows)), "duplicate path rows")

    @settings(max_examples=50, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(), glob=st.sampled_from(["*.txt", "*.md", "sub/**"]))
    def test_a_single_file_target_is_still_filtered_by_glob(self, files, glob):
        root = self.case_root()
        write_tree(root, files)
        for relative in tree_files(str(root)):
            target = Path(root) / relative
            body = target.read_text(encoding="utf-8")
            rows = self.find("needle", str(target), literal=True, glob=glob,
                             max_results=5)
            numbers = [
                number
                for number, line in enumerate(body.split("\n"), 1)
                if matches(line, "needle", True, True)
            ]
            # A file target is searched from its parent, so a rooted glob is
            # anchored there rather than at the tree root.
            expected = (
                [(relative, number) for number in numbers]
                if glob_match(glob, target.name)
                else []
            )
            if not numbers:
                continue
            self.assertEqual(
                [(row.path, row.line) for row in rows if not row.context],
                [(f"{root}/{relative}", number) for relative, number in expected],
            )

    @settings(max_examples=60, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(), spelling=st.sampled_from(["plain", "trailing", "dotdot"]))
    def test_path_spelling_does_not_change_matches(self, files, spelling):
        """The same directory named differently is the same search."""
        root = self.case_root()
        write_tree(root, files)
        (root / "sub").mkdir(exist_ok=True)
        spelled = {
            "plain": str(root),
            "trailing": str(root) + "/",
            "dotdot": str(root / "sub" / ".."),
        }[spelling]
        rows = self.find("needle", spelled, literal=True, max_results=50)
        expected = {
            (str(Path(root) / relative), number)
            for relative, number in oracle_find(str(root), "needle", True, True)
        }
        self.assertEqual(
            {(str(Path(row.path).resolve()), row.line) for row in rows if not row.context},
            expected,
        )

    def test_find_pages_past_one_thousand_matches(self):
        """Native paging is an item offset; a page boundary must not drop rows."""
        root = self.case_root()
        for number in range(1200):
            (root / f"file_{number:04}.txt").write_text(
                "needle\n" if number % 2 else "other\n"
            )
        rows = self.find("needle", str(root), literal=True, max_results=1000)
        self.assertEqual(len(rows), 600)
        self.assertEqual(len({row.path for row in rows}), 600)
        self.assertFalse(rows.truncated)
        limited = self.find("needle", str(root), literal=True, max_results=400)
        self.assertEqual(len(limited), 400)
        self.assertTrue(limited.truncated)
        self.assertLessEqual({row.path for row in limited}, {row.path for row in rows})


    # --- documented exclusions ---------------------------------------------

    @settings(max_examples=40, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(), query=st.sampled_from(["needle", "alpha", "NEEDLE"]))
    def test_hidden_and_ignored_files_are_never_reported(self, files, query):
        """`Ignore files and hidden files are skipped always`."""
        root = self.case_root()
        write_tree(root, files)
        (root / ".gitignore").write_text("ignored.txt\n")
        (root / "ignored.txt").write_text("needle alpha NEEDLE\n")
        hidden = root / ".hidden"
        hidden.mkdir()
        (hidden / "secret.txt").write_text("needle alpha NEEDLE\n")
        (root / ".dotfile").write_text("needle alpha NEEDLE\n")
        excluded = {"ignored.txt", ".dotfile", ".hidden/secret.txt", ".gitignore"}
        rows = self.find(query, str(root), literal=True, max_results=200)
        for row in rows:
            relative = row.path.removeprefix(str(root) + "/")
            self.assertNotIn(relative, excluded, f"reported an excluded file: {row.path}")
        listed = {
            path.removeprefix(str(root) + "/")
            for path in self.paths(path=str(root), max_results=500)
        }
        self.assertFalse(listed & excluded, f"listed an excluded file: {listed & excluded}")
        self.assertLessEqual(
            {row.path.removeprefix(str(root) + "/") for row in rows if not row.context},
            set(tree_files(str(root))) - excluded,
        )

    @settings(max_examples=60, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(names=LOWER_NAMES, extensions=LOWER_EXTENSIONS),
           max_results=st.integers(min_value=1, max_value=6),
           glob=st.sampled_from(["*.txt", "sub/*.txt", "**/*.md"]))
    def test_paths_respect_max_results_exactly(self, files, max_results, glob):
        root = self.case_root()
        write_tree(root, files)
        rows = self.paths(path=str(root), glob=glob, max_results=max_results)
        expected = [
            f"{root}/{relative}"
            for relative in tree_files(str(root))
            if glob_match(glob, relative)
        ]
        self.assertEqual(len(rows), min(len(expected), max_results))
        self.assertLessEqual(set(rows), set(expected), "reported a filtered-out path")
        self.assertEqual(len(rows), len(set(rows)), "duplicate path rows")
        self.assertEqual(rows.truncated, len(expected) > max_results)

    # --- cache invalidation -------------------------------------------------

    @settings(max_examples=40, deadline=None, suppress_health_check=SLOW)
    @given(files=trees(),
           operations=st.lists(
               st.tuples(st.integers(min_value=0, max_value=3),
                         st.sampled_from(["create", "modify", "delete", "rename"])),
               max_size=4),
           max_results=st.integers(min_value=1, max_value=10))
    def test_search_reflects_current_disk(self, files, operations, max_results):
        root = self.case_root()
        write_tree(root, files)
        self.find("needle", str(root), literal=True)  # warm the index
        counter = 0
        for index, operation in operations:
            names = tree_files(str(root))
            target = names[index % len(names)] if names else None
            if operation == "create":
                counter += 1
                (Path(root) / f"created{counter}.txt").write_text("needle created\n")
            elif operation == "modify" and target:
                (Path(root) / target).write_text("needle modified\n")
            elif operation == "delete" and target:
                (Path(root) / target).unlink()
            elif operation == "rename" and target:
                source = Path(root) / target
                source.rename(source.with_name(source.name + ".moved"))
            expected = oracle_find(str(root), "needle", True, True)
            rows = self.find("needle", str(root), literal=True, max_results=max_results)
            self.check_rows(root, rows, expected, max_results, 0, "needle")
            listed = {f"{root}/{relative}" for relative in tree_files(str(root))}
            self.assertEqual(set(self.paths(path=str(root), max_results=50)), listed)

    @settings(max_examples=20, deadline=None, suppress_health_check=SLOW)
    @given(count=st.integers(min_value=1, max_value=7))
    def test_root_eviction_keeps_results_correct(self, count):
        base = self.case_root()
        roots = []
        for number in range(count):
            root = base / f"project{number}"
            root.mkdir()
            (root / "note.txt").write_text(f"token{number}\n")
            roots.append(root)
        for number, root in enumerate(roots):
            rows = self.find(f"token{number}", str(root), literal=True)
            self.assertEqual([row.path for row in rows], [str(root / "note.txt")])
        # a revisited root is re-indexed rather than answered from a stale index
        (roots[0] / "new.txt").write_text("token0 fresh\n")
        rows = self.find("token0", str(roots[0]), literal=True)
        self.assertEqual(sorted(row.path for row in rows),
                         sorted([str(roots[0] / "note.txt"), str(roots[0] / "new.txt")]))


# --- stdio worker protocol --------------------------------------------------

FAKE_MODULE = """
const ok = value => ({ ok: true, value });
let live = 0;
exports.FileFinder = { create: () => {
  live++;
  return ok({
    getScanProgress: () => ok({ isScanning: false, isWarmupComplete: true }),
    scanFiles: () => ok({}),
    grep: query => ok({ items: [], totalFilesSearched: live, nextCursor: null }),
    glob: () => ok({ items: [] }),
    fileSearch: () => ok({ items: [] }),
    destroy: () => { live--; },
  });
} };
"""


class StdioPropertyTests(unittest.TestCase):
    """Random frame sequences against the real worker and a stub engine."""

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="fff-property-stdio-"))
        self.addCleanup(shutil.rmtree, self.directory, True)
        modules = self.directory / "node_modules"
        package = modules / "@ff-labs/fff-node"
        package.mkdir(parents=True)
        (package / "index.js").write_text(FAKE_MODULE)
        script = os.environ.get("ALBEDO_FFF_SCRIPT") or str(
            Path(__file__).resolve().parents[1] / "src/server/python/albedo_fff.mjs"
        )
        self.worker = subprocess.Popen(
            ["node", script, "--stdio"],
            cwd=self.directory,
            env={
                **os.environ,
                "NODE_PATH": str(modules),
                "HOME": str(self.directory),
                "XDG_CACHE_HOME": str(self.directory / "cache"),
            },
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.stop)

    def stop(self):
        if self.worker.poll() is None:
            self.worker.kill()
        self.worker.wait(timeout=5)

    def exchange(self, line):
        assert self.worker.stdin is not None and self.worker.stdout is not None
        self.worker.stdin.write(line + "\n")
        self.worker.stdin.flush()
        ready, _, _ = select.select([self.worker.stdout], [], [], 35)
        self.assertTrue(ready, f"worker did not answer {line[:40]!r}")
        reply = self.worker.stdout.readline()
        self.assertTrue(reply, "worker closed its output")
        return json.loads(reply)

    def frame(self, root, limit=5):
        return json.dumps({
            "op": "find",
            "protocol": 1,
            "root": root,
            "query": "needle",
            "filters": [],
            "hidden": False,
            "limit": limit,
            "context": 0,
        })

    @settings(max_examples=8, deadline=None, suppress_health_check=SLOW)
    @given(roots=st.lists(st.sampled_from([f"r{n}" for n in range(6)]),
                          min_size=1, max_size=8),
           garbage=st.lists(st.sampled_from([
               "", "{", "null", "[]", '{"protocol": 2, "op": "find"}',
               '{"protocol": 1, "op": "nope"}', "\u00e9" * 5,
           ]), max_size=3))
    def test_every_frame_gets_one_versioned_reply(self, roots, garbage):
        for root in roots:
            reply = self.exchange(self.frame(root))
            self.assertEqual(reply["protocol"], 1)
            self.assertTrue(reply["ok"], reply)
            self.assertLessEqual(reply["value"]["searched"], 4)
        for line in garbage:
            reply = self.exchange(line)
            self.assertEqual(reply["protocol"], 1)
            self.assertFalse(reply["ok"])
            self.assertIsInstance(reply["error"], str)
            # an error must not poison the worker
            reply = self.exchange(self.frame(roots[0]))
            self.assertTrue(reply["ok"], reply)

    @settings(max_examples=3, deadline=None, suppress_health_check=SLOW)
    @given(size=st.integers(min_value=1048577, max_value=1048600))
    def test_oversized_frame_is_rejected_and_worker_survives(self, size):
        reply = self.exchange("x" * size)
        self.assertFalse(reply["ok"])
        self.assertIn("1 MiB", reply["error"])
        self.assertTrue(self.exchange(self.frame("r0"))["ok"])


if __name__ == "__main__":
    unittest.main()
