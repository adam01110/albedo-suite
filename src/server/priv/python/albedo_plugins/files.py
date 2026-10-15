"""Bounded reads, exact edits, and FFF-backed search over workspace files.

Production searches use the daemon-owned FFF worker shared by host sessions.
"""

from __future__ import annotations

import asyncio
import codecs
import difflib
import fnmatch
import json
import os
import re
import shlex
import shutil
import secrets
import stat
import sys
import tempfile
from dataclasses import dataclass
from io import BufferedReader
from pathlib import Path
from collections.abc import Awaitable, Callable, Generator
from typing import Generic, Iterable, Sequence, TypeVar

from albedo_api import PythonApi, ReadyList, Text
import albedo_trace
from albedo_plugins import hook
from albedo_plugins import run as jobs


def _record_edit(path: Path) -> None:
    # Disabled and remote kernels do not configure local checks.
    if "albedo_plugins.formatter" in sys.modules:
        import albedo_formatter

        albedo_formatter.record(path)
    plugin = sys.modules.get("albedo_plugins.lsp")
    if plugin is not None:
        plugin.record(path)


READ_LIMIT = 16_000
READ_CHUNK_BYTES = 64 * 1024
LINE_SEPARATORS = "\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029"
LINE_BOUNDARIES = re.compile(rf"\r\n|[{re.escape(LINE_SEPARATORS)}]")
SEARCH_TIMEOUT = 30
LINE_WIDTH = 160
CANDIDATES = 4
LISTED = 10
CONTEXT = 2
PREVIEW_LINES = 2
WITHHELD = 3


@dataclass(frozen=True)
class Match:
    """One matching line, or with `context=` a surrounding line that prints
    grep-style as `path-line- text`."""

    path: str
    line: int
    text: str
    context: bool = False

    def __str__(self) -> str:
        mark = "-" if self.context else ":"
        return f"{self.path}{mark}{self.line}{mark} {self.text}"

    def to_dict(self) -> dict[str, str | int | bool]:
        fields: dict[str, str | int | bool] = {
            "path": self.path,
            "line": self.line,
            "text": self.text,
        }
        if self.context:
            fields["context"] = True
        return fields


class Rows(ReadyList):
    """A list that prints one row per line, so a REPL result reads like output.
    Like Text, it may be awaited or used directly."""

    def __init__(
        self, items: Iterable[object] = (), truncated: bool = False, note: str = ""
    ) -> None:
        super().__init__(items)
        self.truncated = truncated
        self.note = note

    def __repr__(self) -> str:
        if not self:
            return f"[]\n{self.note}" if self.note else "[]"
        body = "\n".join(str(item) for item in self)
        return body + ("\n[truncated]" if self.truncated else "")

    __str__ = __repr__


Result = TypeVar("Result")


class Search(Generic[Result]):
    """Work that runs a supervised job, so its result exists only once awaited:
    `Search[Rows]` awaits to Rows. Using it without `await` explains that
    instead of printing a coroutine."""

    def __init__(
        self, call: str, run: Callable[[], Awaitable[Result]], result: str = "rows"
    ) -> None:
        self._call = call
        self._run = run
        self._result = result

    def __await__(self) -> Generator[object, None, Result]:
        return self._run().__await__()

    def __getitem__(self: Search[Rows], index: int | slice) -> Search[object]:
        """`await files.find(...)[:10]` slices before it awaits; apply the
        slice to the rows instead of failing on precedence."""

        async def run() -> object:
            rows = await self._run()
            picked = rows[index]
            if isinstance(rows, Rows) and isinstance(index, slice):
                return Rows(picked, truncated=rows.truncated, note=rows.note)
            return picked

        return Search(self._call, run, self._result)

    def _unawaited(self) -> TypeError:
        return TypeError(
            f"{self._call}(...) runs in the background; "
            f"use `await {self._call}(...)` to get its {self._result}"
        )

    def __repr__(self) -> str:
        return f"<{self._call}(...) has not run: use `await {self._call}(...)` for its {self._result}>"

    __str__ = __repr__

    def __iter__(self):
        raise self._unawaited()

    def __len__(self) -> int:
        raise self._unawaited()


