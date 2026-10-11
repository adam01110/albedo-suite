import os
from pathlib import Path
import runpy
import sys

control = Path(sys.argv[1])
server = Path(sys.argv[2])
(control / ("pid-" + str(os.getpid()))).touch()
os.environ["FAKE_MCP_CONTROL"] = str(control)
os.environ["FAKE_MCP_CLOSED"] = str(control / "closed")
runpy.run_path(str(server), run_name="__main__")
