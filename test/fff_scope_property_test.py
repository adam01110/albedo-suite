"""Property tests for FFF glob scoping: files.find(glob=) and files.paths(pattern).

An independent matcher for the documented glob subset (*, ?, [], **, and "!"
entries in a glob list) is applied to generated trees, and the real worker's
selection must agree with it. The reference is character based and shares no
code with the production translation, so a wrong translation cannot make both
sides agree.

Run it against a writable Python tree and the packaged worker:

  export ALBEDO_FFF_SOURCE=/path/to/python       # upstream python/ + suite files
  export ALBEDO_FFF_COMMAND=/path/to/albedo-fff
  export ALBEDO_FFF_ERLANG=$PWD/src/server/extensions/files/src/albedo_fff.erl
  python3 test/fff_scope_property_test.py -v

ALBEDO_FFF_SCOPE_EXAMPLES changes the Hypothesis example count (default 40).
ALBEDO_FFF_SCOPE_IGNORE names mismatch families the run tolerates, so a known
defect does not hide new ones: "classes" (glob character classes, pending change
puvozwkx) and "case" (paths wildcard patterns fold case in the worker while
find's glob filters do not). Any unclassified mismatch always fails.
"""

import asyncio
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

from hypothesis import HealthCheck, assume, given, settings, strategies as st

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fff_test import DaemonRpc, module  # noqa: E402

EXAMPLES = int(os.environ.get("ALBEDO_FFF_SCOPE_EXAMPLES", "40"))
IGNORED = {
    family.strip()
    for family in os.environ.get("ALBEDO_FFF_SCOPE_IGNORE", "").split(",")
    if family.strip()
}
NEEDLE = "SCOPENEEDLE"
SETTINGS = settings(
    max_examples=EXAMPLES,
    deadline=None,
    database=None,
    derandomize=True,
    suppress_health_check=list(HealthCheck),
)


# ---------- independent reference for the documented glob subset ----------


def _class(pat):
    """Parse one [...] at the start of `pat` into a predicate and the rest."""
    j = 1
    negate = pat[j : j + 1] == "!"
    if negate:
        j += 1
    items = []
    if pat[j : j + 1] == "]":
        items.append(("]", "]"))
        j += 1
    while j < len(pat) and pat[j] != "]":
        low = pat[j]
        if j + 2 < len(pat) and pat[j + 1] == "-" and pat[j + 2] != "]":
            items.append((low, pat[j + 2]))
            j += 3
        else:
            items.append((low, low))
            j += 1
    if j >= len(pat):
        raise ValueError("unclosed character class")
    j += 1

    def member(char):
        return any(low <= char <= high for low, high in items) != negate

    return member, pat[j:]


def _segment(pat, name):
    """One path segment: * and ? stay inside it, [] is a shell class."""
    if not pat:
        return not name
    char = pat[0]
    if char == "*":
        return _segment(pat[1:], name) or (bool(name) and _segment(pat, name[1:]))
    if char == "?":
        return bool(name) and _segment(pat[1:], name[1:])
    if char == "[":
        member, rest = _class(pat)
        return bool(name) and member(name[0]) and _segment(rest, name[1:])
    return bool(name) and name[0] == char and _segment(pat[1:], name[1:])


def _segments(pat, parts):
    """A whole path: a "**" segment matches zero or more segments."""
    if not pat:
        return not parts
    if pat[0] == "**":
        return _segments(pat[1:], parts) or (
            bool(parts) and _segments(pat, parts[1:])
        )
    return bool(parts) and _segment(pat[0], parts[0]) and _segments(pat[1:], parts[1:])


def reference_match(pattern, relative_path):
    """Root-relative globs; a pattern without a separator matches any basename."""
    rooted = pattern.startswith(("./", "/")) or "/" in pattern
    pat = pattern.removeprefix("./").removeprefix("/")
    parts = relative_path.split("/")
    if rooted:
        return _segments(pat.split("/"), parts)
    return _segments(pat.split("/"), parts[-1:])


def reference_select(relative_path, globs):
    """Later globs win; a list holding only exclusions allows the rest."""
    if not globs:
        return True
    allowed = not any(not one.startswith("!") for one in globs)
    for one in globs:
        include = not one.startswith("!")
        if reference_match(one if include else one[1:], relative_path):
            allowed = include
    return allowed


def visible(relative_path):
    return not any(part.startswith(".") for part in relative_path.split("/"))


def astral(text):
    return any(ord(char) > 0xFFFF for char in text)


