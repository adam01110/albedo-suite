"""Deterministic RTK argv grammar tests; no subprocess in classification."""

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(
    0,
    os.environ.get(
        "ALBEDO_RTK_SOURCE",
        str(Path(__file__).resolve().parents[1] / "src/server/priv/python"),
    ),
)
import albedo_rtk


class RtkRoutingTests(unittest.TestCase):
    def test_supported_grammar(self):
        for argv in (
            ["cargo", "test", "a b", "--", "--nocapture"],
            ["go", "build", "./..."],
            ["git", "diff", "--", "a b"],
            ["rg", "-F", "$(touch PWN);*"],
            ["wc", "-l"],
            ["ls", "-lah", "a b"],
            ["pytest", "tests/a b.py"],
        ):
            with self.subTest(argv=argv):
                with patch("albedo_rtk.shutil.which", return_value="/tools/rtk"):
                    self.assertEqual(
                        albedo_rtk.route(argv, None), ["/tools/rtk", *argv]
                    )

    def test_native_identity_and_unsupported_grammar(self):
        for argv in (
            ["rtk", "ls"],
            ["/tools/rtk", "ls"],
            ["/tools/cargo", "test"],
            ["cargo", "+nightly", "test"],
            ["cargo", "metadata"],
            ["git", "-C", "a b", "status"],
            ["jj", "status"],
            ["ls", "--", "-file"],
            ["ls", "--sort", "size"],
            ["pytest", "--", "-file"],
            ["wc", "-"],
            ["rg", "--help"],
            ["ls", "--ultra-compact"],
            ["rg", "--json", "x"],
            ["cargo", "check", "--message-format=json"],
            ["git", "status", "--porcelain"],
        ):
            with (
                self.subTest(argv=argv),
                patch(
                    "albedo_rtk.shutil.which",
                    side_effect=AssertionError("unexpected RTK probe"),
                ),
            ):
                self.assertEqual(albedo_rtk.route(argv, {}), argv)

    def test_missing_required_rtk_is_not_native_fallback(self):
        with patch("albedo_rtk.shutil.which", return_value=None) as which:
            with self.assertRaisesRegex(FileNotFoundError, "no native fallback"):
                albedo_rtk.route(["ls"], {"PATH": "/empty"})
            which.assert_called_once_with("rtk", path="/empty")

    def test_stdin_grammar(self):
        self.assertTrue(albedo_rtk.supported(["rg", "match"], stdin=True))
        self.assertTrue(albedo_rtk.supported(["wc", "-l"], stdin=True))
        for argv in (["cargo", "test"], ["go", "build"], ["ls"], ["pytest"]):
            self.assertFalse(albedo_rtk.supported(argv, stdin=True))


if __name__ == "__main__":
    unittest.main()
