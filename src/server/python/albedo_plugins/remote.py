"""Remote kernels over SSH: every harness tool, on another machine.

connect() stages albedo's python bundle on the target, boots the same kernel
over one long-lived ssh connection, and answers its host-route calls against
this session's daemon, so session tools (work, skills, cells) keep running
where the daemon runs while machine tools (run, files) run on the target.
Both kernels load the same content-hashed bundle, so a tool's remote shape
matches its local one and results cross as real objects.

Every call is one reference: the reply inlines the value when it can cross and
keeps the object live over there otherwise, so methods can be called on the
remote object either way. If the kernel cannot boot, the connection degrades
to command mode -- only rem.run() -- and says so at connect.
"""

from __future__ import annotations

from albedo_output import JobOutput, plain

import asyncio
import base64
import contextlib
import json
import os
import shlex
import struct
import time
import secrets
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from pathlib import Path
from collections.abc import Callable, Generator, Iterator
from typing import Any, NotRequired, TypedDict, cast

from albedo_protocol import RemoteCall, RemoteMessage, parse_remote

from albedo_capture import MAX_CLIP_BYTES
from albedo_api import OutputCapture, PythonApi, ReadyList, Text, check_timeout, excerpt
import albedo_notices
from albedo_values import InvalidValue, decode
import albedo_shell
import albedo_rtk
import albedo_ssh
from albedo_plugins import hook
from albedo_plugins.files import refuse_listing
from albedo_plugins.run import NOTICE_RETRY, JobFailed, PendingText, notice, notices

CONNECT_TIMEOUT = 60  # seconds before an unreachable target gives up
HANDSHAKE_TIMEOUT = 60  # seconds for the remote kernel to say ready
INVOKE_TIMEOUT = 3600  # anti-wedge bound; the cell deadline is the real limit
COMMAND_TIMEOUT = 120  # degraded-mode command default
WRITE_BYTES_PER_SECOND = 128 * 1024  # conservative floor for upload deadlines
MAX_FRAME = 8 * 1024 * 1024  # control-frame ceiling, as in the kernel
STDERR_TAIL = 65536  # bytes of ssh diagnostics kept for failures
# one byte past the clip limit. an oversized file comes back over it.
READ = MAX_CLIP_BYTES + 1

loop: asyncio.AbstractEventLoop
host_call: Any
HostErrorType: type[Exception]
capture_factory: Any
send_frame: Any
attach_media: Any = None
session_modules: list[str] = []
current_cell: Callable[[], str | None] | None = None


class LiveJob(TypedDict):
    """A job still running over ssh, as the supervisor lists it."""

    id: str
    command: str
    service: bool  # nothing waits on its end
    started: int  # wall-clock milliseconds
    cell: NotRequired[str | None]


MAX_LISTED_JOBS = 100  # as many rows as the supervisor lists for local jobs
COMMAND_SCALARS = 4096  # a command's preview, as local jobs report it

_fallback_live: dict[str, LiveJob] = {}  # degraded-mode jobs still running over ssh
_fallback_jobs: dict[str, FallbackJob] = {}


def _live_job(id: str, command: str, service: bool, cell: str | None = None) -> LiveJob:
    return {
        "id": id,
        "command": command[:COMMAND_SCALARS],
        "service": service,
        "started": time.time_ns() // 1_000_000,
        **({"cell": cell} if cell is not None else {}),
    }


def _report_live() -> None:
    """Tell the local supervisor which remote jobs are still live, so it lists
    them beside its own and knows which will wake the session: every one not
    started as a service.

    Releasing the kernel would kill every ssh client and with them the remote
    kernels, so the idle sweep keeps a kernel alive while remote work runs,
    and the cache warmer keeps an idle session warm while one it awaits does.
    """
    try:
        live = [*_fallback_live.values()]
        for c in connections:
            if c.closed:
                continue
            job_cells = {
                str(c._mirrors[h]["job"]): ref._cell
                for h, ref in c._refs.items()
                if h in c._mirrors and ref._cell is not None and "job" in c._mirrors[h]
            }
            for job in c._live.values():
                cell = job_cells.get(job["id"])
                live.append({**job, "cell": cell} if cell is not None else job)
        send_frame(
            {
                "type": "jobs",
                "live": len(live),
                "awaited": sum(not job["service"] for job in live),
                "items": live[:MAX_LISTED_JOBS],
            }
        )
    except Exception:
        pass  # no channel or shutdown; the supervisor keeps the last count


def idle_seconds() -> int:
    """Remote connection idle limit, clamped to one second through one week."""
    try:
        return max(
            1, min(604800, int(os.environ.get("ALBEDO_REMOTE_IDLE_SECONDS", "3600")))
        )
    except ValueError:
        return 3600


configured: dict[str, str | None] = {}
connections: list["RemoteConnection"] = []

_UNSET = object()  # a value result that has not settled yet


class RemoteError(RuntimeError):
    """A remote operation failed; the message names what happened."""


class RemoteBootError(RemoteError):
    """The remote kernel could not start; the connection degrades to commands."""


class RemoteLost(RemoteError):
    """The ssh channel is gone; every reference it held is invalid."""


class RemoteTimeout(RemoteError):
    """A remote call did not answer; an interrupt was sent."""


class RemoteCancelled(RemoteError):
    """The wait was cancelled; the remote effect may continue."""


class RemoteExecutionError(RemoteError):
    """A remote tool call raised; its traceback crossed the connection."""

    def __init__(self, ename: str, evalue: str, traceback: list[str]) -> None:
        lines = "\n".join(traceback[-4:])
        super().__init__(f"{ename}: {evalue}" + (f"\n{lines}" if lines else ""))
        self.ename = ename
        self.evalue = evalue
        self.traceback = tuple(traceback)


def parse_target(arg: str) -> dict[str, str | None]:
    """Split `user@host[:/path]` or `ssh://user@host[:port][/path]`. ssh takes
    the URI as its target, path left out; in the scp form a colon not followed
    by a path stays in the host."""
    if arg.startswith("ssh://"):
        authority, slash, path = arg.removeprefix("ssh://").partition("/")
        return {
            "host": f"ssh://{authority}",
            "remote_cwd": f"/{path}" if slash else None,
        }
    head, separator, tail = arg.partition(":")
    remote_cwd = tail if separator and tail.startswith("/") else None
    return {"host": arg if remote_cwd is None else head, "remote_cwd": remote_cwd}


def _settings() -> dict[str, str]:
    """The `remote` section of extensions.json, each key missing from it taken
    from the older `ssh` section; errors raise."""
    home = os.environ.get("ALBEDO_HOME") or os.path.expanduser("~/.albedo")
    try:
        with open(os.path.join(home, "extensions.json"), "rb") as handle:
            sections = json.load(handle)
    except FileNotFoundError:
        return {}
    if not isinstance(sections, dict):
        raise RemoteError("extensions.json must hold an object")
    section: dict[str, object] = {}
    for name in ("ssh", "remote"):
        part = sections.get(name)
        if part is None:
            continue
        if not isinstance(part, dict):
            raise RemoteError(f"extensions.json {name} section must be an object")
        section.update(part)
    result: dict[str, str] = {}
    for key in ("host", "remoteCwd", "python"):
        if key not in section:
            continue
        value = section[key]
        if not isinstance(value, str):
            raise RemoteError(f"extensions.json remote.{key} must be a string")
        result[key] = value
    return result


def resolve(
    host: str | None = None, remote_cwd: str | None = None, python: str | None = None
) -> dict[str, str | None]:
    """The target a connection runs against, or a misuse error naming every source."""
    if host is None and configured:
        target = dict(configured)
    else:
        if host is None:
            host = os.environ.get("ALBEDO_SSH") or _settings().get("host")
        if host is None:
            raise RemoteError(
                "no remote target: pass host=, call remote.configure(), set $ALBEDO_SSH, "
                'or add a "remote" section to extensions.json'
            )
        target = parse_target(host)
        if target["remote_cwd"] is None:
            target["remote_cwd"] = _settings().get("remoteCwd")
    if remote_cwd is not None:
        target["remote_cwd"] = remote_cwd
    if python is None:
        python = _settings().get("python")
    target["python"] = python
    return target


