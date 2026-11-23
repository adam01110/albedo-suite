"""One ssh layer for albedo: the daemon's remote kernels and the model's remote plugin.

Both ride the same multiplexed control connection per host: the ControlPath
the user's ssh config names, so their own ssh, colmena and git share it too,
or `/tmp/albedo-ssh-cm/%C` when it names none. BatchMode stays on: a host
that needs a passphrase, a second factor or a new host key answers
`needs_auth`, and the tui opens the master in the terminal instead.

    albedo_ssh.py probe <[user@]host>
    albedo_ssh.py commands <[user@]host> <home> [<run_dir>]
    albedo_ssh.py hosts

`probe` prints `{"step": "staging"}` on a line of its own before it copies
the bundle over, so a waiting client can say so, then one JSON object:
`{state, detail, os, arch, home, cpus, python}` and, once the home is known,
the `commands` answer: `{argv, control, bundle, bridge, signal, remove,
gather, relay, auth_sock}`, the complete remote commands the daemon runs there.
state is ready, needs_auth, unreachable or unsupported. A ready probe has prepared
Python and staged the content-hashed bundle under `~/.albedo-remote/<digest>`.
`commands` needs no network. It uses helpers already uploaded to the host,
including bundles staged before managed environments. `hosts` lists the `Host`
names of ~/.ssh/config and its includes, patterns left out.
"""

from __future__ import annotations

import hashlib
import glob
import io
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from collections.abc import Callable
from typing import TYPE_CHECKING, Literal

import albedo_bundle
import albedo_uv

if TYPE_CHECKING:
    import tarfile

CONNECT_TIMEOUT = 10  # seconds ssh may take to reach a host
PROBE_TIMEOUT = 30  # seconds for the whole probe command
STAGE_TIMEOUT = 120  # seconds to move the bundle over one ssh stream
ENV_TIMEOUT = 180
# host -> (ssh -o values, environment) for hosts named by alias()
ALIASES: dict[str, tuple[list[str], dict[str, str]]] = {}
STAGED_DIR = ".albedo-remote"


def control_dir() -> str:
    """Control sockets live under /tmp when it fits, else the temp dir: unix
    socket paths are capped (~104 bytes on macOS) and %C hashes to 40 more,
    so neither ALBEDO_HOME nor macOS's deep $TMPDIR may be on the path."""
    control = os.path.join("/tmp", "albedo-ssh-cm")
    if len(control) + 42 > 104:
        control = os.path.join(tempfile.gettempdir(), "albedo-ssh-cm")
    return control


def multiplexing(target: str) -> tuple[str, str]:
    """The control path and ControlPersist for `target`: the user's own when
    their ssh config names a ControlPath, so a master they or their tools
    opened carries albedo too and albedo's carries theirs; else albedo's.
    `ssh -G` only reads the config."""
    try:
        done = subprocess.run(
            ["ssh", "-G", target],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=5,
        )
        lines = done.stdout.splitlines() if done.returncode == 0 else []
    except (OSError, subprocess.SubprocessError):
        lines = []
    settings = {}
    for line in lines:
        key, _, value = line.partition(" ")
        settings[key] = value
    path = settings.get("controlpath", "none")
    if path == "none":
        return f"{control_dir()}/%C", "600"
    persist = settings.get("controlpersist", "no")
    # -G expanded the path's tokens; a % left in it is literal
    return path.replace("%", "%%"), "600" if persist in ("no", "0") else persist


def alias(host: str, ssh_options: list[str], environment: dict[str, str]) -> None:
    """Name a host this process reaches without ~/.ssh/config, as a ProxyCommand
    does: `ssh_options` are `-o` values, `environment` is added for ssh and the
    command it spawns, which is how a token stays out of the command line."""
    ALIASES[host] = (ssh_options, environment)


def unalias(host: str) -> None:
    ALIASES.pop(host, None)


def base(target: str) -> list[str]:
    """The ssh argv prefix for `target`, up to the target itself. An alias's
    options come first: ssh keeps the first value it is given for an option."""
    argv = options(*multiplexing(target))
    named = ALIASES.get(target, ([], {}))[0]
    return [argv[0], *(arg for value in named for arg in ("-o", value)), *argv[1:]]


