"""Property tests that files.find line numbers point read at the match.

Run with a Python that has hypothesis, and point PYTHONPATH and
ALBEDO_PYTHON_SOURCE at a writable copy of upstream ``python/`` with
``src/server/python`` copied over it:

    PYTHONPATH=<copy> ALBEDO_FFF_SOURCE=<copy> ALBEDO_PYTHON_SOURCE=<copy> \
    ALBEDO_FFF_ERLANG=src/server/extensions/files/src/albedo_fff.erl \
    ALBEDO_FFF_COMMAND=$(command -v albedo-fff) \
    python3 test/files_line_number_prop_test.py

The oracle is independent of the plugin: ``str.splitlines`` (stdlib) defines
the line numbers ``read`` promises, since its docstring says read "returns
numbered whole lines" and that "the numbers are what ``edit(line_hint=)``
takes". A line number any tool reports for a match must therefore make
``read(path, start_line=N, end_line=N)`` show a line that contains the match.
"""

from __future__ import annotations

import asyncio
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

CORE = os.environ.get("ALBEDO_PYTHON_SOURCE")
if CORE:
    sys.path.insert(0, CORE)

SOURCE = (
    Path(os.environ["ALBEDO_FFF_SOURCE"]) / "albedo_plugins/files.py"
    if os.environ.get("ALBEDO_FFF_SOURCE")
    else Path(__file__).resolve().parents[1]
    / "src/server/python/albedo_plugins/files.py"
)
spec = importlib.util.spec_from_file_location("line_numbers_tested", SOURCE)
assert spec is not None and spec.loader is not None
module: Any = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fff_test  # noqa: E402  (production daemon RPC bridge shared with fff_test)

EXAMPLES = int(os.environ.get("PROPTEST_COUNT", "200"))
SEED = os.environ.get("PROPTEST_SEED")
# The line boundaries `read` documents: one per character here, with CRLF as a
# single boundary. The oracle below uses str.splitlines, not this list.
SEPARATORS = [
    "\n",
    "\r\n",
    "\r",
    "\v",
    "\f",
    "\x1c",
    "\x1d",
    "\x1e",
    "\x85",
    "\u2028",
    "\u2029",
]

def model_lines(text: str) -> list[str]:
    """The lines `read` promises, straight from the standard library."""
    return text.splitlines()


NEEDLE = "needle"


def content() -> st.SearchStrategy[str]:
    return st.text(
        alphabet=st.sampled_from(
            list("abcdefgh \t0123_-.,:;'()[]{}") + ["\u00e9", "\u4e2d", "\u00a0"]
        ),
        min_size=1,
        max_size=24,
    )


@st.composite
def texts_with_needles(
    draw: st.DrawFn, needles: int = 2, max_lines: int = 8
) -> str:
    """Lines joined by every separator `read` splits on, with `needles` lines that
    are exactly NEEDLE."""
    bodies = draw(st.lists(content(), min_size=max(2, needles), max_size=max_lines))
    separators = draw(
        st.lists(
            st.sampled_from(SEPARATORS),
            min_size=len(bodies) - 1,
            max_size=len(bodies) - 1,
        )
    )
    chosen = draw(
        st.lists(
            st.integers(0, len(bodies) - 1),
            min_size=needles,
            max_size=needles,
            unique=True,
        )
    )
    for index in chosen:
        bodies[index] = NEEDLE
    return "".join(
        body + (separators[index] if index < len(separators) else "")
        for index, body in enumerate(bodies)
    )


@unittest.skipUnless(
    os.environ.get("PROPTEST_FIND_READ_LINES") == "1", "find/read numbering is opt-in"
)
class FindLineNumberProperties(unittest.TestCase):
    """`find` reports the same line numbers `read` shows.

    Only literal needles are checked: in regex mode FFF's engine decides, and a
    widened FFF line names the read line it starts on, so the reported line can
    sit above the match. That limit is documented in the plugin's `_find`.
    """

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.rpc_temp = tempfile.TemporaryDirectory()
        # Hypothesis cannot drive async tests, so one loop serves every example.
        self.loop = asyncio.new_event_loop()
        self.rpc = fff_test.DaemonRpc()
        self.loop.run_until_complete(self.rpc.start(Path(self.rpc_temp.name)))
        module._fff = module._FFF(self.rpc)
        self.files = module.Files()
        self.case = 0

    def tearDown(self) -> None:
        self.loop.run_until_complete(self.files.close())
        self.loop.run_until_complete(self.rpc.close())
        self.loop.close()
        self.rpc_temp.cleanup()
        self.temp.cleanup()

    def write(self, text: str) -> Path:
        self.case += 1
        path = self.root / f"case_{self.case}.txt"
        path.write_bytes(text.encode("utf-8"))
        return path

    def find(self, pattern: str, path: Path, **options: Any) -> Any:
        return self.loop.run_until_complete(
            self.files.find(pattern, str(path), **options)
        )

    def read_line(self, path: Path, number: int) -> str:
        return str(
            self.files.read(
                str(path), start_line=number, end_line=number, max_chars=200_000
            )
        )

    @settings(
        max_examples=max(1, EXAMPLES // 4),
        deadline=None,
        database=None,
        derandomize=bool(SEED),
        suppress_health_check=[HealthCheck.too_slow],
    )
    @given(text=texts_with_needles(max_lines=6))
    def test_find_line_points_read_at_the_match(self, text: str) -> None:
        path = self.write(text)
        model = model_lines(text)
        expected = [n for n, line in enumerate(model, 1) if NEEDLE in line]
        self.assertGreaterEqual(len(expected), 2)
        rows = self.find(NEEDLE, path, literal=True)
        reported = [row.line for row in rows if not row.context]
        self.assertEqual(reported, expected, repr(text))
        for number in reported:
            self.assertIn(NEEDLE, self.read_line(path, number), f"{text!r} line {number}")


if __name__ == "__main__":
    unittest.main()