def refusal(host: str, stderr: str) -> str:
    """Why ssh could not reach `host`; a sign-in only a person can give names
    the command that opens the master this connection would ride."""
    if albedo_ssh.failure(stderr)[0] != "needs_auth":
        return f"ssh target {host!r} is unreachable: {stderr.strip()[:300]}"
    return (
        f"ssh target {host!r} needs a person to sign in: {stderr.strip()[:300]}\n"
        f"ask the user to run `{shlex.join(albedo_ssh.sign_in(host))}` in a terminal,"
        " then connect again; the master it opens carries this connection"
    )


ssh_env = albedo_ssh.env
in_login_shell = albedo_ssh.in_login_shell
ssh_base = albedo_ssh.base


def _transfer_timeout(size: int) -> float:
    """Scale an upload deadline with payload size while keeping small runs bounded."""
    return min(
        float(INVOKE_TIMEOUT),
        COMMAND_TIMEOUT + max(0, size) / WRITE_BYTES_PER_SECOND,
    )


async def ssh_run(
    target: str,
    script: str,
    *,
    timeout: float | None = None,
    stdin: bytes | None = None,
) -> tuple[int | None, bytes, str]:
    """One command over the control connection; its exit code is data."""
    effective = (
        _transfer_timeout(len(stdin) if stdin is not None else 0)
        if timeout is None
        else timeout
    )
    check_timeout(effective)
    process = await asyncio.create_subprocess_exec(
        *ssh_base(target),
        target,
        script,
        stdin=asyncio.subprocess.PIPE
        if stdin is not None
        else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=ssh_env(target),
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(stdin), effective)
    except asyncio.TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        with contextlib.suppress(Exception):
            await process.wait()
        raise RemoteTimeout(
            f"ssh command did not finish in {effective:g}s: {script}"
        ) from None
    return process.returncode, stdout, stderr.decode(errors="replace")


async def _raise(error: BaseException) -> Any:
    raise error


def _revive(value: Any) -> Any:
    """Pickle hook target: a reference with a crossed value saves as its value."""
    return value


class RemoteRef:
    """One remote reference: pending, live, or settled into its value.

    A call returns this immediately -- the invoke is already in flight, no
    round trip blocks the call -- and the reference settles on first await.
    Methods called before the reply lands target the pending call, so
    `rem.run(program, ...)` behaves like local run: the handle exists now, `await`
    waits for the object, and mirrored job state answers tail() and poll()
    locally, with no round trip. A result whose value crossed reads and
    iterates like that value; its local methods run locally, and attributes
    that only exist remotely are remote calls.
    """

    def __init__(
        self,
        connection: "RemoteConnection",
        handle: str | None = None,
        value: Any = None,
        task: "asyncio.Task[Any] | None" = None,
        call_id: str | None = None,
        label: str = "",
    ) -> None:
        self._connection = connection
        self._handle = handle
        self._value = value
        self._task = task
        self._call_id = call_id
        self._label = label
        self._settled: Any = _UNSET
        self._withdrawn: bool = False
        self._awaited = False  # an await here returned, so its result reached this cell
        self._waiters = 0  # awaits here still waiting on it
        self._cell = current_cell() if current_cell else None  # the cell that made it

    # --- mirrored job state: sync, like the local handle ---

    def tail(self, n: int = 4000, *, lines: int | None = None) -> Text:
        """The recent output of the remote job this reference holds: the last
        n characters, or its last `lines` lines."""
        state = self._mirror(read=False)
        text = str(state.get("tail", "")) if state else ""
        size = state.get("tail_bytes", len(text.encode())) if state else 0
        result = excerpt(
            text,
            n,
            lines,
            end=True,
            clipped=bool(state and state.get("seen", 0) > size),
        )
        self._mirror()
        return result

    def poll(self) -> int | None:
        """The remote job's exit status so far, from the mirrored stream. A job
        whose connection died says so instead of running forever."""
        state = self._mirror()
        if state is None or state.get("exit_code") is None:
            lost = self._connection.lost
            if lost:
                raise RemoteLost(lost)
        return state.get("exit_code") if state else None

    @property
    def exit_code(self) -> int | None:
        """The remote job's exit status; the mirror keeps it current."""
        return self.poll()

    @property
    def returncode(self) -> int | None:
        """`exit_code` under subprocess's name; both spellings answer."""
        return self.poll()

    @property
    def timed_out(self) -> bool:
        """Whether the remote job lost its deadline."""
        state = self._mirror()
        return bool(state.get("timed_out")) if state else False

    @property
    def duration(self) -> float | None:
        """The seconds the remote job ran, known once it ended."""
        state = self._mirror()
        return state.get("duration") if state else None

    @property
    def id(self) -> str | None:
        """The remote job's id, for output.read on the remote side."""
        state = self._mirror()
        return state.get("job") if state else None

    def _mirror(self, *, read: bool = True) -> dict[str, Any] | None:
        if (failure := self._failure()) is not None:
            raise failure
        if self._handle is None:
            return None
        state = self._connection._mirrors.get(self._handle)
        # A finished job read through its mirror is consumed on the remote side
        # too, or its kernel would keep retrying a wake this read satisfies.
        if (
            read
            and state is not None
            and state.get("exit_code") is not None
            and not self._withdrawn
        ):
            self._withdrawn = True
            try:
                _ = loop.create_task(self._connection.mark_read(self._handle))
            except RuntimeError:
                pass  # the loop is closing; the notice dies with the kernel
        return state

    def _failure(self) -> BaseException | None:
        """The error of a call that failed before anything awaited it. A ref
        nobody awaits (a long build left to wake the session) has no other way
        to say it never started."""
        task = self._task
        if task is None or not task.done() or task.cancelled():
            return None
        return task.exception()

    @property
    def _claimed(self) -> bool:
        """Its result reached this side, or an await here is about to take it,
        so the job's wake is not owed."""
        return self._awaited or self._waiters > 0 or self._withdrawn

    # --- the value surface: identical output to the local tool ---

    def __repr__(self) -> str:
        if (failure := self._failure()) is not None:
            return f"<failed remote {self._label or 'call'}: {failure}>"
        if self._value is not None:
            return repr(self._value)
        if self._handle is not None:
            return f"<remote reference {self._handle[:8]} on {self._connection.host}>"
        return f"<pending remote {self._label or 'call'}; await it>"

    __str__ = __repr__

    def _wanted(self) -> Any:
        if self._value is None and self._handle is None:
            raise TypeError(
                f"the remote {self._label or 'result'} is still pending; await it first"
            )
        if self._value is None:
            raise TypeError(
                "a live remote reference is not a value; await it or call its methods"
            )
        return self._value

    def __iter__(self) -> Iterator[object]:
        return iter(self._wanted())

    def __len__(self) -> int:
        return len(self._wanted())

    def __getitem__(self, key: Any) -> Any:
        return self._wanted()[key]

    def __contains__(self, key: Any) -> bool:
        return key in self._wanted()

    def __eq__(self, other: object) -> bool:
        return self._value == other if self._value is not None else self is other

    def __dir__(self) -> list[str]:
        return sorted(
            set(dir(type(self)))
            | (set(dir(self._value)) if self._value is not None else set())
        )

    def __reduce__(self) -> tuple[Callable[[Any], Any], tuple[object]]:
        if self._value is None:
            raise TypeError(
                "a live remote reference cannot be saved; await or release it first"
            )
        return _revive, (self._value,)

    # --- the remote surface ---

    def __getattr__(self, name: str) -> Any:
        if name.startswith("_"):
            raise AttributeError(name)
        if self._value is not None and hasattr(self._value, name):
            return getattr(self._value, name)
        if self._connection.closed:
            raise RemoteLost(
                f"the connection for reference {self._label or '?'} is closed"
            )
        if self._handle is not None:
            return _RemoteCall(self._connection, self._handle, name)
        return _RemoteCall(
            self._connection,
            None,
            name,
            pending=self._call_id,
            label=f"{self._label}.{name}" if self._label else name,
        )

    def __await__(self) -> Generator[object, None, Any]:
        return self._wait().__await__()

    async def _wait(self) -> Any:
        # Counted now, like a local job: the await crosses the connection only
        # after the reply to the call, and a quick job is done before that. An
        # await cut short interrupts the remote one too, so the remote job owes
        # its wake again and this reference no longer claims it.
        self._waiters += 1
        try:
            result = await self._settle()
            self._awaited = True
        finally:
            self._waiters -= 1
        return result

    async def _settle(self) -> Any:
        """Resolve the in-flight call; awaiting a live object awaits the object."""
        if self._task is not None:
            task, self._task = self._task, None
            result = await task
            if result is not self:
                self._settled = result
                return result
        if self._settled is not _UNSET:
            return self._settled
        if self._handle is not None and self._value is None:
            await self._connection.invoke(handle=self._handle, wait=True)
        return self

    async def release(self) -> None:
        """Drop the live reference; the object itself is the remote plugin's to keep."""
        if self._task is not None:
            self._task.cancel()
            self._task = None
            return
        if self._handle is not None:
            self._connection._refs.pop(self._handle, None)
            await self._connection.invoke_release(self._handle)
        self._value = None


