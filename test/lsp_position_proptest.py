"""Property tests for the LSP tools' positions, sync payloads and diagnostics.

Run with a Python that has hypothesis, and point PYTHONPATH and
ALBEDO_LSP_SOURCE at a writable copy of upstream ``python/`` with
``src/server/python`` copied over it:

    PYTHONPATH=<copy> ALBEDO_LSP_SOURCE=<copy> \
    python3 test/lsp_position_proptest.py

The oracles do not call the code under test: line contents come from an
explicit LF/CRLF scanner and widths from ``str.encode("utf-16-le")``, so
``didOpen``/``didChange`` payloads and rejected positions are judged against
the LSP base protocol rather than against ``albedo_lsp``.

Excluded on purpose (known ambiguities, not assertions): lone CR line endings
(``"a\rb"``), ``fnmatch`` patterns where ``*`` crosses ``/``, and the document
eviction order once 32 files are open.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

SOURCE = Path(
    os.environ.get(
        "ALBEDO_LSP_SOURCE",
        Path(__file__).resolve().parents[1] / "src/server/python",
    )
)
sys.path.insert(0, str(SOURCE))
from albedo_lsp import Lsp, LspError  # noqa: E402

EXAMPLES = int(os.environ.get("PROPTEST_COUNT", "200"))
SEED = os.environ.get("PROPTEST_SEED")
SETTINGS = settings(
    max_examples=EXAMPLES,
    deadline=None,
    derandomize=bool(SEED),
    database=None,
    suppress_health_check=[
        HealthCheck.too_slow,
        HealthCheck.data_too_large,
        HealthCheck.function_scoped_fixture,
    ],
)


def utf16_units(text: str) -> int:
    """UTF-16 code unit count of a string, straight from the codec."""
    return len(text.encode("utf-16-le")) // 2


def lsp_lines(text: str) -> list[str]:
    """Lines of `text` under the base protocol's LF and CRLF terminators."""
    lines, start, index = [], 0, 0
    while index < len(text):
        if text[index] == "\r":
            # Generators exclude lone CR, which the specification leaves open.
            assert text[index + 1 : index + 2] == "\n", "lone CR in document"
            lines.append(text[start:index])
            index += 2
            start = index
            continue
        if text[index] == "\n":
            lines.append(text[start:index])
            index += 1
            start = index
            continue
        index += 1
    lines.append(text[start:])
    return lines


def boundaries(line: str) -> list[int]:
    """Every valid `character` on `line`: the UTF-16 offset after each code point."""
    widths, total = [0], 0
    for char in line:
        total += utf16_units(char)
        widths.append(total)
    return widths


CONTENT = st.text(
    alphabet=st.sampled_from(
        list("ab \t_0123;()[]{}")
        + ["\u00e9", "\u4e2d", "\u00a0", "\ud7ff", "\uffff", "\U0001f600", "\U0001d518"]
    ),
    max_size=10,
)
ENDINGS = st.sampled_from(["\n", "\r\n"])
TERMINATED = st.builds(
    lambda pairs: "".join(body + ending for body, ending in pairs),
    st.lists(st.tuples(CONTENT, ENDINGS), min_size=1, max_size=5),
)
DOCUMENTS = st.one_of(
    TERMINATED,
    st.builds(
        lambda pairs, tail: "".join(body + ending for body, ending in pairs) + tail,
        st.lists(st.tuples(CONTENT, ENDINGS), min_size=0, max_size=4),
        CONTENT,
    ),
    st.just(""),
)


@st.composite
def distinct_steps(draw, minimum: int = 33, maximum: int = 45):
    """(file index, text) steps over distinct files, enough to hit the open cap."""
    count = draw(st.integers(minimum, maximum))
    indices = draw(
        st.lists(st.integers(0, 60), min_size=count, max_size=count, unique=True)
    )
    texts = draw(st.lists(DOCUMENTS, min_size=count, max_size=count))
    return list(zip(indices, texts))