class _FFF:
    """Private supervised RPC worker; no native search fallback."""

    def __init__(self, host=None):
        self.host = host
        self.target = os.environ.get("ALBEDO_REMOTE_TARGET")
        self.worker_pid = None
        self.job = None
        self.directory = None
        self.lock = asyncio.Lock()

    async def close(self):
        async with self.lock:
            await self._close()

    async def _close(self):
        if self.job is not None:
            await self.job.stop()
            jobs.forget(self.job)
            self.job = None
        if self.directory is not None:
            self.directory.cleanup()
            self.directory = None

    async def request(self, payload):
        if self.host is not None:
            if self.target:
                payload = {**payload, "_fff_target": self.target}
            result = await self.host("files.fff", payload)
            self.worker_pid = result.pop("workerPid", None)
            return result
        async with self.lock:
            try:
                return await asyncio.wait_for(self._request(payload), SEARCH_TIMEOUT)
            except (OSError, asyncio.TimeoutError, asyncio.CancelledError):
                await self._close()
                raise

    async def _request(self, payload):
        if self.job is not None and (
            self.job.exit_code is not None
            or self.job.timed_out
            or self.job.termination is not None
        ):
            detail = self.job.tail(2000)
            await self._close()
            raise RuntimeError(f"FFF worker died: {detail}")
        if self.job is None:
            command = os.environ.get("ALBEDO_FFF_COMMAND")
            argv = shlex.split(command) if command else []
            if not command and (executable := shutil.which("albedo-fff")):
                argv = [executable]
            if not argv or not argv[0]:
                raise RuntimeError(
                    "FFF runtime missing on this host: install albedo-fff or set ALBEDO_FFF_COMMAND"
                )
            self.directory = tempfile.TemporaryDirectory(prefix="albedo-fff-")
            self.socket = str(Path(self.directory.name) / "rpc.sock")
            self.secret = secrets.token_hex(32)
            self.job = jobs.start(
                [*argv, self.socket, self.secret], 86400, traced=False, service=True
            )
            while not (
                Path(self.socket).exists() and "FFF_READY" in self.job.tail(2000)
            ):
                if self.job.exit_code is not None or self.job.task.done():
                    detail = self.job.tail(2000)
                    await self._close()
                    raise RuntimeError(f"FFF worker failed to start: {detail}")
                await asyncio.sleep(0.01)
        reader, writer = await asyncio.open_unix_connection(
            self.socket, limit=16 * 1024 * 1024
        )
        try:
            writer.write(
                (
                    json.dumps({**payload, "secret": self.secret, "protocol": 1}) + "\n"
                ).encode()
            )
            await writer.drain()
            try:
                reply = await reader.readline()
                if not reply:
                    raise OSError("FFF worker closed its connection")
                result = json.loads(reply)
            except ValueError as error:
                raise OSError(
                    f"FFF invalid or oversized protocol response: {error}"
                ) from error
            if result.get("protocol") != 1:
                raise OSError(
                    "FFF protocol mismatch: install matching albedo-fff on this host"
                )
            if not result["ok"]:
                raise ValueError(result["error"])
            return result["value"]
        finally:
            writer.close()
            await writer.wait_closed()


_fff = _FFF()


