"""Property tests for the FFF compatibility glob translation in files.py.

The documented contract, quoted from ``src/server/python/albedo_plugins/files.py``:

- ``_path_regex``: "Segment-aware root-relative globs; ** crosses directory
  boundaries."
- refusal: "FFF compatibility glob supports *, ?, [], **; braces and escapes
  are unsupported" (ValueError)
- ``Files.paths``: "A pattern with *, ? or [ is a glob over names, or over the
  path from the search root when it has a /; other text uses ranked fuzzy
  filename matching."
- ``docs/tool-parity.md``: "wildcard patterns and `glob=` retain exact glob
  filtering."

So the accepted glob subset is ``*``, ``?``, ``[]`` classes and ``**`` as a
whole segment; braces and backslashes are refused with the message above,
and
every accepted pattern must yield a usable path regex.

Oracle: an independent reference matcher (``ref_match``) that tokenizes each
pattern segment into literals, ``?``, ``*`` and character-class predicates and
runs a small dynamic program over the path segments.  It never builds or
evaluates a regex, so it cannot share the production translator's mistakes.  It
is cross-checked against ``pathlib.PurePosixPath.full_match`` on the subset both
support (``check_reference_against_pathlib``), because pathlib's ``full_match``
is the standard library's own segment-aware glob implementation and pins the
meaning of ``*``, ``?`` and ``**``; pathlib's character-class handling differs
from shells (it has no leading-']' rule), so classes are only checked against
the reference matcher.

Known ambiguities deliberately excluded from the equivalence property and
reported separately instead of being invented into a spec:

- a leading ``^`` inside a class: shells negate, pathlib/fnmatch treat it as a
  literal.  Production currently negates.  ``test_leading_caret_is_ambiguous``
  records the current behavior.
- ``**`` inside a segment (``a**b``): pathlib crosses separators there, which
  contradicts its own documentation; production treats it as ``*``.

Run (needs the upstream python/ tree with src/server/python overlaid first):

    ALBEDO_PYTHON_SOURCE=/tmp/overlay-py \
    ALBEDO_FFF_SOURCE=/tmp/overlay-py \
    python test/glob_translation_property_test.py

Findings against main before the fix in change "Fix FFF glob character class
translation": five properties fail.  Class bodies were copied verbatim into the
regex, so ``[]]``/``[]a]``/``[!]]`` produced an unterminated set (and could
swallow the rest of the pattern), ``[9-0]``/``[0-.]`` produced a bad range,
``[\d]``/``[0-\]`` were reinterpreted as regex escapes instead of being
refused, a negated class could consume the ``/`` that ends a segment, and a
brace inside a class was accepted.  All eight properties hold after the fix.
"""

import fnmatch
import importlib.util
import os
from pathlib import Path
import re
import sys
import warnings

from hypothesis import HealthCheck, given, settings, strategies as st

SOURCE = (
    Path(os.environ["ALBEDO_FFF_SOURCE"]) / "albedo_plugins/files.py"
    if os.environ.get("ALBEDO_FFF_SOURCE")
    else Path(__file__).resolve().parents[1] / "src/server/python/albedo_plugins/files.py"
)
CORE = os.environ.get("ALBEDO_PYTHON_SOURCE")
if CORE:
    sys.path.insert(0, CORE)
spec = importlib.util.spec_from_file_location("glob_files_tested", SOURCE)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# Production copies class bodies into the regex, which raises these.
warnings.simplefilter("ignore", FutureWarning)

REFUSED = {"{", "}"}
ESCAPE = "\\"


class Refused(Exception):
    """The reference matcher refuses this pattern, like the documented subset."""


# --- reference matcher -----------------------------------------------------


