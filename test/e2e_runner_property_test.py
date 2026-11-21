"""Property tests for scripts/test-e2e.py's own selection, retry and lane logic.

Discovery suite: not wired into the flake checks (it needs hypothesis). Drive the
runner with fake cases and a fake e2e/run.py log, never with the real E2E suite.

    python3 -m unittest test/e2e_runner_property_test.py -v
"""

import contextlib
import gc
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import warnings
from pathlib import Path
from unittest.mock import patch

from hypothesis import HealthCheck, given, settings, strategies as st

RUNNER = Path(
    os.environ.get("ALBEDO_E2E_RUNNER", Path(__file__).parents[1] / "scripts/test-e2e.py")
)
spec = importlib.util.spec_from_file_location("suite_e2e_runner_props", RUNNER)
assert spec is not None and spec.loader is not None
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

CASES = (*runner.SUITE_CASES, *runner.UPSTREAM_CASES)
SETTINGS = settings(
    max_examples=200,
    deadline=None,
    suppress_health_check=list(HealthCheck),
    derandomize=False,
)


def module_of(case):
    """The e2e/run.py module name of a case, without the .py suffix."""
    return case.split(":")[0].removesuffix(".py")


MODULES = tuple(sorted({module_of(case) for case in CASES}))


FAKE_RUN = """\
import json
import os
import sys

if os.environ.get("FAKE_ARGV"):
    with open(os.environ["FAKE_ARGV"], "w", encoding="utf-8") as stream:
        json.dump(sys.argv[1:], stream)
sys.stdout.write(os.environ.get("FAKE_STDOUT", ""))
sys.stderr.write(os.environ.get("FAKE_STDERR", ""))
sys.exit(int(os.environ.get("FAKE_STATUS", "0")))
"""


def failures_line(module, klass, method, seconds=1.25):
    """The line upstream's e2e/run.py report() prints for a failing test."""
    return f"{'FAILED':6} {module}.{klass}.{method} ({seconds:.1f}s)"


def passing_line(module, klass, method, seconds=0.5):
    return f"{'ok':6} {module}.{klass}.{method} ({seconds:.1f}s)"


