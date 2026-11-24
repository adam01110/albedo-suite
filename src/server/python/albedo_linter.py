"""Read-only linting of tracked workspace files for explicit files.check() batches."""

from __future__ import annotations

import asyncio
import json
import os
import re
import signal
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlparse

MAX_FILES = 1024
MAX_OUTPUT = 4 * 1024 * 1024
MAX_FINDINGS = 200
MAX_ERROR = 16384
CONCURRENCY = 4
BATCH_SECONDS = 45
DEFAULT_ROOT_MARKERS = (".git", ".jj")
STDIN_NAMES = {"-", "stdin", "<stdin>", "/dev/stdin"}
GROUPS = {
    "path",
    "line",
    "column",
    "endLine",
    "endColumn",
    "severity",
    "code",
    "message",
}
SEVERITIES = {
    "e": "error",
    "err": "error",
    "error": "error",
    "fatal": "error",
    "w": "warning",
    "warn": "warning",
    "warning": "warning",
    "i": "info",
    "info": "info",
    "information": "info",
    "note": "info",
    "h": "hint",
    "hint": "hint",
    "none": "hint",
    "style": "hint",
}


@dataclass(frozen=True)
class Linter:
    name: str
    command: tuple[str, ...]
    format: str
    pattern: re.Pattern[str] | None
    stdin: bool
    ignore_exit_code: bool
    root_markers: tuple[str, ...]


_root: Path | None = None
_linters: dict[str, Linter] = {}
_chains: dict[str, tuple[str, ...]] = {}
_timeout = 30.0
_pending: dict[Path, int] = {}
_generation = 0
_overflow = False
_lock: asyncio.Lock | None = None


def _strings(value: object, what: str, *, empty: bool = False) -> tuple[str, ...]:
    if (
        not isinstance(value, list)
        or (not value and not empty)
        or not all(isinstance(x, str) and x and "\x00" not in x for x in value)
    ):
        raise ValueError(
            f"{what} must be a {'' if empty else 'nonempty '}list of strings"
        )
    return tuple(value)


def _linter(name: str, value: object) -> Linter:
    if not isinstance(value, dict):
        raise ValueError(f"linter {name} must be an object")
    unknown = set(value) - {
        "command",
        "format",
        "pattern",
        "stdin",
        "ignoreExitCode",
        "rootMarkers",
    }
    if unknown:
        raise ValueError(f"linter {name} has unknown keys: {sorted(unknown)}")
    kind = value.get("format", "regex")
    pattern = None
    if kind == "regex":
        raw = value.get("pattern")
        if not isinstance(raw, str):
            raise ValueError(f"linter {name} needs a pattern for regex output")
        try:
            pattern = re.compile(raw, re.MULTILINE)
        except re.error as error:
            raise ValueError(f"linter {name} pattern is invalid: {error}") from None
        groups = set(pattern.groupindex)
        if not {"line", "message"} <= groups or groups - GROUPS:
            raise ValueError(
                f"linter {name} pattern needs line and message groups and may only name {sorted(GROUPS)}"
            )
    elif kind != "sarif":
        raise ValueError(f"linter {name} format must be regex or sarif")
    flags = {key: value.get(key, False) for key in ("stdin", "ignoreExitCode")}
    if not all(isinstance(flag, bool) for flag in flags.values()):
        raise ValueError(f"linter {name} stdin and ignoreExitCode must be booleans")
    return Linter(
        name,
        _strings(value.get("command"), f"linter {name} command"),
        kind,
        pattern,
        flags["stdin"],
        flags["ignoreExitCode"],
        _strings(
            value.get("rootMarkers", list(DEFAULT_ROOT_MARKERS)),
            f"linter {name} rootMarkers",
            empty=True,
        ),
    )


def configure(config: dict, workspace: str | None = None) -> None:
    """Validate linter declarations and enable local tracking."""
    global _root, _linters, _chains, _timeout, _generation, _overflow, _lock
    timeout = config.get("timeoutMs", 30000)
    if (
        isinstance(timeout, bool)
        or not isinstance(timeout, int)
        or not 0 < timeout <= 45000
    ):
        raise ValueError("linter timeoutMs must be in 1..45000")
    linters = config.get("linters", {})
    chains = config.get("chains", {})
    if not isinstance(linters, dict) or not isinstance(chains, dict):
        raise ValueError("linter linters and chains must be objects")
    parsed = {name: _linter(name, value) for name, value in linters.items()}
    parsed_chains = {}
    for key, names in chains.items():
        names = _strings(names, f"linter chain {key}", empty=True)
        missing = [name for name in names if name not in parsed]
        if missing:
            raise ValueError(f"linter chain {key} refers to unknown linters: {missing}")
        parsed_chains[key] = names
    _root = Path(workspace or os.getcwd()).resolve(strict=True)
    _linters, _chains, _timeout = parsed, parsed_chains, timeout / 1000
    _pending.clear()
    _generation = 0
    _overflow = False
    _lock = asyncio.Lock()