def _path_regex(pattern):
    """Segment-aware root-relative globs; ** crosses directory boundaries."""
    rooted = "/" in pattern
    pattern = pattern.removeprefix("./")
    if pattern.startswith("/"):
        pattern = pattern[1:]
    prefix = "" if rooted else "(?:.*/)?"
    parts = pattern.split("/")
    body = ""
    for i, part in enumerate(parts):
        if part == "**":
            body += "(?:[^/]+/)*" if i < len(parts) - 1 else ".*"
        else:
            j = 0
            while j < len(part):
                char = part[j]
                if char == "*":
                    body += "[^/]*"
                elif char == "?":
                    body += "[^/]"
                elif char == "[":
                    end = part.find("]", j + 1)
                    if end < 0:
                        raise ValueError("unclosed glob character class")
                    value = part[j + 1 : end]
                    body += (
                        "["
                        + ("^" + value[1:] if value.startswith("!") else value)
                        + "]"
                    )
                    j = end
                elif char in "{}\\":
                    raise ValueError(
                        "FFF compatibility glob supports *, ?, [], **; braces and escapes are unsupported"
                    )
                else:
                    body += re.escape(char)
                j += 1
            if i < len(parts) - 1:
                body += "/"
    return "^" + prefix + body + "$"


def _fff_scope(target, glob, hidden, limit):
    if hidden:
        raise ValueError(
            "hidden=True is unsupported by FFF 0.11: its index excludes hidden files"
        )
    if not 1 <= limit <= 10000:
        raise ValueError("1 <= max_results <= 10000")
    globs = _globs(glob)
    native_glob = None
    if len(globs) == 1 and re.fullmatch(r"[A-Za-z0-9_./ -]+", globs[0]):
        exact = globs[0].removeprefix("./").removeprefix("/")
        native_glob = exact if "/" in globs[0] else "**/" + exact
    file_glob = (
        target.name
        if target.is_file() and re.fullmatch(r"[A-Za-z0-9_. -]+", target.name)
        else None
    )
    return {
        "root": str((target.parent if target.is_file() else target).resolve()),
        "file": target.name if target.is_file() else None,
        "hidden": hidden,
        "limit": limit,
        "nativeGlob": native_glob,
        "fileGlob": file_glob,
        "filters": [
            {
                "regex": _path_regex(g[1:] if g.startswith("!") else g),
                "include": not g.startswith("!"),
            }
            for g in globs
        ],
    }


def _numbered(number: int, lines: Sequence[str]) -> str:
    text = lines[number - 1] if 0 < number <= len(lines) else ""
    return f"{number:>6} | {text[:LINE_WIDTH]}"


class _ReadWindow:
    """Track selected lines, the current line, and the first rejected row."""

    def __init__(self, start_line: int, last_line: int | None, max_chars: int):
        self.start_line = start_line
        self.last_line = last_line
        self.max_chars = max_chars
        self.lines: list[str] = []
        self.used_chars = 0
        self.stopped_line: int | None = None
        self.stopped_row_chars = 0
        self.number = 1
        self.line_chars = 0
        self.fragments: list[str] = []

    def wants_line(self) -> bool:
        return (
            self.stopped_line is None
            and self.number >= self.start_line
            and (self.last_line is None or self.number <= self.last_line)
        )

    def extend(self, text: str, start: int, end: int) -> None:
        self.line_chars += end - start
        if self.wants_line():
            row_chars = max(6, len(str(self.number))) + 3 + self.line_chars
            if self.used_chars + row_chars + 1 <= self.max_chars:
                if start < end:
                    self.fragments.append(text[start:end])
            else:
                # Keep counting a giant line, but release its retained prefix.
                self.fragments.clear()

    def finish_line(self) -> None:
        if self.wants_line():
            row_chars = max(6, len(str(self.number))) + 3 + self.line_chars
            if self.used_chars + row_chars + 1 > self.max_chars:
                self.stopped_line = self.number
                self.stopped_row_chars = row_chars
            else:
                self.lines.append("".join(self.fragments))
                self.used_chars += row_chars + 1
        self.number += 1
        self.line_chars = 0
        self.fragments.clear()