def tokenize(segment):
    """Tokenize one pattern segment into ('lit', c), ('any',), ('star',), ('class', ...)."""
    tokens = []
    i = 0
    while i < len(segment):
        char = segment[i]
        if char in REFUSED or char == ESCAPE:
            raise Refused(segment)
        if char == "*":
            tokens.append(("star",))
            i += 1
        elif char == "?":
            tokens.append(("any",))
            i += 1
        elif char == "[":
            i += 1
            negated = False
            if i < len(segment) and segment[i] == "!":
                negated = True
                i += 1
            specs = []
            # A ']' directly after '[' or '[!' is a literal member.
            if i < len(segment) and segment[i] == "]":
                specs.append(("lit", "]"))
                i += 1
            while i < len(segment) and segment[i] != "]":
                char = segment[i]
                if char in REFUSED or char == ESCAPE:
                    raise Refused(segment)
                # POSIX: '-' between two members is a range, elsewhere literal.
                if char == "-" and specs and segment[i + 1 : i + 2] not in ("", "]"):
                    previous = specs.pop()
                    if previous[0] == "lit":
                        specs.append(("range", previous[1], segment[i + 1]))
                        i += 2
                        continue
                    specs.append(previous)
                specs.append(("lit", char))
                i += 1
            if i >= len(segment):
                raise Refused(segment)
            i += 1
            tokens.append(("class", negated, tuple(specs)))
        else:
            tokens.append(("lit", char))
            i += 1
    return tokens


def class_matches(token, char):
    _, negated, specs = token
    inside = any(
        char == spec[1] if spec[0] == "lit" else spec[1] <= char <= spec[2]
        for spec in specs
    )
    return inside != negated


def segment_matches(name, tokens):
    """True when `name` matches the token sequence, without crossing '/'."""
    width = len(name)
    reachable = [set() for _ in range(len(tokens) + 1)]
    reachable[0].add(0)
    for index, token in enumerate(tokens):
        for position in reachable[index]:
            if token[0] == "star":
                # Match zero to all remaining characters of the name.
                reachable[index + 1].update(range(position, width + 1))
            elif token[0] == "any" and position < width:
                reachable[index + 1].add(position + 1)
            elif token[0] == "lit" and position < width and name[position] == token[1]:
                reachable[index + 1].add(position + 1)
            elif token[0] == "class" and position < width and class_matches(token, name[position]):
                reachable[index + 1].add(position + 1)
    return width in reachable[len(tokens)]


def ref_match(path, pattern):
    """Root-relative, segment-aware glob match, per the documented rule."""
    rooted = "/" in pattern
    body = pattern.removeprefix("./")
    if body.startswith("/"):
        body = body[1:]
    pattern_segments = [
        [("globstar",)] if part == "**" else tokenize(part)
        for part in body.split("/")
    ]
    if not rooted:
        pattern_segments = [[("globstar",)], *pattern_segments]
    names = path.split("/")
    states = {0}
    for number, tokens in enumerate(pattern_segments):
        following = set()
        for start in states:
            if tokens == [("globstar",)] and number == len(pattern_segments) - 1:
                # A trailing '**' needs at least one segment, as in pathlib.
                following.update(range(start + 1, len(names) + 1))
            elif tokens == [("globstar",)]:
                following.update(range(start, len(names) + 1))
            elif start < len(names) and segment_matches(names[start], tokens):
                following.add(start + 1)
        states = following
        if not states:
            return False
    return len(names) in states


def ref_accepts(pattern):
    try:
        ref_match("x", pattern)
    except Refused:
        return False
    return True


# --- generators ------------------------------------------------------------

PATH_CHARS = "ab09._-[]^é"
PATH_SEGMENT = st.text(alphabet=PATH_CHARS, min_size=1, max_size=3)
PATHS = st.lists(PATH_SEGMENT, min_size=1, max_size=4).map("/".join)

LITERAL_CHARS = "abxyz09._-é!^]"
CLASS_CHARS = "abxyz09._-é]^"
CLASS_BODY = st.text(alphabet=CLASS_CHARS, min_size=0, max_size=4)
SEGMENT_PART = st.one_of(
    st.text(alphabet=LITERAL_CHARS, min_size=0, max_size=3),
    st.just("*"),
    st.just("?"),
    st.builds(lambda body: "[" + body + "]", CLASS_BODY),
    st.builds(lambda negate, body: "[" + negate + body + "]", st.sampled_from(["!", "^"]), CLASS_BODY),
)
SEGMENT = st.lists(SEGMENT_PART, min_size=0, max_size=3).map("".join)
PATTERNS = st.lists(st.one_of(SEGMENT, st.just("**")), min_size=1, max_size=4).map(
    "/".join
)

