"""Exercise the packaged quota core without credentials or network requests."""

import json
import os
import subprocess
import unittest


@unittest.skipUnless(
    os.environ.get("ALBEDO_USAGE_CORE"), "requires packaged usage core"
)
class UsageCoreTest(unittest.TestCase):
    def test_codex_window_labels(self):
        envelope = {
            "provider": "openai-codex",
            "credential": {"kind": "oauth", "access": "fake", "accountId": "fake"},
            "nowMs": 1793013065263,
            "responses": [
                [
                    {
                        "status": 200,
                        "body": json.dumps(
                            {
                                "rate_limit": {
                                    "primary_window": {
                                        "used_percent": 3,
                                        "limit_window_seconds": 18000,
                                        "reset_at": 1793029889,
                                    },
                                    "secondary_window": {
                                        "used_percent": 0,
                                        "limit_window_seconds": 604800,
                                        "reset_at": 1793616689,
                                    },
                                },
                            }
                        ),
                    }
                ]
            ],
        }
        result = subprocess.run(
            [os.environ["ALBEDO_USAGE_CORE"], "advance", "-"],
            input=json.dumps(envelope) + "\n",
            text=True,
            capture_output=True,
            check=False,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout.splitlines()[-1])["report"]
        self.assertFalse(report.get("error"))
        self.assertEqual(
            [
                (limit["windowLabel"], limit["usedPercent"])
                for limit in report["limits"]
            ],
            [("5h window", 3), ("7d window", 0)],
        )


if __name__ == "__main__":
    unittest.main()
