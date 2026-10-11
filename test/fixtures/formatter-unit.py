"""Controllable child formatter for staging, timeout and race regressions."""

import json
import os
from pathlib import Path
import sys
import time

state = json.loads(Path(sys.argv[1]).read_text())
target = Path(sys.argv[-1])
mode = state["mode"]

if mode == "uppercase":
    target.write_text(target.read_text().upper())
elif mode == "write":
    target.write_text(state["text"])
elif mode == "failure":
    sys.stderr.write(state["diagnostic"])
    sys.exit(state.get("exit_code", 1))
elif mode == "concurrent_change":
    target.write_text("formatted")
    Path(state["original"]).write_text("user change")
elif mode == "verbose_failure":
    sys.stdout.write("x" * 1000000)
    sys.exit(3)
elif mode == "timeout":
    time.sleep(20)
elif mode == "blocked":
    Path(state["started"]).write_text(str(os.getpid()))
    time.sleep(20)
    target.write_text("late")
elif mode == "project":
    Path(state["log"]).write_text(json.dumps(sys.argv[2:]))
    target.write_text("project")
elif mode == "slow":
    time.sleep(0.65)
    target.write_text("done")
else:
    raise ValueError(f"Unknown fixture mode: {mode}")
