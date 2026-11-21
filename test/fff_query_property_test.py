r"""Property tests for `files.find`'s FFF query construction.

`files.find` does not hand the caller's text to FFF verbatim: it hex-escapes
the characters FFF's query parser treats as separators (`\x20`, `\x2f`,
`\x22`, `\x27`, ...) and prefixes `(?i)` for case-insensitive searches. Those
rewrites are invisible to a plain-regex oracle, so these properties drive the
real `albedo-fff` worker through the production Erlang bridge and compare
against an independent model of the documented contract:

* `literal=True` returns exactly the `(file, line)` pairs whose line contains
  the needle (`str.__contains__` on the line).
* `case_sensitive=False` returns exactly the lines that match the same needle
  as a case-insensitive regex.
* otherwise the pattern is a regex, and the returned lines are exactly the
  lines an independent regex engine matches.
* `context=N` adds exactly the N lines either side of each hit.
* searching two roots returns the union of the one-root searches.

It is not part of `nix flake check` because `hypothesis` is not a suite
dependency; run it against a real worker instead (no Nix build needed):

    ALBEDO_FFF_SOURCE=<python dir holding albedo_plugins/files.py> \
    ALBEDO_FFF_COMMAND=$(command -v albedo-fff) \
    ALBEDO_FFF_ERLANG=src/server/extensions/files/src/albedo_fff.erl \
    python3 test/fff_query_property_test.py -v

The oracle never calls the code under test: expectations come from Python's
own string and regex semantics over the same temporary tree. Three known
engine limits are reported rather than asserted here, because they come from
FFF rather than from the query rewrite: FFF folds case for ASCII only, its
`\w`/`\s`/`\b` classes are ASCII-only, and it applies a regex to the whole
file text, so a class such as `[^x]` also matches the line break.
"""

import asyncio
import itertools
import os
import re
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from typing import Any

from hypothesis import example, given, settings
from hypothesis import strategies as st

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fff_test  # noqa: E402  (same-directory test helper)

module: Any = fff_test.module

CONTENT = (
    list("abcXYZ019_-+.:#*?[](){}^$|&~@%<>=_")
    + list("/\"'\\!,;")
    + ["é", "É", "日", "Ω", "ω", "→", "İ", "ß"]
    + [" ", "\t", "\v", "\f", "\u00a0", "\u2009", "\u2028", "\u3000"]
)
# FFF's engine folds case for ASCII only, so the case-insensitive property
# keeps to ASCII; that limitation is reported instead of asserted here.
ASCII_CONTENT = [char for char in CONTENT if char.isascii()]
# Simple regex atoms that Python and FFF's engine read the same way.
REGEX_ATOMS = list("ab0_ -") + [
    ".", r"\d", "[ab]", "[a-z]", "/", "'", '"', "\t", "\v", "\u00a0",
]
REGEX_ESCAPES = [r"\.", r"\*", r"\(", r"\)", r"\[", r"\]", r"\{", r"\}",
                 r"\+", r"\?", r"\|", r"\^", r"\$", r"\/", r"\'", r"\""]
REGEX_QUANTIFIERS = ["", "*", "+", "?", "{1,2}"]
# FFF's word-boundary escapes, which Python spells with ASCII lookarounds.
WORD = "[A-Za-z0-9_]"
REGEX_BOUNDARIES = {
    r"\<": f"(?<!{WORD})(?={WORD})",
    r"\>": f"(?<={WORD})(?!{WORD})",
}


def lines_of(text: str) -> list[str]:
    """Lines as `files.read` numbers them: every `str.splitlines` boundary."""
    return text.splitlines()


def occurrences(files: dict[str, str], match) -> set[tuple[str, int]]:
    """Read-numbered hits of the newline-split lines FFF matches.

    One FFF line can hold several read lines. Its hits are the read lines
    that match on their own, or its first read line when the match spans a
    separator."""
    hits = set()
    for name, text in files.items():
        lines = lines_of(text)
        starts = list(
            itertools.accumulate(
                (len(line) for line in text.splitlines(keepends=True)), initial=0
            )
        )
        index = 0
        start = 0
        for fff_line in text.split("\n"):
            end = start + len(fff_line)
            members = []
            while index < len(lines) and starts[index] <= end:
                members.append(index)
                index += 1
            if members and match(fff_line):
                held = [member for member in members if match(lines[member])]
                for member in held or members[:1]:
                    hits.add((name, member + 1))
            start = end + 1
    return hits


def literal_hits(files: dict[str, str], needle: str) -> set[tuple[str, int]]:
    return occurrences(files, lambda line: needle in line)