class FakeEndpoint:
    """An in-process language server wedged into the stdio transport.

    Writing a frame delivers it synchronously to `serve`, which answers by
    feeding stdout, so ordering is deterministic instead of timer based.
    """

    def __init__(self, mode: str = "normal") -> None:
        self.mode = mode
        self.stdin = self
        self.stdout = asyncio.StreamReader()
        self.stderr = asyncio.StreamReader()
        self.pid = 0x7FFF0000
        self.returncode = None
        self.buffer = bytearray()
        self.received: list[dict] = []
        # What the server believes is open, from its own didOpen/didClose stream.
        self.open: set[str] = set()

    # -- stdin -------------------------------------------------------------
    def write(self, data: bytes) -> None:
        self.buffer.extend(data)
        while True:
            header, separator, rest = bytes(self.buffer).partition(b"\r\n\r\n")
            if not separator:
                return
            length = None
            for line in header.split(b"\r\n"):
                key, _, value = line.partition(b":")
                if key.lower() == b"content-length":
                    length = int(value)
            assert length is not None and len(rest) >= length
            message = json.loads(rest[:length])
            del self.buffer[: len(header) + 4 + length]
            self.received.append(message)
            self.serve(message)

    async def drain(self) -> None:
        return None

    # -- process -----------------------------------------------------------
    async def wait(self):
        self.returncode = 0
        return 0

    def send(self, value) -> None:
        data = json.dumps({"jsonrpc": "2.0", **value}).encode()
        self.stdout.feed_data(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)

    def documents(self) -> list[dict]:
        """Every didOpen/didChange document in the order the client sent it."""
        found = []
        for message in self.received:
            method = message.get("method")
            if method == "textDocument/didOpen":
                found.append(dict(message["params"]["textDocument"]))
            elif method == "textDocument/didChange":
                found.append(
                    {
                        **message["params"]["textDocument"],
                        "text": message["params"]["contentChanges"][0]["text"],
                    }
                )
        return found

    def methods(self) -> list[str | None]:
        return [message.get("method") for message in self.received]

    def serve(self, message: dict) -> None:
        method = message.get("method")
        if method == "initialize":
            self.send(
                {
                    "id": message["id"],
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "hoverProvider": True,
                            "definitionProvider": True,
                            "referencesProvider": True,
                            "documentSymbolProvider": True,
                        }
                    },
                }
            )
        elif method == "shutdown":
            self.send({"id": message["id"], "result": None})
        elif method == "exit":
            self.returncode = 0
        elif method == "textDocument/didClose":
            self.open.discard(message["params"]["textDocument"]["uri"])
        elif method in ("textDocument/didOpen", "textDocument/didChange"):
            document = message["params"]["textDocument"]
            text = (
                document["text"]
                if "text" in document
                else message["params"]["contentChanges"][0]["text"]
            )
            uri = document["uri"]
            if method == "textDocument/didChange":
                assert uri in self.open, "didChange before didOpen"
            self.open.add(uri)
            # A stale publication precedes the fresh one, as a real server may send.
            self.send(
                {
                    "method": "textDocument/publishDiagnostics",
                    "params": {
                        "uri": uri,
                        "version": document["version"] - 1,
                        "diagnostics": [{"message": "stale"}],
                    },
                }
            )
            if self.mode == "stale-only":
                return
            self.send(
                {
                    "method": "textDocument/publishDiagnostics",
                    "params": {
                        "uri": uri,
                        "version": document["version"],
                        "diagnostics": [
                            {
                                "message": "fresh",
                                "text": text,
                                "range": {
                                    "start": {"line": 0, "character": 0},
                                    "end": {"line": 0, "character": 1},
                                },
                            }
                        ],
                    },
                }
            )
        elif method == "textDocument/hover":
            self.send(
                {
                    "id": message["id"],
                    "result": {"position": message["params"]["position"]},
                }
            )
        elif "id" in message:
            self.send({"id": message["id"], "result": None})