def family(spec, expected, found, folded):
    """Name the mismatch family so a known defect cannot hide a new one."""
    if any("[" in one for one in spec):
        return "classes"
    if astral("".join(spec)) or any(
        astral(path) for path in expected ^ found
    ):
        return "astral"
    if found == folded:
        return "case"
    return "unknown"


def check(spec, expected, found, truncated=False):
    assert not truncated, f"{spec}: truncated before every match was listed"
    assert found == expected, "\n".join(
        [
            f"{spec}:",
            f"  trees differ, missing={sorted(expected - found)} extra={sorted(found - expected)}",
        ]
    )


class Harness:
    """One worker session and one root whose contents are replaced per example."""

    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.rpc_temp = tempfile.TemporaryDirectory()
        self.rpc = DaemonRpc()
        self.loop.run_until_complete(self.rpc.start(Path(self.rpc_temp.name)))
        module._fff = module._FFF(self.rpc)
        self.files = module.Files()

    def build(self, paths):
        for entry in self.root.iterdir():
            if entry.is_dir():
                shutil.rmtree(entry)
            else:
                entry.unlink()
        for relative in paths:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(NEEDLE + "\n")

    def find_rows(self, globs, limit=200):
        rows = self.loop.run_until_complete(
            self.files.find(
                NEEDLE, str(self.root), glob=globs, literal=True, max_results=limit
            )
        )
        return [
            str(Path(row.path).relative_to(self.root)) for row in rows if not row.context
        ], rows.truncated

    def find(self, globs, limit=200):
        rows, truncated = self.find_rows(globs, limit)
        return set(rows), truncated

    def paths_rows(self, pattern, limit=200):
        rows = self.loop.run_until_complete(
            self.files.paths(pattern, str(self.root), max_results=limit)
        )
        return [str(Path(one).relative_to(self.root)) for one in rows], rows.truncated

    def paths(self, pattern, limit=200):
        rows, truncated = self.paths_rows(pattern, limit)
        return set(rows), truncated

    def close(self):
        self.loop.run_until_complete(self.rpc.close())
        self.rpc_temp.cleanup()
        self.temp.cleanup()


HARNESS = None


def harness():
    global HARNESS
    if HARNESS is None:
        HARNESS = Harness()
    return HARNESS


# ---------- generators ----------


ALPHABET = list("abABz019-_. éü€😀[]#&~{}+@!,'")


def _usable(name):
    return (
        name not in ("", ".", "..")
        and "/" not in name
        and "\x00" not in name
        and not name.startswith(".")
    )


NAMES = st.text(alphabet=st.sampled_from(ALPHABET), min_size=1, max_size=5).filter(
    _usable
)
SEGMENTS = [
    "*",
    "?",
    "[ab]",
    "[!ab]",
    "[a-c]",
    "a*",
    "*b",
    "a?",
    "??",
    "*.txt",
    "?.md",
    "a",
    "b",
    "A",
    "file",
    "notes.md",
    "a.txt",
    "space name",
    "é",
    "😀.txt",
    "0",
]
LITERALS = ["a", "b", "A", "0", "file", "notes.md", "a.txt", "space name", "é", "😀.txt"]


@st.composite
def trees(draw):
    """Files, optionally under one or two directories; empty means unusable."""
    directories = list(
        dict.fromkeys(
            draw(NAMES) for _ in range(draw(st.integers(min_value=0, max_value=2)))
        )
    )
    paths = set()
    for _ in range(draw(st.integers(min_value=1, max_value=5))):
        name = draw(NAMES)
        if directories and draw(st.booleans()):
            paths.add(draw(st.sampled_from(directories)) + "/" + name)
        else:
            paths.add(name)
    inner = {
        "/".join(path.split("/")[:depth])
        for path in paths
        for depth in range(1, len(path.split("/")))
    }
    return sorted(paths) if not inner & paths else []


SEGMENT = st.sampled_from(SEGMENTS + LITERALS)


@st.composite
def patterns(draw):
    """Paths of one or two matching segments; "**" only where it cannot trail.

    A trailing "**" is left out: "a/**" keeps a separator before the recursive
    tail, so it cannot match the path "a" itself, and whether shell globstar
    matches "a" is arguable rather than settled.
    """
    parts = ["**"] if draw(st.booleans()) else []
    parts.append(draw(SEGMENT))
    if draw(st.booleans()):
        parts.extend(["**", draw(SEGMENT)])
    pattern = "/".join(parts)
    if draw(st.booleans()):
        pattern = draw(st.sampled_from(["./", "/"])) + pattern
    return pattern


@st.composite
def glob_lists(draw):
    return [
        ("!" if draw(st.booleans()) else "") + draw(patterns())
        for _ in range(draw(st.integers(1, 2)))
    ]