class Harness:
    """One fake package tree so main() can build its shipment directory."""

    def __init__(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        package = self.root / "package"
        (package / "lib/albedo/albedo").mkdir(parents=True)
        (package / "bin").mkdir()
        (package / "bin/albedo").write_text("#!/bin/sh\n")
        (package / "bin/albedo-daemon").write_text("#!/bin/sh\n")
        self.package = package

    def close(self):
        self.temp.cleanup()

    def run(self, argv, replies):
        """Run main() with argv and a scripted list of run_cases replies."""
        calls = []
        prepared = []

        def fake_prepare(source, destination, suite):
            prepared.append((Path(source), Path(destination), Path(suite)))

        def fake_run_cases(source, environment, targets, jobs, exclusive_jobs):
            calls.append(
                {
                    "targets": list(targets),
                    "jobs": jobs,
                    "exclusive_jobs": exclusive_jobs,
                    "source": source,
                }
            )
            index = len(calls) - 1
            return replies[index] if index < len(replies) else (1, "")

        stderr = []

        def capture(text):
            stderr.append(text)
            return len(text)

        with (
            patch.object(runner, "prepare_source", fake_prepare),
            patch.object(runner, "run_cases", fake_run_cases),
            # The fake source has no upstream resources.py, so no host lane plan.
            patch.object(runner, "widened_exclusive_lanes", lambda path: None),
            patch.object(
                sys,
                "argv",
                [
                    "test-e2e.py",
                    "--source",
                    str(self.root / "source"),
                    "--package",
                    str(self.package),
                    *argv,
                ],
            ),
            patch.object(sys.stderr, "write", capture),
        ):
            try:
                code = runner.main()
            except SystemExit as exit_code:
                return exit_code.code, calls, "".join(stderr), prepared
        return code, calls, "".join(stderr), prepared


class RunnerPropertyTests(unittest.TestCase):
    def setUp(self):
        self.harness = Harness()
        self.addCleanup(self.harness.close)

    # ---- case selection -------------------------------------------------

    def test_selected_cases_run_once_in_requested_order(self):
        @SETTINGS
        @given(
            selected=st.lists(
                st.sampled_from(CASES), min_size=1, max_size=5, unique=True
            ),
            skipped=st.lists(st.sampled_from(CASES), max_size=4, unique=True),
        )
        def property(selected, skipped):
            argv = []
            for case in selected:
                argv += ["--case", case]
            for case in skipped:
                argv += ["--skip-case", case]
            expected = [case for case in selected if case not in set(skipped)]
            code, calls, _stderr, prepared = self.harness.run(argv, [(0, "")])
            if not expected:
                # Every requested case was skipped: a usage error, no run.
                self.assertEqual(code, 2)
                self.assertEqual(calls, [])
                return
            self.assertEqual(len(prepared), 1)
            self.assertEqual(len(calls), 1, calls)
            self.assertEqual(calls[0]["targets"], expected)
            self.assertEqual(calls[0]["jobs"], None)
            self.assertEqual(calls[0]["exclusive_jobs"], None)
            self.assertEqual(code, 0)

        property()

    def test_full_run_selection_is_the_published_case_lists(self):
        """Without --case the runner must run every listed case exactly once."""
        code, calls, _stderr, _prepared = self.harness.run([], [(0, "")])
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["targets"], list(CASES))
        self.assertEqual(len(set(CASES)), len(CASES))
        self.assertEqual(len(calls[0]["targets"]), len(set(calls[0]["targets"])))

    def test_lane_flags_are_forwarded_unchanged(self):
        @SETTINGS
        @given(jobs=st.integers(min_value=1, max_value=64), exclusive=st.integers(min_value=1, max_value=64))
        def property(jobs, exclusive):
            argv = [
                "--case",
                CASES[0],
                "-j",
                str(jobs),
                "-x",
                str(exclusive),
            ]
            code, calls, _stderr, _prepared = self.harness.run(argv, [(0, "")])
            self.assertEqual(code, 0)
            self.assertEqual(calls[0]["jobs"], jobs)
            self.assertEqual(calls[0]["exclusive_jobs"], exclusive)

        property()

    # ---- retry behaviour ------------------------------------------------

    def test_retry_runs_exactly_the_failed_tests_serially(self):
        @SETTINGS
        @given(
            selected=st.lists(st.sampled_from(CASES), min_size=1, max_size=4, unique=True),
            retry_status=st.integers(min_value=0, max_value=2),
            noise=st.booleans(),
            count=st.integers(min_value=1, max_value=3),
        )
        def property(selected, retry_status, noise, count):
            available = sorted({module_of(case) for case in selected})
            chosen = [available[index % len(available)] for index in range(count)]
            failed_modules = list(dict.fromkeys(chosen))
            log_lines = []
            expected = []
            for index, module in enumerate(failed_modules):
                klass, method = f"Case{index}", f"test_failure_{index}"
                log_lines.append(passing_line(module, "Other", "test_passes"))
                log_lines.append(failures_line(module, klass, method))
                expected.append(f"{module}.py:{klass}.{method}")
            if noise:
                log_lines.append("Ran 12 tests; 2 failing")
                log_lines.append("\ndaemon log during test:\nlistening")
            argv = []
            for case in selected:
                argv += ["--case", case]
            code, calls, stderr, _prepared = self.harness.run(
                argv, [(1, "\n".join(log_lines) + "\n"), (retry_status, "")]
            )
            self.assertEqual(len(calls), 2, calls)
            self.assertEqual(calls[0]["targets"], selected)
            self.assertEqual(calls[1]["targets"], expected)
            self.assertEqual(calls[1]["jobs"], 1)
            self.assertEqual(calls[1]["exclusive_jobs"], 1)
            self.assertEqual(len(set(calls[1]["targets"])), len(calls[1]["targets"]))
            self.assertTrue(set(calls[1]["targets"]).issubset(set(expected)))
            if retry_status == 0:
                self.assertEqual(code, 0)
                self.assertIn("FLAKY", stderr)
            else:
                self.assertEqual(code, retry_status)

        property()

    def test_passing_first_run_never_retries_even_with_failed_text(self):
        @SETTINGS
        @given(
            module=st.sampled_from(MODULES),
        )
        def property(module):
            log = failures_line(module, "Case", "test_x") + "\n"
            code, calls, stderr, _prepared = self.harness.run(
                ["--case", CASES[0]], [(0, log), (0, "")]
            )
            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 1, calls)
            self.assertNotIn("retrying", stderr)
            self.assertNotIn("FLAKY", stderr)

        property()

    def test_no_retry_flag_and_unretryable_failures_return_original_status(self):
        @SETTINGS
        @given(
            status=st.integers(min_value=1, max_value=3),
            kind=st.sampled_from(["no_retry", "fixture", "empty"]),
            module=st.sampled_from(MODULES),
        )
        def property(status, kind, module):
            log = {
                "no_retry": failures_line(module, "Case", "test_x"),
                "fixture": f"{'FAILED':6} setUpClass ({module}.Case) (0.1s)",
                "empty": "Ran 3 tests; 1 failing",
            }[kind]
            argv = ["--case", CASES[0]]
            if kind == "no_retry":
                argv.append("--no-retry")
            code, calls, stderr, _prepared = self.harness.run(argv, [(status, log + "\n")])
            self.assertEqual(code, status)
            self.assertEqual(len(calls), 1, calls)
            self.assertNotIn("retrying", stderr)

        property()

    def test_every_listed_case_maps_to_a_retry_target(self):
        @SETTINGS
        @given(
            module=st.sampled_from(MODULES),
            klass=st.from_regex(r"[A-Z][A-Za-z0-9]{0,12}", fullmatch=True),
            method=st.from_regex(r"test_[a-z0-9_]{1,20}", fullmatch=True),
            seconds=st.floats(min_value=0, max_value=600, allow_nan=False),
            extra=st.lists(st.sampled_from(CASES), min_size=0, max_size=4),
        )
        def property(module, klass, method, seconds, extra):
            log = "\n".join(
                [passing_line(module, klass, method)]
                + [failures_line(module, klass, method, seconds)]
                + [passing_line(module_of(case), "Case", "test_x") for case in extra]
            )
            self.assertEqual(
                runner.retry_targets(log), [f"{module}.py:{klass}.{method}"]
            )
            # A retry target resolves back to the file run.py would load.
            target = runner.retry_targets(log)[0]
            file_part, _, test_name = target.partition(":")
            self.assertTrue(file_part.endswith(".py"))
            self.assertIn(file_part, {case.split(":")[0] for case in CASES})
            self.assertEqual(test_name, f"{klass}.{method}")

        property()

    def test_retry_targets_does_not_invent_targets_from_noise(self):
        @SETTINGS
        @given(
            noise=st.lists(
                st.sampled_from(
                    [
                        "Ran 4 tests; 1 failing",
                        "slowest tests:",
                        "  12.0s module.Case.test_x",
                        "module.Case.test_x:",
                        "Traceback (most recent call last):",
                        "FAILED",
                        "FAILED module (1.0s)",
                        "FAILED setUpClass (module.Case) (0.1s)",
                        " FAILED module.Case.test_x (1.0s)",
                    ]
                ),
                max_size=4,
            )
        )
        def property(noise):
            self.assertEqual(runner.retry_targets("\n".join(noise)), [])

        property()

    # ---- result parsing and exit status --------------------------------

    def test_exit_status_is_zero_iff_every_selected_case_passed(self):
        @SETTINGS
        @given(
            first=st.integers(min_value=0, max_value=2),
            retry=st.integers(min_value=0, max_value=2),
            failed=st.booleans(),
        )
        def property(first, retry, failed):
            module = module_of("zed_e2e_test.py")
            log = failures_line(module, "Zed", "test_login") if failed else ""
            code, calls, _stderr, _prepared = self.harness.run(
                ["--case", "zed_e2e_test.py"], [(first, log + "\n"), (retry, "")]
            )
            if first == 0:
                self.assertEqual(code, 0)
                self.assertEqual(len(calls), 1)
            elif not failed:
                self.assertEqual(code, first)
                self.assertEqual(len(calls), 1)
            else:
                self.assertEqual(len(calls), 2)
                self.assertEqual(code, retry)

        property()

    def test_retried_targets_are_never_a_superset_of_the_selection(self):
        @SETTINGS
        @given(
            selected=st.lists(st.sampled_from(CASES), min_size=1, max_size=3, unique=True),
            extra=st.lists(st.sampled_from(CASES), min_size=1, max_size=3),
        )
        def property(selected, extra):
            modules = sorted({module_of(case) for case in selected})
            log = "\n".join(failures_line(module, "Case", "test_x") for module in modules)
            argv = []
            for case in selected:
                argv += ["--case", case]
            _code, calls, _stderr, _prepared = self.harness.run(
                argv, [(1, log + "\n"), (1, "")]
            )
            selected_files = {case.split(":")[0] for case in selected}
            for target in calls[1]["targets"]:
                self.assertIn(target.split(":")[0], selected_files, target)
            self.assertEqual(len(calls[1]["targets"]), len(modules))

        property()

    # ---- run_cases: the real child process ------------------------------

    def test_run_cases_passes_targets_and_lanes_to_run_py(self):
        """The child sees the targets after the script, and layers as flags."""

        @SETTINGS
        @given(
            targets=st.lists(st.sampled_from(CASES), min_size=1, max_size=4, unique=True),
            jobs=st.one_of(st.none(), st.integers(min_value=1, max_value=8)),
            exclusive=st.one_of(st.none(), st.integers(min_value=1, max_value=8)),
            status=st.integers(min_value=0, max_value=3),
        )
        def property(targets, jobs, exclusive, status):
            source = self.harness.root / "source"
            (source / "e2e").mkdir(parents=True, exist_ok=True)
            (source / "e2e" / "run.py").write_text(FAKE_RUN)
            record = self.harness.root / "argv.json"
            environment = dict(
                os.environ,
                FAKE_ARGV=str(record),
                FAKE_STATUS=str(status),
                PYTHONDONTWRITEBYTECODE="1",
            )
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code, log = runner.run_cases(source, environment, targets, jobs, exclusive)
            self.assertEqual(code, status)
            argv = json.loads(record.read_text())
            expected = list(targets)
            if jobs:
                expected += ["-j", str(jobs)]
            if exclusive:
                expected += ["-x", str(exclusive)]
            self.assertEqual(argv, expected)
            self.assertEqual(log, "")

        property()

    def test_run_cases_returns_the_child_stderr_as_its_log(self):
        @SETTINGS
        @given(
            lines=st.lists(
                st.sampled_from(
                    [
                        "ok     module.Case.test_a (0.1s)",
                        "FAILED module.Case.test_b (1.0s)",
                        "Ran 2 tests; 1 failing",
                        "",
                    ]
                ),
                max_size=4,
            ),
            status=st.sampled_from([0, 1]),
        )
        def property(lines, status):
            source = self.harness.root / "source"
            (source / "e2e").mkdir(parents=True, exist_ok=True)
            (source / "e2e" / "run.py").write_text(FAKE_RUN)
            body = "\n".join(lines)
            environment = dict(
                os.environ,
                FAKE_STDOUT="",
                FAKE_STDERR=body,
                FAKE_STATUS=str(status),
                PYTHONDONTWRITEBYTECODE="1",
            )
            captured = io.StringIO()
            # run_cases leaves the child's stderr wrapper to the collector.
            with warnings.catch_warnings(), contextlib.redirect_stderr(captured):
                warnings.simplefilter("ignore", ResourceWarning)
                code, log = runner.run_cases(
                    source, environment, [CASES[0]], None, None
                )
                gc.collect()
            self.assertEqual(code, status)
            self.assertEqual(log, captured.getvalue())
            self.assertEqual(captured.getvalue().splitlines(), body.splitlines())

        property()

    # ---- documented ambiguity -------------------------------------------

    def test_a_repeated_case_flag_runs_that_case_twice(self):
        """Current behaviour, recorded because the help does not define it."""
        case = "zed_e2e_test.py"
        code, calls, _stderr, _prepared = self.harness.run(
            ["--case", case, "--case", case], [(0, "")]
        )
        self.assertEqual(code, 0)
        self.assertEqual(calls[0]["targets"], [case, case])

    # ---- prepare_source: suite cases and fixture patching ---------------

    def test_prepare_source_installs_suite_cases_and_patches_fixtures(self):
        upstream = Path(os.environ.get("ALBEDO_UPSTREAM_SOURCE", "/nonexistent"))
        if not (upstream / "e2e").is_dir():
            self.skipTest("set ALBEDO_UPSTREAM_SOURCE to the pinned upstream source")

        root = self.harness.root
        fake = root / "upstream"
        shutil.copytree(upstream / "e2e", fake / "e2e")
        # The Nix store is read-only; prepare_source must not need it writable.
        for path in [fake, *fake.rglob("*")]:
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o500)
        suite = Path(__file__).resolve().parents[1]
        destination = root / "prepared"
        runner.prepare_source(fake, destination, suite)

        for case in runner.SUITE_CASES:
            self.assertEqual(
                (destination / "e2e" / case).read_bytes(),
                (suite / "test" / case).read_bytes(),
                case,
            )
        self.assertEqual(
            (destination / "e2e/albedo_monitor.py").read_bytes(),
            (suite / "scripts/albedo-monitor.py").read_bytes(),
        )
        for source in (suite / "test/fixtures").rglob("*"):
            if source.is_file():
                relative = source.relative_to(suite / "test/fixtures")
                self.assertEqual(
                    (destination / "e2e/fixtures" / relative).read_bytes(),
                    source.read_bytes(),
                    str(relative),
                )
        kernel_upgrade = (destination / "e2e/kernel_upgrade_test.py").read_text()
        self.assertEqual(kernel_upgrade.count("harness.wait_until(reattached"), 1)
        patched = kernel_upgrade[
            kernel_upgrade.index(
                "def test_kernel_upgrade_forces_the_swap_past_a_live_job"
            ) :
        ]
        self.assertLess(
            patched.index("self.app.restart()"),
            patched.index("harness.wait_until(reattached"),
        )
        self.assertLess(
            patched.index("harness.wait_until(reattached"),
            patched.index('f"/sessions/{self.session}/kernel/upgrade"'),
        )
        self.assertIn(
            "harness.message_text(item)",
            (destination / "e2e/kernel_detach_test.py").read_text(),
        )
        for path in destination.rglob("*"):
            if not path.is_symlink():
                self.assertTrue(
                    path.stat().st_mode & 0o200, f"read-only after prepare: {path}"
                )


if __name__ == "__main__":
    unittest.main()