class Harness:
    """One temporary workspace with the stdio transport pointing at a fake."""

    def __init__(self, mode: str = "normal", wait_ms: int = 5000) -> None:
        self.mode = mode
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = self.root / "doc.nix"
        self.endpoints: list[FakeEndpoint] = []
        self._patcher = patch.object(asyncio, "create_subprocess_exec", self.spawn)
        self._patcher.start()
        self.manager = Lsp(
            {
                "version": 1,
                "servers": [
                    {
                        "id": "fake",
                        "bin": "unused",
                        "include": ["**/*.nix"],
                        "languageIdByExtension": {".nix": "nix"},
                        "startupTimeoutMs": 5000,
                        "diagnosticsWaitMs": wait_ms,
                    }
                ],
            },
            self.root,
        )

    def spawn(self, *_args, **_kwargs):
        endpoint = FakeEndpoint(self.mode)
        self.endpoints.append(endpoint)

        async def started():
            return endpoint

        return started()

    def write(self, text: str) -> None:
        self.path.write_bytes(text.encode("utf-8"))

    async def close(self) -> None:
        await self.manager.close()
        self._patcher.stop()
        self.temp.cleanup()


def case(body, *, mode: str = "normal", wait_ms: int = 5000):
    """Run one async property body on a fresh harness in its own loop."""

    async def main():
        harness = Harness(mode, wait_ms)
        try:
            await body(harness)
        finally:
            await harness.close()

    asyncio.run(main())


