"""Model-based property tests for `files.check` pending tracking and publishing.

Discovery harness for the formatter / files.check batch. It replays generated
operation histories against a scratch workspace and an independent model of the
documented contract (docs/formatter.md):

* writes and edits through the files API enroll a path, external writes do not;
* `files.check()` formats exactly the pending scope, or the explicit paths while
  leaving other pending paths untouched, and adopts current disk snapshots;
* successful publishes replace whole files, failed or conflicting paths stay
  pending and are never overwritten, and every pending path keeps the postimage
  of the bytes it was recorded with;
* `reconciled`, `checked`, `unmatched`, `changed_paths`, `conflicts` and the
  reported pending map describe what actually happened.

The formatter is a deterministic in-process stand-in installed as
`albedo_formatter._run` (as the unit tests do). It appends a marker to the staged
bytes or writes a chosen literal. It is deliberately not idempotent, so feeding
the wrong bytes into staging (a stale snapshot, the wrong file) changes the
published result. The model never calls the code under test for an expectation.

Run with a Python that has hypothesis, for example:

  PYTHONPATH=<python overlay with albedo_formatter> \
  ALBEDO_FORMATTER_SOURCE=<same overlay> \
  <python-with-hypothesis> test/files_check_property_test.py

It is not wired into `nix flake check`: that check's Python has no hypothesis.
"""

import asyncio
import contextlib
import importlib
import os
import sys
import tempfile
import unittest
from pathlib import Path

from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

sys.path.insert(0, os.environ["ALBEDO_FORMATTER_SOURCE"])
formatter = importlib.import_module("albedo_formatter")
# Importing the plugin is what enables the formatting stage in Files.check().
importlib.import_module("albedo_plugins.formatter")
files_plugin = importlib.import_module("albedo_plugins.files")
assert "albedo_plugins.lsp" not in sys.modules, "the harness measures formatting only"


def formatted(text):
    """The stand-in formatter, fixed here and never asked from the module."""
    return text + "!"


NAMES = ("a.py", "b.py", "sub/c.py", "d.txt")
CHAINED = tuple(name for name in NAMES if name.endswith(".py"))
BASENAMES = {name: Path(name).name for name in NAMES}


