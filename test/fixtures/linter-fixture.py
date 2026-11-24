"""Fake linter: argv is MODE [PATH]; it never edits files."""

import json
import os
import sys
import time
from pathlib import Path

mode = sys.argv[1]
target = sys.argv[2] if len(sys.argv) > 2 else "-"
text = sys.stdin.read() if target == "-" else Path(target).read_text()
lines = text.splitlines()
hits = [(number, line) for number, line in enumerate(lines, 1) if "bad" in line]

if mode == "regex":
    for number, line in hits:
        print(f"{target}:{number}:{line.index('bad') + 1}: warning[no-bad]: bad word")
    print(f"other.py:1:1: error[elsewhere]: about another file")
    print("Results: summary lines are ignored", file=sys.stderr)
    sys.exit(1 if hits else 0)
if mode == "sarif":
    results = [
        {
            "ruleId": "no-bad",
            "level": "error",
            "message": {"text": "bad word"},
            "locations": [
                {
                    "physicalLocation": {
                        "artifactLocation": {
                            "uri": Path(os.path.abspath(target)).as_uri()
                        },
                        "region": {
                            "startLine": number,
                            "startColumn": 2,
                            "endLine": number,
                        },
                    }
                }
            ],
        }
        for number, _ in hits
    ]
    print(json.dumps({"version": "2.1.0", "runs": [{"results": results}]}))
    sys.exit(1 if hits else 0)
if mode == "cwd":
    print(f"-:1:1: info[cwd]: {os.getcwd()}")
    sys.exit(0)
if mode == "fail":
    print("configuration error", file=sys.stderr)
    sys.exit(2)
if mode == "sleep":
    time.sleep(30)
