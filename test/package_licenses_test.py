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


def sealed_files(output):
    """The files upstream's build seal hashes (build_identity's
    applications_digest): each application's ebin and priv trees, symlinks
    followed, named from `output` and sorted, without the kernel venv."""
    paths = []
    for app in output.iterdir():
        if not (app / "ebin").is_dir():
            continue
        for subtree in ("ebin", "priv"):
            for directory, directories, names in os.walk(
                app / subtree, followlinks=True
            ):
                if Path(directory) == output / "albedo/priv/python":
                    directories[:] = [d for d in directories if d != ".venv"]
                paths += [
                    (Path(directory) / name).relative_to(output).as_posix()
                    for name in names
                    if (Path(directory) / name).is_file()
                ]
    return sorted(paths)


class PackageLicenseTests(unittest.TestCase):
    def assert_agpl_with_classpath_exception(self, doc):
        license_text = (doc / "LICENSE").read_text()
        self.assertIn("GNU AFFERO GENERAL PUBLIC LICENSE", license_text)
        self.assertIn('"CLASSPATH" EXCEPTION', license_text)
        self.assertIn("If you modify albedo, you may extend this", license_text)

    def test_suite_packages_include_agpl_exception_and_attribution(self):
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
                self.assert_agpl_with_classpath_exception(doc)
                self.assertIn("AGPL-3.0-only", (doc / "SOURCE.md").read_text())
                self.assertTrue((doc / "THIRD_PARTY_NOTICES.md").is_file())
                self.assertTrue((doc / "LICENSES/albedo-AUTHORS.md").is_file())
                self.assertIn(
                    "Mozilla Public License Version 2.0",
                    (doc / "LICENSES/albedo-MPL-2.0.txt").read_text(),
                )
                self.assertTrue(
                    (doc / "LICENSES/albedo-THIRD_PARTY_NOTICES.md").is_file()
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
        self.assertEqual(
            (upstream / "LICENSE").read_bytes(), (doc / "LICENSE").read_bytes()
        )
        self.assertEqual(
            (upstream / "THIRD_PARTY_NOTICES.md").read_bytes(),
            (doc / "LICENSES/albedo-THIRD_PARTY_NOTICES.md").read_bytes(),
        )
        source = (doc / "SOURCE.md").read_text()
        self.assertIn("nix build path:.#albedo-patched", source)
        self.assertIn("cd -P source/suite", source)

    def test_server_build_seal_matches_installed_files(self):
        output = PACKAGES["server"] / "lib/albedo"
        seal = (output / "albedo/.build-digest-v2").read_text()
        paths = sealed_files(output)
        self.assertTrue(paths)
        digest = hashlib.sha256()
        for name in paths:
            digest.update(name.encode())
            with (output / name).open("rb") as source:
                while chunk := source.read(65536):
                    digest.update(chunk)
        self.assertEqual(seal, digest.hexdigest() + "\n")

    def test_fff_retains_agpl_adapter_and_mit_dependency_licenses(self):
        package = PACKAGES["fff"]
        doc = package / "share/licenses/albedo-fff"
        self.assert_agpl_with_classpath_exception(doc)
        self.assertIn("libexec/albedo-fff.mjs", (doc / "SOURCE.md").read_text())
        self.assertIn("Permission is hereby granted", (doc / "fff-LICENSE").read_text())
        self.assertIn(
            "Permission is hereby granted", (doc / "ffi-rs-LICENSE").read_text()
        )
        self.assertTrue((package / "libexec/albedo-fff.mjs").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
