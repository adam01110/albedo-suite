"""Private pre-final formatting gate; only successful files edits are tracked."""

from __future__ import annotations

import asyncio
import hashlib
import os
import re
from pathlib import Path
import signal
import stat
import sys
import tempfile
from dataclasses import dataclass

MAX_FILES = 1024
MAX_BYTES = 16 * 1024 * 1024
MAX_OUTPUT = 16 * 1024


@dataclass(frozen=True)
class Postimage:
    digest: bytes
    identity: tuple[int, ...]


_root: Path | None = None
_config: dict = {}
_pending: dict[Path, Postimage | str] = {}
_overflow = ""
_lock: asyncio.Lock | None = None


def configure(config: dict, workspace: str | None = None) -> None:
    """Enable local tracking without adding a model-visible binding."""
    global _root, _config, _lock, _overflow
    timeout = config.get("timeoutMs", 120000)
    if (
        isinstance(timeout, bool)
        or not isinstance(timeout, int)
        or not 0 < timeout <= 120000
    ):
        raise ValueError("formatter timeoutMs must be in 1..120000")
    _root = Path(workspace or os.getcwd()).resolve(strict=True)
    _config = config
    _pending.clear()
    _overflow = ""
    _lock = asyncio.Lock()


def _canonical(path: Path) -> Path:
    resolved = path.resolve(strict=True)
    if _root is None or not resolved.is_relative_to(_root):
        raise ValueError(f"formatter path outside workspace: {path}")
    return resolved


def _read(path: Path) -> tuple[bytes, Postimage]:
    if _canonical(path) != path:
        raise ValueError(f"formatter path changed or became a symlink: {path}")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_BYTES:
            raise ValueError(f"formatter requires regular file <=16MiB: {path}")
        data = stream.read(MAX_BYTES + 1)
        after = os.fstat(stream.fileno())

    def identity(info):
        return (
            info.st_dev,
            info.st_ino,
            info.st_mode,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
        )

    if (
        len(data) > MAX_BYTES
        or identity(before) != identity(after)
        or identity(after) != identity(path.stat())
    ):
        raise ValueError(f"formatter file changed while reading: {path}")
    return data, Postimage(hashlib.sha256(data).digest(), identity(after))


def record(path: str | Path) -> None:
    """Remember the postimage, not a command to run after each write."""
    global _overflow
    if _root is None:
        return
    target = Path(os.path.abspath(Path(path).expanduser()))
    if not target.is_relative_to(_root):
        return
    try:
        target = _canonical(target)
        if target not in _pending and len(_pending) >= MAX_FILES:
            _overflow = "formatter tracking exceeds 1024 files; finish pending files before further writes"
            return
        _pending[target] = _read(target)[1]
    except (OSError, ValueError) as error:
        if target in _pending or len(_pending) < MAX_FILES:
            _pending[target] = str(error)[:MAX_OUTPUT]
        else:
            _overflow = "formatter tracking exceeds 1024 files"


def _argv(value: object) -> list[str]:
    if (
        not isinstance(value, list)
        or not value
        or not all(isinstance(x, str) and x and "\x00" not in x for x in value)
    ):
        raise ValueError("formatter command must be a nonempty argv list")
    return value


def _commands(path: Path, staged: Path) -> list[tuple[list[str], Path]]:
    assert _root is not None
    directory = path.parent
    while True:
        for name in ("treefmt.toml", ".treefmt.toml"):
            config = directory / name
            if config.is_file():
                _canonical(config)
                command = _argv(_config.get("treefmt"))
                return [
                    (
                        command
                        + [
                            "--no-cache",
                            "--config-file",
                            str(config),
                            "--",
                            str(staged),
                        ],
                        directory,
                    )
                ]
        if (directory / "flake.nix").is_file():
            _canonical(directory / "flake.nix")
            command = _argv(_config.get("nix"))
            return [(command + ["fmt", "--", str(staged)], directory)]
        if directory == _root:
            break
        directory = directory.parent
    return _file_commands(path, staged)


def _file_commands(path: Path, staged: Path) -> list[tuple[list[str], Path]]:
    commands = []
    for name in _config.get("chains", {}).get(path.suffix, []):
        formatter = _config.get("formatters", {}).get(name)
        if not isinstance(formatter, dict):
            raise ValueError(f"formatter chain refers to unknown formatter: {name}")
        command = _argv(formatter.get("command"))
        commands.append((command + [str(staged)], path.parent))
    return commands


class MissingFormatter(ValueError):
    pass


