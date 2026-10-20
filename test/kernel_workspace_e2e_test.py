"""Unavailable workspaces pause boot without losing inputs or retrying forever."""

import json
import time
import unittest

from harness import Albedo, Provider, python, text, wait_until


class KernelWorkspaceTests(unittest.TestCase):
    def setUp(self):
        def script(request):
            if request["input"][-1].get("role") == "user":
                return python(
                    "kept = 41; print(os.getcwd()); print(Path('project-marker').read_text())"
                )
            return text("recovered")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.workspace = self.app.workspace / "project"
        self.workspace.mkdir()
        (self.workspace / "project-marker").write_text("original project")
        self.session = self.app.session(self.workspace)

    def api(self, path, body=None, **options):
        with self.app.api(path, body, **options) as response:
            return json.load(response)

    def snapshot(self):
        return self.api(f"/sessions/{self.session}?tail=0")

    def block(self):
        with self.app.prompt(self.session, "original input") as response:
            self.input_id = json.load(response)["id"]
        wait_until(
            lambda: self.snapshot()["status"]["blocking_reason"] is not None,
            10,
            "missing workspace did not expose a blocked input",
        )
        snapshot = self.snapshot()
        self.assertEqual(snapshot["status"]["phase"], "idle")
        self.assertEqual(snapshot["kernel"]["state"], "none")
        detail = snapshot["status"]["blocking_reason"]["detail"]
        self.assertIn(str(self.workspace), detail)
        self.assertIn("/cd", detail)
        self.assertEqual(self.provider.requests, [])
        return snapshot

    def assert_recovered(self, expected_users):
        snapshot = self.app.idle(self.session)
        self.assertEqual(snapshot["kernel"]["state"], "attached")
        entries = self.app.history(self.session)["items"]
        users = [
            part["text"]
            for entry in entries
            if entry["kind"] == "user"
            for part in entry["content"]
            if part["kind"] == "text"
        ]
        self.assertEqual(users, expected_users)
        results = [
            json.loads(part["value"])
            for entry in entries
            if entry["kind"] == "tool_result"
            for part in entry["content"]
            if part["kind"] == "json" and part["field"] == "result"
        ]
        self.assertEqual(results[-1]["status"], "ok")
        self.assertIn("original project", results[-1]["output"])
        self.assertIn(snapshot["workspace"], results[-1]["output"])

    def test_missing_workspace_stays_paused_and_restored_input_runs_once(self):
        saved = self.workspace.with_name("saved-project")
        self.workspace.rename(saved)
        blocked = self.block()
        # Cross the old 15-second automatic retry deadline.
        time.sleep(16)
        still_blocked = self.snapshot()
        self.assertEqual(still_blocked["cursor"], blocked["cursor"])
        self.assertEqual(still_blocked["status"], blocked["status"])
        self.assertEqual(self.provider.requests, [])
        saved.rename(self.workspace)
        # Replaying an admission is not a new request to retry the kernel.
        self.api(
            f"/sessions/{self.session}/inputs/{self.input_id}",
            {"kind": "message", "text": "original input"},
            method="PUT",
        )
        self.assertIsNotNone(self.snapshot()["status"]["blocking_reason"])
        self.app.prompt(self.session, "retry after restoring mount").close()
        self.assert_recovered(["original input", "retry after restoring mount"])

    def test_workspace_move_retries_retained_input_without_another_message(self):
        moved = self.workspace.with_name("moved-project")
        self.workspace.rename(moved)
        self.block()
        with self.app.api(f"/sessions/{self.session}?view=configuration") as response:
            response.read()
            etag = response.headers["ETag"]
        moved_response = self.api(
            f"/sessions/{self.session}?view=configuration",
            {
                "workspace": str(moved),
                "family_revision": self.snapshot()["family_revision"],
            },
            method="PATCH",
            headers={"If-Match": etag},
        )
        self.assertEqual(moved_response["move"]["warnings"], [], moved_response["move"])
        self.assert_recovered(["original input"])

    def test_workspace_replaced_by_file_reports_the_path_without_booting(self):
        self.workspace.rename(self.workspace.with_name("saved-project"))
        self.workspace.write_text("not a directory")
        self.block()
        self.assertEqual(self.provider.requests, [])
