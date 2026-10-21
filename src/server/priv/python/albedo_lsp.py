"""Temporary, explicit local stdio LSP support. Server output is untrusted data."""

from __future__ import annotations

import asyncio
import atexit
from collections import OrderedDict
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import sys

MAX_BYTES = 8 * 1024 * 1024
MAX_RESULT = 1024 * 1024
REQUEST_SECONDS = 30
MAX_OPERATIONS = 4
IDLE_SECONDS = 60
_PROCESSES: set[int] = set()


class LspError(RuntimeError):
    pass


def _kill(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


@atexit.register
def _shutdown():
    for pid in tuple(_PROCESSES):
        _kill(pid)


def _json(value, limit=MAX_RESULT):
    data = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
    if len(data) > limit:
        raise LspError("LSP data exceeds byte limit")
    return data


def _string(value):
    return isinstance(value, str) and 0 < len(value) <= 4096 and "\0" not in value


def validate(config):
    if (
        not isinstance(config, dict)
        or type(config.get("version", 1)) is not int
        or config.get("version", 1) != 1
    ):
        raise ValueError("LSP configuration must be a version 1 object")
    servers = config.get("servers", [])
    if not isinstance(servers, list) or len(servers) > 64:
        raise ValueError("LSP servers must be a list of at most 64 entries")
    # Detach mutable host data and reject non-JSON values before storing it.
    try:
        servers = json.loads(_json(servers))
    except (TypeError, ValueError, LspError) as error:
        raise ValueError("invalid or oversized LSP configuration") from error
    result = []
    ids = set()
    for raw in servers:
        if not isinstance(raw, dict):
            raise ValueError("LSP server must be an object")
        item = dict(raw)
        for key in ("id", "bin"):
            if not _string(item.get(key)):
                raise ValueError(f"invalid LSP {key}")
        if item["id"] in ids:
            raise ValueError("duplicate LSP server id")
        ids.add(item["id"])
        for key, default in (("args", []), ("include", ["**/*"]), ("rootMarkers", [])):
            value = item.setdefault(key, default)
            if (
                not isinstance(value, list)
                or len(value) > 128
                or not all(_string(v) for v in value)
            ):
                raise ValueError(f"invalid LSP {key}")
        if any(
            Path(v).is_absolute() or ".." in Path(v).parts for v in item["rootMarkers"]
        ):
            raise ValueError("rootMarkers must be relative without traversal")
        if type(item.setdefault("enabled", True)) is not bool:
            raise ValueError("enabled must be boolean")
        if not _string(item.setdefault("cwd", "{root}")):
            raise ValueError("invalid cwd")
        for key, default, maximum in (
            ("startupTimeoutMs", 45000, 120000),
            ("diagnosticsWaitMs", 2000, 30000),
        ):
            value = item.setdefault(key, default)
            if type(value) is not int or not 1 <= value <= maximum:
                raise ValueError(f"invalid {key}")
        for key in ("initializationOptions", "settings", "languageIdByExtension"):
            value = item.setdefault(key, {})
            if not isinstance(value, dict):
                raise ValueError(f"{key} must be an object")
            _json(value)
        if not all(
            _string(k) and k.startswith(".") and _string(v)
            for k, v in item["languageIdByExtension"].items()
        ):
            raise ValueError("invalid languageIdByExtension")
        result.append(item)
    _json(result)
    return result


async def _finish_cleanup(operation):
    task = asyncio.create_task(operation)
    try:
        return await asyncio.shield(task)
    except asyncio.CancelledError:
        # Keep teardown alive and retain its ownership until it finishes.
        while not task.done():
            try:
                await asyncio.shield(task)
            except asyncio.CancelledError:
                continue
        if not task.cancelled():
            task.exception()
        raise


class _Client:
    def __init__(self, config, root, cwd):
        self.config, self.root, self.cwd = config, root, cwd
        self.lock = asyncio.Lock()
        self.proc = None
        self.reader = self.stderr_task = None
        self.pending = {}
        self.next_id = 0
        self.doc_version = 0
        self.docs = OrderedDict()
        self.diagnostics = {}
        self.changed = asyncio.Event()
        self.failure = None
        self.capabilities = {}
        self.stderr = bytearray()

    async def send(self, value):
        if self.failure:
            raise LspError(self.failure)
        data = _json({"jsonrpc": "2.0", **value}, MAX_BYTES)
        if self.proc is None or self.proc.stdin is None:
            raise LspError("LSP stdin is not available")
        stdin = self.proc.stdin
        stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        async with asyncio.timeout(REQUEST_SECONDS):
            await stdin.drain()

    async def request(self, method, params, timeout=REQUEST_SECONDS):
        self.next_id += 1
        ident = self.next_id
        future = asyncio.get_running_loop().create_future()
        self.pending[ident] = future
        try:
            async with asyncio.timeout(timeout):
                await self.send({"id": ident, "method": method, "params": params})
                return await future
        except TimeoutError as error:
            raise LspError(f"LSP request timed out: {method}") from error
        finally:
            self.pending.pop(ident, None)

    async def start(self):
        self.proc = await asyncio.create_subprocess_exec(
            self.config["bin"],
            *self.config["args"],
            cwd=self.cwd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
            limit=16384,
        )
        _PROCESSES.add(self.proc.pid)
        self.reader = asyncio.create_task(self.read())
        self.stderr_task = asyncio.create_task(self.drain_stderr())
        response = await self.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": self.root.as_uri(),
                "workspaceFolders": [
                    {"uri": self.root.as_uri(), "name": self.root.name}
                ],
                "capabilities": {
                    "general": {"positionEncodings": ["utf-16"]},
                    "workspace": {"configuration": True, "workspaceFolders": True},
                    "textDocument": {"publishDiagnostics": {"versionSupport": True}},
                },
                "initializationOptions": self.config["initializationOptions"],
            },
            self.config["startupTimeoutMs"] / 1000,
        )
        if not isinstance(response, dict) or not isinstance(
            response.get("capabilities"), dict
        ):
            raise LspError("invalid initialize result")
        self.capabilities = response["capabilities"]
        if self.capabilities.get("positionEncoding", "utf-16") != "utf-16":
            raise LspError("server selected unsupported position encoding")
        await self.send({"method": "initialized", "params": {}})
        await self.send(
            {
                "method": "workspace/didChangeConfiguration",
                "params": {"settings": self.config["settings"]},
            }
        )

    async def drain_stderr(self):
        assert self.proc is not None and self.proc.stderr is not None
        while data := await self.proc.stderr.read(4096):
            self.stderr.extend(data)
            del self.stderr[:-16384]

    async def read(self):
        assert self.proc is not None and self.proc.stdout is not None
        try:
            while True:
                length = None
                total = 0
                while True:
                    line = await self.proc.stdout.readline()
                    total += len(line)
                    if not line:
                        raise LspError("LSP stdout closed (EOF)")
                    if total > 16384:
                        raise LspError("LSP header exceeds 16 KiB")
                    if line == b"\r\n":
                        break
                    key, sep, value = line.partition(b":")
                    if not sep:
                        raise LspError("malformed LSP header")
                    if key.lower() == b"content-length":
                        if length is not None:
                            raise LspError("duplicate Content-Length")
                        length = int(value.strip())
                if length is None or not 0 < length <= MAX_BYTES:
                    raise LspError("invalid LSP frame size")
                message = json.loads(await self.proc.stdout.readexactly(length))
                if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
                    raise LspError("invalid LSP message")
                if "method" in message:
                    if "id" in message:
                        await self.server_request(message)
                    elif message["method"] == "textDocument/publishDiagnostics":
                        params = message.get("params", {})
                        uri = params.get("uri")
                        doc = self.docs.get(uri)
                        version = params.get("version")
                        if doc and (
                            version is None
                            or type(version) is int
                            and version == doc[0]
                        ):
                            diagnostics = params.get("diagnostics")
                            if not isinstance(diagnostics, list):
                                raise LspError("invalid diagnostics")
                            _json(diagnostics)
                            # Bound aggregate retained diagnostics across open documents.
                            projected = sum(
                                len(_json(item[1]))
                                for key, item in self.diagnostics.items()
                                if key != uri
                            ) + len(_json(diagnostics))
                            if projected > 4 * MAX_RESULT:
                                raise LspError("retained diagnostics exceed 4 MiB")
                            self.diagnostics[uri] = (doc[0], diagnostics)
                            self.changed.set()
                else:
                    ident = message.get("id")
                    if type(ident) is int and ident in self.pending:
                        future = self.pending[ident]
                        if not future.done():
                            if "error" in message:
                                future.set_exception(
                                    LspError(
                                        "LSP server error: "
                                        + _json(message["error"]).decode()[:2000]
                                    )
                                )
                            elif "result" in message:
                                _json(message["result"])
                                future.set_result(message["result"])
                            else:
                                raise LspError("response missing result/error")
        except asyncio.CancelledError:
            raise
        except Exception as error:
            if self.failure is None:
                self.failure = f"LSP transport failed: {error}"
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(LspError(self.failure))
            self.changed.set()
            _kill(self.proc.pid)

    async def server_request(self, message):
        method = message["method"]
        params = message.get("params", {})
        reply = {"id": message["id"]}
        if method == "workspace/configuration":
            items = params.get("items", [])
            if not isinstance(items, list) or len(items) > 128:
                raise LspError("invalid configuration request")
            result = []
            for item in items:
                value = self.config["settings"]
                for part in (
                    item.get("section", "").split(".") if item.get("section") else []
                ):
                    value = value.get(part) if isinstance(value, dict) else None
                result.append(value)
            reply["result"] = result
        elif method == "workspace/workspaceFolders":
            reply["result"] = [{"uri": self.root.as_uri(), "name": self.root.name}]
        elif method == "workspace/applyEdit":
            reply["result"] = {
                "applied": False,
                "failureReason": "read-only LSP client",
            }
        elif method == "window/workDoneProgress/create":
            reply["result"] = None
        else:
            reply["error"] = {"code": -32601, "message": "unsupported client method"}
        await self.send(reply)

    async def sync(self, path, text):
        uri = path.as_uri()
        previous = self.docs.get(uri)
        digest = hashlib.sha256(text.encode("utf-8")).digest()
        if previous and previous[1] == digest:
            self.docs.move_to_end(uri)
            return previous[0]
        self.doc_version += 1
        version = self.doc_version
        if not previous and len(self.docs) >= 32:
            old, _ = self.docs.popitem(last=False)
            self.diagnostics.pop(old, None)
            await self.send(
                {
                    "method": "textDocument/didClose",
                    "params": {"textDocument": {"uri": old}},
                }
            )
        self.docs[uri] = (version, digest)
        self.diagnostics.pop(uri, None)
        if previous:
            sync = self.capabilities.get("textDocumentSync", 0)
            change = sync.get("change", 0) if isinstance(sync, dict) else sync
            if change not in (1, 2):
                raise LspError("server does not support document changes")
            params = {
                "textDocument": {"uri": uri, "version": version},
                "contentChanges": [{"text": text}],
            }
            method = "textDocument/didChange"
        else:
            params = {
                "textDocument": {
                    "uri": uri,
                    "version": version,
                    "languageId": self.config["languageIdByExtension"].get(
                        path.suffix, path.suffix.lstrip(".")
                    ),
                    "text": text,
                }
            }
            method = "textDocument/didOpen"
        await self.send({"method": method, "params": params})
        return version

    async def stop(self):
        await _finish_cleanup(self._stop())

    async def _stop(self):
        if not self.proc:
            return
        for future in self.pending.values():
            if not future.done():
                future.set_exception(LspError(self.failure or "LSP closed"))
        _kill(self.proc.pid)
        try:
            await asyncio.wait_for(self.proc.wait(), 3)
        finally:
            for task in (self.reader, self.stderr_task):
                if task:
                    task.cancel()
            await asyncio.gather(
                *(t for t in (self.reader, self.stderr_task) if t),
                return_exceptions=True,
            )
            _PROCESSES.discard(self.proc.pid)
            self.docs.clear()
            self.diagnostics.clear()