class PositionProperties(unittest.TestCase):
    """Zero-based line and UTF-16 character name exactly the text boundaries."""

    def test_position_integers_are_required(self) -> None:
        """Non-integer positions are rejected before any server starts."""
        # Booleans, floats and strings are not UTF-16 code unit counts.
        text = "a\U0001f600b\n"
        for line, character in (
            (True, 0),
            (0, True),
            (0.0, 0),
            (0, 2.0),
            ("0", 0),
            (0, "0"),
            (None, 0),
            (0, None),
            (-1, 0),
            (-0, -1),
        ):
            with self.subTest(line=line, character=character):
                with self.assertRaises(ValueError):
                    self.hover_result(text, line, character)

    def hover_result(self, text: str, line, character):
        """Call hover with arbitrary arguments, returning the call's outcome."""
        async def body(harness: Harness) -> None:
            harness.write(text)
            await harness.manager.hover("doc.nix", line, character)
            self.fail("hover accepted an invalid position")

        return case(body)

    @SETTINGS
    @given(DOCUMENTS)
    def test_positions_are_utf16_boundaries(self, text: str) -> None:
        async def body(harness: Harness) -> None:
            harness.write(text)
            expected = boundaries_by_line(text)
            for line, valid in enumerate(expected):
                # Every boundary, plus two units past the end of the line.
                for character in range(0, valid[-1] + 3):
                    try:
                        _, position = harness.manager.snapshot(
                            harness.path, "hover", line, character
                        )
                    except ValueError:
                        self.assertNotIn(
                            character, valid, (text, line, character, valid)
                        )
                    else:
                        self.assertIn(character, valid, (text, line, character, valid))
                        self.assertEqual(
                            position, {"line": line, "character": character}
                        )
            self.assertEqual(harness.endpoints, [])

        case(body)

    @SETTINGS
    @given(DOCUMENTS, st.data())
    def test_hover_echoes_the_requested_boundary(self, text: str, data) -> None:
        async def body(harness: Harness) -> None:
            harness.write(text)
            expected = boundaries_by_line(text)
            line = data.draw(st.integers(0, len(expected) - 1))
            character = data.draw(st.sampled_from(expected[line]))
            result = await harness.manager.hover("doc.nix", line, character)
            self.assertEqual(
                result["result"]["position"], {"line": line, "character": character}
            )
            sent = harness.endpoints[0].documents()
            self.assertEqual(sent[-1]["text"], text)

        case(body)

    @SETTINGS
    @given(DOCUMENTS)
    def test_invalid_positions_never_start_a_server(self, text: str) -> None:
        async def body(harness: Harness) -> None:
            harness.write(text)
            expected = boundaries_by_line(text)
            for line, valid in enumerate(expected):
                for character in (valid[-1] + 1, valid[-1] + 17, -1):
                    with self.assertRaises(ValueError):
                        await harness.manager.hover("doc.nix", line, character)
                with self.assertRaises(ValueError):
                    await harness.manager.hover("doc.nix", line, valid[0] + 0.5)
            with self.assertRaises(ValueError):
                await harness.manager.hover("doc.nix", len(expected), 0)
            self.assertEqual(harness.endpoints, [])

        case(body)

    @SETTINGS
    @given(st.lists(DOCUMENTS, min_size=1, max_size=6))
    def test_sync_sends_exact_text_once_per_change(self, texts) -> None:
        async def body(harness: Harness) -> None:
            versions: list[int] = []
            previous = None
            for text in texts:
                harness.write(text)
                result = await harness.manager.diagnostics("doc.nix")
                sent = harness.endpoints[0].documents()
                if previous == text:
                    # No redundant notification for an unchanged snapshot.
                    self.assertEqual(len(sent), len(versions))
                    self.assertEqual(result["version"], versions[-1])
                else:
                    self.assertEqual(len(sent), len(versions) + 1)
                    self.assertEqual(sent[-1]["text"], text)
                    self.assertEqual(sent[-1]["version"], result["version"])
                    if versions:
                        self.assertGreater(result["version"], versions[-1])
                    versions.append(result["version"])
                previous = text
                # Fresh diagnostics only: the stale publication never surfaces.
                messages = [item["message"] for item in result["diagnostics"]]
                self.assertEqual(messages, ["fresh"], result["diagnostics"])

        case(body)

    @SETTINGS
    @given(DOCUMENTS)
    def test_stale_publication_is_never_fresh_diagnostics(self, text: str) -> None:
        async def body(harness: Harness) -> None:
            harness.write(text)
            with self.assertRaises(LspError) as raised:
                await harness.manager.diagnostics("doc.nix")
            self.assertIn("fresh diagnostics", str(raised.exception))
            # The failure is terminal and keeps the server from being restarted.
            with self.assertRaises(LspError) as again:
                await harness.manager.diagnostics("doc.nix")
            self.assertIn("close explicitly", str(again.exception))

        case(body, mode="stale-only", wait_ms=1)

    @SETTINGS
    @given(distinct_steps())
    def test_open_documents_match_the_server(self, steps) -> None:
        async def body(harness: Harness) -> None:
            for index, text in steps:
                name = f"file{index}.nix"
                (harness.root / name).write_bytes(text.encode("utf-8"))
                await harness.manager.diagnostics(name)
                client = harness.manager.clients["fake"]
                endpoint = harness.endpoints[0]
                uris = set(client.docs)
                self.assertEqual(endpoint.open, uris)
                self.assertLessEqual(len(uris), 32)

        case(body)

    @SETTINGS
    @given(st.lists(st.tuples(st.integers(0, 3), DOCUMENTS), min_size=1, max_size=8))
    def test_batch_reports_every_matching_server(self, steps) -> None:
        async def body(harness: Harness) -> None:
            harness.manager.config.append(
                {**harness.manager.config[0], "id": "second"}
            )
            for index, text in steps:
                name = f"batch{index}.nix"
                (harness.root / name).write_bytes(text.encode("utf-8"))
                harness.manager.record(harness.root / name)
            result = await harness.manager.finish()
            self.assertTrue(result["ok"], result)
            reports = [
                json.loads(line)
                for line in result["feedback"].splitlines()
                if line.startswith("{")
            ]
            self.assertTrue(reports)
            servers = [report["server"] for report in reports]
            self.assertIn("fake", servers)
            self.assertIn("second", servers)
            for report in reports:
                self.assertEqual(
                    [item["message"] for item in report["diagnostics"]],
                    ["fresh"],
                    report,
                )
                self.assertNotIn("stale", json.dumps(report))
            self.assertEqual(harness.manager.pending, {})

        case(body)

    @SETTINGS
    @given(DOCUMENTS)
    def test_close_leaves_no_documents(self, text: str) -> None:
        async def body(harness: Harness) -> None:
            harness.write(text)
            await harness.manager.diagnostics("doc.nix")
            self.assertEqual(len(harness.manager.clients["fake"].docs), 1)
            await harness.manager.close()
            self.assertEqual(harness.manager.clients, {})
            self.assertEqual(harness.endpoints[0].methods()[-1], "exit")

        case(body)


def boundaries_by_line(text: str) -> list[list[int]]:
    return [boundaries(line) for line in lsp_lines(text)]


if __name__ == "__main__":
    unittest.main()