ALL_CHARS = "ab09._-{}[]!^?*\\/"
ALL_PATTERNS = st.text(alphabet=ALL_CHARS, min_size=1, max_size=10)
# Class bodies that some escapes appear in: the documented refusal applies here too.
ESCAPING_PATTERNS = st.builds(
    lambda prefix, negate, body, suffix: prefix + "[" + negate + body + "]" + suffix,
    st.text(alphabet=LITERAL_CHARS, min_size=0, max_size=2),
    st.sampled_from(["", "!"]),
    st.text(alphabet="ab.{}\\-09", min_size=0, max_size=3),
    st.text(alphabet=LITERAL_CHARS, min_size=0, max_size=2),
)

# Per-property example counters, printed by main() so a run reports its volume.
SEEN = {}


def counted(name):
    SEEN[name] = SEEN.get(name, 0) + 1


SETTINGS = dict(
    deadline=None,
    max_examples=int(os.environ.get("GLOB_PROPERTY_EXAMPLES", "800")),
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.filter_too_much],
)


# --- properties ------------------------------------------------------------


@given(st.one_of(PATTERNS, ALL_PATTERNS, ESCAPING_PATTERNS))
@settings(**SETTINGS)
def prop_accepted_patterns_compile(pattern):
    """Every accepted pattern yields a regex that compiles."""
    counted("compile")
    try:
        translated = module._path_regex(pattern)
    except ValueError:
        return
    re.compile(translated)


@given(st.one_of(PATTERNS, ALL_PATTERNS, ESCAPING_PATTERNS))
@settings(**SETTINGS)
def prop_escapes_and_braces_are_refused(pattern):
    """Braces and backslashes are refused wherever they appear, classes too."""
    if not any(char in pattern for char in "{}" + ESCAPE):
        return
    counted("refusal")
    try:
        module._path_regex(pattern)
    except ValueError:
        return
    raise AssertionError(
        f"accepted pattern with an escape or brace: {pattern!r} -> "
        f"{module._path_regex(pattern)!r}"
    )


@given(PATHS, st.one_of(PATTERNS, ALL_PATTERNS, ESCAPING_PATTERNS))
@settings(**SETTINGS)
def prop_matches_reference(path, pattern):
    """Accepted patterns match exactly what the reference matcher matches."""
    if not ref_accepts(pattern):
        return
    counted("equivalence")
    pattern_segments = (
        ["**", *pattern.split("/")]
        if "/" not in pattern
        else pattern.removeprefix("./").removeprefix("/").split("/")
    )
    # A leading '^' in a class is ambiguous (shells negate, fnmatch does not).
    if "[^" in pattern or "[!^" in pattern:
        return
    try:
        translated = module._path_regex(pattern)
    except ValueError:
        return
    try:
        actual = re.fullmatch(translated, path) is not None
    except re.error as error:
        raise AssertionError(
            f"pattern={pattern!r} regex={translated!r}: {error}"
        ) from None
    expected = ref_match(path, pattern)
    assert actual == expected, (
        f"path={path!r} pattern={pattern!r} regex={translated!r} "
        f"production={actual} reference={expected}"
    )


@given(PATHS, PATTERNS)
@settings(**SETTINGS)
def prop_translation_is_deterministic(path, pattern):
    """Translating the same pattern twice gives the same regex."""
    try:
        first = module._path_regex(pattern)
    except ValueError:
        return
    assert first == module._path_regex(pattern)


@given(st.text(alphabet="ab09", min_size=0, max_size=2), st.sampled_from(["]", "a", "0"]))
@settings(**SETTINGS)
def prop_leading_bracket_is_a_member(body, char):
    """A ']' directly after '[' is a literal member, so '[]]' matches ']'."""
    counted("leading-bracket")
    pattern = "[]" + body + "]"
    translated = module._path_regex(pattern)
    expected = char == "]" or char in body
    assert (re.fullmatch(translated, char) is not None) == expected, (
        f"pattern={pattern!r} regex={translated!r} char={char!r}"
    )


