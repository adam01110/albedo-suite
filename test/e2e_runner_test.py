"""The pinned native upgrade fixture waits for actual kernel reattachment."""

import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

RUNNER = Path(
    os.environ.get(
        "ALBEDO_E2E_RUNNER", Path(__file__).parents[1] / "scripts/test-e2e.py"
    )
)
spec = importlib.util.spec_from_file_location("suite_e2e_runner", RUNNER)
assert spec is not None and spec.loader is not None
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_typed_response_adapters_preserve_assertions_and_reject_drift(self):
        specifications = json.loads(
            (Path(__file__).parent / "fixtures/typed-response-fixtures.json").read_text()
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, spec in specifications.items():
                source = "\n".join(old for old, _ in spec["replacements"])
                source += "\nassert original_checks\n"
                (root / name).write_text(source)
                spec["sha256"] = hashlib.sha256(source.encode()).hexdigest()
            runner.synchronize_typed_response_fixtures(root, specifications)
            snapshots = {name: (root / name).read_text() for name in specifications}
            self.assertTrue(all("assert original_checks" in text for text in snapshots.values()))
            self.assertIn("harness.message_text(item)", snapshots["kernel_detach_test.py"])
            with self.assertRaisesRegex(RuntimeError, "fixture changed"):
                runner.synchronize_typed_response_fixtures(root, specifications)
            self.assertEqual(snapshots, {name: (root / name).read_text() for name in specifications})

    def test_typed_response_text_helper_preserves_string_and_content_part_text(self):
        specifications = json.loads(
            (Path(__file__).parent / "fixtures/typed-response-fixtures.json").read_text()
        )
        source = specifications["harness.py"]["replacements"][0][1]
        namespace = {}
        exec(source.removesuffix("def prompt_text(request):"), namespace)
        message_text = namespace["message_text"]
        self.assertEqual(message_text({"content": "plain"}), "plain")
        self.assertEqual(message_text({"content": [
            {"type": "input_text", "text": "first"},
            {"type": "input_image", "image_url": "fixture"},
            {"type": "input_text", "text": "second"},
        ]}), "firstsecond")

    def test_failed_tests_map_to_upstream_targets(self):
        log = (
            "ok     zed_e2e_test.ZedTests.test_login (1.0s)\n"
            "FAILED python_test.PythonToolsTests.test_chdir_moves_run_and_files (2.5s)\n"
            "FAILED mcp_http_test.McpHttpTests.test_identity_future (10.0s)\n"
        )
        self.assertEqual(
            runner.retry_targets(log),
            [
                "python_test.py:PythonToolsTests.test_chdir_moves_run_and_files",
                "mcp_http_test.py:McpHttpTests.test_identity_future",
            ],
        )
        fixture = "FAILED setUpClass (mcp_test.McpTests) (0.1s)\n"
        self.assertEqual(runner.retry_targets(log + fixture), [])
        targets = [case for case in runner.UPSTREAM_CASES if ":" in case]
        failures = "".join(
            f"FAILED {name.removesuffix('.py')}.{test} (1.0s)\n"
            for name, _, test in (target.partition(":") for target in targets)
        )
        self.assertEqual(runner.retry_targets(failures), targets)

    def test_kernel_upgrade_fixture_is_patched_once_and_refuses_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "kernel_upgrade_test.py"
            source = (
                "class Fixture:\n"
                "    def test_kernel_upgrade_forces_the_swap_past_a_live_job(self):\n        self.cell(\"import os\\nsurvivor = 41\\nj = run('sleep', '60')\\nos.getpid()\")\n        self.edit_bundle()\n        self.app.restart()\n"
                "        with self.app.api('/kernel/upgrade', {}):\n            pass\n"
            )
            path.write_text(source)
            runner.synchronize_kernel_upgrade_fixture(
                path, expected_sha256=hashlib.sha256(source.encode()).hexdigest()
            )
            result = path.read_text()
            ast.parse(result)
            self.assertLess(
                result.index("harness.wait_until"),
                result.index("self.app.api('/kernel/upgrade'"),
            )
            path.write_text("changed fixture")
            with self.assertRaisesRegex(RuntimeError, "fixture changed"):
                runner.synchronize_kernel_upgrade_fixture(path)
            self.assertEqual(path.read_text(), "changed fixture")


if __name__ == "__main__":
    unittest.main()