class _RemoteCall:
    """A method of the remote namespace, of one live reference, or of a pending call."""

    def __init__(
        self,
        connection: "RemoteConnection",
        handle: str | None,
        name: str,
        pending: str | None = None,
        label: str | None = None,
    ) -> None:
        self._connection = connection
        self._handle = handle
        self._name = name
        self._pending = pending
        self._label = label or name

    def __call__(self, *args: Any, **kwargs: Any) -> RemoteRef:
        """Start the call now; the reference it produces settles on first await."""
        return self._connection.start(self, args, kwargs)

    def __await__(self) -> Generator[object, None, Any]:
        """Awaiting an uncalled method runs it with no arguments, like a property."""
        return self().__await__()

    def __getattr__(self, name: str) -> Any:
        if name.startswith("_"):
            raise AttributeError(name)
        return _RemoteCall(
            self._connection,
            self._handle,
            f"{self._name}.{name}",
            pending=self._pending,
        )

    def __repr__(self) -> str:
        where = (
            self._handle[:8]
            if self._handle
            else (self._pending[:8] if self._pending else "namespace")
        )
        return f"<remote call {self._name} on {where}>"


SHELL_ONLY_DEGRADED = "rem.shell is only available in degraded SSH command mode; use rem.run(...).pipe(...) instead"