@given(
    st.text(alphabet="abxy09.", min_size=1, max_size=1),
    st.text(alphabet="abxy09", min_size=1, max_size=2),
    st.text(alphabet="abxy09.", min_size=1, max_size=1),
)
@settings(**SETTINGS)
def prop_negated_classes_stay_inside_one_segment(left, body, right):
    """A negated class must not consume the '/' that ends a segment."""
    counted("negated-class")
    pattern = left + "[!" + body + "]" + right
    path = left + "/" + right
    translated = module._path_regex(pattern)
    assert re.fullmatch(translated, path) is None, (
        f"pattern={pattern!r} regex={translated!r} consumed a separator of {path!r}"
    )
    assert ref_match(path, pattern) is False


@given(st.sampled_from("abxyz"), st.sampled_from("abxyz"))
@settings(**SETTINGS)
def prop_ranges_match_their_bounds(low, high):
    """A '-' between two members is an inclusive range, both bounds included."""
    counted("range")
    if low > high:
        low, high = high, low
    translated = module._path_regex("[" + low + "-" + high + "]")
    middle = chr((ord(low) + ord(high)) // 2)
    for inside in (low, middle, high):
        assert re.fullmatch(translated, inside), (low, high, inside, translated)
    outside = next(char for char in "abxyz0]" if not low <= char <= high)
    assert re.fullmatch(translated, outside) is None, (low, high, outside, translated)


# --- oracle cross-check against pathlib ------------------------------------

PATHLIB_PARTS = st.one_of(
    st.text(alphabet="ab09._-", min_size=0, max_size=3), st.just("*"), st.just("?")
)
PATHLIB_PATTERN = st.lists(
    st.one_of(PATHLIB_PARTS, st.just("**")), min_size=1, max_size=4
).map("/".join).filter(
    lambda pattern: all(part and part not in (".", "..") for part in pattern.split("/"))
)
PATHLIB_PATHS = st.lists(
    st.text(alphabet="ab09_-", min_size=1, max_size=3), min_size=1, max_size=4
).map("/".join)


@given(PATHLIB_PATHS, PATHLIB_PATTERN)
@settings(**SETTINGS)
def check_reference_against_pathlib(path, pattern):
    """The reference matcher agrees with pathlib on *, ? and whole-segment **."""
    import pathlib

    # pathlib has no implicit "basename at any depth" rule, so an unrooted
    # pattern compares against its '**/' form.
    reference = pattern if "/" in pattern else "**/" + pattern
    assert ref_match(path, pattern) == pathlib.PurePosixPath(path).full_match(
        reference
    ), f"path={path!r} pattern={pattern!r}"


def test_leading_caret_is_ambiguous():
    """A leading '^' in a class: shells negate, fnmatch treats it literally."""
    return {
        "production": module._path_regex("[^a]"),
        "fnmatch": fnmatch.translate("[^a]"),
        "reference": ref_match("^", "[^a]"),
    }


PROPERTIES = [
    prop_accepted_patterns_compile,
    prop_escapes_and_braces_are_refused,
    prop_matches_reference,
    prop_leading_bracket_is_a_member,
    prop_negated_classes_stay_inside_one_segment,
    prop_ranges_match_their_bounds,
    prop_translation_is_deterministic,
    check_reference_against_pathlib,
]


def main():
    failures = 0
    for property_test in PROPERTIES:
        try:
            property_test()
        except AssertionError as error:
            failures += 1
            print(f"FAIL {property_test.__name__}: {error}")
        except Exception as error:  # noqa: BLE001 - report any translator error
            failures += 1
            print(f"ERROR {property_test.__name__}: {type(error).__name__}: {error}")
            details = getattr(error, "exceptions", None) or [error]
            for detail in details:
                print(f"  - {type(detail).__name__}: {detail}")
        else:
            print(f"ok   {property_test.__name__}")
    print(f"\nexamples: {SEEN}")
    print(f"{len(PROPERTIES) - failures}/{len(PROPERTIES)} properties hold")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