def insensitive_hits(files: dict[str, str], needle: str) -> set[tuple[str, int]]:
    """The needle as a literal, matched the way a case-insensitive regex does."""
    pattern = re.compile(re.escape(needle), re.IGNORECASE)
    return occurrences(files, pattern.search)


def regex_hits(files: dict[str, str], pattern: str) -> set[tuple[str, int]]:
    for escape, spelling in REGEX_BOUNDARIES.items():
        pattern = pattern.replace(escape, spelling)
    compiled = re.compile(pattern)
    return occurrences(files, compiled.search)


def target_of(path: Any) -> Any:
    """`files.find` takes one string path or a sequence of them, never Paths."""
    if isinstance(path, str):
        return path
    if isinstance(path, Path):
        return str(path)
    return [str(item) for item in path]


class Worker:
    """One daemon bridge and two search roots, reused across every example.

    The bridge is started once, because a scan per example would dominate the
    run. The worker refreshes its index before each search, so rewriting the
    same files is enough to change what the next search sees.
    """

    def __init__(self) -> None:
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(
            target=self.loop.run_forever, name="fff-property-loop", daemon=True
        )
        self.thread.start()
        self.root = Path(tempfile.mkdtemp(prefix="fff-property-"))
        self.roots = Path(tempfile.mkdtemp(prefix="fff-property-roots-"))
        self.rpc_temp = tempfile.TemporaryDirectory(prefix="fff-property-rpc-")
        self.rpc: Any = None
        self.files: Any = None
        self.call(self.boot())

    def call(self, coroutine: Any) -> Any:
        return asyncio.run_coroutine_threadsafe(coroutine, self.loop).result(180)

    async def boot(self) -> None:
        self.rpc = fff_test.DaemonRpc()
        await self.rpc.start(Path(self.rpc_temp.name))
        module._fff = module._FFF(self.rpc)
        self.files = module.Files()

    def write(self, files: dict[str, str]) -> None:
        for stale in self.root.glob("*.txt"):
            stale.unlink()
        for name, text in files.items():
            (self.root / name).write_text(text, encoding="utf-8")

    def rows(
        self, pattern: str, path: Any, base: Any = None, **options: Any
    ) -> set[tuple[str, int, bool]]:
        """Rows as (path relative to `base`, line, is context)."""
        return self.call(self._rows(pattern, path, base or path, options))

    async def _rows(self, pattern: str, path: Any, base: Any, options: dict[str, Any]):
        rows = await asyncio.wait_for(
            self.files.find(pattern, target_of(path), **options), 60
        )
        origin = str(target_of(base)[0] if not isinstance(base, (str, Path)) else base)
        return {
            (os.path.relpath(str(row.path), origin), row.line, bool(row.context))
            for row in rows
        }

    def find(
        self, pattern: str, path: Any = None, base: Any = None, **options: Any
    ) -> set[tuple[str, int]]:
        found = path or self.root
        return {
            (name, line)
            for name, line, context in self.rows(
                pattern, found, base or found, **options
            )
            if not context
        }

    def close(self) -> None:
        if self.files is not None:
            self.call(self.files.close())
            self.call(self.rpc.close())
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(10)
        self.rpc_temp.cleanup()


WORKER: "Worker | None" = None


def worker() -> "Worker":
    global WORKER
    if WORKER is None:
        WORKER = Worker()
    return WORKER


def setUpModule() -> None:
    worker()


def tearDownModule() -> None:
    if WORKER is not None:
        WORKER.close()


def files_strategy() -> Any:
    """Zero to three files of zero to four short noise lines each."""
    noise = st.text(alphabet=CONTENT, min_size=0, max_size=5)
    line_lists = st.lists(noise, min_size=0, max_size=4)
    return st.lists(line_lists, min_size=1, max_size=3).map(
        lambda per_file: {
            f"f{index}.txt": "\n".join(lines) + "\n" if lines else ""
            for index, lines in enumerate(per_file)
        }
    )


@st.composite
def needle_corpus(draw: Any, alphabet: list[str] = CONTENT) -> tuple[str, dict[str, str]]:
    """A needle plus files built around it, so hits are common but not sure."""
    needle = draw(st.text(alphabet=alphabet, min_size=1, max_size=6))
    noise = st.text(alphabet=alphabet, min_size=0, max_size=5)
    files: dict[str, str] = {}
    for index in range(draw(st.integers(min_value=1, max_value=3))):
        lines: list[str] = []
        for _ in range(draw(st.integers(min_value=0, max_value=4))):
            shape = draw(st.integers(min_value=0, max_value=3))
            if shape == 0:
                lines.append(needle)
            elif shape == 1:
                lines.append(f"{draw(noise)}{needle}{draw(noise)}")
            else:
                lines.append(draw(noise))
        files[f"f{index}.txt"] = "\n".join(lines) + "\n" if lines else ""
    return needle, files


