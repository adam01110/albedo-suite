"""Escaping sweep: user text that becomes FFF regex or glob syntax.

Discovery harness, not a wired check. Run it against a writable copy of the
upstream ``python/`` tree with this suite's ``src/server/python`` overlaid:

    PYTHONPATH=/tmp/albedo-py python3 -m unittest discover -s test \
        -p escaping_sweep_test.py -v

Properties and their oracles:

- ``files._path_regex`` must agree with an independent recursive glob matcher
  over ``*``, ``?``, ``**`` and literal segments.
"""

import asyncio
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest

from hypothesis import HealthCheck, given, settings, strategies as st

SOURCE = Path(
    os.environ.get("ALBEDO_PYTHON_SOURCE")
    or Path(__file__).resolve().parents[1] / "src/server/python"
)
# Appended, so a PYTHONPATH tree under test wins over this checkout's sources.
sys.path.append(str(SOURCE))

import albedo_plugins.files as files_module  # noqa: E402


def _segment_matches(pattern, name):
    """One path segment, with `*` and `?` inside it."""
    if not pattern:
        return not name
    head, rest = pattern[0], pattern[1:]
    if head == "*":
        return any(_segment_matches(rest, name[index:]) for index in range(len(name) + 1))
    if head == "?":
        return bool(name) and _segment_matches(rest, name[1:])
    return bool(name) and name[0] == head and _segment_matches(rest, name[1:])


def _glob_matches(pattern_parts, parts):
    """Independent segment matcher: `**` crosses separators, `*` does not."""
    if not pattern_parts:
        return not parts
    head, rest = pattern_parts[0], pattern_parts[1:]
    if head == "**":
        if not rest:
            # A trailing `**` names the subtree below, so it needs the separator
            # before it. Whether it also matches zero segments is a spec question
            # the implementation answers "no"; this reading is recorded there.
            return bool(parts)
        return any(_glob_matches(rest, parts[index:]) for index in range(len(parts) + 1))
    if not parts:
        return False
    return _segment_matches(head, parts[0]) and _glob_matches(rest, parts[1:])


def expected_match(pattern, name):
    """The documented rule: root-relative, and an unrooted glob may sit deep."""
    parts = name.split("/")
    if "/" in pattern:
        return _glob_matches(pattern.split("/"), parts)
    return any(_glob_matches([pattern], parts[index:]) for index in range(len(parts)))


@st.composite
def glob_patterns(draw):
    pieces = []
    for _ in range(draw(st.integers(min_value=1, max_value=3))):
        choice = draw(st.integers(min_value=0, max_value=2))
        if choice == 0:
            pieces.append("**")
        elif choice == 1:
            pieces.append(
                draw(st.sampled_from(["a*", "*b", "?", "a", "b", "ab*"]))
            )
        else:
            pieces.append(
                draw(st.sampled_from(["a", "b", "?", "a*", "*b", "**"]))
            )
    return "/".join(pieces)


@st.composite
def paths(draw):
    parts = [
        draw(st.sampled_from(["a", "b", "ab", "ba", "aab"]))
        for _ in range(draw(st.integers(min_value=1, max_value=4)))
    ]
    return "/".join(parts)


class GlobSegmentTests(unittest.TestCase):
    """`_path_regex` is the FFF name filter, so it must match the documented glob."""

    @settings(max_examples=300, deadline=None, suppress_health_check=[HealthCheck.too_slow])
    @given(pattern=glob_patterns(), name=paths())
    def test_regex_agrees_with_segment_matcher(self, pattern, name):
        regex = files_module._path_regex(pattern)
        self.assertEqual(
            re.fullmatch(regex, name) is not None,
            expected_match(pattern, name),
            f"pattern {pattern!r} against {name!r} via {regex!r}",
        )


class _RecordingFFF:
    """Stand-in for the daemon worker: records queries, matches nothing."""

    def __init__(self):
        self.queries = []

    async def request(self, payload):
        self.queries.append(payload["query"])
        return {"searched": 0, "total": 0, "items": []}

    async def close(self):
        pass


QUERY_CHARS = [
    "a",
    "b",
    "/",
    " ",
    "\t",
    "'",
    '"',
    "$",
    "`",
    ";",
    "|",
    "&",
    "-",
    "*",
    ".",
    "\\",
    "~",
    "[",
    "]",
    "?",
    "(",
    ")",
    "+",
    "^",
    "{",
    "}",
]


def _python_regex(query):
    """Spell Rust's braced `\\x{H}` escapes, which `re` lacks, as `\\U` escapes."""
    out = []
    index = 0
    while index < len(query):
        if query[index] == "\\" and query.startswith("x{", index + 1):
            end = query.index("}", index)
            out.append(f"\\U{int(query[index + 3 : end], 16):08x}")
            index = end + 1
        elif query[index] == "\\":
            out.append(query[index : index + 2])
            index += 2
        else:
            out.append(query[index])
            index += 1
    return "".join(out)


class FindQueryEscapingTests(unittest.TestCase):
    """`literal=True` turns text into an FFF regex that matches that text as is.

    The oracle is the regex meaning of the query the plugin sends: both the
    worker's Rust regex and Python's `re` read `\\xNN` the same way (braced
    `\\x{H}` escapes are respelled for `re`), and the generated alphabet
    covers every character the plugin rewrites.
    """

    def setUp(self):
        self.previous = files_module._fff
        self.fff = _RecordingFFF()
        files_module._fff = self.fff
        self.addCleanup(setattr, files_module, "_fff", self.previous)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = directory.name

    async def query(self, pattern):
        await files_module.Files()._find(
            pattern, self.directory, None, 0, 5, True, None, False, False
        )
        return self.fff.queries[-1]

    @settings(max_examples=300, deadline=None, suppress_health_check=[HealthCheck.too_slow])
    @given(
        pattern=st.lists(st.sampled_from(QUERY_CHARS), max_size=5).map("".join),
        line=st.lists(st.sampled_from(["a", "b", "/", " ", "x", "\t", "\\"]), max_size=6).map(
            "".join
        ),
    )
    def test_literal_query_matches_exactly_the_text(self, pattern, line):
        if "\n" in pattern or "\r" in pattern:
            return  # multiline patterns are refused before a query is built
        query = asyncio.run(self.query(pattern))
        self.assertEqual(
            re.search(_python_regex(query), line) is not None,
            pattern in line,
            f"pattern {pattern!r} against {line!r} via {query!r}",
        )


if __name__ == "__main__":
    unittest.main()
