"""Hypothesis discovery properties for the Python LSP, formatter, and RTK helpers.

Standalone harness: it imports the suite-owned sources from src/server/python and
needs a python3.13+ interpreter that can import hypothesis. Run it with, for
example:

  PYTHONPATH=/nix/store/phkb1drsrhb5z2bz3nf002f5cyy9sdfc-python3.14-hypothesis-6.168.1/lib/python3.14/site-packages:/nix/store/9l217z54y7skgapjy1q3kbf20g9mlfq8-python3.14-sortedcontainers-2.4.0/lib/python3.14/site-packages:/nix/store/l19pdmyq1s4lrmqa3n4z95c4xcv7bmla-python3.14-attrs-26.1.0/lib/python3.14/site-packages \
  /nix/store/bya4ansy58az5133kryqp2cvrxbnz8qy-python3-3.14.10/bin/python3.14 \
      test/proptest/py_lsp_formatter_rtk.py [-k <substring>]

Set ALBEDO_PY_SOURCE to import the three modules from another directory, which
calibrate.py uses to plant defects in throwaway copies.

Reference models here are deliberately independent of the production helpers:
UTF-16 boundaries come from encode("utf-16-le") prefix decoding, document
versions from a small OrderedDict replay, formatter publishes from an insertion
ordered replay of the pending postimages, and routing from the documented
grammar tables.

Known findings, each with its own fix change on main; every other test passes
against those changes merged:

- IdleBookkeepingTests fails where Lsp.close() cancels the idle-shutdown timer
  before rejecting an unknown server id, so the loaded server is never reaped.
  Fix: "Keep LSP idle shutdown armed when close rejects an unknown server".
RecordScopeTests pins the other half of that convention: record() follows the
write path (process cwd, like files.write/edit), while diagnostics and
files.check name workspace paths. The difference between those two conventions
is documented ambiguity, not a defect.
"""

from __future__ import annotations

import asyncio
from collections import OrderedDict
import hashlib
import fnmatch
import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

SOURCE = Path(
    os.environ.get("ALBEDO_PY_SOURCE")
    or Path(__file__).resolve().parents[2] / "src/server/python"
)
sys.path.insert(0, str(SOURCE))

import albedo_formatter  # noqa: E402,F401
import albedo_lsp  # noqa: E402
import albedo_rtk  # noqa: E402

import unittest.mock

from hypothesis import HealthCheck, given, settings, strategies as st  # noqa: E402  # ty: ignore[import-not-found]

EXAMPLES = int(os.environ.get("PROPTEST_EXAMPLES", "60"))
FAST = settings(
    max_examples=EXAMPLES,
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)


def u16(line: str) -> bytes:
    return line.encode("utf-16-le")


