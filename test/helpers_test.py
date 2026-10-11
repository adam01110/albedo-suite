"""Configuration and MCP launch regressions using isolated homes and fake secrets."""

import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest

FIXTURES = Path(__file__).parent / "fixtures"


class HelperFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="albedo-suite-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home with spaces"
        self.home.mkdir()

    def write_json(self, path, value):
        path.write_text(json.dumps(value))

    def run_helper(self, name, *arguments):
        return subprocess.run(
            [os.environ[name], *(str(argument) for argument in arguments)],
            capture_output=True,
            text=True,
            timeout=10,
            env={"HOME": str(self.home), "PATH": os.defpath},
        )

    def assert_succeeded(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)


class ConfigureTests(HelperFixture):
    def configure(self, defaults, target="extensions.json"):
        managed_file = self.root / "defaults.json"
        self.write_json(managed_file, defaults)
        return self.run_helper("ALBEDO_CONFIGURE", self.home, managed_file, target)

    def test_recursive_merge_preserves_credentials_permissions_and_mtime(self):
        destination = self.home / "extensions.json"
        credential = "PRIVATE_RUNTIME_SENTINEL"
        original = {
            "enabled": {"other": True},
            "credentials": {"key": credential},
        }
        defaults = {"enabled": {"formatter": True}}
        self.write_json(destination, original)

        self.assert_succeeded(self.configure(defaults))
        self.assertEqual(
            json.loads(destination.read_text()),
            {
                "enabled": {"other": True, "formatter": True},
                "credentials": {"key": credential},
            },
        )
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)

        modified_at = destination.stat().st_mtime_ns
        self.assert_succeeded(self.configure(defaults))
        self.assertEqual(destination.stat().st_mtime_ns, modified_at)

    def test_capability_choices_merge_without_removing_unmanaged_choices(self):
        destination = self.home / "capabilities.json"
        original = {
            "global": {
                "skills": {"unmanaged": True, "research": True},
                "instructions": {"private-instructions": False},
                "mcp": {"docs": True},
            },
            "unrelated": "PRESERVE_SENTINEL",
        }
        choices = {"research": False, "customize-albedo": True}
        defaults = {"global": {"skills": choices}}

        self.assert_succeeded(self.configure(defaults, "capabilities.json"))
        self.assertEqual(json.loads(destination.read_text()), defaults)
        self.write_json(destination, original)
        self.assert_succeeded(self.configure(defaults, "capabilities.json"))
        expected = json.loads(json.dumps(original))
        expected["global"]["skills"].update(choices)
        self.assertEqual(json.loads(destination.read_text()), expected)
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        modified_at = destination.stat().st_mtime_ns
        self.assert_succeeded(self.configure(defaults, "capabilities.json"))
        self.assertEqual(destination.stat().st_mtime_ns, modified_at)

    def test_invalid_capabilities_are_left_untouched(self):
        destination = self.home / "capabilities.json"
        invalid_documents = [
            [],
            {"global": None},
            {"global": {"skills": None}},
            {"global": {"skills": []}},
            {"global": {"skills": {"research": "false"}}},
            {"global": {"instructions": {"AGENTS.md": 0}}},
            {"global": {"mcp": {"docs": "true"}}},
        ]
        for document in invalid_documents:
            with self.subTest(document=document):
                self.write_json(destination, document)
                original = destination.read_bytes()
                result = self.configure({}, "capabilities.json")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(destination.read_bytes(), original)
        self.write_json(destination, {})
        result = self.configure({"global": {"skills": {"bad": 1}}}, "capabilities.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(destination.read_text()), {})

    def test_capability_changes_respect_daemon_lock_and_pending_recovery(self):
        destination = self.home / "capabilities.json"
        original = {"global": {"skills": {"research": True}}}
        defaults = {"global": {"skills": {"research": False}}}
        self.write_json(destination, original)
        connection = sqlite3.connect(self.home / "daemon.lock")
        try:
            connection.execute("BEGIN EXCLUSIVE")
            self.assertNotEqual(
                self.configure(defaults, "capabilities.json").returncode, 0
            )
            self.assertEqual(json.loads(destination.read_text()), original)
        finally:
            connection.close()
        (self.home / ".settings-recovery").touch()
        self.assertNotEqual(self.configure(defaults, "capabilities.json").returncode, 0)
        self.assertEqual(json.loads(destination.read_text()), original)

    def test_invalid_documents_are_left_untouched(self):
        destination = self.home / "extensions.json"
        invalid_documents = ["[1]", "{} {}", "{broken", '{"enabled":false}']
        for document in invalid_documents:
            with self.subTest(document=document):
                destination.write_text(document)
                result = self.configure({"enabled": {}})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(destination.read_text(), document)

    def test_daemon_lock_prevents_settings_creation(self):
        connection = sqlite3.connect(self.home / "daemon.lock")
        try:
            connection.execute("BEGIN EXCLUSIVE")
            self.assertNotEqual(self.configure({}).returncode, 0)
            self.assertFalse((self.home / "extensions.json").exists())
        finally:
            connection.close()

    def test_pending_recovery_prevents_settings_creation(self):
        (self.home / ".settings-recovery").touch()
        self.assertNotEqual(self.configure({}).returncode, 0)
        self.assertFalse((self.home / "extensions.json").exists())

    def test_legacy_provider_document_is_left_untouched(self):
        destination = self.home / "config.json"
        original = '{"model":"legacy"}'
        destination.write_text(original)
        result = self.configure({"providers": {}, "active": "missing"}, "config.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.read_text(), original)

    def test_adding_provider_preserves_existing_authentication(self):
        destination = self.home / "config.json"
        existing_profile = {"model": "x", "account": "PRIVATE_ACCOUNT_SENTINEL"}
        self.write_json(
            destination,
            {
                "active": "old",
                "providers": {"old": existing_profile},
            },
        )
        new_profile = {"model": "fixture", "extension": "codex"}

        result = self.configure(
            {
                "active": "new",
                "providers": {"new": new_profile},
            },
            "config.json",
        )
        self.assert_succeeded(result)
        self.assertEqual(
            json.loads(destination.read_text()),
            {
                "active": "new",
                "providers": {"old": existing_profile, "new": new_profile},
            },
        )


class McpLauncherTests(HelperFixture):
    def launch_configuration(self):
        return {
            "command": sys.executable,
            "args": [str(FIXTURES / "inspect-process.py")],
            "environment": {},
            "secrets": {},
            "runtimePath": "",
        }

    def launch(self, configuration):
        launch_file = self.root / "launcher.json"
        self.write_json(launch_file, configuration)
        return self.run_helper("ALBEDO_MCP_LAUNCHER", launch_file)

    def test_arguments_and_secrets_are_literal_and_do_not_shadow_parser_locals(self):
        secret_value = "SECRET_SENTINEL_$literal\ninner-line"
        secret_file = self.root / "secret with spaces"
        secret_file.write_text(secret_value)
        arguments = ["arg with spaces", "$literal", "line\nbreak"]
        configuration = self.launch_configuration()
        configuration["args"].extend(arguments)
        configuration["environment"] = {
            "config": "PUBLIC_LOCAL_COLLISION",
            "command": "not a command",
            "KEY": "public",
            "PATH": "/nonexistent",
        }
        configuration["secrets"] = {"KEY": str(secret_file)}

        result = self.launch(configuration)
        self.assert_succeeded(result)
        environment, received_arguments = json.loads(result.stdout)
        self.assertEqual(environment["KEY"], secret_value)
        self.assertEqual(environment["config"], "PUBLIC_LOCAL_COLLISION")
        self.assertEqual(environment["command"], "not a command")
        self.assertEqual(received_arguments, arguments)
        self.assertEqual(environment["PATH"], ":/nonexistent")
        self.assertNotIn("SECRET_SENTINEL", (self.root / "launcher.json").read_text())

    def test_missing_secret_does_not_execute_command(self):
        configuration = self.launch_configuration()
        configuration["secrets"] = {"KEY": str(self.root / "missing")}
        result = self.launch(configuration)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_invalid_metadata_does_not_execute_command(self):
        invalid_fields = [
            ("command", ""),
            ("command", "a\x00b"),
            ("args", ["a\x00b"]),
            ("args", "not a list"),
            ("environment", {"BAD-NAME": "x"}),
            ("secrets", {"KEY": "a\x00b"}),
        ]
        for field, value in invalid_fields:
            with self.subTest(field=field, value=value):
                configuration = self.launch_configuration()
                configuration[field] = value
                result = self.launch(configuration)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