def _scan_read(
    source: BufferedReader, window: _ReadWindow, end_line: int | None
) -> int:
    chunk = source.read(READ_CHUNK_BYTES)
    at_eof = len(chunk) < READ_CHUNK_BYTES or not source.peek(1)
    text = chunk.decode("utf-8", errors="replace") if at_eof else ""
    # Native splitting is cheap for a bounded ASCII file. Unicode uses spans
    # instead, so dense replacement characters never build a list of substrings.
    if at_eof and text.isascii():
        lines = text.splitlines()
        total = len(lines)
        last = total if window.last_line is None else min(total, window.last_line)
        window.lines = lines[window.start_line - 1 : last]
        return total

    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    if not at_eof:
        text = decoder.decode(chunk)
    skip_lf = False
    while True:
        if skip_lf and text.startswith("\n"):
            text = text[1:]
        separator_count = 0
        if any(separator in text for separator in LINE_SEPARATORS):
            separator_count = sum(
                text.count(separator) for separator in LINE_SEPARATORS
            )
            separator_count -= text.count("\r\n")
        window_complete = window.stopped_line is not None or (
            window.last_line is not None and window.number > window.last_line
        )
        if not separator_count:
            window.extend(text, 0, len(text))
        elif window_complete or window.number + separator_count < window.start_line:
            window.number += separator_count
            if end_line is not None and window.number > end_line:
                return end_line
            # Skipped lines need only an unfinished-line flag for EOF.
            # A requested line begins after a separator resets this state.
            window.line_chars = int(text[-1] not in LINE_SEPARATORS)
        else:
            position = 0
            for boundary in LINE_BOUNDARIES.finditer(text):
                window.extend(text, position, boundary.start())
                window.finish_line()
                if end_line is not None and window.number > end_line:
                    return end_line
                position = boundary.end()
            window.extend(text, position, len(text))
        skip_lf = text.endswith("\r")
        if at_eof:
            if window.line_chars:
                window.finish_line()
            return window.number - 1
        chunk = source.read(READ_CHUNK_BYTES)
        at_eof = not chunk
        text = decoder.decode(chunk, final=at_eof)