def _missing_formatter(output: str) -> bool:
    # Match Nix's absent-attribute diagnostic, never build/evaluation failures.
    return (
        re.search(
            r"error: flake '[^\n]+' does not provide attribute "
            r"(?:'packages\.[^'.]+\.formatter', "
            r"'legacyPackages\.[^'.]+\.formatter' or )?'formatter\.[^']+'(?:\n|$)",
            output,
        )
        is not None
    )


async def _run(argv: list[str], cwd: Path, *, nix_fmt: bool = False) -> None:
    """Drain output in chunks; cancellation kills the complete process group."""
    spawn = asyncio.create_task(
        asyncio.create_subprocess_exec(
            *argv,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            start_new_session=True,
        )
    )
    try:
        process = await asyncio.shield(spawn)
    except asyncio.CancelledError:
        process = await spawn
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        # Do not capture potentially unbounded output while reaping a cancelled spawn.
        if process.stdout is not None:
            while await process.stdout.read(4096):
                pass
        await process.wait()
        raise
    output = bytearray()

    async def drain():
        assert process.stdout is not None
        while chunk := await process.stdout.read(4096):
            output.extend(chunk[: max(0, MAX_OUTPUT - len(output))])
        return await process.wait()

    task = asyncio.create_task(drain())
    try:
        code = await asyncio.wait_for(
            asyncio.shield(task), _config.get("timeoutMs", 120000) / 1000
        )
        if code:
            diagnostic = output.decode(errors="replace")
            if nix_fmt and _missing_formatter(diagnostic):
                raise MissingFormatter(diagnostic)
            raise ValueError(f"formatter exited {code}: {diagnostic}")
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await process.wait()
        await task
        raise


def _publish(path: Path, staged: Path, expected: Postimage) -> bool:
    data, _ = _read(staged)
    if _read(path)[1] != expected:
        raise ValueError(f"formatter refuses concurrent change: {path}")
    if hashlib.sha256(data).digest() == expected.digest:
        return False
    descriptor, name = tempfile.mkstemp(dir=path.parent, prefix=".albedo-publish-")
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), stat.S_IMODE(expected.identity[2]))
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if _read(path)[1] != expected:
            raise ValueError(f"formatter refuses concurrent change: {path}")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def _busy() -> bool:
    cells = sys.modules.get("albedo_cells")
    current = asyncio.current_task()
    if cells is not None and any(
        task is not current and not task.done()
        for task in getattr(cells, "CELL_TASKS", {}).values()
    ):
        return True
    jobs = sys.modules.get("albedo_plugins.run")
    return jobs is not None and any(
        not job.service and job.exit_code is None
        for job in getattr(jobs, "jobs", {}).values()
    )


async def finish() -> dict:
    """Format staged copies, revalidate postimages, then atomically publish."""
    changed = False
    if _root is None or _busy():
        return {"ok": True, "error": "", "changed": False}
    assert _lock is not None
    async with _lock:
        try:
            async with asyncio.timeout(
                min(_config.get("timeoutMs", 120000), 45000) / 1000
            ):
                if _overflow:
                    raise ValueError(_overflow)
                for path, expected in list(_pending.items()):
                    if isinstance(expected, str):
                        raise ValueError(expected)
                    original, current = _read(path)
                    if current != expected:
                        raise ValueError(f"formatter refuses concurrent change: {path}")
                    with tempfile.TemporaryDirectory(
                        dir=path.parent, prefix="albedo-format-"
                    ) as directory:
                        staged = Path(directory) / path.name
                        staged.write_bytes(original)
                        staged.chmod(stat.S_IMODE(expected.identity[2]))
                        commands = _commands(path, staged)
                        for argv, cwd in commands:
                            nix_fmt = argv == _config.get("nix", []) + [
                                "fmt",
                                "--",
                                str(staged),
                            ]
                            try:
                                await _run(argv, cwd, nix_fmt=nix_fmt)
                            except MissingFormatter:
                                # An absent flake formatter is not a formatter failure.
                                staged.write_bytes(original)
                                for fallback, fallback_cwd in _file_commands(
                                    path, staged
                                ):
                                    await _run(fallback, fallback_cwd)
                        # A write during the await must not be confused with this snapshot.
                        if _pending.get(path) != expected:
                            raise ValueError(
                                f"formatter file edited during gate: {path}"
                            )
                        if commands:
                            changed = _publish(path, staged, expected) or changed
                        else:
                            if _read(path)[1] != expected:
                                raise ValueError(
                                    f"formatter refuses concurrent change: {path}"
                                )
                        del _pending[path]
            return {"ok": True, "error": "", "changed": changed}
        except (OSError, ValueError, asyncio.TimeoutError) as error:
            message = str(error) or "formatter timed out"
            return {"ok": False, "error": message[:MAX_OUTPUT], "changed": changed}