class Machine:
    """Replays one operation history and compares results with the model."""

    def __init__(self, root):
        self.root = root
        self.fs = files_plugin.Files()
        self.content = {}  # name -> bytes the model expects on disk
        self.modes = {}  # name -> permission bits a publish must preserve
        self.pending = {}  # name -> None, in tracking order
        self.dirty = set()  # pending names whose bytes moved since their postimage
        self.by_basename = {BASENAMES[name]: name for name in NAMES}
        self.mode = None
        self.target = None
        self.text = None
        self.event = None  # (trigger, victim, text) written during a run
        self.acted = False
        self.race = None  # victim written between the publish checks
        self.last_fire_possible = False
        self.current = None

    # -- disk helpers -----------------------------------------------------

    def path(self, name):
        return self.root / name

    def read(self, name):
        try:
            return self.path(name).read_text()
        except FileNotFoundError:
            return None

    def snapshot_disk(self):
        return {name: self.read(name) for name in NAMES}

    # -- the stand-in formatter ------------------------------------------

    async def fake_run(self, argv, cwd, *, nix_fmt=False, tree_root=None):
        staged = Path(argv[-1])
        name = self.by_basename[staged.name]
        self.current = name
        if self.event is not None and name == self.event[0] and not self.acted:
            self.acted = True
            victim, text = self.event[1], self.event[2]
            if self.path(victim).is_file():
                self.path(victim).write_text(text)
        if self.mode == "fail" and name == self.target:
            raise ValueError("formatter exited 1: boom")
        if self.mode == "record_self" and name == self.target:
            formatter.record(self.path(name))
        original = staged.read_text()
        if self.mode == "noop":
            return
        if self.mode == "set" and name == self.target:
            staged.write_text(self.text)
            return
        staged.write_text(formatted(original))

    @contextlib.contextmanager
    def publish_window_race(self):
        """Rewrite the target between `_publish`'s identity check and replace."""
        machine = self
        real_fsync = os.fsync

        def racing_fsync(descriptor):
            real_fsync(descriptor)
            if machine.race is not None and machine.current == machine.race[0]:
                victim, text = machine.race
                machine.race = None
                machine.path(victim).write_text(text)

        formatter.os.fsync = racing_fsync
        try:
            yield
        finally:
            formatter.os.fsync = real_fsync

    # -- operations -------------------------------------------------------

    def do_write(self, name, text, mode=0o644):
        self.path(name).parent.mkdir(parents=True, exist_ok=True)
        self.path(name).touch()
        self.path(name).chmod(mode)
        self.fs.write(str(self.path(name)), text)
        self.content[name] = text
        self.modes[name] = mode
        self.pending[name] = None
        self.dirty.discard(name)

    def do_external(self, name, text, mode=0o644):
        self.path(name).parent.mkdir(parents=True, exist_ok=True)
        self.path(name).write_text(text)
        self.path(name).chmod(mode)
        self.content[name] = text
        self.modes[name] = mode
        self.dirty.add(name)

    def do_delete(self, name):
        self.path(name).unlink()
        del self.content[name]
        self.modes.pop(name, None)
        self.dirty.discard(name)

    def model_check(self, scope, mode, target, victim, text, project=False):
        """Expected outcome, computed only from this model's own state."""
        expected = {
            "selected": set(),
            "ok": True,
            "changed": set(),
            "checked": set(),
            "unmatched": set(),
            "conflicts": set(),
            "reconciled": set(),
            "invalid": False,
        }
        self.last_fire_possible = False
        selected = set(self.pending) if scope is None else set(scope)
        expected["selected"] = selected
        if not selected:
            return expected
        if any(name not in self.content for name in selected):
            # Validation rejects a missing or irregular selected path before
            # anything is enrolled, formatted or published.
            expected["ok"] = False
            expected["invalid"] = True
            return expected

        expected["reconciled"] = {
            name for name in selected if name in self.pending and name in self.dirty
        }
        # Adoption enrolls every selected path, newcomers in sorted order.
        for name in sorted(selected):
            self.pending.setdefault(name, None)
            self.dirty.discard(name)

        order = [name for name in self.pending if name in selected]
        positions = {name: index for index, name in enumerate(order)}
        fire_at = positions.get(target) if mode == "concurrent" else None
        if mode == "publish_race":
            fire_at = positions.get(victim)
            current = self.content.get(victim)
            # An absent or unmatched file publishes nothing: no window.
            if (
                current is None
                or formatted(current) == current
                or not victim.endswith(".py")
            ):
                fire_at = None
        self.last_fire_possible = fire_at is not None

        stopped = False
        fired = False
        for index, name in enumerate(order):
            if index == fire_at and victim in self.content:
                self.content[victim] = text
                self.dirty.add(victim)
                fired = True
            if mode in ("fail", "record_self") and name == target:
                stopped = True
                break
            if fired and name == victim:
                # The recorded postimage (or the staged publish) no longer
                # matches the bytes on disk: this path stops the batch.
                stopped = True
                break
            current = self.content[name]
            if not name.endswith(".py") and not project:
                # No configured chain: a successful exclusion, never published.
                expected["unmatched"].add(name)
                self.pending.pop(name, None)
                continue
            if mode == "set" and name == target:
                new = self.text
            elif mode == "noop":
                new = current
            else:
                new = formatted(current)
            if new != current:
                self.content[name] = new
                expected["changed"].add(name)
            expected["checked"].add(name)
            self.pending.pop(name, None)

        if fired and victim in selected:
            # A change to an already published path is caught by the final
            # revalidation and re-enrolled, without overwriting it.
            expected["conflicts"].add(victim)
            if victim not in self.pending:
                self.pending[victim] = None
            self.dirty.discard(victim)

        if stopped or expected["conflicts"]:
            expected["ok"] = False
        elif not expected["checked"]:
            # Nothing was verified, so `ok` stays unknown.
            expected["ok"] = None
        return expected

    async def do_check(self, scope, mode, target, victim, text, project=False):
        self.mode = "upper" if mode == "concurrent" else mode
        self.target = target if mode in ("fail", "record_self", "set") else None
        self.text = text
        self.event = (target, victim, text) if mode == "concurrent" else None
        self.race = (victim, text) if mode == "publish_race" else None
        self.acted = False
        formatter._run = self.fake_run
        paths = None if scope is None else [str(self.path(name)) for name in scope]
        with contextlib.ExitStack() as stack:
            if mode == "publish_race":
                stack.enter_context(self.publish_window_race())
            result = await self.fs.check(paths=paths)
        expected = self.model_check(scope, mode, target, victim, text, project)
        if mode == "publish_race" and self.last_fire_possible:
            assert self.race is None, "the publish window race never fired"
        self.verify(result, expected)

    # -- assertions -------------------------------------------------------

    def verify(self, result, expected):
        stage = result["formatting"]
        context = {"mode": self.mode, "event": self.event, "stage": stage}
        model_disk = {name: self.content.get(name) for name in NAMES}
        assert self.snapshot_disk() == model_disk, (
            f"on-disk contents diverged from the model: {self.snapshot_disk()} != {model_disk} ({context})"
        )
        model_modes = {
            name: self.path(name).stat().st_mode & 0o7777 for name in self.content
        }
        assert model_modes == self.modes, (
            f"published files lost their mode: {model_modes} != {self.modes} ({context})"
        )
        model_pending = {str(self.path(name)) for name in self.pending}
        tracked = {str(path) for path in formatter.pending_paths()}
        assert tracked == model_pending, (
            f"tracked pending paths diverged: {sorted(tracked)} != {sorted(model_pending)} ({context})"
        )
        reported = result["pending"].get("formatting")
        if reported is not None:
            assert set(reported) == model_pending, (
                f"reported pending paths diverged: {sorted(reported)} != {sorted(model_pending)} ({context})"
            )
        scope = {str(self.path(name)) for name in expected["selected"]}
        if scope:
            for key, names in (
                ("changed_paths", expected["changed"]),
                ("checked", expected["checked"]),
                ("unmatched", expected["unmatched"]),
            ):
                wanted = {str(self.path(name)) for name in names}
                got = set(stage.get(key, []))
                assert got == wanted, (
                    f"{key} diverged: {sorted(got)} != {sorted(wanted)} ({context})"
                )
            reconciled = set(stage.get("reconciled", []))
            wanted = {str(self.path(name)) for name in expected["reconciled"]}
            assert reconciled == wanted, (
                f"reconciled diverged: {sorted(reconciled)} != {sorted(wanted)} ({context})"
            )
        conflicts = {str(self.path(name)) for name in expected["conflicts"]}
        assert set(result["conflicts"]) == conflicts, (
            f"conflicts diverged: {result['conflicts']} != {sorted(conflicts)} ({context})"
        )
        assert result["ok"] == expected["ok"], (
            f"ok diverged: {result['ok']} != {expected['ok']} ({context})"
        )
        if not expected["selected"]:
            wanted_status, wanted_clean = "idle", None
        else:
            wanted_status = (
                "failed"
                if expected["ok"] is False
                else "ok"
                if expected["ok"]
                else "unmatched"
            )
            if expected["invalid"]:
                wanted_clean = False
            else:
                wanted_clean = (
                    None
                    if expected["ok"] is None or not expected["checked"]
                    else bool(expected["ok"])
                )
        assert result["status"] == wanted_status, (
            f"status diverged: {result['status']} != {wanted_status} ({context})"
        )
        assert result["clean"] == wanted_clean, (
            f"clean diverged: {result['clean']} != {wanted_clean} ({context})"
        )
        stale = set(formatter._versions) - set(formatter._pending)
        assert not stale, (
            f"version entries leaked for unchecked paths: {sorted(map(str, stale))}"
        )

    async def run_op(self, op, project=False):
        kind = op[0]
        if kind == "write":
            self.do_write(*op[1:])
        elif kind == "external":
            self.do_external(*op[1:])
        elif kind == "delete" and op[1] in self.content:
            self.do_delete(op[1])
        elif kind == "check":
            await self.do_check(*op[1:], project=project)