class Files:
    """Workspace file access with the diagnostics an exact edit needs."""

    def read(
        self,
        path: str,
        start_line: int = 1,
        end_line: int | None = None,
        *,
        limit: int | None = None,
        max_chars: int = READ_LIMIT,
    ) -> Text:
        """Numbered lines from start_line through end_line, at most `limit` lines.

        `limit` counts lines. `max_chars` is a separate character budget (at
        most 200000) that keeps a huge window from flooding the context; when it
        stops a read early, the result says so and names the line to resume
        from. Lines are never shortened. The numbers are what `edit(line_hint=)`
        takes.
        """
        if (
            start_line < 1
            or (end_line is not None and end_line < start_line)
            or (limit is not None and limit < 1)
            or not 0 < max_chars <= 200_000
        ):
            raise ValueError(
                "start_line >= 1, end_line >= start_line, limit >= 1 line, "
                "0 < max_chars <= 200000"
            )
        target = Path(path).expanduser()
        if not target.is_file():
            if target.is_dir():
                raise IsADirectoryError(
                    f"{path} is a directory; files.ls({path!r}) lists it"
                )
            raise FileNotFoundError(_missing(target, path))
        last = end_line
        if limit is not None:
            limited_last = start_line + limit - 1
            last = limited_last if last is None else min(last, limited_last)
        window = _ReadWindow(start_line, last, max_chars)
        with target.open("rb") as source:
            total = _scan_read(source, window, end_line)
        if start_line > total:
            return Text(f"[{path} has {total} lines; nothing at line {start_line}]")
        requested = total if end_line is None else min(end_line, total)
        last = requested if last is None else min(last, requested)
        body, used = window.lines, 0
        number = window.stopped_line
        row_chars = window.stopped_row_chars
        for current, text in enumerate(body, start_line):
            row = f"{current:>6} | {text}"
            if used + len(row) + 1 > max_chars:
                number, row_chars = current, len(row)
                del body[current - start_line :]
                break
            used += len(row) + 1
            body[current - start_line] = row
        if number is not None:
            if not body:
                retry = (
                    f"read it alone with start_line={number}, end_line={number}, max_chars={row_chars + 1}"
                    if row_chars + 1 <= 200_000
                    else "it exceeds the 200000-character maximum"
                )
                body.append(
                    f"[line {number} is {row_chars} characters with its number, over "
                    f"max_chars={max_chars}; {retry}]"
                )
            else:
                body.append(
                    f"[stopped at max_chars={max_chars} characters; lines {number}-{last} "
                    f"not shown; read again with start_line={number}, or raise max_chars]"
                )
        elif last < requested:
            body.append(
                f"[limit={limit} lines reached; {requested - last} more through line "
                f"{requested}; read again with start_line={last + 1}]"
            )
        result = "\n".join(body)
        # Release numbered rows before Text copies the joined Unicode buffer.
        body.clear()
        return Text(result)

    def ls(
        self, path: str = ".", pattern: str | None = None, *, hidden: bool = False
    ) -> Rows:
        """One directory, directories suffixed with `/`."""
        directory = Path(path).expanduser()
        entries = []
        for entry in sorted(directory.iterdir(), key=lambda item: item.name):
            if not hidden and entry.name.startswith("."):
                continue
            if pattern and not fnmatch.fnmatch(entry.name, pattern):
                continue
            entries.append(entry.name + ("/" if entry.is_dir() else ""))
        return Rows(entries)

    def find(
        self,
        pattern: str,
        path: str | Sequence[str] = ".",
        *,
        glob: str | Sequence[str] | None = None,
        context: int = 0,
        max_results: int = 50,
        literal: bool = False,
        case_sensitive: bool | None = None,
        hidden: bool = False,
        ignored: bool = False,
    ) -> Search[Rows]:
        """Content search through the native FFF index, with a rescan barrier.
        `path` may be one path or a list; `context=N` adds N lines around each
        match. A missing path raises. Ignore files and hidden files are skipped
        always; hidden=True and ignored=True are unsupported and raise. An empty result says what was
        searched and skipped. Await it: `await files.find(pattern)`."""
        if not 0 <= context <= 50:
            raise ValueError("0 <= context <= 50")
        return Search(
            "files.find",
            lambda: albedo_trace.noted(
                "search",
                pattern,
                self._find(
                    pattern,
                    path,
                    glob,
                    context,
                    max_results,
                    literal,
                    case_sensitive,
                    hidden,
                    ignored,
                ),
            ),
        )

    async def _find(
        self,
        pattern: str,
        path: str | Sequence[str],
        glob: str | Sequence[str] | None,
        context: int,
        max_results: int,
        literal: bool,
        case_sensitive: bool | None,
        hidden: bool,
        ignored: bool,
    ) -> Rows:
        if ignored:
            raise ValueError(
                "ignored=True is unsupported by FFF 0.11: its index excludes ignored files"
            )
        if "\n" in pattern or "\r" in pattern:
            raise ValueError("FFF line search does not support multiline patterns")
        # Escape query-parser constraints as hex in regex mode, not plain mode.
        query = re.escape(pattern) if literal else pattern
        for char in " \t\v\f":
            query = query.replace("\\" + char, char).replace(
                char, rf"\x{ord(char):02x}"
            )
        query = query.replace("/", r"\x2f").replace('"', r"\x22").replace("'", r"\x27")
        if (max_results + 1) * (context * 2 + 1) * LINE_WIDTH * 4 > 4 * 1024 * 1024:
            raise ValueError(
                "FFF result exceeds 4 MiB bound; reduce max_results or context"
            )
        if case_sensitive is False:
            query = "(?i)" + query
        targets = _targets(path)
        _require_roots(targets)
        found = []
        total = searched = 0
        for target in targets:
            result = await _fff.request(
                {
                    **_fff_scope(target, glob, hidden, max_results),
                    "op": "find",
                    "query": query,
                    "context": context,
                }
            )
            searched += result["searched"]
            total += result["total"]
            for item in result["items"]:
                if len(found) < max_results:
                    found.append((target, item))
        lines = {}
        for target, item in found:
            name = str(
                target if target.is_file() else target / item["relativePath"]
            ).removeprefix("./")
            number = item["lineNumber"]
            for n, text in enumerate(
                item.get("contextBefore", []),
                number - len(item.get("contextBefore", [])),
            ):
                lines.setdefault(
                    (name, n), Match(name, n, text[: LINE_WIDTH * 4], True)
                )
            lines[(name, number)] = Match(
                name, number, item["lineContent"][: LINE_WIDTH * 4]
            )
            for n, text in enumerate(item.get("contextAfter", []), number + 1):
                lines.setdefault(
                    (name, n), Match(name, n, text[: LINE_WIDTH * 4], True)
                )
        skipped = ["FFF ignore rules", "binary files", "files above 1 GiB"]
        if not hidden:
            skipped.append("hidden files")
        return Rows(
            sorted(lines.values(), key=lambda m: (m.path, m.line)),
            truncated=total > max_results,
            note=_empty_note(pattern, targets, searched, skipped, glob, [])
            if not lines
            else "",
        )

    def paths(
        self,
        pattern: str | None = None,
        path: str | Sequence[str] = ".",
        *,
        glob: str | Sequence[str] | None = None,
        max_results: int = 100,
        hidden: bool = False,
    ) -> Search[Rows]:
        """File names, not contents; enumerated by the native FFF index. A pattern
        with *, ? or [ is a glob over names, or over the path from the search
        root when it has a /; other text uses ranked fuzzy filename matching.
        `path` may be one path or a list. Await it: `await files.paths(pattern)`."""
        return Search(
            "files.paths", lambda: self._paths(pattern, path, glob, max_results, hidden)
        )

    async def _paths(
        self,
        pattern: str | None,
        path: str | Sequence[str],
        glob: str | Sequence[str] | None,
        max_results: int,
        hidden: bool,
    ) -> Rows:
        mode = "fuzzy" if pattern and not any(c in pattern for c in "*?[") else "paths"
        return await self._names(mode, pattern, path, glob, max_results, hidden)

    async def _names(self, op, pattern, path, glob, max_results, hidden):
        targets = _targets(path)
        _require_roots(targets)
        rows = []
        total = 0
        for target in targets:
            name = None
            base = False
            if op == "paths" and pattern:
                base = "/" not in pattern and any(c in pattern for c in "*?[")
                name = (
                    _path_regex(pattern)
                    if any(c in pattern for c in "*?[")
                    else re.escape(pattern)
                )
            result = await _fff.request(
                {
                    **_fff_scope(target, glob, hidden, max_results),
                    "op": op,
                    "query": pattern or "",
                    "name": name,
                    "nameBase": base,
                }
            )
            total += result["total"]
            rows.extend(
                str(
                    target if target.is_file() else target / item["relativePath"]
                ).removeprefix("./")
                for item in result["items"]
            )
        return Rows(rows[:max_results], truncated=total > max_results)

    async def close(self):
        """Destroy FFF indexes and stop the supervised worker."""
        await _fff.close()

    @hook.reported(
        "files.edit",
        {"path": "file_path", "old_str": "old_string", "new_str": "new_string"},
    )
    def edit(
        self, path: str, old_str: str, new_str: str, line_hint: int | None = None
    ) -> Text:
        """Replace one exact, unique string. A miss reports what is actually there."""
        if not old_str:
            raise ValueError("old_str must be non-empty")
        if line_hint is not None and (
            isinstance(line_hint, bool) or not isinstance(line_hint, int)
        ):
            raise ValueError(
                f"line_hint must be a line number, not {type(line_hint).__name__}"
            )
        target = Path(path).expanduser()
        if not target.exists():
            raise FileNotFoundError(_missing(target, path))
        target = target.resolve()
        snapshot = _snapshot(target)
        content = snapshot[0].decode("utf-8")
        found = _occurrences(content, old_str)
        if not found:
            closest = _closest(content, old_str)
            raise ValueError(
                f"string not found in {path}"
                + (
                    "; the text is there, but whitespace differs (indentation, "
                    "tabs, trailing spaces or line endings)"
                    if _words(old_str) in _words(content) and _words(old_str)
                    else ""
                )
                + (f"\n{closest}" if closest else "")
            )
        chosen = _choose(content, old_str, found, line_hint, path)
        replacement = (
            content[: chosen.index] + new_str + content[chosen.index + len(old_str) :]
        ).encode("utf-8")
        _replace(target, snapshot, replacement)
        _record_edit(Path(path).expanduser())
        return Text(f"Edited {target}")

    @hook.reported("files.write", {"path": "file_path", "content": "content"})
    def write(self, path: str, content: str) -> Text:
        """Create or replace a whole file. Use `edit` to change part of one."""
        target = Path(path).expanduser()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        _record_edit(target)
        return Text(f"Wrote {target.resolve()} ({len(content.encode())} bytes)")