class Lsp:
    """One session. Explicit operations start servers; close permits a fresh start.

    Positions are zero-based UTF-16 code units, not Python string indices.
    No remote operations, automatic diagnostics, or edits are provided.
    """

    def __init__(self, config, cwd=None):
        self.config = validate(config)
        self.cwd = Path(cwd or os.getcwd()).resolve()
        self.clients = {}
        self.guard = asyncio.Lock()
        self.active_operations = 0
        self.pending = {}
        self.edit_version = 0
        self.overflow = False
        self.finish_lock = asyncio.Lock()
        self.idle_timer = None
        self.idle_tasks = set()

    def cancel_idle(self):
        if self.idle_timer is not None:
            self.idle_timer.cancel()
            self.idle_timer = None

    def arm_idle(self):
        self.cancel_idle()
        if not self.active_operations and any(
            not client.failure for client in self.clients.values()
        ):
            self.idle_timer = asyncio.get_running_loop().call_later(
                IDLE_SECONDS, self.expire_idle
            )

    def expire_idle(self):
        self.idle_timer = None
        task = asyncio.create_task(self._close(None, idle=True))
        self.idle_tasks.add(task)
        task.add_done_callback(self.idle_done)

    def idle_done(self, task):
        self.idle_tasks.discard(task)
        if not task.cancelled() and task.exception() is not None:
            asyncio.get_running_loop().call_exception_handler(
                {"message": "LSP idle shutdown failed", "exception": task.exception()}
            )

    def record(self, path):
        """Queue an edit without reading text or starting servers."""
        path = Path(os.path.abspath(Path(path).expanduser()))
        if not path.is_relative_to(self.cwd):
            return
        if path not in self.pending and len(self.pending) >= 1024:
            self.overflow = True
            return
        self.edit_version += 1
        self.pending[path] = self.edit_version

    async def finish(self, paths=None, *, details=False):
        """Report diagnostics once per edited snapshot, retaining failed checks."""
        result = {"ok": True, "error": "", "feedback": ""}
        feedback = ""
        checked = []
        unmatched = []
        versions = {}
        async with self.finish_lock:
            try:
                async with asyncio.timeout(45):
                    if self.overflow:
                        raise LspError("LSP tracking exceeds 1024 files")
                    for path, edit in list(self.pending.items()):
                        if paths is not None and path not in paths:
                            continue
                        relative = path.relative_to(self.cwd).as_posix()
                        servers = [
                            c
                            for c in self.config
                            if c["enabled"]
                            and any(
                                fnmatch.fnmatchcase(relative, pattern)
                                or pattern.startswith("**/")
                                and fnmatch.fnmatchcase(relative, pattern[3:])
                                for pattern in c["include"]
                            )
                        ]
                        if servers:
                            before = self.snapshot(path, "diagnostics", None, None)[0]
                            reports = ""
                            for config in servers:
                                report = await self.diagnostics(
                                    path, server=config["id"]
                                )
                                if report["diagnostics"]:
                                    if len(feedback) + len(reports) < 16384:
                                        reports += (
                                            json.dumps(report, ensure_ascii=True)[
                                                : 16384 - len(feedback) - len(reports)
                                            ]
                                            + "\n"
                                        )
                            if (
                                self.pending.get(path) != edit
                                or self.snapshot(path, "diagnostics", None, None)[0]
                                != before
                            ):
                                raise LspError(f"LSP file changed during check: {path}")
                            feedback = (feedback + reports)[:16384]
                        (checked if servers else unmatched).append(str(path))
                        versions[path] = edit
                        del self.pending[path]
            except (OSError, ValueError, LspError, TimeoutError) as error:
                result["ok"] = False
                result["error"] = (str(error) or "LSP check timed out")[:16384]
        if feedback:
            result["feedback"] = feedback + (
                " [truncated]" if len(feedback) == 16384 else ""
            )
        if details:
            result["checked"] = checked
            result["unmatched"] = unmatched
            result["_versions"] = versions
        return result

    def servers(self):
        return [
            {
                "id": c["id"],
                "enabled": c["enabled"],
                "state": (
                    "failed"
                    if c["id"] in self.clients and self.clients[c["id"]].failure
                    else "loaded"
                    if c["id"] in self.clients
                    else "unloaded"
                ),
            }
            for c in self.config
        ]

    def select(self, path, server):
        path = (self.cwd / path).resolve(strict=True)
        if not path.is_relative_to(self.cwd) or not path.is_file():
            raise LspError("LSP path must be a regular file inside the workspace")
        relative = path.relative_to(self.cwd).as_posix()
        matches = [
            c
            for c in self.config
            if c["enabled"]
            and (server is None or c["id"] == server)
            and any(
                fnmatch.fnmatchcase(relative, pattern)
                or pattern.startswith("**/")
                and fnmatch.fnmatchcase(relative, pattern[3:])
                for pattern in c["include"]
            )
        ]
        if len(matches) != 1:
            raise LspError(
                "no matching LSP server"
                if not matches
                else "ambiguous LSP servers; specify server id"
            )
        return path, matches[0]

    async def client(self, config, path):
        async with self.guard:
            ident = config["id"]
            root = self.cwd
            for candidate in (path.parent, *path.parent.parents):
                if not candidate.is_relative_to(self.cwd):
                    break
                if any(
                    (candidate / marker).exists() for marker in config["rootMarkers"]
                ):
                    root = candidate
                    break
            if ident in self.clients and self.clients[ident].root != root:
                raise LspError(
                    "server is attached to a different project root; close(server) first"
                )
            if ident not in self.clients:
                if len(self.clients) >= 8:
                    raise LspError("LSP live client limit (8); close a server first")
                cwd = Path(config["cwd"].replace("{root}", str(root)))
                if not cwd.is_absolute():
                    cwd = root / cwd
                cwd = cwd.resolve(strict=True)
                if not cwd.is_relative_to(self.cwd) or not cwd.is_dir():
                    raise LspError("server cwd escapes workspace")
                self.clients[ident] = _Client(config, root, cwd)
            return self.clients[ident]

    def snapshot(self, path, method, line, character):
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as handle:
            opened = Path(f"/proc/self/fd/{handle.fileno()}").resolve(strict=True)
            if not opened.is_relative_to(self.cwd) or not stat.S_ISREG(
                os.fstat(handle.fileno()).st_mode
            ):
                raise LspError("opened LSP file escapes workspace or is not regular")
            data = handle.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise LspError("LSP file exceeds 8 MiB")
        text = data.decode("utf-8")
        position = None
        if method in ("hover", "definition", "references"):
            if type(line) is not int or type(character) is not int:
                raise ValueError("line and character must be UTF-16 integers")
        if line is not None or character is not None:
            lines = text.split("\n")
            if (
                type(line) is not int
                or type(character) is not int
                or not 0 <= line < len(lines)
                or character < 0
            ):
                raise ValueError("invalid zero-based UTF-16 position")
            units = 0
            for ch in lines[line].rstrip("\r"):
                units += 2 if ord(ch) > 0xFFFF else 1
                if units >= character:
                    break
            if character != 0 and character != units:
                raise ValueError(
                    "UTF-16 position outside line or splitting surrogate pair"
                )
            position = {"line": line, "character": character}
        return text, position

    async def operation(
        self,
        path,
        method,
        server=None,
        line=None,
        character=None,
        include_declaration=True,
    ):
        if self.active_operations >= MAX_OPERATIONS:
            raise LspError("LSP operation limit (4); await pending calls first")
        self.cancel_idle()
        self.active_operations += 1
        try:
            return await self._operation(
                path, method, server, line, character, include_declaration
            )
        finally:
            self.active_operations -= 1
            self.arm_idle()

    async def _operation(
        self,
        path,
        method,
        server=None,
        line=None,
        character=None,
        include_declaration=True,
    ):
        path, config = self.select(path, server)
        # Validate before startup without retaining file text in the wait queue.
        self.snapshot(path, method, line, character)
        client = await self.client(config, path)
        async with client.lock:
            if client.failure:
                raise LspError(
                    f"LSP server {config['id']!r} for {path}: {client.failure}; "
                    f"close explicitly with await lsp.close({config['id']!r}) "
                    "before restarting"
                )
            try:
                if client.proc is None:
                    await client.start()
                capability = {
                    "hover": "hoverProvider",
                    "definition": "definitionProvider",
                    "references": "referencesProvider",
                    "documentSymbol": "documentSymbolProvider",
                }.get(method)
                if capability and client.capabilities.get(capability) in (None, False):
                    raise LspError(f"server does not support {method}")
                text, position = self.snapshot(path, method, line, character)
                version = await client.sync(path, text)
                if method == "diagnostics":

                    async def wait():
                        while True:
                            if client.failure:
                                raise LspError(client.failure)
                            found = client.diagnostics.get(path.as_uri())
                            if found and found[0] == version:
                                return found[1]
                            client.changed.clear()
                            await client.changed.wait()

                    try:
                        result = await asyncio.wait_for(
                            wait(), config["diagnosticsWaitMs"] / 1000
                        )
                    except TimeoutError as error:
                        raise LspError(
                            "no fresh diagnostics publication before timeout"
                        ) from error
                else:
                    params = {"textDocument": {"uri": path.as_uri()}}
                    if position is not None:
                        params["position"] = position
                    if method == "references":
                        if type(include_declaration) is not bool:
                            raise ValueError("include_declaration must be boolean")
                        params["context"] = {"includeDeclaration": include_declaration}
                    result = await client.request("textDocument/" + method, params)
                return {
                    "server": config["id"],
                    "path": str(path),
                    "version": version,
                    "diagnostics" if method == "diagnostics" else "result": result,
                }
            except BaseException as error:
                # Failure is terminal: there is no implicit reconnect or replay.
                if client.failure is None:
                    client.failure = f"{type(error).__name__}: {error}"
                await client.stop()
                if isinstance(error, Exception):
                    stderr = client.stderr.decode("utf-8", errors="replace")[-4096:]
                    detail = f"\nServer stderr (untrusted): {stderr}" if stderr else ""
                    raise LspError(
                        f"LSP server {config['id']!r} for {path}: "
                        f"{client.failure}{detail}; "
                        f"close explicitly with await lsp.close({config['id']!r}) "
                        "before restarting"
                    ) from error
                raise

    async def diagnostics(self, path, server=None):
        return await self.operation(path, "diagnostics", server)

    async def hover(self, path, line, character, server=None):
        return await self.operation(path, "hover", server, line, character)

    async def definition(self, path, line, character, server=None):
        return await self.operation(path, "definition", server, line, character)

    async def references(
        self, path, line, character, server=None, include_declaration=True
    ):
        return await self.operation(
            path, "references", server, line, character, include_declaration
        )

    async def symbols(self, path, server=None):
        return await self.operation(path, "documentSymbol", server)

    async def close(self, server=None):
        self.cancel_idle()
        await _finish_cleanup(self._close(server))
        if self.idle_tasks:
            await asyncio.gather(*self.idle_tasks)
        self.arm_idle()

    async def _close(self, server, *, idle=False):
        async with self.guard:
            if idle and (self.active_operations or self.idle_timer is not None):
                return
            if server is not None and not any(c["id"] == server for c in self.config):
                raise LspError("unknown LSP server")
            for ident in list(self.clients):
                if server is None or ident == server:
                    client = self.clients[ident]
                    if idle and client.failure:
                        continue
                    # An idle healthy client receives bounded graceful shutdown.
                    if client.proc and not client.lock.locked() and not client.failure:
                        async with client.lock:
                            try:
                                async with asyncio.timeout(2):
                                    await client.request("shutdown", None, timeout=1)
                                    await client.send({"method": "exit"})
                            except Exception:
                                pass
                    # Abort in-flight work before waiting for its operation lock.
                    client.failure = "LSP server explicitly closed"
                    await client.stop()
                    async with client.lock:
                        self.clients.pop(ident, None)