class RemoteConnection:
    """One ssh channel owning one remote kernel, or degraded to plain commands."""

    def __init__(self, target: dict[str, str | None]) -> None:
        self.target = target
        self._process: asyncio.subprocess.Process | None = None
        self._stdin = None
        self._stdout = None
        self._write_lock = asyncio.Lock()
        self._pending: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._placeholders: dict[str, RemoteRef] = {}
        # Invoke frames built this step and not yet written, by every call id
        # they carry; a call on one of those ids joins the frame's `then`.
        self._unsent: dict[str, dict[str, Any]] = {}
        self._refs: dict[str, RemoteRef] = {}
        self._mirrors: dict[str, dict[str, Any]] = {}
        self._handshake: asyncio.Future[dict[str, Any]] | None = None
        self._live: dict[str, LiveJob] = {}
        self._stderr_tail = bytearray()
        self._reader: asyncio.Task[None] | None = None
        self._drain: asyncio.Task[None] | None = None
        self.closed = False
        # Why the channel is gone, once it is: a dead connection's references
        # say so rather than reporting a job that never ended.
        self.lost: str | None = None
        self.degraded: RemoteBootError | None = None
        self._idle_seconds = idle_seconds()
        # connect() stamps this when it starts the idle watch.
        self._used_at = 0.0
        self._calls = 0
        self._idle_watch: asyncio.Task[None] | None = None

    def _require_open(self) -> None:
        if self.closed:
            raise RemoteLost(
                self.lost or f"the connection to {self.host} is closed; connect again"
            )

    def _idle_delay(self, now: float) -> float:
        busy = (
            self._calls
            or self._pending
            or self._unsent
            or self._live
            or self._refs
            or any(job._connection is self for job in _fallback_jobs.values())
        )
        if busy:
            self._used_at = now
        return max(0.0, self._idle_seconds - (now - self._used_at))

    async def _expire_idle(self) -> None:
        while not self.closed:
            delay = self._idle_delay(loop.time())
            if delay > 0:
                await asyncio.sleep(delay)
                continue
            self.lost = (
                f"the connection to {self.host} was closed after "
                f"{self._idle_seconds / 60:g} minutes idle; connect again with remote.connect()"
            )
            await self.close()

    def __reduce__(self):
        if not self.closed:
            raise TypeError("a live remote connection cannot be saved; close it first")
        return _closed_connection, (self.target, self.lost)

    # --- boot ---

    async def boot(
        self, modules: list[str] | None = None, timeout: float = HANDSHAKE_TIMEOUT
    ) -> None:
        """Stage, spawn, and wait for ready; a failure raises RemoteBootError."""
        # A persistent executor thread would keep the kernel from going idle.
        executor = ThreadPoolExecutor(max_workers=1)
        probe = partial(
            albedo_ssh.probe,
            self.host,
            candidate=self.target.get("python"),
            remote_cwd=self.target.get("remote_cwd"),
        )
        try:
            prepared = await asyncio.get_running_loop().run_in_executor(executor, probe)
        finally:
            executor.shutdown(wait=False, cancel_futures=True)
        python = prepared.get("executable")
        if prepared["state"] != "ready" or not isinstance(python, str):
            raise RemoteBootError(str(prepared["detail"]))
        script_path = f"{prepared['bundle']}/albedo_kernel.py"
        # The stamp reaches the remote kernel's plugins, so a finished remote
        # job's wake notice names the machine it ran on.
        inner = (
            f"ALBEDO_REMOTE_TARGET={shlex.quote(self.host)} exec "
            + f"{shlex.quote(python)} -E -u {shlex.quote(script_path)} "
            + shlex.quote(
                json.dumps(modules if modules is not None else default_modules())
            )
        )
        remote_cwd = self.target.get("remote_cwd")
        if remote_cwd:
            inner = f"CDPATH= cd -- {shlex.quote(remote_cwd)} && {inner}"
        script = in_login_shell(inner)
        self._handshake = loop.create_future()
        self._process = await asyncio.create_subprocess_exec(
            *ssh_base(self.host),
            self.host,
            script,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=ssh_env(self.host),
        )
        self._stdin, self._stdout = self._process.stdin, self._process.stdout
        self._drain = loop.create_task(self._drain_stderr())
        self._reader = loop.create_task(self._read_frames())
        try:
            frame = await asyncio.wait_for(asyncio.shield(self._handshake), timeout)
        except asyncio.TimeoutError:
            raise RemoteBootError(f"kernel did not say ready in {timeout:g}s") from None
        if frame.get("type") != "ready":
            raise RemoteBootError(str(frame.get("message", "invalid kernel handshake")))
        self._handshake = None

    async def _drain_stderr(self) -> None:
        """Keep a bounded tail of ssh diagnostics; a banner must not wedge the pipe."""
        assert self._process is not None and self._process.stderr is not None
        while True:
            chunk = await self._process.stderr.read(4096)
            if not chunk:
                return
            self._stderr_tail.extend(chunk)
            del self._stderr_tail[:-STDERR_TAIL]

    # --- frames ---

    async def _read_frames(self) -> None:
        try:
            while True:
                assert self._stdout is not None
                header = await self._stdout.readexactly(4)
                size = struct.unpack(">I", header)[0]
                if size > MAX_FRAME:
                    raise RemoteLost("remote control frame exceeds the ceiling")
                frame = parse_remote(json.loads(await self._stdout.readexactly(size)))
                self._dispatch(frame)
        except asyncio.CancelledError:
            raise
        except Exception:
            pass  # Every reader failure invalidates its outstanding work below.
        finally:
            self._lost()

    def _dispatch(self, frame: RemoteMessage) -> None:
        self._used_at = loop.time()
        if (
            frame["type"] == "invoked"
            or frame["type"] == "introspected"
            or frame["type"] == "job_stop"
        ):
            if (
                frame["type"] == "invoked"
                and frame.get("ok") is True
                and "handle" in frame
            ):
                handle = str(frame["handle"])
                state = frame.get("state")
                if isinstance(state, dict):
                    self._mirrors[handle] = dict(state)
                placeholder = self._placeholders.get(frame["id"])
                if placeholder is not None:
                    placeholder._handle = handle
                    self._refs[handle] = placeholder
                if isinstance(state, dict) and "job" in state:
                    _report_live()
            future = self._pending.get(frame["id"])
            if future is not None and not future.done():
                future.set_result(dict(frame))
        elif frame["type"] in ("ready", "startup_error"):
            if self._handshake is not None and not self._handshake.done():
                self._handshake.set_result(dict(frame))
        elif frame["type"] == "call":
            _ = loop.create_task(self._relay(frame))
        elif frame["type"] == "mirror":
            self._mirrors[frame["handle"]] = dict(frame)
            if "job" in frame:
                _report_live()
        elif frame["type"] == "job_start":
            self._live[frame["id"]] = _live_job(
                frame["id"],
                str(frame.get("command", "")),
                frame.get("service") is True,
            )
            _report_live()
        elif frame["type"] == "job":
            self._live.pop(frame["id"], None)
            _report_live()
        # trace, done, cleanup describe remote cells; those are addressed
        # through references, not events on this side.

    async def _relay(self, frame: RemoteCall) -> None:
        """Answer one remote host-route call against this session's daemon."""
        self._calls += 1
        try:
            await self._relay_call(frame)
        finally:
            self._calls -= 1
            self._used_at = loop.time()

    async def _relay_call(self, frame: RemoteCall) -> None:
        try:
            if frame["method"] == "jobs.completed":
                value = await self._wake(frame["args"])
            else:
                value = await host_call(frame["method"], frame["args"])
            reply: dict[str, Any] = {"ok": True, "value": value}
        except HostErrorType as error:
            reply = {
                "ok": False,
                "code": getattr(error, "code", "host"),
                "message": str(getattr(error, "message", error)),
            }
        except Exception as error:  # the daemon's answer must always be a reply
            reply = {
                "ok": False,
                "code": "host",
                "message": f"{type(error).__name__}: {error}",
            }
        await self._send({"type": "reply", "id": frame["id"], "value": reply})

    async def _wake(self, args: Any) -> Any:
        """Pass on a remote job's wake unless a reference here already awaited
        or read the job, which the remote kernel may not have heard yet."""
        facts = [
            fact
            for fact in args.get("jobs", [])
            if not self._claimed_here(fact.get("id"))
        ]
        if not facts:
            return None
        return await host_call("jobs.completed", {"key": args["key"], **notice(facts)})

    def _claimed_here(self, job: object) -> bool:
        return any(
            reference._claimed
            for handle, reference in self._refs.items()
            if self._mirrors.get(handle, {}).get("job") == job
        )

    async def _send(self, frame: dict[str, Any]) -> None:
        self._require_open()
        self._used_at = loop.time()
        if self._stdin is None:
            raise RemoteLost(f"the connection to {self.host} is closed")
        data = json.dumps(frame).encode()
        if len(data) > MAX_FRAME:
            raise RemoteError(
                f"remote call payload is {len(data)} bytes, over the {MAX_FRAME}-byte ceiling"
            )
        async with self._write_lock:
            self._stdin.write(struct.pack(">I", len(data)) + data)
            await self._stdin.drain()

    def _lost(self) -> None:
        """The channel died: every pending call and reference learns it once,
        and the jobs nobody here claimed wake the session instead of running
        forever in a supervisor that no longer has a connection."""
        if self._idle_watch is not None:
            self._idle_watch.cancel()
            self._idle_watch = None
        if self._handshake is not None and not self._handshake.done():
            self._handshake.set_exception(
                RemoteBootError(
                    "the ssh channel closed at startup: "
                    + bytes(self._stderr_tail).decode(errors="replace").strip()[:500]
                )
            )
        for future in self._pending.values():
            if not future.done():
                future.set_exception(
                    RemoteLost(f"the connection to {self.host} was lost")
                )
        self.closed = True
        self.lost = self.lost or f"the connection to {self.host} was lost"
        orphaned = [job for id, job in self._live.items() if not self._claimed_here(id)]
        if self._live:
            self._live.clear()
            _report_live()
        if orphaned:
            try:
                loop.create_task(self._announce_lost(orphaned))
            except RuntimeError:
                pass  # the loop is closing; no turn is left to wake

    async def _announce_lost(self, jobs: list[LiveJob]) -> None:
        """Wake the session for the jobs a dead connection took with it; their
        results are no longer readable, so this notice is all there is."""
        facts = [
            {
                "id": job["id"],
                "command": job["command"],
                "where": f" on {self.host}",
                "summary": "connection lost, exit status unknown",
                "exit_code": None,
                "timed_out": False,
                "duration": None,
                "host": self.host,
            }
            for job in jobs
        ]
        # Nothing withdraws it; one key keeps a retry from posting it twice.
        posted = albedo_notices.key()
        while True:
            try:
                await self._wake({"key": posted, "jobs": facts})
                return
            except Exception as error:
                # The host route may not be up yet; anything else means the
                # daemon is gone, or the session is shutting down.
                if getattr(error, "code", "") != "unknown":
                    return
                await asyncio.sleep(NOTICE_RETRY)

    # --- calls ---

    def start(
        self, call: "_RemoteCall", args: tuple[Any, ...], kwargs: dict[str, Any]
    ) -> RemoteRef:
        """Fire one call and return its reference immediately; it settles on await.

        A call on a pending reference whose frame has not gone out yet rides
        in that frame's `then` list, and the remote side makes it right after
        the call it names, with nothing scheduled between them. So
        run(...).pipe(...) attaches the pipe before the job's output can
        outgrow the replay limit, as it does locally, however the two calls'
        bytes cross the channel.
        """
        self._require_open()
        call_id = secrets.token_hex(16)
        reference = RemoteRef(self, call_id=call_id, label=call._label)
        try:
            frame = self._frame(call._name, call._handle, call._pending, args, kwargs)
        except Exception as error:
            reference._task = loop.create_task(_raise(error))
            return reference
        frame["id"] = call_id
        root = self._unsent.get(call._pending) if call._pending is not None else None
        self._expect(call_id, reference)
        if root is None:
            self._unsent[call_id] = frame
            outgoing: dict[str, Any] | None = frame
        else:
            del frame["type"]
            root.setdefault("then", []).append(frame)
            self._unsent[call_id] = root
            outgoing = None
        reference._task = loop.create_task(
            self._exchange(
                call_id, outgoing, call._name, None, INVOKE_TIMEOUT, reference
            )
        )
        if outgoing is not None:
            reference._task.add_done_callback(lambda _: self._unsendable(frame))
        return reference

    def _unsendable(self, frame: dict[str, Any]) -> None:
        """A frame whose call ended before writing it, cancelled before it
        started, fails the calls riding in it."""
        if not any(held is frame for held in self._unsent.values()):
            return
        for key in [key for key, held in self._unsent.items() if held is frame]:
            del self._unsent[key]
        for entry in frame.get("then", ()):
            waiting = self._pending.get(entry["id"])
            if waiting is not None and not waiting.done():
                waiting.set_exception(RemoteLost("the call it follows was never sent"))

    async def invoke(
        self,
        name: str = "",
        *,
        handle: str | None = None,
        pending: str | None = None,
        args: tuple[Any, ...] = (),
        kwargs: dict[str, Any] | None = None,
        wait: bool = False,
        timeout: float = INVOKE_TIMEOUT,
        call_id: str | None = None,
        placeholder: RemoteRef | None = None,
    ) -> Any:
        """One remote call; the answer is a value, or a reference to the live object.

        A `pending` target names an earlier call whose result this one uses, so
        method calls raced ahead of their own reply still resolve in order. The
        `placeholder` is the reference the caller already holds; a handle reply
        adopts into it rather than minting a second object.
        """
        self._require_open()
        frame = self._frame(name, handle, pending, args, kwargs or {})
        call_id = call_id or secrets.token_hex(16)
        frame["id"] = call_id
        if wait:
            frame["await"] = True
        self._expect(call_id, placeholder)
        return await self._exchange(call_id, frame, name, handle, timeout, placeholder)

    def _frame(
        self,
        name: str,
        handle: str | None,
        pending: str | None,
        args: tuple[Any, ...],
        kwargs: dict[str, Any],
    ) -> dict[str, Any]:
        """An invoke frame without its id."""
        if self.degraded is not None:
            raise RemoteError(
                f"degraded to ssh command mode ({self.degraded}); only rem.run() is available"
            )
        frame: dict[str, Any] = {
            "type": "invoke",
            "args": [_encode_arg(item) for item in args],
            "kwargs": {key: _encode_arg(item) for key, item in kwargs.items()},
        }
        if name:
            frame["name"] = name
        if handle is not None:
            frame["target"] = {"handle": handle}
        elif pending is not None:
            frame["target"] = {"pending": pending}
        return frame

    def _expect(self, call_id: str, placeholder: RemoteRef | None) -> None:
        self._pending[call_id] = loop.create_future()
        if placeholder is not None:
            self._placeholders[call_id] = placeholder

    async def _exchange(
        self,
        call_id: str,
        frame: dict[str, Any] | None,
        name: str,
        handle: str | None,
        timeout: float,
        placeholder: RemoteRef | None,
    ) -> Any:
        """Write `frame`, unless this call rides in another's, and await the
        reply to `call_id`. A frame that never goes out fails every call it
        carries, so none waits for a reply that cannot come."""
        future = self._pending[call_id]
        try:
            if frame is not None:
                for key in [key for key, held in self._unsent.items() if held is frame]:
                    del self._unsent[key]
                try:
                    await self._send(frame)
                except BaseException as error:
                    for entry in frame.get("then", ()):
                        waiting = self._pending.get(entry["id"])
                        if waiting is not None and not waiting.done():
                            waiting.set_exception(
                                RemoteLost(f"the call it follows was not sent: {error}")
                            )
                    raise
            try:
                reply = await asyncio.wait_for(future, timeout)
            except asyncio.TimeoutError:
                await self._interrupt(call_id)
                raise RemoteTimeout(
                    f"remote call {name or ('await ' + str(handle))!r} did not answer "
                    f"in {timeout:g}s; an interrupt was sent"
                ) from None
            except asyncio.CancelledError:
                await self._interrupt(call_id)
                raise
        finally:
            self._pending.pop(call_id, None)
            self._placeholders.pop(call_id, None)
            if self._unsent.get(call_id) is frame and frame is not None:
                del self._unsent[call_id]
        return self._result(reply, placeholder)

    def _result(
        self, reply: dict[str, Any], placeholder: RemoteRef | None = None
    ) -> Any:
        """One reply into a value or a reference, or the error it names."""
        if reply.get("ok") is not True:
            error = reply.get("error") or {}
            if reply.get("cancelled"):
                raise RemoteCancelled(str(error.get("evalue", "cancelled remotely")))
            raise RemoteExecutionError(
                str(error.get("ename", "RemoteError")),
                str(error.get("evalue", "")),
                [str(line) for line in error.get("traceback", [])],
            )
        try:
            value = decode(reply.get("value"))
        except InvalidValue as error:
            raise RemoteError(str(error)) from error
        if "handle" in reply:
            handle = str(reply["handle"])
            reference = (
                placeholder if placeholder is not None else self._refs.get(handle)
            )
            if reference is None:
                reference = RemoteRef(self, handle, value)
            else:
                reference._handle = handle
                reference._value = value
            self._refs[handle] = reference
            return reference
        return value

    async def _interrupt(self, call_id: str) -> None:
        """Best-effort: tell the remote kernel this wait is over."""
        try:
            await self._send({"type": "interrupt", "id": call_id})
        except Exception:
            pass  # the channel is already gone; the caller has that error

    async def invoke_release(self, handle: str) -> None:
        """Drop a live reference; no reply waits for it."""
        self._refs.pop(handle, None)
        await self._send({"type": "release", "handle": handle})

    async def mark_read(self, handle: str) -> None:
        """Tell the remote object its result was read, retiring its wake.

        A local mirror read never crosses the channel on its own, so this one
        round trip (a poll, which the job counts as a read) is the only way a
        finished remote job learns the model already has its output.
        """
        try:
            await self.invoke(handle=handle, name="poll", timeout=30)
        except Exception:
            pass  # the channel is gone; the notice fails its own way

    async def tools(self) -> dict[str, Any]:
        """What the remote namespace holds, and the live references it kept."""
        self._require_open()
        if self.degraded is not None:
            return {"names": ["run"], "handles": [], "degraded": str(self.degraded)}
        call_id = secrets.token_hex(16)
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending[call_id] = future
        await self._send({"type": "introspect", "id": call_id})
        try:
            frame = await asyncio.wait_for(future, CONNECT_TIMEOUT)
        finally:
            self._pending.pop(call_id, None)
        return {"names": frame.get("names", []), "handles": frame.get("handles", [])}

    async def stop_job(self, job_id: str) -> dict[str, object]:
        """Stop a background job running on the remote kernel."""
        if self.closed or self.degraded is not None:
            return {
                "ok": False,
                "error": "the remote kernel is closed or degraded",
            }
        future: asyncio.Future[dict[str, Any]] = loop.create_future()
        self._pending[job_id] = future
        try:
            await self._send({"type": "job_stop", "id": job_id})
            reply = await asyncio.wait_for(future, 15.0)
            return {
                "ok": reply.get("ok") is True,
                **({"error": reply["error"]} if "error" in reply else {}),
                **({"code": reply["code"]} if "code" in reply else {}),
            }
        except asyncio.TimeoutError:
            return {
                "ok": False,
                "error": "remote job stop was not confirmed after 15s",
            }
        except Exception as error:
            return {
                "ok": False,
                "error": str(error).lower() or "could not stop remote job",
            }
        finally:
            self._pending.pop(job_id, None)

    # --- ssh conveniences, both modes ---

    async def read(self, path: str, *, timeout: float = COMMAND_TIMEOUT) -> str | bytes:
        """A remote file over the control connection, not the kernel: its
        text, or its bytes when it is not UTF-8."""
        remote = _remote_path(self, path)
        data = await self._ssh(f"cat {shlex.quote(remote)}", timeout)
        try:
            return data.decode()
        except UnicodeDecodeError:
            return data

    async def show_media(
        self,
        source: bytes | str | os.PathLike[str],
        *,
        fps: float | None = None,
        timeout: float = COMMAND_TIMEOUT,
    ) -> str:
        """Return a remote image or audio or video clip to yourself with this
        cell's result, under the same limits as local show_media, a video
        sampled at `fps` frames a second when given. The remote kernel has no
        cell of its own to carry one, so the bytes come here over the control
        connection."""
        if attach_media is None:
            raise RemoteError("this kernel cannot attach images or clips")
        return attach_media(await self._attachment(source, timeout), fps)

    show_image = show_media

    async def _attachment(
        self, source: bytes | str | os.PathLike[str], timeout: float
    ) -> bytes:
        if isinstance(source, (bytes, bytearray, memoryview)):
            return bytes(source)
        if isinstance(source, (str, os.PathLike)):
            remote = shlex.quote(_remote_path(self, os.fspath(source)))
            return await self._ssh(f"head -c {READ} {remote}", timeout)
        raise TypeError(
            f"show_media takes bytes or a remote path, not {type(source).__name__}"
        )

    async def _ssh(
        self, script: str, timeout: float, stdin: bytes | None = None
    ) -> bytes:
        self._require_open()
        self._calls += 1
        try:
            code, stdout, stderr = await ssh_run(
                self.host, in_login_shell(script), timeout=timeout, stdin=stdin
            )
        finally:
            self._calls -= 1
            self._used_at = loop.time()
        if code != 0:
            raise RemoteError(f"SSH failed ({code}): {stderr.strip()}")
        return stdout

    async def write(
        self,
        path: str,
        content: str | bytes | bytearray | memoryview,
        *,
        timeout: float | None = None,
    ) -> None:
        """Replace a remote file, text or binary. The content travels on
        stdin, never in the command line, which a host caps (128 KiB per
        argument on Linux). A `files.read` listing is refused."""
        if timeout is not None:
            check_timeout(timeout)
        if isinstance(content, str):
            refuse_listing(content)
        data = content.encode() if isinstance(content, str) else bytes(content)
        shown = content if isinstance(content, str) else f"<{len(data)} bytes>"

        async def write(given: dict[str, object]) -> None:
            text = given["content"]
            body = data if text == shown else str(text).encode()
            remote = _remote_path(self, str(given["file_path"]))
            effective = _transfer_timeout(len(body)) if timeout is None else timeout
            await self._ssh(f"cat > {shlex.quote(remote)}", effective, body)

        arguments: dict[str, object] = {
            "file_path": path,
            "content": shown,
            "host": self.host,
        }
        await hook.around("files.write", arguments, write)

    # --- degraded mode ---

    @property
    def run(self) -> Any:
        """rem.run: the remote binding in kernel mode, command mode otherwise."""
        self._require_open()
        if self.degraded is None:
            return _RemoteCall(self, None, "run")

        def run(
            program: object,
            *args: object,
            cwd: str | None = None,
            env: dict[str, object] | None = None,
            stdin: str | bytes | None = None,
            timeout: float = 300,
        ) -> FallbackJob:
            self._require_open()
            check_timeout(timeout)
            if not (stdin is None or isinstance(stdin, (str, bytes))):
                raise TypeError("in ssh command mode stdin is text or bytes")
            argv = albedo_shell.words((program, *args))
            script = albedo_shell.shell_script(argv)
            if script is not None:
                raise albedo_shell.refusal(
                    f"`{os.path.basename(argv[0])} -c`", script=script
                )
            line = shlex.join(argv)
            hooked = hook.before("run", {"command": line, "host": self.host})
            command = str(hooked.arguments.get("command", line))
            argv = argv if command == line else shlex.split(command)
            if albedo_rtk.supported(argv, stdin=stdin is not None):
                raise RemoteError(
                    "RTK routing requires the remote Python kernel; degraded SSH mode cannot "
                    "verify remote RTK resolution (no native fallback for supported commands)"
                )
            return FallbackJob(
                self, argv, timeout, cwd=cwd, env=env, stdin=stdin, hooked=hooked
            )

        return run

    @property
    def shell(self) -> Any:
        """A shell escape hatch only when the remote kernel could not boot."""
        if self.degraded is None:
            raise AttributeError(SHELL_ONLY_DEGRADED)
        self._require_open()

        def shell(
            script: str,
            *,
            cwd: str | None = None,
            env: dict[str, object] | None = None,
            stdin: str | bytes | None = None,
            timeout: float = 300,
        ) -> FallbackJob:
            self._require_open()
            if not isinstance(script, str):
                raise ValueError("shell script must be text")
            check_timeout(timeout)
            if not (stdin is None or isinstance(stdin, (str, bytes))):
                raise TypeError("in ssh command mode stdin is text or bytes")
            hooked = hook.before("run", {"command": script, "host": self.host})
            script = str(hooked.arguments.get("command", script))
            return FallbackJob(
                self,
                ["bash", "-c", script],
                timeout,
                cwd=cwd,
                env=env,
                stdin=stdin,
                shell=script,
                hooked=hooked,
            )

        return shell

    # --- surface ---

    def __getattr__(self, name: str) -> Any:
        if name.startswith("_"):
            raise AttributeError(name)
        if name == "shell" and self.degraded is None:
            raise AttributeError(SHELL_ONLY_DEGRADED)
        if self.degraded is not None:
            raise AttributeError(
                f"{name!r} is unavailable: this connection is degraded to ssh command "
                f"mode ({self.degraded}); only rem.run(), rem.shell(), rem.read, and rem.write work"
            )
        self._require_open()
        return _RemoteCall(self, None, name)

    def __repr__(self) -> str:
        state = (
            "degraded"
            if self.degraded is not None
            else ("closed" if self.closed else "kernel")
        )
        return f"<remote {self.host} ({state})>"

    async def close(self) -> None:
        """End the kernel and its channel: shutdown frame, then the signal ladder."""
        watch, self._idle_watch = self._idle_watch, None
        if watch is not None and watch is not asyncio.current_task():
            watch.cancel()
        if self.closed and self._process is None:
            return
        if self._process is not None and self._process.returncode is None:
            try:
                await self._send({"type": "shutdown"})
            except Exception:
                pass
            try:
                await asyncio.wait_for(self._process.wait(), 1.0)
            except asyncio.TimeoutError:
                self._process.terminate()
                try:
                    await asyncio.wait_for(self._process.wait(), 1.0)
                except asyncio.TimeoutError:
                    self._process.kill()
                    await self._process.wait()
        self.closed = True
        self.lost = self.lost or f"the connection to {self.host} was closed"
        self._live.clear()
        _report_live()
        for future in self._pending.values():
            if not future.done():
                future.set_exception(
                    RemoteLost(f"the connection to {self.host} closed")
                )
        self._pending.clear()
        for task in (self._reader, self._drain):
            if task is not None:
                task.cancel()
        await asyncio.gather(
            *(task for task in (self._reader, self._drain) if task is not None),
            return_exceptions=True,
        )
        if self in connections:
            connections.remove(self)

    async def __aenter__(self) -> "RemoteConnection":
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.close()

    @property
    def host(self) -> str:
        return str(self.target["host"])