def derived_specs(path):
    """Globs that select `path` itself, so an example always has matches.

    The subset has no escapes, so a name holding a wildcard or class character
    cannot be written as a pattern; a leading "!" needs a "./" to stay literal.
    """
    name = path.split("/")[-1]
    if any(char in path for char in "*?[]{}"):
        return []
    if name.startswith("!"):
        return ["./" + path, "./" + name, "**/" + path]
    return [
        path,
        name,
        "**/" + path,
        "*/" + name,
        "*" + name[-2:],
        name[:-1] + "*",
        "?" + name[1:],
        name[:-1] + "?",
        "*",
        "?",
    ]


@st.composite
def tree_globs(draw):
    """A tree plus globs, derived from the tree about half of the time."""
    tree = draw(trees())
    if not tree or not draw(st.booleans()):
        return tree, draw(glob_lists())
    specs = derived_specs(draw(st.sampled_from(tree)))
    if not specs:
        return tree, draw(glob_lists())
    globs = [draw(st.sampled_from(specs))]
    if draw(st.booleans()):
        globs.insert(0, draw(patterns()))
    if draw(st.booleans()):
        globs.append("!" + draw(patterns()))
    return tree, globs


@st.composite
def tree_pattern(draw):
    """A tree plus one wildcard pattern, derived from the tree about half of the time."""
    tree = draw(trees())
    if not tree or not draw(st.booleans()):
        return tree, draw(
            st.sampled_from(
                ["*", "?", "??", "*.txt", "?.md", "a*", "*b", "a?", "[ab]", "[!ab]"]
            )
            | st.builds(
                "{}/{}".format,
                st.sampled_from(SEGMENTS + LITERALS),
                st.sampled_from(SEGMENTS),
            )
        )
    specs = derived_specs(draw(st.sampled_from(tree)))
    if not specs:
        return tree, draw(st.sampled_from(["*", "?", "**/*"]))
    return tree, draw(st.sampled_from(specs))


def _mismatch(description, spec, expected, found, folded):
    missing, extra = expected - found, found - expected
    if not missing and not extra:
        return None
    kind = family(spec, expected, found, folded)
    if kind in IGNORED:
        return None
    return (
        f"{description}: missing={sorted(missing)} extra={sorted(extra)} family={kind}"
        " (set ALBEDO_FFF_SCOPE_IGNORE to tolerate a known family)"
    )


# ---------- properties ----------