def _require_roots(targets: list[Path]) -> None:
    for target in targets:
        if not target.exists():
            raise FileNotFoundError(_missing(target, str(target)))


def _empty_note(
    pattern: str,
    targets: list[Path],
    searched: int,
    skipped: list[str],
    glob: str | Sequence[str] | None,
    withheld: list[str],
) -> str:
    """Why a search came back empty: where it looked, what it left out, and
    which skipped files would have matched."""
    roots = ", ".join(str(target.resolve()) for target in targets)
    left_out = [*skipped, *([f"files outside glob {_globs(glob)}"] if glob else [])]
    note = f"no matches for {pattern!r} in {roots}: {searched} files searched"
    if left_out:
        note += f"; skipped {', '.join(left_out)}"
    if withheld:
        note += (
            f"; it matches in skipped files ({', '.join(withheld)}): "
            "rerun with hidden=True and/or ignored=True"
        )
    return note


def _targets(path: str | Sequence[str]) -> list[Path]:
    return [
        Path(item).expanduser() for item in ([path] if isinstance(path, str) else path)
    ]


def _globs(glob: str | Sequence[str] | None) -> list[str]:
    return [glob] if isinstance(glob, str) else list(glob or [])


def _snapshot(target: Path) -> tuple[bytes, tuple[int, int, int, int, int]]:
    """Bytes plus identity: an edit refuses to publish over a concurrent change."""
    for _ in range(3):
        before = target.stat()
        data = target.read_bytes()
        after = target.stat()
        identity = (
            after.st_dev,
            after.st_ino,
            stat.S_IMODE(after.st_mode),
            after.st_size,
            after.st_mtime_ns,
        )
        if identity == (
            before.st_dev,
            before.st_ino,
            stat.S_IMODE(before.st_mode),
            before.st_size,
            before.st_mtime_ns,
        ):
            return data, identity
    raise ValueError(f"file changed while reading {target}; refusing to edit it")