# The key sets the remote's argument reader takes for something else.
_ARG_MARKERS = {
    frozenset(keys) for keys in (["__ref__"], ["pending"], ["__bytes__"], ["__dict__"])
}


def _encode_arg(value: Any) -> Any:
    """References pass as references; everything else must already be wire data."""
    if isinstance(value, RemoteRef):
        if value._connection.closed:
            raise RemoteLost("cannot pass a reference from a closed connection")
        if value._handle is not None:
            return {"__ref__": value._handle}
        if value._task is not None:
            return {"pending": value._call_id}
        if value._settled is not _UNSET:
            return _encode_arg(value._settled)
        raise RemoteError("cannot pass an unusable remote reference")
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, (bytes, bytearray)):
        return {"__bytes__": base64.b64encode(bytes(value)).decode("ascii")}
    if isinstance(value, list):
        return [_encode_arg(item) for item in value]
    if isinstance(value, dict) and type(value) is dict:
        if all(isinstance(key, str) for key in value) and (
            frozenset(value) not in _ARG_MARKERS
        ):
            return {key: _encode_arg(item) for key, item in value.items()}
        # Keys a JSON object cannot hold, or a key set the remote reads as a
        # reference, a pending call or bytes: the pairs.
        pairs = []
        for key, item in value.items():
            if not (isinstance(key, (str, int, float, bytes)) or key is None):
                raise RemoteError(
                    f"cannot pass a dict keyed by {type(key).__name__} to a remote call"
                )
            pairs.append([_encode_arg(key), _encode_arg(item)])
        return {"__dict__": pairs}
    try:
        json.dumps(value)
        return value
    except (TypeError, ValueError) as error:
        raise RemoteError(
            f"cannot pass {type(value).__name__} to a remote call: only wire data "
            "and remote references cross"
        ) from error