def seed_strategy():
    return st.tuples(
        st.sampled_from(NAMES),
        st.text(alphabet="aA \n", max_size=5),
        st.sampled_from([0o600, 0o644, 0o751, 0o755]),
    )


def op_strategy():
    names = st.sampled_from(NAMES)
    chained = st.sampled_from(CHAINED)
    texts = st.text(alphabet="aA \n", max_size=5)
    modes = st.sampled_from([0o600, 0o644, 0o751, 0o755])
    write = st.tuples(st.just("write"), names, texts, modes)
    external = st.tuples(st.just("external"), names, texts, modes)
    delete = st.tuples(st.just("delete"), names)
    # Checks dominate: a deleted pending path fails every later pending check,
    # and too many deletes crowd out publishing and conflict histories.
    return st.one_of(
        [write, write, write, external, external, delete]
        + [
            check
            for check in [
                st.tuples(
                    st.just("check"),
                    st.one_of(
                        st.none(), st.lists(names, min_size=1, max_size=3, unique=True)
                    ),
                    st.sampled_from(
                        [
                            "upper",
                            "noop",
                            "fail",
                            "set",
                            "concurrent",
                            "record_self",
                            "publish_race",
                        ]
                    ),
                    chained,
                    chained,
                    texts,
                )
            ]
            * 6
        ]
    )