@st.composite
def regex_pattern(draw: Any) -> str:
    """A small pattern whose meaning Python and FFF's engine agree on."""
    alphabet = REGEX_ATOMS + REGEX_ESCAPES + list(REGEX_BOUNDARIES)

    def atom() -> str:
        chosen = draw(st.sampled_from(alphabet))
        if chosen in REGEX_BOUNDARIES:
            return chosen
        return chosen + draw(st.sampled_from(REGEX_QUANTIFIERS))

    def sequence() -> str:
        return "".join(
            atom() for _ in range(draw(st.integers(min_value=1, max_value=3)))
        )

    return "|".join(
        sequence() for _ in range(draw(st.integers(min_value=1, max_value=2)))
    )


class QueryTests(unittest.TestCase):
    def check(self, pattern: str, files: dict[str, str], **options: Any) -> None:
        work = worker()
        work.write(files)
        if options.get("literal"):
            expected = (
                insensitive_hits(files, pattern)
                if options.get("case_sensitive") is False
                else literal_hits(files, pattern)
            )
        else:
            expected = regex_hits(files, pattern)
        actual = work.find(pattern, **options)
        self.assertEqual(
            actual, expected, f"pattern={pattern!r} options={options} files={files}"
        )

    @example(("*", {"f0.txt": "*\n"}))
    @example(("a/b", {"f0.txt": "a/b\n"}))
    @example(("x\u00a0y", {"f0.txt": "x\u00a0y\n"}))
    @example(("x\u2028y", {"f0.txt": "x\u2028y\n"}))
    @settings(max_examples=150, deadline=None)
    @given(needle_corpus())
    def test_literal_finds_exactly_the_lines_containing_the_needle(self, case):
        needle, files = case
        self.check(needle, files, literal=True)

    @settings(max_examples=150, deadline=None)
    @given(needle_corpus(ASCII_CONTENT))
    def test_case_insensitive_literal_matches_the_same_lines(self, case):
        needle, files = case
        self.check(needle, files, literal=True, case_sensitive=False)

    @example(r"\*", {"f0.txt": "*\n"})
    @example(r"a\/b", {"f0.txt": "a/b\n"})
    @example(r"it\'s", {"f0.txt": "it's\n"})
    @example(r"\d", {"f0.txt": "5\n"})
    @example(r"\<ab", {"f0.txt": "<ab>\nxab\nab_\n"})
    @example(r"b\>", {"f0.txt": "<ab>\nabc\n"})
    @example("x\u00a0y", {"f0.txt": "x\u00a0y\n"})
    @settings(max_examples=150, deadline=None)
    @given(regex_pattern(), files_strategy())
    def test_regex_mode_equals_an_independent_regex(self, pattern, files):
        self.check(pattern, files)

    @settings(max_examples=80, deadline=None)
    @given(needle_corpus(), st.integers(min_value=1, max_value=2))
    def test_context_rows_are_the_lines_around_each_hit(self, case, context):
        needle, files = case
        work = worker()
        work.write(files)
        hits = literal_hits(files, needle)
        expected = set()
        for name, text in files.items():
            for number in range(1, len(lines_of(text)) + 1):
                if (name, number) in hits:
                    expected.add((name, number, False))
                elif any((name, other) in hits for other in range(number - context, number + context + 1)):
                    expected.add((name, number, True))
        actual = work.rows(needle, work.root, literal=True, context=context)
        self.assertEqual(
            actual, expected, f"needle={needle!r} context={context} files={files}"
        )

    @settings(max_examples=80, deadline=None)
    @given(needle_corpus())
    def test_two_roots_are_the_union_of_the_single_root_searches(self, case):
        needle, files = case
        work = worker()
        sides = {}
        for side in ("left", "right"):
            directory = work.roots / side
            directory.mkdir(exist_ok=True)
            for stale in directory.iterdir():
                stale.unlink()
            sides[side] = directory
        for index, name in enumerate(sorted(files)):
            (sides["left" if index % 2 else "right"] / name).write_text(
                files[name], encoding="utf-8"
            )
        single = {
            side: work.find(needle, directory, base=work.roots, literal=True)
            for side, directory in sides.items()
        }
        both = work.find(
            needle, list(sides.values()), base=work.roots, literal=True
        )
        self.assertEqual(
            both,
            single["left"] | single["right"],
            f"needle={needle!r} files={files}",
        )


if __name__ == "__main__":
    unittest.main()