def _remote_path(connection: RemoteConnection, path: str) -> str:
    """The remote spelling of a workspace path; anything else passes through.

    Membership is decided by path boundary, not string prefix: a sibling whose
    name merely starts with the workspace's is not inside it. A workspace at the
    filesystem root maps nothing, since every absolute path is under root.
    """
    remote_cwd = connection.target.get("remote_cwd")
    if not remote_cwd:
        return path
    candidate = Path(path)
    if not candidate.is_absolute():
        return path  # the remote kernel's cwd is the workspace already
    workspace = Path.cwd()
    if workspace == Path(workspace.anchor):
        return path
    try:
        inside = Path(os.path.normpath(candidate)).relative_to(workspace)
    except ValueError:
        return path  # a path outside the workspace keeps its meaning
    return str(Path(remote_cwd) / inside)


class FallbackProcess(asyncio.SubprocessProtocol):
    """Observe ssh's exit separately from EOF held by a surviving descendant."""

    def __init__(self, capture: OutputCapture) -> None:
        self.capture = capture
        self.exited: asyncio.Future[int] = loop.create_future()
        self.drained: asyncio.Future[None] = loop.create_future()
        self.transport: asyncio.SubprocessTransport

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = cast(asyncio.SubprocessTransport, transport)

    def pipe_data_received(self, fd: int, data: bytes) -> None:
        self.capture.write_bytes(data)

    def pipe_connection_lost(self, fd: int, exc: Exception | None) -> None:
        if fd == 1 and not self.drained.done():
            self.drained.set_result(None)

    def process_exited(self) -> None:
        code = self.transport.get_returncode()
        assert code is not None
        self.exited.set_result(code)