def sign_in(target: str) -> list[str]:
    """What a person runs in a terminal to sign in to `target` where ssh can
    ask them: it opens the master albedo rides, which outlives it."""
    control, persist = multiplexing(target)
    return [
        "ssh",
        "-M",
        "-fN",
        "-o",
        f"ControlPath={control}",
        "-o",
        f"ControlPersist={persist}",
        target,
    ]


def options(control: str, persist: str) -> list[str]:
    """The ssh argv prefix riding the master at `control`."""
    os.makedirs(control_dir(), exist_ok=True)
    return [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={CONNECT_TIMEOUT}",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ControlMaster=auto",
        "-o",
        f"ControlPath={control}",
        "-o",
        f"ControlPersist={persist}",
    ]


def agent_socket() -> str | None:
    """SSH_AUTH_SOCK, or a standard agent socket when it was not inherited, so
    hardware keys, 1Password, and ssh-agent work out of the box."""
    if "SSH_AUTH_SOCK" in os.environ:
        return os.environ["SSH_AUTH_SOCK"]
    for candidate in (
        os.path.expanduser("~/.ssh/agent.sock"),
        os.path.expanduser(
            "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        ),
    ):
        if os.path.exists(candidate):
            return candidate
    return None


def env(target: str | None = None) -> dict[str, str]:
    """The local environment for ssh client processes, with the alias's for `target`."""
    environment = {**os.environ, **ALIASES.get(target or "", ([], {}))[1]}
    socket = agent_socket()
    if socket is not None:
        environment["SSH_AUTH_SOCK"] = socket
    return environment


def in_login_shell(script: str) -> str:
    """The remote command that runs `script` under the user's login shell.

    Non-interactive SSH commands run under `$SHELL -c` without sourcing
    `/etc/profile` or user profiles, which leaves PATH minimal (missing
    Nix, Homebrew, or user tool paths); a login shell finds python3 and the
    user's tools. Profiles often print (a motd, a greeting), which would
    corrupt a framed stdout and fill the daemon's log on every command, so
    the login shell starts with both on /dev/null and the real ones kept on
    fds 3 and 4, and `script` gets them back.

    `$SHELL` is not always a POSIX shell (`nu`, `fish` and `tcsh` are not),
    so it never sees the script: `/bin/sh` writes it to a temporary file and
    the login shell is asked for one quote-free command, `/bin/sh <path>`.
    Both the redirections and the script stay POSIX, and stdin is never
    touched, which the bridge's frames travel on.
    """
    # The script deletes its own file before running: an unlinked script keeps
    # reading from its open handle, and the exec below leaves no process behind
    # whose command line still holds it.
    login = f'rm -f "$0"; exec 1>&3 2>&4 3>&- 4>&-; {script}'
    # A heredoc ends at its delimiter on a line of its own, so the script's
    # own text must not hold one; extend the delimiter until it does not.
    delimiter = "ALBEDO-REMOTE"
    while re.search(f"^{re.escape(delimiter)}$", script, re.MULTILINE):
        delimiter += "-x"
    outer = (
        'f=$(mktemp "${TMPDIR:-/tmp}/albedo-remote-XXXXXX" 2>/dev/null) || exit 1\n'
        "trap 'rm -f -- \"$f\"' EXIT HUP INT TERM\n"
        f"cat > \"$f\" <<'{delimiter}' || exit 1\n"
        f"{login}\n"
        f"{delimiter}\n"
        "exec 3>&1 4>&2 1>/dev/null 2>&1\n"
        'exec "${SHELL:-/bin/sh}" -l -c "/bin/sh $f"\n'
    )
    return f"/bin/sh -c {shlex.quote(outer)}"


def selector(bundle: str, candidate: str, remote_cwd: str | None) -> str:
    request = candidate
    if remote_cwd and "/" in candidate and not candidate.startswith("/"):
        request = f"{remote_cwd}\0{candidate}"
    key = hashlib.sha256(request.encode()).hexdigest()[:16]
    return f"{bundle}.env/{key}/current"


def commands(target: str, home: str, run_dir: str | None = None) -> dict[str, object]:
    """Build read-only recovery commands without contacting the host."""
    return _commands(target, home, run_dir=run_dir)


def _commands(
    target: str,
    home: str,
    *,
    bundle: str | None = None,
    executable: str | None = None,
    run_dir: str | None = None,
) -> dict[str, object]:
    def launch(script: str, *args: str) -> str:
        if bundle is not None and executable is not None:
            return in_login_shell(
                "exec "
                + shlex.join([executable, "-E", "-u", f"{bundle}/{script}", *args])
            )
        return existing_helper(home, script, args, run_dir)

    control, persist = multiplexing(target)
    answer: dict[str, object] = {
        "host": target,
        "argv": [*options(control, persist), target],
        "control": control,
        "bridge": launch("albedo_bridge.py", "--frame"),
        "signal": launch("albedo_signal.py", "-"),
        "remove": in_login_shell('IFS= read -r run && rm -rf -- "$run"'),
        "gather": launch("albedo_gather.py"),
        "relay": launch("albedo_transfer_relay.py"),
    }
    if bundle is not None:
        answer["bundle"] = bundle
    socket = agent_socket()
    if socket is not None:
        answer["auth_sock"] = socket
    return answer


def existing_helper(
    home: str, script: str, args: tuple[str, ...], run_dir: str | None
) -> str:
    """Run an already uploaded helper without preparing an environment.

    The attach bridge forwards the frozen framing protocol and the signal
    helper uses the standard library. Older stages ran both under python3.
    The interpreter check reads no input, leaving stdin with the selected helper.
    """
    root = shlex.quote(f"{home}/{STAGED_DIR}") if home else f'"$HOME/{STAGED_DIR}"'
    check = shlex.quote(
        "import os, runpy, sys; "
        "assert sys.version_info >= (3, 11); "
        "sys.path.insert(0, os.path.dirname(sys.argv[1])); "
        "runpy.run_path(sys.argv[1]); print('ready')"
    )
    arguments = shlex.join(args)
    recorded = ""
    if run_dir is not None:
        path = shlex.quote(f"{run_dir}/bridge-launch")
        recorded = f"""
if [ -f {path} ]; then
  if IFS= read -r python && IFS= read -r bundle; then
    case "$python" in
      /*) case "$bundle" in
            /*) if helper_ready "$python" "$bundle/{script}"; then
                  exec "$python" -E -u "$bundle/{script}" {arguments} <&3
                fi ;;
          esac ;;
    esac
  fi 3<&0 <{path}
fi
"""

    return in_login_shell(
        f"""
helper_ready() {{
  [ -f "$2" ] &&
    [ "$("$1" -E -B -c {check} "$2" </dev/null 2>/dev/null)" = ready ]
}}
{recorded}
root={root}
unset found chosen
for helper in "$root"/*/{script}; do
  [ -f "$helper" ] || continue
  bundle=${{helper%/*}}; digest=${{bundle##*/}}
  case "$digest" in *[!0-9a-f]*) continue ;; esac
  [ "${{#digest}}" -eq 16 ] || continue
  if [ -n "${{found:-}}" ] && [ ! "$helper" -nt "$found" ]; then continue; fi
  for python in "$bundle.env"/*/current/bin/python \
                "$bundle.env"/*/*/env-*/bin/python \
                "$bundle.env"/*/*/bin/python; do
    [ -x "$python" ] && [ -f "${{python%/bin/python}}/.ready" ] || continue
    if helper_ready "$python" "$helper"; then
      found="$helper"; chosen="$python"; break
    fi
  done
  if [ "$helper" != "${{found:-}}" ] && helper_ready python3 "$helper"; then
    found="$helper"; chosen=python3
  fi
done
if [ -n "${{found:-}}" ]; then exec "$chosen" -E -u "$found" {arguments}; fi
echo "no staged Albedo helper and usable Python found" >&2
exit 1
"""
    )


def staged_name(digest: str | None = None) -> str:
    """The bundle's directory under the remote home."""
    return f"{STAGED_DIR}/{(digest or albedo_bundle.digest())[:16]}"


def _shipped(info: tarfile.TarInfo) -> tarfile.TarInfo | None:
    """Sources only: no bytecode, and no tool cache (.ruff_cache, .mypy_cache)."""
    if info.name == "./package.nix":
        return None
    parts = info.name.split("/")
    skipped = any(p == "__pycache__" or p.startswith(".") and p != "." for p in parts)
    if skipped:
        return None
    if info.isdir():
        # Nix store directories are 0555. The remote owner must be able to
        # rename the extracted root and clean up a losing concurrent stage.
        info.mode |= 0o700
    return info


def archive() -> bytes:
    import tarfile  # staging a host is rare; not worth every kernel's boot

    with io.BytesIO() as data:
        with tarfile.open(fileobj=data, mode="w") as tar:
            tar.add(str(albedo_bundle.ROOT), arcname=".", filter=_shipped)
        return data.getvalue()


def stage_script(remote: str) -> str:
    """Unpack beside the target, then move into place, so a bundle directory
    that exists is always complete."""
    return (
        f'dest="{remote}"; '
        "parent=${dest%/*}; name=${dest##*/}; "
        'set -eu; mkdir -p "$parent"; tmp=$(mktemp -d "$dest.part.XXXXXX"); '
        # A losing publisher removes its own tree, read-only directories included.
        """trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT; mkdir "$tmp/$name"; """
        'tar -C "$tmp/$name" -xf -; '
        # Renaming a directory into another parent rewrites its "..", which
        # needs write access to that directory even when Nix shipped it read-only.
        'chmod u+w "$tmp/$name"; '
        'mv "$tmp/$name" "$parent/" 2>/dev/null || test -f "$dest/albedo_bridge.py"'
    )


def run(
    target: str, script: str, timeout: float, data: bytes | None = None
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [*base(target), target, script],
        input=data,
        stdin=None if data is not None else subprocess.DEVNULL,
        capture_output=True,
        timeout=timeout,
        env=env(target),
    )


def failure(stderr: str) -> tuple[Literal["needs_auth", "unreachable"], str]:
    """What ssh's own exit (255) means: a host we could reach with a person's
    help, or one we could not reach at all."""
    text = stderr.strip()
    lines = [line for line in text.splitlines() if line.strip()]
    detail = lines[-1] if lines else "ssh failed"
    lowered = text.lower()
    interactive = (
        "permission denied",
        "host key verification failed",
        "passphrase",
        "keyboard-interactive",
        "verification code",
        "too many authentication failures",
    )
    if any(phrase in lowered for phrase in interactive):
        return "needs_auth", detail
    return "unreachable", detail


def python_floor() -> tuple[int, int]:
    """The kernel project's inclusive major/minor floor also selects a fallback."""
    import tomllib

    with (albedo_bundle.ROOT / "pyproject.toml").open("rb") as project:
        requirement = tomllib.load(project)["project"]["requires-python"]
    match = re.fullmatch(r">=([0-9]+)\.([0-9]+)", requirement)
    if match is None:
        raise ValueError(
            f"expected an inclusive Python major/minor floor, got {requirement!r}"
        )
    return int(match[1]), int(match[2])


def supports_python(version: str, floor: tuple[int, int]) -> bool:
    parts = version.split(".")
    return (
        len(parts) == 2
        and all(p.isascii() and p.isdigit() for p in parts)
        and tuple(map(int, parts)) >= floor
    )


PROBE = (
    "uname -s; uname -m; printf '%s\\n' \"$HOME\"; "
    "getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1; "
    "if {directory}true; then "
    "{interpreter} -c 'import sys; print(\"%d.%d\" % sys.version_info[:2])' || echo none; "
    "else echo invalid-cwd; fi; "
    'test -f "$HOME/{bundle}/albedo_bridge.py" && echo staged || echo missing'
)


def probe(
    target: str,
    step: Callable[[str], None] = lambda _: None,
    candidate: str | None = None,
    *,
    remote_cwd: str | None = None,
) -> dict[str, object]:
    control, persist = multiplexing(target)
    answer: dict[str, object] = {
        "host": target,
        "argv": [*options(control, persist), target],
        "control": control,
    }
    bundle = staged_name()
    command = candidate if candidate is not None else "python3"
    interpreter = shlex.quote(command)
    directory = f"CDPATH= cd -- {shlex.quote(remote_cwd)} && " if remote_cwd else ""
    try:
        done = run(
            target,
            in_login_shell(
                PROBE.format(
                    bundle=bundle, interpreter=interpreter, directory=directory
                )
            ),
            PROBE_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return {**answer, "state": "unreachable", "detail": "ssh timed out"}
    except OSError as error:
        return {**answer, "state": "unreachable", "detail": f"ssh: {error}"}
    fields = done.stdout.decode(errors="replace").splitlines()
    if done.returncode == 255 or len(fields) != 6:
        state, detail = failure(done.stderr.decode(errors="replace"))
        return {**answer, "state": state, "detail": detail}
    system, arch, home, cpus, python, staged = (field.strip() for field in fields)
    answer.update(
        os=system,
        arch=arch,
        home=home,
        cpus=int(cpus) if cpus.isdigit() and int(cpus) > 0 else 1,
        python=python,
    )
    floor = python_floor()
    fallback = ".".join(map(str, floor))
    supported = supports_python(python, floor)
    if python == "invalid-cwd":
        stderr = done.stderr.decode(errors="replace").strip()[-500:]
        return {
            **answer,
            "state": "unsupported",
            "detail": f"cannot enter remote working directory {remote_cwd!r}: {stderr}",
        }
    if candidate is not None and not supported:
        stderr = done.stderr.decode(errors="replace").strip()[-500:]
        if python == "none":
            detail = stderr or "no Python version returned"
        else:
            detail = f"found Python {python}; need Python {fallback} or newer"
        return {
            **answer,
            "state": "unsupported",
            "detail": f"requested remote Python {candidate!r}: {detail}",
        }
    if staged != "staged":
        step("staging")
        try:
            staging = run(
                target,
                in_login_shell(stage_script(f"$HOME/{bundle}")),
                STAGE_TIMEOUT,
                archive(),
            )
        except subprocess.TimeoutExpired:
            return {**answer, "state": "unreachable", "detail": "staging timed out"}
        except OSError as error:
            return {**answer, "state": "unreachable", "detail": f"staging: {error}"}
        if staging.returncode != 0:
            detail = staging.stderr.decode(errors="replace").strip()[-500:]
            return {
                **answer,
                "state": "unreachable",
                "detail": f"staging failed: {detail}",
            }
    root = f"{home}/{bundle}"
    current = selector(root, command, remote_cwd)
    source = "host" if supported else "managed"
    setup = shlex.join([f"{root}/albedo_remote_env.py", current, source])
    if supported:
        check = f"{directory}{interpreter} {setup}"
    else:
        cached = shlex.quote(current)
        check = (
            f"if envdir=$(CDPATH= cd -P {cached} 2>/dev/null && pwd -P); then "
            f'"$envdir/bin/python" -E {setup} 2>/dev/null || echo cold; else echo cold; fi'
        )
    try:
        prepared = run(target, in_login_shell(check), PROBE_TIMEOUT)
        if prepared.stdout.strip() == b"cold" and prepared.returncode == 0:
            step("staging")
            tool = shlex.quote(albedo_uv.ensure_uv(target, system, arch, home))
            if not supported:
                interpreter = (
                    f"export UV_PYTHON_INSTALL_DIR={shlex.quote(home + '/' + STAGED_DIR + '/python')}; "
                    f"{tool} --no-config python install --no-bin {fallback} >&2 && "
                    f'py=$({tool} --no-config python find --managed-python {fallback}) && "$py"'
                )
            prepared = run(
                target,
                in_login_shell(f"{directory}{interpreter} {setup} {tool}"),
                ENV_TIMEOUT,
            )
        if prepared.returncode == 255:
            state, detail = failure(prepared.stderr.decode(errors="replace"))
            return {**answer, "state": state, "detail": detail}
        executable = prepared.stdout.decode().strip()
        if prepared.returncode or not executable.startswith("/"):
            detail = prepared.stderr.decode(errors="replace").strip()[-1600:]
            if not detail:
                detail = (
                    f"preparation exited with status {prepared.returncode}"
                    if prepared.returncode
                    else "preparation returned no interpreter path"
                )
            return {
                **answer,
                "state": "unsupported",
                "detail": f"kernel environment: {detail}",
            }
        answer.update(
            _commands(target, home, bundle=root, executable=executable),
            executable=executable,
            python=python if supported else fallback,
        )
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        return {**answer, "state": "unsupported", "detail": str(error)}
    return {**answer, "state": "ready", "detail": ""}


def _read_lines(path: str) -> list[str]:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()
    except OSError:
        return []


def known_hosts(ssh_dir: str | None = None) -> list[str]:
    """Plain hostnames in ~/.ssh/known_hosts(2), skipping hashed entries,
    markers, wildcards and raw IP addresses."""
    base_dir = ssh_dir or os.path.expanduser("~/.ssh")
    names: list[str] = []
    for filename in ("known_hosts", "known_hosts2"):
        for line in _read_lines(os.path.join(base_dir, filename)):
            stripped = line.strip()
            if not stripped or stripped.startswith(("#", "@")):
                continue
            for token in stripped.split(None, 1)[0].split(","):
                if (
                    not token
                    or not token[0].isalnum()
                    or any(c in token for c in "*?!:/")
                    or re.fullmatch(r"\d+(?:\.\d+){3}", token)
                ):
                    continue
                names.append(token)
    return list(dict.fromkeys(names))


def config_hosts(path: str | None = None, seen: set[str] | None = None) -> list[str]:
    """`Host` names in ~/.ssh/config (and its includes) followed by plain
    hostnames from ~/.ssh/known_hosts, in order, without patterns."""
    top = seen is None and path is None
    path = path or os.path.expanduser("~/.ssh/config")
    seen = set() if seen is None else seen
    if path in seen:
        return []
    seen.add(path)
    lines = _read_lines(path)
    names: list[str] = []
    for line in lines:
        words = shlex.split(line, comments=True) if line.strip() else []
        if len(words) < 2:
            continue
        keyword = words[0].lower()
        if keyword == "host":
            names += [w for w in words[1:] if not any(c in w for c in "*?!")]
        elif keyword == "include":
            for pattern in words[1:]:
                pattern = os.path.expanduser(pattern)
                if not os.path.isabs(pattern):
                    pattern = os.path.join(os.path.expanduser("~/.ssh"), pattern)
                for included in sorted(glob.glob(pattern)):
                    names += config_hosts(included, seen)
    if top:
        names += known_hosts(os.path.dirname(path))
    return list(dict.fromkeys(names))


def announce(step: str) -> None:
    print(json.dumps({"step": step}), flush=True)


def fetch_snapshot(target: str, source: str, archive: str, digest: str) -> None:
    """Copy the original from an SSH kernel before retiring its run directory."""
    if re.fullmatch("[0-9a-f]{64}", digest) is None:
        raise ValueError("invalid snapshot digest")
    original = os.path.join(source + ".originals", digest + ".state")
    os.makedirs(archive, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=archive, prefix=".copy-")
    try:
        with os.fdopen(fd, "w+b") as out:
            subprocess.run(
                [*base(target), target, "cat < " + shlex.quote(original)],
                stdin=subprocess.DEVNULL,
                stdout=out,
                check=True,
                timeout=STAGE_TIMEOUT,
                env=env(target),
            )
            out.seek(0)
            if hashlib.file_digest(out, "sha256").hexdigest() != digest:
                raise ValueError("incomplete or changed remote snapshot")
        os.replace(temporary, os.path.join(archive, digest + ".state"))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv: list[str]) -> int:
    if len(argv) == 6 and argv[1] == "fetch-snapshot":
        fetch_snapshot(argv[2], argv[3], argv[4], argv[5])
        return 0
    if len(argv) == 3 and argv[1] == "probe":
        print(json.dumps(probe(argv[2], announce)))
        return 0
    if len(argv) == 2 and argv[1] == "hosts":
        print(json.dumps(config_hosts()))
        return 0
    if len(argv) in (4, 5) and argv[1] == "commands":
        print(json.dumps(commands(*argv[2:])))
        return 0
    print(
        "usage: albedo_ssh.py probe <[user@]host> | commands <[user@]host> <home>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
