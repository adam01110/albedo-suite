#!/usr/bin/env python3
"""Repeat the suite's own deterministic tests to expose flaky failures.

Runs the Gleam postCheck modules, the Go postCheck filters and the Python
check tests in an overlay tree (see `scripts/overlay-tree.sh`) many times,
optionally several at once, and prints every module whose runs were not all
green. The parallel mode is what catches tests that share a fixed path in
/tmp: two runs of the same module collide only when they overlap.
"""

import argparse
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

GLEAM_MODULES = [
    "suite_prompt_docs_test",
    "suite_quota_test",
    "suite_codex_error_test",
    "suite_opencode_go_test",
    "suite_bridge_test",
    "suite_zed_test",
    "suite_zed_login_test",
    "suite_catalog_prices_test",
    "suite_memory_index_test",
    "suite_lazy_mcp_test",
    "suite_agents_glance_test",
    "suite_tool_count_test",
    "suite_usage_profile_test",
]

GO_FILTERS = [
    ("./internal/app", ""),
    ("./internal/cli", ""),
    ("./internal/webui", ""),
    ("./internal/daemon", ""),
    ("./internal/tui", "^TestBase16"),
    ("./internal/tui", "^(TestVim|TestSessionViewerTotalCostTopRight|TestSessionListCostLeftOfAge)"),
    ("./internal/tui", "^TestComposerScope"),
    ("./internal/tui", "^TestContext"),
    ("./internal/tui", "^TestQuota"),
    ("./internal/tui", "^TestProviderAvailability"),
    ("./internal/tui", "^TestSuiteEscape"),
    ("./internal/tui", "^(TestOpenCodeGo|TestZed)"),
    ("./internal/tui", "^TestToolImages"),
    ("./internal/tui", "^TestActivity"),
    ("./internal/tui", "^TestAgentsGlance"),
    ("./internal/tui", "^TestTurnNotify"),
    ("./internal/tui", "^TestZoxide"),
    ("./internal/tui", "^TestUsage"),
    ("./internal/terminal", "^TestSuiteInline"),
]

PYTHON_TESTS = [
    "formatter_python_test.py",
    "files_check_test.py",
    "linter_python_test.py",
    "e2e_runner_test.py",
    "prompt_context_python_test.py",
    "lazy_mcp_python_test.py",
    "lsp_test.py",
    "remote_path_test.py",
    "remote_staging_test.py",
    "rtk_python_test.py",
    "rtk_e2e_test.py",
    "fff_test.py",
    "fff_stdio_test.py",
]


def gleam_command(tree, module):
    return [os.path.join(tree, "shell"), "gleam", "run", "-m", module]


def go_command(tree, package, filter_):
    # The tree's shell enters the unpacked source, so the module directory is
    # named absolutely instead of relative to the caller's directory.
    script = "cd %s && go test %s" % (
        os.path.join(tree, "source", "cli"),
        package,
    )
    if filter_:
        script += " -run '%s'" % filter_
    return [os.path.join(tree, "shell"), "bash", "-c", script]


def python_command(suite, test):
    return [sys.executable, os.path.join(suite, "test", test)]


def run_once(command, env=None):
    completed = subprocess.run(
        command, capture_output=True, text=True, env=env, timeout=1800
    )
    return completed.returncode, (completed.stdout + completed.stderr)[-4000:]


def attempt(label, command, env):
    code, output = run_once(command, env)
    return label, code, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-tree", help="server overlay tree directory")
    parser.add_argument("--client-tree", help="client overlay tree directory")
    parser.add_argument("--suite", default=os.getcwd(), help="suite checkout")
    parser.add_argument("--runs", type=int, default=10, help="runs per test")
    parser.add_argument("--parallel", type=int, default=1, help="concurrent runs")
    parser.add_argument("--only", default="", help="regex over test labels")
    parser.add_argument("--python", action="store_true", help="include Python tests")
    options = parser.parse_args()

    cases = []
    if options.server_tree:
        for module in GLEAM_MODULES:
            cases.append((module, gleam_command(options.server_tree, module)))
    if options.client_tree:
        for package, filter_ in GO_FILTERS:
            label = "go %s %s" % (package, filter_ or "")
            cases.append((label.strip(), go_command(options.client_tree, package, filter_)))

    env = dict(os.environ)
    if options.python:
        source = os.path.join(options.server_tree, "source", "apps", "albedo", "priv", "python")
        env.update(
            PYTHONPATH=source,
            PYTHONDONTWRITEBYTECODE="1",
            ALBEDO_E2E_RUNNER=os.path.join(options.suite, "scripts", "test-e2e.py"),
            ALBEDO_FORMATTER_SOURCE=source,
            ALBEDO_LINTER_SOURCE=source,
            ALBEDO_LSP_SOURCE=source,
            ALBEDO_REMOTE_SOURCE=source,
            ALBEDO_RTK_SOURCE=source,
            ALBEDO_FFF_SOURCE=source,
            ALBEDO_PYTHON_SOURCE=source,
            ALBEDO_FFF_ERLANG=os.path.join(
                options.suite, "src", "server", "extensions", "files", "src", "albedo_fff.erl"
            ),
        )
        for test in PYTHON_TESTS:
            cases.append((test, python_command(options.suite, test)))

    pattern: re.Pattern[str] | None = re.compile(options.only) if options.only else None
    cases = [case for case in cases if pattern is None or pattern.search(case[0])]
    if not cases:
        parser.error("no test matched")

    failures = {}
    with ThreadPoolExecutor(max_workers=options.parallel) as pool:
        for _ in range(options.runs):
            for label, code, output in pool.map(
                lambda case: attempt(case[0], case[1], env), cases
            ):
                if code != 0:
                    failures.setdefault(label, []).append(output)
    for label in [case[0] for case in cases]:
        found = failures.get(label, [])
        state = "ok" if not found else "FAILED %d/%d" % (len(found), options.runs)
        print("%-60s %s" % (label, state))
    for label, outputs in failures.items():
        print("\n=== %s failed %d/%d times, last output:" % (label, len(outputs), options.runs))
        print(outputs[-1])
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