class FallbackJob(JobOutput):
    """One command over the control connection when no kernel could boot.

    The same shape as a run job: await it, tail() it, stop() it. Killing the
    ssh client cannot stop the remote side, so a deadline reports timed_out
    and says the remote effect is unknown rather than ended.
    """

    def __init__(
        self,
        connection: RemoteConnection,
        argv: list[str],
        timeout: float,
        *,
        cwd: str | None = None,
        env: dict[str, object] | None = None,
        stdin: str | bytes | None = None,
        shell: str | None = None,
        hooked: hook.Call | None = None,
    ) -> None:
        self.id = secrets.token_hex(16)
        self._hooked = hooked
        self.argv = argv
        self.command = shell if shell is not None else shlex.join(argv)
        self.timed_out = False
        self.exit_code: int | None = None
        self.started: float = loop.time()
        self.duration: float | None = None
        self.capture = capture_factory(self.id)
        self.cell = current_cell() if current_cell else None
        self._awaited = False  # an await returned this job; its result reached them
        self._waiters = 0  # awaits still waiting; one cut short leaves the wake owed
        self._read = False
        self._announcer: asyncio.Task[None] | None = None
        self._connection = connection
        _fallback_live[self.id] = _live_job(self.id, self.command, False, self.cell)
        _fallback_jobs[self.id] = self
        _report_live()
        # the remote login shell reads this line; everything in it is quoted
        steps = [
            f"cd {shlex.quote(str(where))}"
            for where in (connection.target.get("remote_cwd"), cwd)
            if where
        ]
        assignments = [f"{name}={value}" for name, value in (env or {}).items()]
        steps.append(
            shlex.join(["exec", *(["env", *assignments] if assignments else []), *argv])
        )
        data = stdin.encode() if isinstance(stdin, str) else stdin
        self._task = loop.create_task(
            self._run(
                connection.host, in_login_shell(" && ".join(steps)), timeout, data
            )
        )

    async def _run(
        self, host: str, script: str, timeout: float, stdin: bytes | None
    ) -> "FallbackJob":
        transport, process = await loop.subprocess_exec(
            lambda: FallbackProcess(self.capture),
            *ssh_base(host),
            host,
            script,
            stdin=asyncio.subprocess.DEVNULL
            if stdin is None
            else asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=ssh_env(host),
        )
        self._process = process
        pipe = cast(asyncio.WriteTransport | None, transport.get_pipe_transport(0))
        if stdin is not None and pipe is not None:
            pipe.write(stdin)
            pipe.close()
        try:
            self.exit_code = await asyncio.wait_for(
                asyncio.shield(process.exited), timeout
            )
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(asyncio.shield(process.drained), timeout=1.0)
        except asyncio.TimeoutError:
            self.timed_out = True
            transport.kill()
            self.exit_code = await asyncio.shield(process.exited)
            self.capture.write(
                f"\n[deadline exceeded after {timeout:g}s; the ssh client was killed; "
                f"the remote command may still be running]"
            )
        finally:
            transport.close()
            if self._hooked is not None:
                self.capture.write(
                    await hook.job_ended(self._hooked, self.exit_code, self.timed_out)
                )
            self.capture.finish()
            self.duration = loop.time() - self.started
            _fallback_live.pop(self.id, None)
            _fallback_jobs.pop(self.id, None)
            self._connection._used_at = loop.time()
            _report_live()
            self._owe_unread()
        return self

    @property
    def _unreported(self) -> bool:
        """Finished, and its result has reached no one yet."""
        return not self._read and not self._awaited and not self._waiters

    def _owe_unread(self) -> None:
        """Start the finished command's wake unless its result reached someone."""
        if host_call is None or not self._unreported:
            return
        if self._announcer is None or self._announcer.done():
            self._announcer = loop.create_task(self._announce())

    async def _announce(self) -> None:
        """Post this command's notice to the session's inbox, withdrawn
        (`notices`) once its result is read."""
        call = host_call
        while self._unreported and call is not None:
            posted = albedo_notices.key()
            try:
                await call("jobs.completed", {"key": posted, **self._notice()})
            except HostErrorType as error:
                if getattr(error, "code", "") == "unknown":
                    await asyncio.sleep(NOTICE_RETRY)
                    continue
                self.capture.write(f"\n[completion notice not delivered: {error}]\n")
                return
            except Exception:
                return  # the kernel is going away; the result stays on the handle
            notices.watch(call, posted, lambda: not self._unreported)
            return

    def _satisfied(self) -> None:
        notices.poke()

    def _notice(self) -> dict[str, object]:
        """The wake turn's display text, model text, and the facts behind both."""
        command = self.command[:200] + ("..." if len(self.command) > 200 else "")
        outcome = (
            "timed out"
            if self.timed_out
            else f"exit_code={self.exit_code}"
            if self.exit_code is not None
            else "exit status unknown"
        )
        seconds = (
            f"{self.duration:.1f}s" if self.duration is not None else "unknown duration"
        )
        display = (
            f"job finished on {self._connection.host} ({outcome}, {seconds}): {command}"
        )
        text = (
            f"<system-note>a background command finished on {self._connection.host}"
            f" (ssh command mode, {outcome}, {seconds}): {command}."
            f" read its output with .tail() or output.read({self.id!r});"
            f" {albedo_notices.IDLE}</system-note>"
        )
        return {
            "display": display,
            "text": text,
            "id": self.id,
            "exit_code": self.exit_code,
            "timed_out": self.timed_out,
            "duration": self.duration,
            "host": self._connection.host,
        }

    def __await__(self) -> Generator[object, None, FallbackJob]:
        return self._wait().__await__()

    async def _wait(self) -> FallbackJob:
        """Wait for the command; an await cut short leaves its wake owed."""
        self._waiters += 1
        try:
            await asyncio.shield(self._task)
            self._awaited = True
            notices.poke()
        finally:
            self._waiters -= 1
            if self._task.done():
                self._owe_unread()
        return self

    @property
    def pipeline(self) -> str:
        """The command line this job ran, matching `Job.pipeline`."""
        return self.command

    def text(self, check: bool = True) -> PendingText:
        """Wait for the command and return its whole output as plain text:
        escape codes dropped, a redrawn line at its last draw. Nonzero
        exits and timeouts raise JobFailed unless check=False."""
        return PendingText(lambda: self._text(check))

    async def _text(self, check: bool) -> Text:
        await self
        output = plain(self.read())
        if check and (self.exit_code != 0 or self.timed_out):
            raise JobFailed(cast(Any, self), output)
        return Text(output)

    def poll(self) -> int | None:
        if self.exit_code is not None:
            self._read = True
        return self.exit_code

    @property
    def returncode(self) -> int | None:
        """`exit_code` under subprocess's name; both spellings answer."""
        return self.poll()

    async def stop(self) -> None:
        """End the ssh client; the remote command's fate is reported, not assumed."""
        self._read = True  # an explicit stop is its own report; no wake is owed
        # A stop can arrive before the spawn produced a process, but a spawn
        # that never does must not spin here forever.
        for _ in range(500):
            if getattr(self, "_process", None) is not None or self._task.done():
                break
            await asyncio.sleep(0.01)
        process = getattr(self, "_process", None)
        if process is not None and process.transport.get_returncode() is None:
            process.transport.terminate()
            try:
                await asyncio.wait_for(asyncio.shield(process.exited), 2.0)
            except asyncio.TimeoutError:
                process.transport.kill()
            self.capture.write(
                "\n[stopped locally; the remote command may still be running]"
            )
        if hasattr(self, "_task"):
            with contextlib.suppress(Exception):
                await self._task

    def __repr__(self) -> str:
        return (
            f"FallbackJob(id={self.id!r}, exit_code={self.exit_code!r}, "
            f"timed_out={self.timed_out!r}, duration={self.duration!r}, "
            f"bytes={self.capture.seen})"
        )


