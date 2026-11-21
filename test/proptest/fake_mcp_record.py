"""Line-delimited JSON-RPC MCP server that records what it receives.

Used by test/proptest/lazy_mcp_call_prop.gleam. FAKE_MCP_CONTROL names a
directory: `pid` receives the server's process id, `seen` one method name per
line, `lines` every raw request line, and `calls` every tools/call params
object as JSON. `tools` replaces the catalogue; `slow` holds every call for
that many seconds; `delay` holds the handshake; `mode` "deaf" ignores SIGTERM.
"""

import json
import os
import signal
import sys
import time
from pathlib import Path

CONTROL = Path(os.environ.get("FAKE_MCP_CONTROL") or "/nonexistent")

DEFAULT_TOOLS = [
    {
        "name": "echo",
        "description": "Echo the arguments back",
        "inputSchema": {"type": "object"},
    }
]


def control(name):
    path = CONTROL / name
    if not path.exists():
        return None
    try:
        return path.read_text()
    except FileNotFoundError:
        return None


if control("mode") == "deaf":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

if CONTROL.exists():
    (CONTROL / "pid").write_text(str(os.getpid()))


def record(name, line):
    with (CONTROL / name).open("a") as handle:
        handle.write(line + "\n")


def reply(id, result=None, error=None):
    body = {"jsonrpc": "2.0", "id": id}
    body["error" if error else "result"] = error or result
    sys.stdout.write(json.dumps(body) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    if not line.strip():
        continue
    if CONTROL.exists():
        record("lines", line.rstrip("\n"))
    message = json.loads(line)
    method = message.get("method")
    id = message.get("id")
    if CONTROL.exists():
        record("seen", method or "")
    if id is None:
        continue
    if method == "initialize":
        delay = control("delay")
        if delay:
            time.sleep(float(delay))
        reply(
            id,
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "record", "version": "1"},
            },
        )
    elif method == "tools/list":
        tools = control("tools")
        reply(id, {"tools": json.loads(tools) if tools else DEFAULT_TOOLS})
    elif method == "tools/call":
        params = message.get("params") or {}
        if CONTROL.exists():
            record("calls", json.dumps(params, ensure_ascii=False))
        slow = control("slow")
        if slow:
            time.sleep(float(slow))
        arguments = params.get("arguments")
        reply(
            id,
            {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(arguments, ensure_ascii=False),
                    }
                ]
            },
        )
    elif method == "ping":
        reply(id, {})
    else:
        reply(id, error={"code": -32601, "message": "method not found"})
