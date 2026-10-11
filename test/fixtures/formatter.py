import json
import os
from pathlib import Path
import sys
import time

control = Path(sys.argv[1])
target = Path(sys.argv[-1])
original = target.read_text()
with (control / "runs.jsonl").open("a") as output:
    output.write(
        json.dumps(
            {
                "path": str(target),
                "input": original,
                "pid": os.getpid(),
            }
        )
        + "\n"
    )

if "BAD" in original:
    print("FORMATTER_FIXTURE_BAD: repair BAD input", file=sys.stderr)
    sys.exit(23)

target.write_text(original.strip() + "\n")
if (control / "block").exists():
    (control / "started").write_text(str(os.getpid()))
    while not (control / "release").exists():
        time.sleep(0.02)