def _replace(
    target: Path,
    snapshot: tuple[bytes, tuple[int, int, int, int, int]],
    replacement: bytes,
) -> None:
    descriptor, name = tempfile.mkstemp(
        dir=target.parent, prefix=f".{target.name}.", suffix=".tmp"
    )
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), snapshot[1][2])
            stream.write(replacement)
            stream.flush()
            os.fsync(stream.fileno())
        if _snapshot(target) != snapshot:
            raise ValueError(
                f"file changed while editing {target}; refusing to overwrite concurrent changes"
            )
        os.replace(temporary, target)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


@dataclass(frozen=True)
class _Occurrence:
    index: int
    start_line: int
    end_line: int

    @property
    def label(self) -> str:
        return (
            str(self.start_line)
            if self.start_line == self.end_line
            else f"{self.start_line}-{self.end_line}"
        )


def _occurrences(content: str, needle: str) -> list[_Occurrence]:
    found, span, start = [], needle.count("\n") + 1, 0
    while True:
        index = content.find(needle, start)
        if index < 0:
            return found
        first = content.count("\n", 0, index) + 1
        found.append(_Occurrence(index, first, first + span - 1))
        start = index + len(needle)


def _choose(
    content: str,
    old_str: str,
    found: list[_Occurrence],
    line_hint: int | None,
    path: str,
) -> _Occurrence:
    if len(found) == 1:
        return found[0]
    listed = ", ".join(one.label for one in found[:LISTED]) + (
        f", ... ({len(found)} total)" if len(found) > LISTED else ""
    )
    if line_hint is None:
        raise ValueError(
            f"found {len(found)} occurrences in {path}: lines {listed}. Nothing was changed. "
            "Retry with line_hint=<a line inside the range you want>, or widen old_str until it is unique.\n"
            + _candidates(content, found)
        )
    inside = next(
        (one for one in found if one.start_line <= line_hint <= one.end_line), None
    )
    if inside is None:
        raise ValueError(
            f"line_hint={line_hint} is inside none of the {len(found)} occurrences in {path}: lines {listed}. "
            f"Nothing was changed.\n{_candidates(content, found)}"
        )
    return inside


