"""Check license notices and corresponding sources in built suite packages."""

import hashlib
import json
import os
import unittest
from pathlib import Path

PACKAGES = {
    name: Path(path)
    for name, path in json.loads(os.environ["ALBEDO_LICENSE_PACKAGES"]).items()
}


class PackageLicenseTests(unittest.TestCase):
    def test_suite_packages_include_mpl_and_attribution(self):
        for name in (
            "defaults",
            "patched",
            "server",
            "client",
            "client-patched",
            "render",
        ):
            with self.subTest(package=name):
                doc = PACKAGES[name] / "share/doc/albedo-suite"
                self.assertIn(
                    "Mozilla Public License Version 2.0", (doc / "LICENSE").read_text()
                )
                self.assertIn("MPL-2.0", (doc / "SOURCE.md").read_text())
                self.assertTrue((doc / "THIRD_PARTY_NOTICES.md").is_file())
                self.assertTrue(
                    (doc / "LICENSES/albedo-THIRD_PARTY_NOTICES.md").is_file()
                )
                self.assertEqual(
                    (doc / "LICENSE").read_bytes(),
                    (doc / "source/suite/LICENSE").read_bytes(),
                )

    def test_component_dependency_notices_are_retained(self):
        for name in ("server", "client", "client-patched", "render"):
            with self.subTest(package=name):
                doc = PACKAGES[name] / "share/doc/albedo-suite"
                self.assertTrue((doc / "LICENSES/JetBrainsMono-OFL.txt").is_file())
                self.assertTrue(
                    any(
                        path.is_file()
                        for path in (doc / "dependency-notices").rglob("*")
                    )
                )

    def test_sources_are_included_and_match_pristine_checksums(self):
        doc = PACKAGES["defaults"] / "share/doc/albedo-suite"
        suite, upstream = doc / "source/suite", doc / "source/upstream"
        self.assertTrue(str(suite.resolve()).startswith("/nix/store/"))
        self.assertTrue(str(upstream.resolve()).startswith("/nix/store/"))
        for name in (
            "flake.nix",
            "flake.lock",
            "nix/modules/packages.nix",
            "upstream/pin.json",
        ):
            self.assertTrue((suite / name).is_file(), name)
        for component in ("server", "client"):
            for line in (
                (suite / f"upstream/{component}.sha256").read_text().splitlines()
            ):
                expected, name = line.split("  ", 1)
                self.assertEqual(
                    hashlib.sha256((upstream / name).read_bytes()).hexdigest(),
                    expected,
                    name,
                )
        self.assertEqual(
            (upstream / "THIRD_PARTY_NOTICES.md").read_bytes(),
            (doc / "LICENSES/albedo-THIRD_PARTY_NOTICES.md").read_bytes(),
        )
        self.assertIn(
            "nix build path:.#albedo-patched",
            (doc / "SOURCE.md").read_text(),
        )

    def test_source_instructions_use_physical_source_directory(self):
        doc = PACKAGES["defaults"] / "share/doc/albedo-suite"
        self.assertIn("cd -P source/suite", (doc / "SOURCE.md").read_text())

    def test_included_python_overlay_matches_installed_source(self):
        package = PACKAGES["server"]
        source = package / "share/doc/albedo-suite/source/suite/src/server/priv/python"
        installed = package / "lib/albedo/albedo/priv/python"
        for path in source.rglob("*.py"):
            with self.subTest(path=str(path.relative_to(source))):
                self.assertEqual(
                    path.read_bytes(),
                    (installed / path.relative_to(source)).read_bytes(),
                )

    def test_standalone_web_has_source_and_dependency_notices(self):
        doc = PACKAGES["web"] / "share/doc/albedo-web"
        self.assertIn(
            "Mozilla Public License Version 2.0", (doc / "LICENSE").read_text()
        )
        self.assertIn("MPL-2.0", (doc / "SOURCE.md").read_text())
        self.assertEqual(
            (doc / "THIRD_PARTY_NOTICES.md").read_bytes(),
            (doc / "source/THIRD_PARTY_NOTICES.md").read_bytes(),
        )
        self.assertTrue((doc / "source/web/package-lock.json").is_file())
        self.assertTrue((doc / "source/nix/packages/web.nix").is_file())
        self.assertTrue(
            (doc / "dependency-notices/node_modules/svelte/LICENSE.md").is_file()
        )

    def test_fff_retains_mpl_adapter_and_mit_dependency_licenses(self):
        package = PACKAGES["fff"]
        doc = package / "share/licenses/albedo-fff"
        self.assertIn(
            "Mozilla Public License Version 2.0", (doc / "LICENSE").read_text()
        )
        self.assertIn("libexec/albedo-fff.mjs", (doc / "SOURCE.md").read_text())
        self.assertIn("Permission is hereby granted", (doc / "fff-LICENSE").read_text())
        self.assertIn(
            "Permission is hereby granted", (doc / "ffi-rs-LICENSE").read_text()
        )
        self.assertTrue((package / "libexec/albedo-fff.mjs").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