def is_boundary(line: str, character: int) -> bool:
    """Independent UTF-16 boundary oracle for one line of text."""
    raw = u16(line)
    if character < 0 or character * 2 > len(raw):
        return False
    if character in (0, len(raw) // 2):
        return True
    try:
        raw[: character * 2].decode("utf-16-le")
    except UnicodeDecodeError:
        return False
    return True


CHARACTERS = st.sampled_from(["a", "Z", " ", "\u00e9", "\u20ac", "\U0001f600", "\U0001d11e", "\t"])
LINES = st.lists(CHARACTERS, max_size=6).map("".join)
TEXTS = st.lists(LINES, max_size=4, min_size=1).map("\n".join)


class SnapshotPositionTests(unittest.TestCase):
    """Lsp.snapshot must accept exactly the UTF-16 code-unit boundaries of a line."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.path = cls.root / "text.txt"
        cls.manager = albedo_lsp.Lsp(
            {"version": 1, "servers": [{"id": "s", "bin": "true"}]}, cls.root
        )

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @FAST
    @given(text=TEXTS, data=st.data())
    def test_position_acceptance_matches_utf16_boundaries(self, text, data):
        self.path.write_bytes(text.encode("utf-8"))
        lines = text.split("\n")
        line = data.draw(st.integers(min_value=-1, max_value=len(lines)))
        character = data.draw(st.integers(min_value=-1, max_value=12))
        expected = 0 <= line < len(lines) and is_boundary(lines[line], character)
        try:
            _, position = self.manager.snapshot(self.path, "hover", line, character)
        except ValueError:
            self.assertFalse(expected, f"rejected valid position {line}:{character} in {text!r}")
        else:
            self.assertTrue(expected, f"accepted invalid position {line}:{character} in {text!r}")
            self.assertEqual(position, {"line": line, "character": character})

    def test_crlf_line_endings_are_not_content(self):
        self.path.write_bytes("bad\r\n\u00e9\r\n".encode("utf-8"))
        for line, character in ((0, 0), (0, 3), (1, 0), (1, 1)):
            self.assertEqual(
                self.manager.snapshot(self.path, "hover", line, character)[1],
                {"line": line, "character": character},
            )
        for line, character in ((0, 4), (1, 2)):
            with self.assertRaises(ValueError):
                self.manager.snapshot(self.path, "hover", line, character)

    def test_astral_characters_are_two_units(self):
        self.path.write_bytes("\U0001f600\n".encode("utf-8"))
        for character, accepted in ((0, True), (1, False), (2, True), (3, False)):
            try:
                self.manager.snapshot(self.path, "hover", 0, character)
            except ValueError:
                self.assertFalse(accepted, f"rejected character {character}")
            else:
                self.assertTrue(accepted, f"accepted character {character}")

    def test_position_is_rejected_for_non_integer_arguments(self):
        self.path.write_bytes(b"abc\n")
        for line, character in ((True, 0), (0, True), (0.0, 0), (0, 0.0)):
            with self.assertRaises(ValueError):
                self.manager.snapshot(self.path, "hover", line, character)


SERVER_IDS = st.text(min_size=1, max_size=8).filter(lambda value: "\0" not in value)
INCLUDE_PATTERNS = st.lists(
    st.sampled_from(["**/*", "**/*.py", "*.py", "src/**"]), max_size=3
)
ROOT_MARKERS = st.lists(st.sampled_from([".git", "pyproject.toml", "src"]), max_size=2)
LANGUAGE_IDS = st.dictionaries(
    st.sampled_from([".py", ".nix", ".go"]),
    st.sampled_from(["python", "nix", "go"]),
    max_size=3,
)


def server_strategy(ident):
    return st.builds(
        lambda include, markers, languages: {
            "id": ident,
            "bin": "/bin/sh",
            "args": ["-c", "exit 0"],
            "include": include,
            "rootMarkers": markers,
            "languageIdByExtension": languages,
        },
        INCLUDE_PATTERNS,
        ROOT_MARKERS,
        LANGUAGE_IDS,
    )


class ValidateTests(unittest.TestCase):
    """albedo_lsp.validate normalizes accepted configs and never aliases them."""

    @FAST
    @given(
        ids=st.lists(SERVER_IDS, min_size=1, max_size=3, unique=True),
        data=st.data(),
    )
    def test_round_trip_fills_defaults_without_sharing_state(self, ids, data):
        servers = [data.draw(server_strategy(ident)) for ident in ids]
        config = {"version": 1, "servers": servers}
        original = json.dumps(config, sort_keys=True)
        result = albedo_lsp.validate(config)
        self.assertEqual(json.dumps(config, sort_keys=True), original)
        self.assertEqual([item["id"] for item in result], ids)
        for item in result:
            self.assertTrue(item["enabled"])
            self.assertEqual(item["cwd"], "{root}")
            self.assertEqual(item["startupTimeoutMs"], 45000)
            self.assertEqual(item["diagnosticsWaitMs"], 2000)
            self.assertEqual(item["settings"], {})
            self.assertEqual(item["initializationOptions"], {})
        result[0]["args"].append("mutated")
        result[0]["settings"]["x"] = 1
        fresh = albedo_lsp.validate(config)
        self.assertEqual(fresh[0]["args"], ["-c", "exit 0"])
        self.assertEqual(fresh[0]["settings"], {})

    @FAST
    @given(
        key=st.sampled_from(
            [
                "id",
                "bin",
                "args",
                "include",
                "rootMarkers",
                "enabled",
                "cwd",
                "startupTimeoutMs",
                "diagnosticsWaitMs",
                "settings",
                "initializationOptions",
                "languageIdByExtension",
            ]
        ),
        value=st.one_of(
            st.none(),
            st.booleans(),
            st.integers(),
            st.floats(),
            st.text(),
            st.lists(st.text()),
            st.dictionaries(st.text(), st.text()),
        ),
    )
    def test_each_field_rejects_a_wrongly_typed_value(self, key, value):
        base = {"id": "srv", "bin": "/bin/sh"}
        if key in base:
            return
        server = {**base, key: value}
        def strings(item):
            return isinstance(item, list) and all(
                isinstance(v, str) and 0 < len(v) <= 4096 and "\0" not in v for v in item
            )

        def markers(item):
            # rootMarkers must be relative and stay inside the root.
            return strings(item) and all(
                not Path(v).is_absolute() and ".." not in Path(v).parts for v in item
            )

        expected = {
            "args": strings(value),
            "include": strings(value),
            "rootMarkers": markers(value),
            "enabled": isinstance(value, bool),
            "cwd": isinstance(value, str) and 0 < len(value) <= 4096 and "\0" not in value,
            "startupTimeoutMs": type(value) is int and 1 <= value <= 120000,
            "diagnosticsWaitMs": type(value) is int and 1 <= value <= 30000,
            "settings": isinstance(value, dict),
            "initializationOptions": isinstance(value, dict),
            "languageIdByExtension": isinstance(value, dict)
            and all(k.startswith(".") and 0 < len(k) <= 4096 for k in value),
        }.get(key)
        if expected is None:
            return
        try:
            albedo_lsp.validate({"version": 1, "servers": [server]})
        except ValueError:
            self.assertFalse(expected, f"rejected valid {key}={value!r}")
        else:
            self.assertTrue(expected, f"accepted invalid {key}={value!r}")

    def test_structural_rejections(self):
        for config in (
            [],
            {"version": 2},
            {"version": True},
            {"servers": {}},
            {"servers": [{"id": "a", "bin": "/bin/sh"}, {"id": "a", "bin": "/bin/sh"}]},
            {"servers": [{"id": "a", "bin": "/bin/sh", "rootMarkers": ["../x"]}]},
            {"servers": [{"id": "a", "bin": "/bin/sh", "rootMarkers": ["/abs"]}]},
            {"servers": [{"id": "a\0", "bin": "/bin/sh"}]},
            {"servers": [{"id": "a", "bin": "/bin/sh", "languageIdByExtension": {"py": "x"}}]},
        ):
            with self.assertRaises(ValueError):
                albedo_lsp.validate(config)
        self.assertEqual(albedo_lsp.validate({"version": 1}), [])

    def test_oversized_configuration_is_rejected(self):
        server = {
            "id": "big",
            "bin": "/bin/sh",
            "args": ["x" * 4000] * 120,
        }
        with self.assertRaises(ValueError):
            albedo_lsp.validate({"version": 1, "servers": [server] * 3})


class SyncModel:
    """Replays the document-sync bookkeeping without the transport."""

    def __init__(self, capacity=32):
        self.capacity = capacity
        self.docs = OrderedDict()
        self.counter = 0
        self.events = []

    def sync(self, uri, text):
        digest = hashlib.sha256(text.encode("utf-8")).digest()
        previous = self.docs.get(uri)
        if previous is not None and previous[1] == digest:
            self.docs.move_to_end(uri)
            return previous[0]
        self.counter += 1
        version = self.counter
        if previous is None and len(self.docs) >= self.capacity:
            old, _ = self.docs.popitem(last=False)
            self.events.append(("didClose", old, None))
        self.docs[uri] = (version, digest)
        method = "didChange" if previous else "didOpen"
        self.events.append((method, uri, version))
        return version


class SyncTests(unittest.TestCase):
    """_Client.sync versions follow one counter and one 32-document window."""

    def drive(self, operations):
        """Replay sync operations against the real client and the model."""
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        config = {
            "bin": "/bin/sh",
            "args": [],
            "include": ["**/*"],
            "languageIdByExtension": {".py": "python"},
            "initializationOptions": {},
            "settings": {},
        }
        client = getattr(albedo_lsp, "_Client")(config, root, root)
        sent = []

        async def send(value):
            sent.append(value)

        setattr(client, "send", send)  # instance transport double
        client.capabilities = {"textDocumentSync": {"change": 2}}
        model = SyncModel()
        loop = asyncio.new_event_loop()
        try:
            for index, text in operations:
                path = root / f"file{index}.py"
                version = loop.run_until_complete(client.sync(path, text))
                expected = model.sync(path.as_uri(), text)
                self.assertEqual(version, expected)
                self.assertLessEqual(len(client.docs), 32)
                self.assertEqual(client.doc_version, model.counter)
        finally:
            loop.close()
        self.assertEqual(
            [(value["method"], value["params"]["textDocument"]["uri"]) for value in sent],
            [("textDocument/" + method, uri) for method, uri, _ in model.events],
        )
        for value, (method, _, version) in zip(sent, model.events):
            if method != "didClose":
                self.assertEqual(value["params"]["textDocument"]["version"], version)
            if method == "didOpen":
                self.assertIn("text", value["params"]["textDocument"])
            else:
                self.assertNotIn("text", value["params"]["textDocument"])
        return sent, model

    def test_document_window_evicts_the_oldest_open_document(self):
        operations = [(index, f"text {index}\n") for index in range(40)]
        sent, model = self.drive(operations)
        closed = [value for value in sent if value["method"] == "textDocument/didClose"]
        self.assertEqual(
            [value["params"]["textDocument"]["uri"] for value in closed],
            [uri for method, uri, _ in model.events if method == "didClose"],
        )
        self.assertEqual(len(closed), 8)

    @FAST
    @given(
        operations=st.lists(
            st.tuples(st.integers(min_value=0, max_value=39), st.sampled_from(["a", "b", "", "c\n"])),
            max_size=60,
        )
    )
    def test_versions_and_events_follow_the_model(self, operations):
        self.drive(operations)

    def test_incremental_change_without_capability_is_rejected(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        config = {
            "bin": "/bin/sh",
            "args": [],
            "include": ["**/*"],
            "languageIdByExtension": {},
            "initializationOptions": {},
            "settings": {},
        }
        client = getattr(albedo_lsp, "_Client")(config, root, root)
        sent = []

        async def send(value):
            sent.append(value)

        setattr(client, "send", send)  # instance transport double
        client.capabilities = {"textDocumentSync": 0}
        loop = asyncio.new_event_loop()
        try:
            path = root / "file.py"
            self.assertEqual(loop.run_until_complete(client.sync(path, "a")), 1)
            with self.assertRaises(albedo_lsp.LspError):
                loop.run_until_complete(client.sync(path, "b"))
        finally:
            loop.close()
        self.assertEqual([value["method"] for value in sent], ["textDocument/didOpen"])


class RecordScopeTests(unittest.TestCase):
    """record() queues the file the caller wrote, which is process-cwd-relative.

    files.write()/edit() write relative paths against the process cwd and then
    hand the same spelling to record(), so a queued edit and its write must name
    one file. Only in-workspace results are queued; lsp diagnostics/hover and
    files.check name paths from the workspace, which is a separate convention.
    """

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name).resolve()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def manager(self, workspace):
        return albedo_lsp.Lsp(
            {"version": 1, "servers": [{"id": "s", "bin": "/bin/true", "include": ["**/*"]}]},
            workspace,
        )

    @FAST
    @given(
        spelling=st.sampled_from(["care.py", "./care.py", "sub/care.py", "sub/../care.py"]),
        cwd=st.sampled_from(["workspace", "nested"]),
    )
    def test_record_queues_the_file_a_relative_write_creates(self, spelling, cwd):
        work = Path(tempfile.mkdtemp(dir=self.root))
        workspace = work / "workspace"
        (workspace / "sub").mkdir(parents=True)
        outside = work / "outside"
        outside.mkdir()
        manager = self.manager(workspace)
        previous = os.getcwd()
        os.chdir({"workspace": workspace, "nested": workspace / "sub"}[cwd])
        try:
            # What files.write() does for the same spelling and cwd.
            written = Path(spelling).expanduser()
            written.parent.mkdir(parents=True, exist_ok=True)
            written.write_text("written\n")
            absolute = Path(os.path.abspath(written))
            manager.record(spelling)
        finally:
            os.chdir(previous)
        self.assertEqual(list(manager.pending), [absolute])
        self.assertEqual(absolute.read_text(), "written\n")

    def test_record_drops_a_write_outside_the_workspace(self):
        work = Path(tempfile.mkdtemp(dir=self.root))
        workspace = work / "workspace"
        workspace.mkdir()
        outside = work / "outside"
        outside.mkdir()
        manager = self.manager(workspace)
        previous = os.getcwd()
        os.chdir(outside)
        try:
            Path("elsewhere.py").write_text("x\n")
            manager.record("elsewhere.py")
        finally:
            os.chdir(previous)
        self.assertEqual(manager.pending, {})

    def test_diagnostics_resolve_relative_paths_against_the_workspace(self):
        work = Path(tempfile.mkdtemp(dir=self.root))
        (work / "nested").mkdir()
        (work / "file.nix").write_text("clean\n")
        (work / "nested" / "file.nix").write_text("nested\n")
        manager = self.manager(work)
        previous = os.getcwd()
        os.chdir(work / "nested")
        try:
            # Diagnostics name workspace paths while record() names written
            # paths; both spellings above are legal and must stay distinct.
            selected, _ = manager.select("file.nix", None)
            manager.record("file.nix")
        finally:
            os.chdir(previous)
        self.assertEqual(selected, work / "file.nix")
        self.assertEqual(list(manager.pending), [work / "nested" / "file.nix"])


class FinishBookkeepingTests(unittest.IsolatedAsyncioTestCase):
    """finish() classifies, versions and releases exactly the selected edits."""

    def manager(self, *, servers, pending):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name).resolve()
        config = []
        for name, include in servers:
            config.append(
                {
                    "id": name,
                    "bin": "/bin/true",
                    "args": [],
                    "include": include,
                    "languageIdByExtension": {".": "x"},
                    "initializationOptions": {},
                    "settings": {},
                    "cwd": "{root}",
                    "enabled": True,
                    "rootMarkers": [],
                    "startupTimeoutMs": 1000,
                    "diagnosticsWaitMs": 1000,
                }
            )
        manager = albedo_lsp.Lsp({"version": 1, "servers": config}, root)
        for name in pending:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("clean\n")
            manager.record(path)
        return manager

    @FAST
    @given(
        names=st.lists(
            st.sampled_from(["a.nix", "b.nix", "sub/c.nix", "d.txt", "sub/e.txt"]),
            max_size=5,
            unique=True,
        ),
        services=st.lists(
            st.tuples(
                st.sampled_from(["nix", "text"]),
                st.sampled_from([["**/*.nix"], ["**/*.txt"], ["**/*"]]),
            ),
            max_size=3,
        ),
        selected=st.one_of(
            st.none(),
            st.lists(
                st.sampled_from(["a.nix", "b.nix", "sub/c.nix", "d.txt", "sub/e.txt"]),
                max_size=3,
            ),
        ),
    )
    def test_checked_unmatched_versions_and_pending_follow_the_model(
        self, names, services, selected
    ):
        servers = [(f"{name}{index}", include) for index, (name, include) in enumerate(services)]
        manager = self.manager(servers=servers, pending=names)

        def matches(include, relative):
            return any(
                fnmatch.fnmatchcase(relative, pattern)
                or pattern.startswith("**/")
                and fnmatch.fnmatchcase(relative, pattern[3:])
                for pattern in include
            )

        subset = None if selected is None else {manager.cwd / name for name in selected}
        report = {"server": "stub", "path": "", "version": 1, "diagnostics": [{"message": "x"}]}
        counts = {}

        async def diagnostics(path, server=None):
            counts[(str(path), server)] = counts.get((str(path), server), 0) + 1
            return {**report, "path": str(path)}

        before = dict(manager.pending)
        with unittest.mock.patch.object(manager, "diagnostics", diagnostics):
            result = asyncio.run(manager.finish(subset, details=True))
        self.assertTrue(result["ok"], result["error"])
        wanted = {path for path in before if subset is None or path in subset}
        checked = set()
        unmatched = set()
        for path in wanted:
            relative = path.relative_to(manager.cwd).as_posix()
            enabled = [name for name, include in servers if matches(include, relative)]
            (checked if enabled else unmatched).add(path)
        self.assertEqual(set(result["checked"]), {str(path) for path in checked})
        self.assertEqual(set(result["unmatched"]), {str(path) for path in unmatched})
        self.assertEqual(set(result["_versions"]), wanted)
        for path, version in before.items():
            if path in wanted:
                self.assertEqual(result["_versions"][path], version)
        self.assertEqual(set(manager.pending), set(before) - wanted)
        expected_calls = set()
        for path in checked:
            relative = path.relative_to(manager.cwd).as_posix()
            for ident, include in servers:
                if matches(include, relative):
                    expected_calls.add((str(path), ident))
        self.assertEqual(set(counts), expected_calls)
        self.assertLessEqual(set(counts.values()), {1})
        self.assertEqual(bool(result["feedback"]), bool(checked))


class FormatterAdoptTests(unittest.IsolatedAsyncioTestCase):
    """finish(adopt=True) re-records selected postimages before publishing."""

    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({"mode": "uppercase"}))
        self.config = {
            "formatters": {
                "upper": {"command": [sys.executable, str(FORMATTER_FIXTURE), str(self.state)]}
            },
            "chains": {".py": ["upper"]},
            "timeoutMs": 20000,
        }
        albedo_formatter.configure(self.config, str(self.root))

    @FAST
    @given(
        first=st.sampled_from(["lower\n", "MiXeD\n"]),
        second=st.sampled_from(["lower\n", "MiXeD\n"]),
        adopted=st.booleans(),
    )
    def test_adopt_reconciles_an_already_changed_postimage(self, first, second, adopted):
        self.case = getattr(self, "case", 0) + 1
        workdir = self.root / f"case{self.case}"
        workdir.mkdir()
        albedo_formatter.configure(self.config, str(workdir))
        path = workdir / "file.py"
        path.write_text(first)
        albedo_formatter.record(path)
        # The user edits the file between record() and finish().
        path.write_text(second)
        result = asyncio.run(albedo_formatter.finish({path}, adopt=adopted, details=True))
        if adopted:
            self.assertTrue(result["ok"], result["error"])
            self.assertIn(str(path), result["reconciled"])
            self.assertEqual(path.read_text(), second.upper())
            self.assertFalse(albedo_formatter._pending)
        else:
            self.assertFalse(result["ok"])
            self.assertIn("concurrent change", result["error"])
            self.assertEqual(path.read_text(), second)
            self.assertIn(path, albedo_formatter._pending)


class FormatterRecordScopeTests(unittest.TestCase):
    """albedo_formatter.record() also queues the file a relative write created."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name).resolve()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @FAST
    @given(
        spelling=st.sampled_from(["care.py", "./care.py", "sub/care.py", "sub/../care.py"]),
        cwd=st.sampled_from(["workspace", "nested"]),
    )
    def test_record_queues_the_file_a_relative_write_creates(self, spelling, cwd):
        work = Path(tempfile.mkdtemp(dir=self.root))
        workspace = work / "workspace"
        (workspace / "sub").mkdir(parents=True)
        albedo_formatter.configure({"timeoutMs": 1000, "chains": {".py": []}}, str(workspace))
        previous = os.getcwd()
        os.chdir({"workspace": workspace, "nested": workspace / "sub"}[cwd])
        try:
            written = Path(spelling).expanduser()
            written.parent.mkdir(parents=True, exist_ok=True)
            written.write_text("written\n")
            absolute = Path(os.path.abspath(written))
            albedo_formatter.record(spelling)
        finally:
            os.chdir(previous)
        self.assertEqual(list(albedo_formatter._pending), [absolute])
        self.assertEqual(absolute.read_text(), "written\n")


class FormatterReadRaceTests(unittest.IsolatedAsyncioTestCase):
    """_read rejects a file whose identity changed between read and stat."""

    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({"mode": "uppercase"}))
        albedo_formatter.configure(
            {
                "formatters": {"upper": {"command": [sys.executable, str(FORMATTER_FIXTURE), str(self.state)]}},
                "chains": {".py": ["upper"]},
                "timeoutMs": 2000,
            },
            str(self.root),
        )

    def race(self, action):
        """Run `action` between the read and the post-read identity checks."""
        original = os.fstat
        calls = []

        def racing_fstat(fd):
            info = original(fd)
            calls.append(info)
            if len(calls) == 2:
                action()
            return info

        return unittest.mock.patch.object(os, "fstat", racing_fstat)

    def test_record_reports_a_file_rewritten_during_the_read(self):
        path = self.root / "file.py"
        path.write_text("original\n")

        def rewrite():
            with path.open("w") as handle:
                handle.write("rewritten and longer\n")

        with self.race(rewrite):
            albedo_formatter.record(path)
        stored = albedo_formatter._pending[path]
        self.assertIs(type(stored), str, f"record accepted a racing read: {stored!r}")
        self.assertIn("changed while reading", str(stored))
        result = asyncio.run(albedo_formatter.finish())
        self.assertFalse(result["ok"])
        self.assertEqual(path.read_text(), "rewritten and longer\n")

    def test_record_reports_a_file_replaced_during_the_read(self):
        path = self.root / "file.py"
        path.write_text("original\n")
        replacement = self.root / "replacement.py"
        replacement.write_text("original\n")

        def replace():
            os.replace(replacement, path)

        with self.race(replace):
            albedo_formatter.record(path)
        stored = albedo_formatter._pending[path]
        self.assertIs(type(stored), str, f"record accepted a replaced inode: {stored!r}")
        self.assertIn("changed while reading", str(stored))