SMALL_OPS = (
    ("write", "a.py", "a", 0o644),
    ("write", "b.py", "b", 0o600),
    ("write", "d.txt", "d", 0o644),
    ("external", "a.py", "x", 0o644),
    ("delete", "b.py"),
    ("check", None, "upper", "a.py", "a.py", ""),
    ("check", ["a.py"], "upper", "a.py", "a.py", ""),
    ("check", None, "fail", "a.py", "a.py", ""),
    ("check", None, "concurrent", "a.py", "b.py", "y"),
    ("check", None, "publish_race", "a.py", "a.py", "z"),
)


def small_histories(depth):
    if depth == 0:
        yield ()
        return
    for history in small_histories(depth - 1):
        for op in SMALL_OPS:
            yield (*history, op)


def replay(operations, project=False):
    temporary = tempfile.TemporaryDirectory()
    root = Path(temporary.name).resolve()
    try:
        if project:
            (root / "treefmt.toml").write_text("[formatter.upper]\n")
        formatter.configure(
            {
                "formatters": {"upper": {"command": [sys.executable, "-c", "format"]}},
                "chains": {".py": ["upper"]},
                "treefmt": [sys.executable, "-c", "format"],
                "timeoutMs": 20000,
            },
            str(root),
        )
        machine = Machine(root)
        loop = asyncio.new_event_loop()
        try:
            for op in operations:
                loop.run_until_complete(machine.run_op(op, project=project))
        finally:
            loop.close()
    finally:
        formatter._root = None
        formatter._pending.clear()
        formatter._versions.clear()
        formatter._overflow = ""
        formatter._generation = 0
        temporary.cleanup()