def workspace() -> Path | None:
    return _root


def pending_paths() -> tuple[Path, ...]:
    return tuple(_pending)


def pending_versions() -> dict[Path, int]:
    return dict(_pending)


def record(path: str | Path) -> None:
    """Queue an edit without running anything."""
    global _generation, _overflow
    if _root is None:
        return
    target = Path(os.path.abspath(Path(path).expanduser()))
    if not target.is_relative_to(_root):
        return
    resolved = target.resolve()
    # Keep workspace escapes visible to the batch validator.
    if resolved.is_relative_to(_root):
        target = resolved
    if target not in _pending and len(_pending) >= MAX_FILES:
        _overflow = True
        return
    _generation += 1
    _pending[target] = _generation


def chain(path: Path) -> tuple[Linter, ...]:
    """Linters for an exact file name (such as Dockerfile) then its suffix."""
    names = dict.fromkeys(
        [
            *_chains.get(path.name, ()),
            *(_chains.get(path.suffix, ()) if path.suffix else ()),
        ]
    )
    return tuple(_linters[name] for name in names)


def _cwd(path: Path, markers: tuple[str, ...]) -> Path:
    assert _root is not None
    directory = path.parent
    while directory.is_relative_to(_root):
        if any((directory / marker).exists() for marker in markers):
            return directory
        if directory == _root:
            break
        directory = directory.parent
    return _root


def _identity(path: Path) -> tuple[int, ...]:
    info = path.stat()
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