def default_modules() -> list[str]:
    """The session's tool selection, minus this plugin: what boots remotely."""
    return [name for name in session_modules if name != "remote"]


class Remote:
    """The namespace bound into the kernel as `remote`."""

    @staticmethod
    def configure(host: str, remote_cwd: str | None = None) -> dict[str, str | None]:
        """Resolve `user@host[:/path]` once and keep it for later connections."""
        target = parse_target(host)
        if remote_cwd is not None:
            target["remote_cwd"] = remote_cwd
        configured.clear()
        configured.update(target)
        return dict(target)

    @staticmethod
    async def connect(
        host: str | None = None,
        *,
        remote_cwd: str | None = None,
        python: str | None = None,
        modules: list[str] | None = None,
        timeout: float = HANDSHAKE_TIMEOUT,
    ) -> RemoteConnection:
        """Boot this session's kernel on a remote host, or degrade to commands.

        The target resolves per call: an explicit `host=`, then the value
        `remote.configure` stored, then `$ALBEDO_SSH`, then the `remote`
        section of extensions.json. If the host is reachable but the kernel
        cannot boot, the connection still returns, prints a warning, and
        answers `rem.run()`, degraded-only `rem.shell()`, `rem.read`, `rem.write`,
        and `rem.show_image`.
        """
        target = resolve(host, remote_cwd, python)
        code, _, stderr = await ssh_run(
            str(target["host"]), "true", timeout=CONNECT_TIMEOUT
        )
        if code != 0:
            raise RemoteError(refusal(str(target["host"]), stderr))
        if target["remote_cwd"] is None:
            code, stdout, _ = await ssh_run(
                str(target["host"]), "pwd", timeout=CONNECT_TIMEOUT
            )
            if code == 0:
                target["remote_cwd"] = stdout.decode(errors="replace").strip() or None
        connection = RemoteConnection(target)
        try:
            await connection.boot(modules, timeout)
        except RemoteBootError as error:
            connection.degraded = error
            if connection._process is not None:
                if connection._reader is not None:
                    connection._reader.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await connection._reader
                if connection._drain is not None:
                    connection._drain.cancel()
                if connection._process.returncode is None:
                    connection._process.terminate()
            connection._process = None
            connection._stdin = connection._stdout = None
            connection.closed = False
            print(
                f"[remote] kernel boot failed on {target['host']}: {error}; "
                "degraded to ssh command mode: rem.run(program, *args) still works; "
                "for pipes or shell syntax use rem.shell('git log --oneline | rg fix') "
                "(bash on the host; no remote process supervision)"
            )
        connections.append(connection)
        connection._used_at = loop.time()
        connection._idle_watch = loop.create_task(connection._expire_idle())
        return connection

    @staticmethod
    def connections() -> ReadyList:
        """Every open connection, kernel or degraded."""
        return ReadyList([c for c in connections if not c.closed])

    @staticmethod
    async def close_all() -> None:
        """Kernel shutdown: end every connection inside the cleanup deadline."""
        for connection in list(connections):
            await connection.close()


def _closed_connection(
    target: dict[str, str | None], reason: str | None
) -> RemoteConnection:
    connection = RemoteConnection(target)
    connection.closed = True
    connection.lost = reason
    return connection


remote = Remote()


async def stop_remote_job(job_id: str) -> dict[str, object] | None:
    """Stop a remote background job across open remote connections and fallbacks."""
    fallback = _fallback_jobs.get(job_id)
    if fallback is not None:
        await fallback.stop()
        return {"ok": True}
    for connection in connections:
        if not connection.closed and job_id in connection._live:
            return await connection.stop_job(job_id)
    return None


def cell_jobs(cell: str) -> list[tuple[str, str]]:
    """The remote jobs `cell` started that still run, on every host."""
    running = [
        (job.id, f"{job.command} on {job._connection.host}")
        for job in _fallback_jobs.values()
        if job.cell == cell and job.exit_code is None
    ]
    for connection in connections:
        if connection.closed:
            continue
        for handle, reference in connection._refs.items():
            mirror = connection._mirrors.get(handle, {})
            job = connection._live.get(str(mirror.get("job")))
            if reference._cell == cell and job is not None and not job["service"]:
                running.append((job["id"], f"{job['command']} on {connection.host}"))
    return running


def setup(api: PythonApi) -> dict[str, object]:
    global loop, host_call, HostErrorType, capture_factory, send_frame
    global attach_media, session_modules, current_cell
    loop, host_call = api.loop, api.host
    HostErrorType, capture_factory = api.HostError, api.capture
    send_frame = api.send
    attach_media = api.attach_media
    session_modules = list(api.modules)
    api.on_shutdown(Remote.close_all)
    if api.owns_resources is not None:
        api.owns_resources(
            lambda: any(not connection.closed for connection in connections)
        )
    if api.on_stop_job is not None:
        api.on_stop_job(stop_remote_job)
    current_cell = api.cell
    if api.on_cell_jobs is not None:
        api.on_cell_jobs(cell_jobs)
    return {"remote": remote, "RemoteError": RemoteError}
