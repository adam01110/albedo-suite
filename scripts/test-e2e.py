#!/usr/bin/env python3
"""Run isolated pinned upstream E2E tests against an explicitly supplied build."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SUITE_CASES = (
    "formatter_e2e_test.py",
    "lazy_mcp_test.py",
    "lsp_e2e_test.py",
    "questions_e2e_test.py",
)
UPSTREAM_CASES = (
    "mcp_test.py",
    "operations_lifecycle_test.py",
    "stream_replay_test.py",
)


def prepare_source(upstream, destination, suite):
    shutil.copytree(upstream, destination)
    for entry in destination.rglob("*"):
        if not entry.is_symlink():
            owner_permissions = 0o200 | (0o100 if entry.is_dir() else 0)
            entry.chmod(entry.stat().st_mode | owner_permissions)
    destination.chmod(0o700)

    cases_directory = destination / "test/e2e"
    for name in SUITE_CASES:
        shutil.copyfile(suite / "test" / name, cases_directory / name)
    shutil.copytree(
        suite / "test/fixtures", cases_directory / "fixtures", dirs_exist_ok=True
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--package", type=Path, required=True)
    args = parser.parse_args()
    suite = Path(__file__).resolve().parents[1]
    environment = dict(
        os.environ,
        PYTHONDONTWRITEBYTECODE="1",
        ALBEDO_TEST_DAEMON=str(args.package / "bin/albedo-daemon"),
        ALBEDO_TEST_CLI=str(args.package / "bin/albedo"),
    )

    with tempfile.TemporaryDirectory(prefix="albedo-suite-e2e-") as directory:
        source = Path(directory) / "source"
        prepare_source(args.source, source, suite)
        for case in (*SUITE_CASES, *UPSTREAM_CASES):
            subprocess.run(
                [sys.executable, "-B", "test/e2e/run.py", case, "-x", "1"],
                cwd=source,
                env=environment,
                check=True,
            )


if __name__ == "__main__":
    main()