class ScopeProperties(unittest.TestCase):
    def test_reference_matcher_table(self):
        """The oracle itself follows shell member and separator rules."""
        cases = [
            ("*.txt", "a/b.txt", True),
            ("*.txt", "a/b.md", False),
            ("src/*.txt", "src/a.txt", True),
            ("src/*.txt", "other/src/a.txt", False),
            ("**/*.txt", "a/b/c.txt", True),
            ("**/a/**/b", "a/b", True),
            ("**/a/**/b", "x/a/y/z/b", True),
            ("a?c", "abc", True),
            ("a?c", "a/c", False),
            ("[!a]bc", "abc", False),
            ("[!a]bc", "zbc", True),
            ("[]]", "]", True),
            ("?.txt", "😀.txt", True),
            ("./root.txt", "root.txt", True),
            ("./root.txt", "sub/root.txt", False),
            ("root.txt", "sub/root.txt", True),
        ]
        for pattern, path, expected in cases:
            with self.subTest(pattern=pattern, path=path):
                self.assertEqual(reference_match(pattern, path), expected)

    def test_glob_list_order_and_exclusions(self):
        paths = ["a.txt", "src/b.txt", "src/c.md", "docs/d.md"]
        self.assertEqual(
            [one for one in paths if reference_select(one, ["*.txt", "!src/**"])],
            ["a.txt"],
        )
        self.assertEqual(
            [
                one
                for one in paths
                if reference_select(one, ["*.txt", "!src/**", "src/**"])
            ],
            ["a.txt", "src/b.txt", "src/c.md"],
        )
        self.assertEqual(
            [one for one in paths if reference_select(one, ["!*.md"])],
            ["a.txt", "src/b.txt"],
        )

    @SETTINGS
    @given(spec=tree_globs())
    def test_find_globs_select_the_reference_files(self, spec):
        tree, globs = spec
        assume(tree)
        worker = harness()
        worker.build(tree)
        files = [path for path in tree if visible(path)]
        expected = {path for path in files if reference_select(path, globs)}
        found, truncated = worker.find(globs)
        folded = {
            path
            for path in files
            if reference_select(path.casefold(), [one.casefold() for one in globs])
        }
        problem = _mismatch(
            f"find glob={globs} tree={tree}", globs, expected, found, folded
        )
        self.assertIsNone(problem)
        self.assertFalse(truncated)

    @SETTINGS
    @given(spec=tree_pattern())
    def test_paths_wildcards_select_the_reference_files(self, spec):
        tree, pattern = spec
        assume(tree)
        assume(any(char in pattern for char in "*?["))
        worker = harness()
        worker.build(tree)
        files = [path for path in tree if visible(path)]
        expected = {path for path in files if reference_match(pattern, path)}
        found, truncated = worker.paths(pattern)
        folded = {
            path
            for path in files
            if reference_match(pattern.casefold(), path.casefold())
        }
        problem = _mismatch(
            f"paths pattern={pattern} tree={tree}", [pattern], expected, found, folded
        )
        self.assertIsNone(problem)
        self.assertFalse(truncated)

    @SETTINGS
    @given(
        spec=tree_globs(),
        limit=st.integers(min_value=1, max_value=4),
    )
    def test_find_limit_lists_a_prefix_and_flags_truncation(self, spec, limit):
        """A capped search lists part of the uncapped result and flags the cap."""
        tree, globs = spec
        assume(tree)
        worker = harness()
        worker.build(tree)
        everything, _ = worker.find_rows(globs)
        found, truncated = worker.find_rows(globs, limit=limit)
        self.assertLessEqual(len(found), limit)
        self.assertEqual(len(found), min(limit, len(everything)))
        self.assertLessEqual(set(found), set(everything))
        self.assertEqual(truncated, len(everything) > limit)

    @SETTINGS
    @given(
        spec=tree_pattern(),
        limit=st.integers(min_value=1, max_value=4),
    )
    def test_paths_limit_lists_a_prefix_and_flags_truncation(self, spec, limit):
        """A capped listing is the prefix of an uncapped one and flags the cap."""
        tree, pattern = spec
        assume(tree)
        worker = harness()
        worker.build(tree)
        everything, _ = worker.paths_rows(pattern)
        found, truncated = worker.paths_rows(pattern, limit=limit)
        self.assertEqual(found, everything[:limit])
        self.assertEqual(truncated, len(everything) > limit)


class ScopeRequestTests(unittest.TestCase):
    """The request built for the worker encodes the glob subset faithfully."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "src").mkdir()
        (self.root / "src/main.txt").write_text("x")

    def tearDown(self):
        self.temp.cleanup()

    def scope(self, glob):
        return module._fff_scope(self.root, glob, False, 10)

    def test_only_a_wildcard_free_single_glob_becomes_native(self):
        self.assertEqual(self.scope("src/main.txt")["nativeGlob"], "src/main.txt")
        self.assertEqual(self.scope("main.txt")["nativeGlob"], "**/main.txt")
        self.assertEqual(self.scope("./main.txt")["nativeGlob"], "main.txt")
        self.assertIsNone(self.scope("*.txt")["nativeGlob"])
        self.assertIsNone(self.scope(["main.txt", "other.txt"])["nativeGlob"])
        self.assertIsNone(self.scope(None)["nativeGlob"])
        self.assertIsNone(self.scope("src/main.txt")["fileGlob"])

    def test_filters_mark_exclusions_and_follow_the_reference(self):
        globs = ["*.txt", "!src/**", "src/**"]
        filters = self.scope(globs)["filters"]
        self.assertEqual([one["include"] for one in filters], [True, False, True])
        import re

        for relative in ["a.txt", "src/b.txt", "docs/c.md"]:
            selected = [
                one["include"]
                for one in filters
                if re.fullmatch(one["regex"], relative)
            ]
            expected = reference_select(relative, globs)
            if selected:
                self.assertEqual(selected[-1], expected)
            else:
                self.assertEqual(expected, not any(one["include"] for one in filters))

    def test_support_boundaries_raise(self):
        for glob in ("{a,b}", "a\\b"):
            with self.subTest(glob=glob):
                with self.assertRaisesRegex(ValueError, "braces and escapes"):
                    self.scope(glob)["filters"]
        with self.assertRaisesRegex(ValueError, "hidden=True"):
            module._fff_scope(self.root, None, True, 10)
        for limit in (0, 10001):
            with self.subTest(limit=limit):
                with self.assertRaisesRegex(ValueError, "max_results"):
                    module._fff_scope(self.root, None, False, limit)


def tearDownModule():
    if HARNESS is not None:
        HARNESS.close()


if __name__ == "__main__":
    unittest.main()