class FilesCheckPropertyTest(unittest.TestCase):
    @settings(
        max_examples=300,
        deadline=None,
        suppress_health_check=[HealthCheck.too_slow, HealthCheck.filter_too_much],
    )
    @given(edit=seed_strategy(), operations=st.lists(op_strategy(), max_size=10))
    def test_check_state_machine(self, edit, operations):
        # Every history starts from pending work, so checks have a scope.
        replay([("write", *edit), *operations])

    @settings(
        max_examples=300,
        deadline=None,
        suppress_health_check=[HealthCheck.too_slow, HealthCheck.filter_too_much],
    )
    @given(edit=seed_strategy(), operations=st.lists(op_strategy(), max_size=10))
    def test_check_state_machine_under_project_formatter(self, edit, operations):
        replay([("write", *edit), *operations], project=True)

    def test_small_histories_exhaustive(self):
        """Every history of DEPTH operations from a reduced alphabet."""
        depth = int(os.environ.get("DS_SMALL_DEPTH", "3"))
        for history in small_histories(depth):
            replay(list(history))
            replay(list(history), project=True)

    def test_scripted_histories(self):
        """Every interesting behaviour is reachable and modelled; keeps the
        generator honest and documents the shapes the model expects."""
        histories = {
            "publish": [
                ("write", "a.py", "abc", 0o644),
                ("check", None, "upper", "a.py", "a.py", ""),
            ],
            "no-op reformat": [
                ("write", "a.py", "ABC", 0o644),
                ("check", None, "noop", "a.py", "a.py", ""),
            ],
            "formatter failure": [
                ("write", "a.py", "a", 0o644),
                ("check", None, "fail", "a.py", "a.py", ""),
            ],
            "concurrent self": [
                ("write", "a.py", "a", 0o644),
                ("check", None, "concurrent", "a.py", "a.py", "user"),
            ],
            "concurrent later": [
                ("write", "a.py", "a", 0o644),
                ("write", "b.py", "b", 0o644),
                ("check", None, "concurrent", "a.py", "b.py", "user"),
            ],
            "concurrent earlier": [
                ("write", "a.py", "a", 0o644),
                ("write", "b.py", "b", 0o644),
                ("check", None, "concurrent", "b.py", "a.py", "user"),
            ],
            "publish window": [
                ("write", "a.py", "a", 0o644),
                ("check", None, "publish_race", "a.py", "a.py", "user"),
            ],
            "record during run": [
                ("write", "a.py", "a", 0o644),
                ("check", None, "record_self", "a.py", "a.py", ""),
            ],
            "external adoption": [
                ("write", "a.py", "a", 0o644),
                ("external", "a.py", "externally formatted", 0o644),
                ("check", None, "upper", "a.py", "a.py", ""),
            ],
            "subset scope": [
                ("write", "a.py", "a", 0o644),
                ("write", "b.py", "b", 0o644),
                ("check", ["a.py"], "upper", "a.py", "a.py", ""),
            ],
            "shell file enrollment": [
                ("external", "b.py", "b", 0o644),
                ("check", ["b.py"], "upper", "b.py", "b.py", ""),
            ],
            "unmatched conflict": [
                ("write", "b.py", "b", 0o644),
                ("write", "d.txt", "d", 0o644),
                ("write", "sub/c.py", "c", 0o644),
                ("check", None, "concurrent", "b.py", "d.txt", "user"),
            ],
            "unmatched suffix": [
                ("write", "d.txt", "d", 0o644),
                ("check", None, "upper", "a.py", "a.py", ""),
            ],
            "deleted pending": [
                ("write", "a.py", "a", 0o644),
                ("delete", "a.py"),
                ("check", None, "upper", "a.py", "a.py", ""),
            ],
            "project publish": [
                ("write", "a.py", "a", 0o644),
                ("write", "sub/c.py", "c", 0o644),
                ("check", None, "upper", "a.py", "a.py", ""),
            ],
        }
        for name, history in histories.items():
            with self.subTest(name=name):
                replay(history)
                replay(history, project=True)


if __name__ == "__main__":
    unittest.main()
