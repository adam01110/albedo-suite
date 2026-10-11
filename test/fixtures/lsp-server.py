"""Actual stdio fixture for temporary LSP integration tests."""

import argparse
import json
import os
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--mode", default="normal")
parser.add_argument("--log")
args = parser.parse_args()


def log(event, **values):
    if args.log:
        with open(args.log, "a") as handle:
            handle.write(json.dumps({"event": event, **values}) + "\n")


def send(value):
    data = json.dumps({"jsonrpc": "2.0", **value}).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
    sys.stdout.buffer.flush()


log("START", pid=os.getpid(), cwd=os.getcwd())
while True:
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        if line == b"\r\n":
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    message = json.loads(sys.stdin.buffer.read(length))
    method = message.get("method")
    params = message.get("params", {})
    log(method or "response", params=params, message=message)
    if method == "initialize":
        if args.mode == "death":
            sys.exit(2)
        if args.mode == "oversized":
            sys.stdout.buffer.write(b"Content-Length: 999999999\r\n\r\n")
            sys.stdout.buffer.flush()
            continue
        if args.mode == "stderr":
            sys.stderr.buffer.write(b"x" * 100000)
            sys.stderr.buffer.flush()
        if args.mode == "malformed":
            sys.stdout.buffer.write(b"Content-Length: 4\r\n\r\nxxxx")
            sys.stdout.buffer.flush()
            continue
        if args.mode == "timeout":
            continue
        providers = args.mode != "unsupported"
        send(
            {
                "id": message["id"],
                "result": {
                    "capabilities": {
                        "textDocumentSync": 1,
                        "hoverProvider": providers,
                        "definitionProvider": providers,
                        "referencesProvider": providers,
                        "documentSymbolProvider": providers,
                    }
                },
            }
        )
    elif method == "shutdown":
        if args.mode == "shutdown-timeout":
            continue
        send({"id": message["id"], "result": None})
    elif method == "exit":
        sys.exit(0)
    elif method == "initialized":
        send(
            {
                "id": "config",
                "method": "workspace/configuration",
                "params": {"items": [{"section": "fixture"}, {}]},
            }
        )
        send({"id": "edit", "method": "workspace/applyEdit", "params": {"edit": {}}})
    elif method in ("textDocument/didOpen", "textDocument/didChange"):
        if args.mode == "no-diagnostics":
            continue
        doc = params["textDocument"]
        text = doc.get("text", params.get("contentChanges", [{}])[0].get("text", ""))
        diagnostics = (
            []
            if "clean" in text
            else [
                {
                    "range": {
                        "start": {"line": 0, "character": 0},
                        "end": {"line": 0, "character": 1},
                    },
                    "message": text[:100],
                    "severity": 2,
                }
            ]
        )
        # Stale version is deliberately delivered before the valid publication.
        send(
            {
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": doc["uri"],
                    "version": doc["version"] - 1,
                    "diagnostics": [{"message": "stale"}],
                },
            }
        )
        send(
            {
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": doc["uri"],
                    "version": doc["version"],
                    "diagnostics": diagnostics,
                },
            }
        )
    elif method == "textDocument/hover":
        if args.mode == "request-timeout":
            continue
        if args.mode == "error":
            send(
                {
                    "id": message["id"],
                    "error": {"code": -32000, "message": "fixture error"},
                }
            )
        else:
            send(
                {
                    "id": message["id"],
                    "result": {
                        "contents": {"kind": "plaintext", "value": "fixture hover"},
                        "position": params["position"],
                    },
                }
            )
    elif method in ("textDocument/definition", "textDocument/references"):
        send(
            {
                "id": message["id"],
                "result": [
                    {
                        "uri": params["textDocument"]["uri"],
                        "range": {
                            "start": {"line": 0, "character": 0},
                            "end": {"line": 0, "character": 1},
                        },
                    }
                ],
            }
        )
    elif method == "textDocument/documentSymbol":
        send(
            {
                "id": message["id"],
                "result": [
                    {
                        "name": "Fixture",
                        "kind": 12,
                        "range": {
                            "start": {"line": 0, "character": 0},
                            "end": {"line": 0, "character": 1},
                        },
                        "selectionRange": {
                            "start": {"line": 0, "character": 0},
                            "end": {"line": 0, "character": 1},
                        },
                    }
                ],
            }
        )