async def _run(linter: Linter, path: Path, cwd: Path) -> tuple[int, str, str, bool]:
    """Bounded capture; cancellation and timeouts kill the whole process group."""
    data = path.read_bytes() if linter.stdin else None
    spawn = asyncio.create_task(
        asyncio.create_subprocess_exec(
            *linter.command,
            *(() if linter.stdin else (str(path),)),
            cwd=cwd,
            stdin=asyncio.subprocess.PIPE
            if linter.stdin
            else asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
    )
    try:
        process = await asyncio.shield(spawn)
    except asyncio.CancelledError:
        process = await spawn
        _kill(process)
        await process.communicate()
        raise
    truncated = False

    async def drain(stream) -> bytes:
        nonlocal truncated
        output = bytearray()
        while chunk := await stream.read(65536):
            room = MAX_OUTPUT - len(output)
            truncated |= len(chunk) > room
            output.extend(chunk[: max(0, room)])
        return bytes(output)

    async def feed():
        if process.stdin is None:
            return
        try:
            process.stdin.write(data or b"")
            await process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            process.stdin.close()

    try:
        async with asyncio.timeout(_timeout):
            stdout, stderr, _ = await asyncio.gather(
                drain(process.stdout), drain(process.stderr), feed()
            )
            code = await process.wait()
    except BaseException:
        _kill(process)
        await process.wait()
        raise
    return (
        code,
        stdout.decode(errors="replace"),
        stderr.decode(errors="replace"),
        truncated,
    )


def _kill(process) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _int(value: object) -> int | None:
    try:
        number = int(str(value))
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def _finding(linter: Linter, path: Path, cwd: Path, reported, **fields) -> dict | None:
    """Attribute a finding to the target, dropping findings about other files."""
    assert _root is not None
    if reported and reported not in STDIN_NAMES:
        location = Path(reported)
        if not location.is_absolute():
            location = cwd / location
        if Path(os.path.realpath(location)) != path:
            return None
    line = _int(fields.get("line"))
    message = str(fields.get("message") or "").strip()
    if line is None or not message:
        return None
    severity = str(fields.get("severity") or "warning").strip().lower()
    finding = {
        "path": path.relative_to(_root).as_posix(),
        "line": line,
        "column": _int(fields.get("column")),
        "endLine": _int(fields.get("endLine")),
        "endColumn": _int(fields.get("endColumn")),
        "severity": SEVERITIES.get(severity, severity),
        "code": str(fields["code"]) if fields.get("code") else None,
        "message": message[:2000],
        "source": linter.name,
    }
    return {key: value for key, value in finding.items() if value is not None}


def _sarif_path(uri: object) -> str | None:
    if not isinstance(uri, str) or not uri:
        return None
    parsed = urlparse(uri)
    return unquote(parsed.path if parsed.scheme == "file" else uri)


def parse(
    linter: Linter, path: Path, cwd: Path, stdout: str, stderr: str
) -> tuple[int, list[dict]]:
    """Return the raw result count and the findings that describe `path`."""
    raw = 0
    findings = []
    if linter.format == "regex":
        assert linter.pattern is not None
        for match in linter.pattern.finditer(stdout + "\n" + stderr):
            raw += 1
            groups = match.groupdict()
            finding = _finding(linter, path, cwd, groups.pop("path", None), **groups)
            if finding is not None:
                findings.append(finding)
        return raw, findings
    if not stdout.strip():
        return 0, []
    document = json.loads(stdout)
    for run in document.get("runs") or []:
        for result in run.get("results") or []:
            raw += 1
            location = ((result.get("locations") or [{}])[0] or {}).get(
                "physicalLocation"
            ) or {}
            region = location.get("region") or {}
            message = result.get("message") or {}
            finding = _finding(
                linter,
                path,
                cwd,
                _sarif_path((location.get("artifactLocation") or {}).get("uri")),
                line=region.get("startLine"),
                column=region.get("startColumn"),
                endLine=region.get("endLine"),
                endColumn=region.get("endColumn"),
                severity=result.get("level") or "warning",
                code=result.get("ruleId"),
                message=message.get("text") or message.get("markdown"),
            )
            if finding is not None:
                findings.append(finding)
    return raw, findings


async def lint(linter: Linter, path: Path) -> list[dict]:
    """Run one linter on one file; errors are failures, findings are results."""
    cwd = _cwd(path, linter.root_markers)
    code, stdout, stderr, truncated = await _run(linter, path, cwd)
    if truncated:
        raise ValueError(f"{linter.name} output exceeds {MAX_OUTPUT} bytes")
    try:
        raw, findings = parse(linter, path, cwd, stdout, stderr)
    except (ValueError, AttributeError, TypeError) as error:
        raise ValueError(
            f"{linter.name} output is not valid {linter.format}: {error}"
        ) from None
    # Linters exit nonzero when they report findings; silence plus failure is an error.
    if code < 0 or (code and not raw and not linter.ignore_exit_code):
        output = (stderr.strip() or stdout.strip())[-2000:]
        raise ValueError(f"{linter.name} exited {code}: {output}")
    return findings


async def finish(paths: set[Path] | None = None, *, details: bool = False) -> dict:
    """Lint selected pending files; failed and changed files stay pending."""
    findings: list[dict] = []
    failures: list[dict] = []
    checked: list[str] = []
    unmatched: list[str] = []
    versions: dict[Path, int] = {}
    error = ""
    if _root is None or _lock is None:
        return {"ok": True, "error": "", "findings": []}
    async with _lock:
        try:
            async with asyncio.timeout(BATCH_SECONDS):
                if _overflow:
                    raise ValueError("linter tracking exceeds 1024 files")
                work = sorted(
                    (path, version)
                    for path, version in _pending.items()
                    if paths is None or path in paths
                )
                gate = asyncio.Semaphore(CONCURRENCY)

                async def one(linter, path):
                    async with gate:
                        try:
                            return await lint(linter, path)
                        except (OSError, ValueError, TimeoutError) as failure:
                            return failure

                for path, version in work:
                    linters = chain(path)
                    if not linters:
                        unmatched.append(str(path))
                        versions[path] = version
                        del _pending[path]
                        continue
                before = {path: _identity(path) for path, _ in work if path in _pending}
                jobs = [
                    (path, version, linter)
                    for path, version in work
                    if path in before
                    for linter in chain(path)
                ]
                outcomes = await asyncio.gather(
                    *(one(linter, path) for path, _, linter in jobs)
                )
                failed = set()
                for (path, _, linter), outcome in zip(jobs, outcomes):
                    if isinstance(outcome, BaseException):
                        failed.add(path)
                        failures.append(
                            {
                                "path": path.relative_to(_root).as_posix(),
                                "linter": linter.name,
                                "error": (str(outcome) or "linter timed out")[
                                    :MAX_ERROR
                                ],
                            }
                        )
                    else:
                        findings.extend(outcome)
                for path, version in work:
                    if path not in before:
                        continue
                    if _pending.get(path) != version or _identity(path) != before[path]:
                        failed.add(path)
                        failures.append(
                            {
                                "path": path.relative_to(_root).as_posix(),
                                "error": "file changed during linting",
                            }
                        )
                    if path in failed:
                        continue
                    checked.append(str(path))
                    versions[path] = version
                    del _pending[path]
        except (OSError, ValueError, TimeoutError) as failure:
            error = (str(failure) or "linting timed out")[:MAX_ERROR]
    if failures and not error:
        error = "; ".join(
            f"{item['path']}: {item.get('linter', 'linter')}: {item['error']}"
            for item in failures
        )[:MAX_ERROR]
    result = {
        "ok": not error,
        "error": error,
        "findings": findings[:MAX_FINDINGS],
        "truncated": len(findings) > MAX_FINDINGS,
    }
    if details:
        result.update(
            checked=checked, unmatched=unmatched, failures=failures, _versions=versions
        )
    return result