class RtkRoutingTests(unittest.TestCase):
    """route() is identity or an RTK exec prefix, and probes RTK only when supported."""

    @FAST
    @given(
        program=st.sampled_from(["cargo", "go", "git", "ls", "pytest", "rg", "wc", "rtk", "/usr/bin/cargo", "./git"]),
        args=st.lists(
            st.sampled_from(
                ["test", "--", "a b", "-l", "-lah", "--json", "status", "diff", "--help", "-", "--porcelain", "--", "$(x)"]
            ),
            max_size=4,
        ),
        stdin=st.booleans(),
        has_rtk=st.booleans(),
    )
    def test_route_projection(self, program, args, stdin, has_rtk):
        argv = [program, *args]
        explicit = os.sep in program or program == "rtk"
        supported = albedo_rtk.supported(argv, stdin=stdin)
        if explicit:
            # RTK resolves tools by basename, so these keep their own identity.
            self.assertFalse(supported, f"explicit executable path routed: {argv}")
            self.assertEqual(albedo_rtk.route(argv, None, stdin=stdin), argv)
        probes = []

        def which(name, path=None):
            probes.append((name, path))
            return "/tools/rtk" if has_rtk else None

        with unittest.mock.patch.object(albedo_rtk.shutil, "which", which):
            try:
                routed = albedo_rtk.route(argv, {"PATH": "/custom/bin"}, stdin=stdin)
            except FileNotFoundError:
                self.assertTrue(supported)
                self.assertFalse(has_rtk)
                self.assertEqual(probes, [("rtk", "/custom/bin")])
                return
        if not supported:
            self.assertEqual(routed, argv)
            self.assertEqual(probes, [])
        else:
            self.assertEqual(routed, ["/tools/rtk", *argv])
            self.assertEqual(probes, [("rtk", "/custom/bin")])

    @FAST
    @given(
        program=st.sampled_from(["cargo", "go", "git", "ls", "pytest", "rg", "wc"]),
        args=st.lists(st.sampled_from(["test", "-l", "a"]), max_size=3),
    )
    def test_only_stdin_preserving_filters_accept_stdin(self, program, args):
        supported = albedo_rtk.supported([program, *args], stdin=True)
        if program == "rg":
            self.assertEqual(supported, bool(args), "rg needs a pattern to keep stdin")
        elif program == "wc":
            self.assertTrue(supported, "wc -l style filters keep stdin")
        else:
            self.assertFalse(supported, f"{program} would lose its stdin")

    def test_documented_grammar_boundaries(self):
        for argv, expected in (
            (["cargo", "test"], True),
            (["cargo", "build", "--", "--release"], True),
            (["go", "vet"], True),
            (["git", "log", "-1"], True),
            (["git"], False),
            (["git", "-C", "x", "status"], False),
            (["cargo", "+nightly", "test"], False),
            (["/usr/bin/cargo", "test"], False),
            (["rtk", "ls"], False),
            (["ls", "-la", "dir"], True),
            (["ls", "-laR"], False),
            (["pytest", "tests"], True),
            (["pytest", "--", "tests"], False),
            (["rg", "pattern"], True),
            (["rg"], False),
            (["wc", "-l", "a"], True),
            (["wc", "-", "a"], False),
            (["wc", "--files0-from", "x"], False),
        ):
            with self.subTest(argv=argv):
                self.assertIs(albedo_rtk.supported(argv), expected)

    def test_forbidden_flags_never_route(self):
        for flag in ("--json", "--null", "-0", "-z", "--message-format=json", "--porcelain", "--help", "-h", "--version", "-V", "--ultra-compact"):
            for program in ("cargo", "git", "go", "rg", "ls", "wc", "pytest"):
                with self.subTest(flag=flag, program=program):
                    self.assertFalse(albedo_rtk.supported([program, "status", flag]))
                    self.assertFalse(albedo_rtk.supported([program, flag, "status"]))



FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
FIXTURE = FIXTURES / "lsp-server.py"
FORMATTER_FIXTURE = FIXTURES / "formatter-unit.py"


class IdleBookkeepingTests(unittest.IsolatedAsyncioTestCase):
    """A loaded, healthy client always keeps an armed idle-shutdown timer."""

    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "test.nix"
        self.path.write_text("clean\n")
        server = {
            "id": "fixture",
            "bin": sys.executable,
            "args": [str(FIXTURE), "--mode", "normal", "--log", str(self.root / "log")],
            "include": ["**/*.nix"],
            "languageIdByExtension": {".nix": "nix"},
            "startupTimeoutMs": 2000,
            "diagnosticsWaitMs": 1000,
        }
        self.manager = albedo_lsp.Lsp({"version": 1, "servers": [server]}, self.root)

    async def asyncTearDown(self):
        await self.manager.close()

    def assert_idle_invariant(self):
        timer = self.manager.idle_timer
        live = [
            client
            for client in self.manager.clients.values()
            if client.proc is not None and not client.failure
        ]
        if live and not self.manager.active_operations:
            if timer is None:
                self.fail("healthy client lost its idle-shutdown timer")
            self.assertFalse(timer.cancelled(), "healthy client's idle timer was cancelled")

    async def test_sequence_steps_keep_idle_bookkeeping(self):
        steps = [
            ("diagnostics", lambda: self.manager.diagnostics("test.nix")),
            ("reject", lambda: self.manager.close("typo")),
            ("servers", self.manager.servers),
        ]
        for name, step in steps:
            with self.subTest(step=name):
                try:
                    outcome = step()
                    if asyncio.iscoroutine(outcome):
                        await outcome
                except albedo_lsp.LspError:
                    pass
                self.assert_idle_invariant()

    async def test_unknown_server_close_keeps_timer_and_client(self):
        await self.manager.diagnostics("test.nix")
        self.assertIsNotNone(self.manager.idle_timer)
        with self.assertRaisesRegex(albedo_lsp.LspError, "unknown LSP server"):
            await self.manager.close("typo")
        self.assertEqual([item["state"] for item in self.manager.servers()], ["loaded"])
        self.assert_idle_invariant()