def _candidates(content: str, found: list[_Occurrence]) -> str:
    lines = content.splitlines()
    blocks = []
    for position, occurrence in enumerate(found[:CANDIDATES], 1):
        matched = occurrence.end_line - occurrence.start_line + 1
        preview = min(matched, PREVIEW_LINES)
        first = max(1, occurrence.start_line - CONTEXT)
        last = min(len(lines), occurrence.end_line + CONTEXT)
        body = [
            _numbered(number, lines) for number in range(first, occurrence.start_line)
        ]
        body += [
            _numbered(number, lines)
            for number in range(occurrence.start_line, occurrence.start_line + preview)
        ]
        if matched > preview:
            body.append(f"{'...':>6} | ({matched - preview} further matching lines)")
        body += [
            _numbered(number, lines)
            for number in range(occurrence.end_line + 1, last + 1)
        ]
        blocks.append(
            f"candidate {position} of {len(found)}: lines {occurrence.label}\n"
            + "\n".join(body)
        )
    if len(found) > CANDIDATES:
        blocks.append(f"... {len(found) - CANDIDATES} further occurrences not shown")
    return "\n\n".join(blocks)


def _words(text: str) -> str:
    """text with every run of whitespace as one space, to see a whitespace-only miss."""
    return " ".join(text.split())


def _closest(content: str, needle: str) -> str:
    lines, needle_lines = content.splitlines(), needle.splitlines()
    head = next((line.strip() for line in needle_lines if line.strip()), "")
    if not lines or not head:
        return ""
    ranked = sorted(
        (
            (
                difflib.SequenceMatcher(
                    None, head, line.strip(), autojunk=False
                ).ratio(),
                index,
            )
            for index, line in enumerate(lines)
            if line.strip()
        ),
        reverse=True,
    )[:12]
    width = max(1, len(needle_lines))
    scored = []
    for _, start in ranked:
        end = min(len(lines), start + width)
        current = "\n".join(lines[start:end]).strip()
        scored.append(
            (
                difflib.SequenceMatcher(
                    None, needle.strip(), current, autojunk=False
                ).ratio(),
                start,
                end,
            )
        )
    blocks = []
    for score, start, end in sorted(scored, reverse=True):
        if score < 0.25:
            continue
        body = "\n".join(_numbered(number + 1, lines) for number in range(start, end))
        blocks.append(
            f"closest candidate lines {start + 1}-{end} (similarity {score:.0%}):\n{body}"
        )
        if len(blocks) == 3:
            break
    return "\n\n".join(blocks)


def _missing(target: Path, original: str) -> str:
    message = f"{original} not found (cwd: {Path.cwd()})"
    parent = target.parent
    if not parent.is_dir():
        return message
    close = difflib.get_close_matches(
        target.name, [entry.name for entry in parent.iterdir()], n=3, cutoff=0.35
    )
    return message + (
        f"; nearby paths: {', '.join(str(parent / name) for name in close)}"
        if close
        else ""
    )


def setup(api: PythonApi) -> dict[str, object]:
    global _fff
    _fff = _FFF(api.host)
    api.on_shutdown(_fff.close)
    return {"files": Files()}
