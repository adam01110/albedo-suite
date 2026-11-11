#!/usr/bin/env python3
"""Run isolated pinned upstream E2E tests against an explicitly supplied build."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SUITE_CASES = (
    "formatter_e2e_test.py",
    "kernel_workspace_e2e_test.py",
    "lazy_mcp_test.py",
    "lsp_e2e_test.py",
    "model_catalogs_test.py",
    "provider_availability_e2e_test.py",
    "prompt_context_e2e_test.py",
    "session_cost_e2e_test.py",
    "opencode_go_e2e_test.py",
    "tool_backends_e2e_test.py",
    "tool_images_e2e_test.py",
    "zed_e2e_test.py",
)
UPSTREAM_CASES = (
    "artifacts_test.py",
    "changes_test.py",
    "crash_durability_test.py",
    "migrations_test.py",
    "events_test.py",
    "direnv_test.py",
    "profile_rename_test.py",
    "session_name_test.py",
    "web_test.py",
    "history_content_test.py",
    "session_status_test.py",
    "kernel_detach_test.py",
    "cache_miss_test.py",
    "context_test.py",
    "skills_test.py",
    "hooks_test.py",
    "idle_reap_test.py",
    "job_wake_test.py",
    "kernel_upgrade_test.py",
    "repetition_test.py",
    "rewind_test.py",
    "traces_test.py",
    "provider_timeout_test.py",
    "speechless_test.py",
    "mcp_test.py",
    "mcp_wire_test.py",
    "mcp_http_test.py",
    "mcp_oauth_test.py",
    "operations_lifecycle_test.py",
    "image_limits_test.py",
    "python_test.py:PythonToolsTests.test_a_list_of_edits_applies_all_or_none",
    "python_test.py:PythonToolsTests.test_text_returns_plain_output_and_raises_with_the_last_lines",
    "python_test.py:PythonToolsTests.test_wait_for_returns_the_line_and_leaves_the_job_running",
    "python_test.py:PythonToolsTests.test_chdir_moves_run_and_files",
    "stream_replay_test.py",
    "provider_protocols_test.py",
    "side_questions_test.py",
    "usage_test.py",
)


def synchronize_kernel_upgrade_fixture(
    path,
    *,
    expected_sha256="bf1e90c3f6a93c4b61b14fa767042a3e226499548c4ed85b136301dceb297c0c",
):
    """Listener readiness precedes asynchronous kernel reattachment after restart."""
    original = "    def test_kernel_upgrade_forces_the_swap_past_a_live_job(self):\n        self.cell(\"import os\\nsurvivor = 41\\nj = run('sleep', '60')\\nos.getpid()\")\n        self.edit_bundle()\n        self.app.restart()\n"
    barrier = '\n        def reattached():\n            with self.app.api(f"/sessions/{self.session}?tail=0") as response:\n                view = json.load(response)\n            return (\n                view["status"]["phase"] == "idle"\n                and view["pending_inputs"] == []\n                and view["kernel"]["state"] == "attached"\n            )\n\n        harness.wait_until(reattached, 10, "kernel did not finish reattaching after restart")\n        kernel = self.kernel()\n        self.assertTrue(kernel["stale"], kernel)\n        self.assertEqual(kernel["live_job_count"], 1, kernel)\n'
    source_bytes = path.read_bytes()
    source = source_bytes.decode()
    if (
        hashlib.sha256(source_bytes).hexdigest() != expected_sha256
        or source.count(original) != 1
    ):
        raise RuntimeError(
            "kernel-upgrade fixture changed; review its restart readiness barrier"
        )
    path.write_text(source.replace(original, original + barrier))


def synchronize_typed_response_fixtures(directory, specifications):
    """Keep native text assertions while accepting typed Responses content."""
    writes = {}
    for name, spec in specifications.items():
        path = directory / name
        original = path.read_bytes()
        if hashlib.sha256(original).hexdigest() != spec["sha256"]:
            raise RuntimeError(f"typed Responses fixture changed: {name}")
        source = original.decode()
        for old, new in spec["replacements"]:
            if old not in source:
                raise RuntimeError(f"typed Responses fixture pattern changed: {name}")
            source = source.replace(old, new)
        writes[path] = source
    for path, source in writes.items():
        path.write_text(source)


def prepare_source(upstream, destination, suite):
    shutil.copytree(upstream, destination)
    for entry in destination.rglob("*"):
        if not entry.is_symlink():
            owner_permissions = 0o200 | (0o100 if entry.is_dir() else 0)
            entry.chmod(entry.stat().st_mode | owner_permissions)
    destination.chmod(0o700)

    cases_directory = destination / "test/e2e"
    synchronize_kernel_upgrade_fixture(cases_directory / "kernel_upgrade_test.py")
    synchronize_typed_response_fixtures(
        cases_directory,
        json.loads((suite / "test/fixtures/typed-response-fixtures.json").read_text()),
    )
    for name in SUITE_CASES:
        shutil.copyfile(suite / "test" / name, cases_directory / name)
    shutil.copytree(
        suite / "test/fixtures", cases_directory / "fixtures", dirs_exist_ok=True
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument(
        "--suite", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument(
        "--case", choices=(*SUITE_CASES, *UPSTREAM_CASES), action="append"
    )
    args = parser.parse_args()
    suite = args.suite
    environment = dict(
        os.environ,
        PYTHONDONTWRITEBYTECODE="1",
        OPENCODE_API_KEY="",
        # Upstream shell-command cases use POSIX syntax; the caller's login shell may not.
        SHELL=shutil.which("bash") or "/bin/sh",
        ALBEDO_TEST_CLI=str(args.package / "bin/albedo"),
    )

    with tempfile.TemporaryDirectory(prefix="albedo-suite-e2e-") as directory:
        # Kernel-upgrade fixtures expect a writable shipment beside the launcher.
        shipment = Path(directory) / "daemon"
        shipment.mkdir()
        for entry in (args.package / "lib/albedo").iterdir():
            target = shipment / entry.name
            if entry.name == "albedo":
                shutil.copytree(
                    entry,
                    target,
                    ignore=shutil.ignore_patterns("__pycache__"),
                )
                for path in (target, *target.rglob("*")):
                    if not path.is_symlink():
                        path.chmod(path.stat().st_mode | 0o200)
            else:
                target.symlink_to(entry)
        launcher = shipment / "albedo-daemon"
        launcher.symlink_to(args.package / "bin/albedo-daemon")
        environment["ALBEDO_TEST_DAEMON"] = str(launcher)

        source = Path(directory) / "source"
        prepare_source(args.source, source, suite)
        for case in args.case or (*SUITE_CASES, *UPSTREAM_CASES):
            subprocess.run(
                [sys.executable, "-B", "test/e2e/run.py", case, "-x", "1"],
                cwd=source,
                env=environment,
                check=True,
            )


if __name__ == "__main__":
    main()