class FormatterSnapshotTests(unittest.TestCase):
    """_snapshot stages tracked targets byte-identically and links the rest."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        albedo_formatter = importlib.import_module("albedo_formatter")
        cls.formatter = albedo_formatter

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @FAST
    @given(
        targets=st.lists(st.sampled_from(["a.py", "sub/b.py", "sub/deep/c.txt", "d.py"]), min_size=1, max_size=3, unique=True),
        siblings=st.lists(st.sampled_from(["loose.txt", "sub/note.md", "sub/deep/other.txt"]), max_size=3, unique=True),
        contents=st.lists(st.binary(max_size=12), min_size=1, max_size=3),
        modes=st.lists(st.sampled_from([0o600, 0o644, 0o751]), min_size=1, max_size=3),
    )
    def test_staged_targets_are_copies_and_other_entries_are_links(self, targets, siblings, contents, modes):
        work = Path(tempfile.mkdtemp(dir=self.root))
        workspace = work / "workspace"
        staged = work / "staged"
        workspace.mkdir()
        staged.mkdir()
        for index, name in enumerate(targets):
            path = workspace / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents[index % len(contents)])
            path.chmod(modes[index % len(modes)])
        for name in siblings:
            path = workspace / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"sibling")
        previous = self.formatter._root
        try:
            self.formatter.configure({"timeoutMs": 1000}, str(workspace))
            selected = [workspace / name for name in targets]
            self.formatter._snapshot(staged, selected)
        finally:
            self.formatter._root = previous
        for index, name in enumerate(targets):
            copy = staged / name
            self.assertFalse(copy.is_symlink(), f"staged target {name} must be a copy")
            self.assertEqual(copy.read_bytes(), (workspace / name).read_bytes())
            self.assertEqual(copy.stat().st_mode & 0o777, modes[index % len(modes)])
        for name in siblings:
            if name in targets:
                continue
            link = staged / name
            self.assertTrue(link.exists(), f"context entry {name} must stay visible")
            self.assertEqual(
                os.stat(link).st_ino,
                os.stat(workspace / name).st_ino,
                f"context entry {name} must be a read-through link, not a copy",
            )


class FormatterCommandTests(unittest.TestCase):
    """_commands targets the nearest project marker and otherwise the suffix chain."""

    @classmethod
    def setUpClass(cls):
        cls.formatter = importlib.import_module("albedo_formatter")

    @FAST
    @given(
        relative=st.sampled_from(["a.py", "sub/b.py", "sub/deep/c.py"]),
        markers=st.dictionaries(
            st.sampled_from(["", "sub", "sub/deep"]),
            st.sampled_from(["treefmt.toml", ".treefmt.toml", "flake.nix"]),
            max_size=3,
        ),
    )
    def test_nearest_marker_wins(self, relative, markers):
        work = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(work, ignore_errors=True))
        (work / relative).parent.mkdir(parents=True, exist_ok=True)
        (work / relative).write_text("x\n")
        for directory, name in markers.items():
            (work / directory / name).parent.mkdir(parents=True, exist_ok=True)
            (work / directory / name).write_text("")
        config = {
            "timeoutMs": 1000,
            "treefmt": ["treefmt"],
            "nix": ["nix"],
            "chains": {".py": ["upper"]},
            "formatters": {"upper": {"command": ["upper"]}},
        }
        self.formatter.configure(config, str(work))
        path = work / relative
        staged = path
        commands = self.formatter._commands(path, staged)
        nearest = None
        directory = path.parent
        while True:
            for name in ("treefmt.toml", ".treefmt.toml", "flake.nix"):
                if (directory / name).is_file():
                    nearest = (directory, name)
                    break
            if nearest or directory == work:
                break
            directory = directory.parent
        if nearest is None:
            self.assertEqual(commands, [(["upper", str(staged)], path.parent)])
            return
        directory, name = nearest
        self.assertEqual(len(commands), 1)
        argv, cwd = commands[0]
        self.assertEqual(cwd, directory)
        if name == "flake.nix":
            self.assertEqual(argv, ["nix", "fmt", "--", str(staged)])
        else:
            self.assertEqual(argv[:2], ["treefmt", "--no-cache"])
            self.assertEqual(argv[argv.index("--config-file") + 1], str(directory / name))
            self.assertEqual(argv[argv.index("--tree-root") + 1], str(work))
            self.assertEqual(argv[-2:], ["--", str(staged)])


class FormatterFinishTests(unittest.IsolatedAsyncioTestCase):
    """finish() publishes formatted content exactly for clean tracked postimages."""

    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({"mode": "uppercase"}))
        self.config: dict = {
            "formatters": {"upper": {"command": [sys.executable, str(FORMATTER_FIXTURE), str(self.state)]}},
            "chains": {".py": ["upper"]},
            "timeoutMs": 20000,
        }
        albedo_formatter.configure(self.config, str(self.root))
        self.formatter = albedo_formatter

    @FAST
    @given(
        operations=st.lists(
            st.tuples(
                st.sampled_from(["write", "record", "finish", "finish_subset"]),
                st.integers(min_value=0, max_value=3),
                st.sampled_from(["lower\n", "MiXeD\n", "already upper\n"]),
            ),
            max_size=8,
        )
    )
    def test_content_and_pending_follow_the_model(self, operations):
        self.case = getattr(self, "case", 0) + 1
        workdir = self.root / f"case{self.case}"
        workdir.mkdir()
        self.log = workdir / "runs.log"
        self.expected_runs = 0
        # A wrapper records every formatter invocation, so the property can tell
        # a batch that aborted before formatting from one that formatted anyway.
        self.config["formatters"]["upper"]["command"] = [
            "/bin/sh",
            "-c",
            'echo run >> "$1"; shift; exec "$@"',
            "sh",
            str(self.log),
            sys.executable,
            str(FORMATTER_FIXTURE),
            str(self.state),
        ]
        albedo_formatter.configure(self.config, str(workdir))
        paths = [workdir / f"file{index}.py" for index in range(4)]
        content = {}
        for index, path in enumerate(paths):
            text = f"seed{index}\n"
            path.write_text(text)
            content[path] = text
        pending = {}
        for kind, index, text in operations:
            path = paths[index]
            if kind == "write":
                path.write_text(text)
                content[path] = text
                if path in pending:
                    # Any rewrite changes the identity the postimage recorded,
                    # even when the bytes are unchanged.
                    pending[path] = None
            elif kind == "record":
                self.formatter.record(path)
                pending[path] = path.read_text()
            elif kind == "finish":
                self.publish(pending, content, paths)
            else:
                subset = {item for item in pending if paths.index(item) % 2 == index % 2}
                self.publish(pending, content, paths, subset)
        self.assertEqual({path: path.read_text() for path in paths}, content)

    def publish(self, pending, content, paths, selected=None):
        """Predict one finish(): publish clean postimages, stop at a stale one."""
        wanted = set(pending) if selected is None else selected
        predicted = dict(content)
        remaining = dict(pending)
        changed = False
        stale = None
        runs = 0
        for path in list(pending):
            if path not in wanted:
                continue
            if pending[path] is None or pending[path] != predicted[path]:
                stale = path
                break
            formatted = predicted[path].upper()
            if formatted != predicted[path]:
                predicted[path] = formatted
                changed = True
            runs += 1
            del remaining[path]
        result = asyncio.run(self.formatter.finish(selected))
        if stale is not None:
            self.assertFalse(result["ok"], f"stale postimage for {stale} must fail the batch")
            self.assertIn("concurrent change", result["error"])
        else:
            self.assertTrue(result["ok"], result["error"])
            self.assertEqual(result["changed"], changed, result)
        self.assertEqual({path: path.read_text() for path in paths}, predicted)
        self.assertEqual(set(remaining), set(self.formatter._pending))
        self.expected_runs += runs
        actual_runs = (
            len(self.log.read_text().splitlines()) if self.log.exists() else 0
        )
        self.assertEqual(
            actual_runs,
            self.expected_runs,
            "formatter ran for a file the batch should have rejected or skipped",
        )
        pending.clear()
        pending.update(remaining)
        content.clear()
        content.update(predicted)


class MissingFormatterTests(unittest.TestCase):
    """_missing_formatter matches only Nix's absent-formatter diagnostic."""

    @classmethod
    def setUpClass(cls):
        cls.formatter = importlib.import_module("albedo_formatter")

    def test_matches_the_observed_nix_diagnostic(self):
        observed = (
            "error: flake 'path:/tmp/nixfmt2-m_3ee9tn' does not provide attribute "
            "'formatter.x86_64-linux'\n"
        )
        self.assertTrue(self.formatter._missing_formatter(observed))
        self.assertTrue(
            self.formatter._missing_formatter(
                "error: flake 'github:o/r' does not provide attribute "
                "'packages.x86_64-linux.formatter', 'legacyPackages.x86_64-linux.formatter' "
                "or 'formatter.x86_64-linux'\n"
            )
        )

    @FAST
    @given(
        flake=st.sampled_from(["path:/tmp/x", "github:o/r", "git+file:///x", "./local"]),
        system=st.sampled_from(["x86_64-linux", "aarch64-darwin", "riscv64-linux"]),
        candidates=st.booleans(),
        suffix=st.sampled_from(["\n", "\nsecond line\n", ""]),
    )
    def test_accepts_generated_absent_formatter_messages(self, flake, system, candidates, suffix):
        if candidates:
            attribute = (
                f"'packages.{system}.formatter', 'legacyPackages.{system}.formatter' "
                f"or 'formatter.{system}'"
            )
        else:
            attribute = f"'formatter.{system}'"
        message = f"error: flake '{flake}' does not provide attribute {attribute}{suffix}"
        self.assertTrue(self.formatter._missing_formatter(message))

    @FAST
    @given(
        text=st.sampled_from(
            [
                "error: builder for '/nix/store/x.drv' failed with exit code 1;\n",
                "error: flake 'path:/tmp/x' does not provide attribute 'packages.x86_64-linux.hello'\n",
                "error: flake 'path:/tmp/x' provides attribute 'formatter.x86_64-linux'\n",
                "error: syntax error, unexpected end of file\n",
                "error: flake 'path:/tmp/x' does not provide attribute formatter.x86_64-linux\n",
                "warning: error: flake 'path:/tmp/x' does not provide attribute 'formatter.x86_64-linux' extra\n",
            ]
        )
    )
    def test_rejects_unrelated_diagnostics(self, text):
        self.assertFalse(self.formatter._missing_formatter(text))


if __name__ == "__main__":
    unittest.main(verbosity=2)
