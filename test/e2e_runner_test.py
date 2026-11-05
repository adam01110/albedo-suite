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
    def test_fixture_barrier_preserves_single_post_and_live_job_assertion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "kernel_upgrade_test.py"
            source = (
                "    def test_kernel_upgrade_forces_the_swap_past_a_live_job(self):\n        self.cell(\"import os\\nsurvivor = 41\\nj = run('sleep', '60')\\nos.getpid()\")\n        self.edit_bundle()\n        self.app.restart()\n"
                + "        with self.app.api('/kernel/upgrade', {}):\n            pass\n        self.assertEqual(len(result['stopped_jobs']), 1, result)\n"
            )
            path.write_text("class Fixture:\n" + source)
            runner.synchronize_kernel_upgrade_fixture(
                path, expected_sha256=hashlib.sha256(path.read_bytes()).hexdigest()
            )
            result = path.read_text()
            ast.parse(result)
            self.assertEqual(
                result.count("with self.app.api('/kernel/upgrade', {})"), 1
            )
            self.assertIn('view["kernel"]["state"] == "attached"', result)
            self.assertIn('view["status"]["phase"] == "idle"', result)
            self.assertIn('view["pending_inputs"] == []', result)
            self.assertIn('self.assertTrue(kernel["stale"], kernel)', result)
            self.assertIn(
                'self.assertEqual(kernel["live_job_count"], 1, kernel)', result
            )
            self.assertIn("len(result['stopped_jobs']), 1", result)
            self.assertLess(
                result.index("harness.wait_until"),
                result.index("self.app.api('/kernel/upgrade'"),
            )
            self.assertNotIn("except", result)
            path.write_text(
                "class Fixture:\n" + source + "\n# changed outside the method prefix\n"
            )
            with self.assertRaisesRegex(RuntimeError, "fixture changed"):
                runner.synchronize_kernel_upgrade_fixture(
                    path,
                    expected_sha256=hashlib.sha256(
                        ("class Fixture:\n" + source).encode()
                    ).hexdigest(),
                )

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

    def test_python_targets_use_the_actual_upstream_filename(self):
        targets = [case for case in runner.UPSTREAM_CASES if ":" in case]
        self.assertEqual(len(targets), 4)
        for target in targets:
            filename, _, test_name = target.partition(":")
            self.assertEqual(filename, "python_test.py")
            self.assertTrue(test_name.startswith("PythonToolsTests.test_"))

    def test_changed_pin_fixture_is_not_silently_patched(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "kernel_upgrade_test.py"
            path.write_text("changed fixture")
            with self.assertRaisesRegex(RuntimeError, "fixture changed"):
                runner.synchronize_kernel_upgrade_fixture(path)
            self.assertEqual(path.read_text(), "changed fixture")


if __name__ == "__main__":
    unittest.main()
