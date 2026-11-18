"""Argv-only routing for the verified RTK 0.50 CLI surface.

No shell strings, rewrite subprocess, fallback execution, or startup probing.
Explicit executable paths retain their identity: RTK resolves tools by basename.
Only stdin-preserving filters accept a supplied stdin. Internal supervised work
uses albedo_plugins.run.start, not the model-facing run entry point.
"""

import os
import shutil

# RTK src/main.rs trailing_var_arg CLI and the corresponding single-run handlers.
# Global options / toolchain selectors are deliberately outside this grammar.
SUBCOMMANDS = {
    "cargo": frozenset({"build", "test", "check", "clippy", "install", "nextest"}),
    "go": frozenset({"build", "test", "vet"}),
    "git": frozenset(
        {
            "diff",
            "log",
            "status",
            "show",
            "add",
            "commit",
            "checkout",
            "push",
            "pull",
            "branch",
            "fetch",
            "worktree",
        }
    ),
}


def supported(argv: list[str], *, stdin: bool = False) -> bool:
    """Whether RTK can preserve this invocation's executable and input semantics."""
    program, *args = argv
    if program == "rtk" or os.path.basename(program) != program:
        return False
    # RTK clap owns these options; do not substitute its help/global behavior
    # for native command behavior. Literal values with these spellings stay raw.
    if any(
        arg in {"--ultra-compact", "--skip-env", "--help", "-h", "--version", "-V"}
        for arg in args
    ):
        return False
    # Structured/machine outputs are protocol, not human display material.
    if any(
        arg in {"--json", "--null", "-0", "-z", "--null-data"}
        or arg.startswith(("--message-format", "--porcelain"))
        for arg in args
    ):
        return False
    if program == "ls":
        # ls.rs regroups flags before paths and adds -l; flags with values or
        # dash-prefixed operands cannot safely pass through this transformation.
        flags = {"-l", "-a", "-A", "-la", "-al", "-lah", "-alh", "-lA"}
        return not stdin and all(
            not arg.startswith("-") or arg in flags for arg in args
        )
    if program == "pytest":
        # pytest_cmd.rs adds -q/--tb=short/-rxX, then cmd.arg forwards arguments.
        # Unlike cargo/search, it does not restore clap's consumed delimiter.
        return not stdin and "--" not in args
    if program == "rg":
        # src/cmds/system/search.rs preserves flags, delimiters and readable stdin.
        return bool(args)
    if program == "wc":
        # wc's RTK stdin detector misclassifies the literal '-' operand and
        # value-taking flags; limit this mapping to verified count flags/files.
        if "-" in args:
            return False
        flags = {
            "-l",
            "-w",
            "-c",
            "-m",
            "-L",
            "--lines",
            "--words",
            "--bytes",
            "--chars",
            "--max-line-length",
            "--",
        }
        return all(not arg.startswith("-") or arg in flags for arg in args)
    if stdin:
        return False
    return bool(args) and args[0] in SUBCOMMANDS.get(program, ())


def route(
    argv: list[str], env: dict[str, str] | None, *, stdin: bool = False
) -> list[str]:
    if not supported(argv, stdin=stdin):
        return list(argv)
    executable = shutil.which(
        "rtk", path=(os.environ if env is None else env).get("PATH", os.defpath)
    )
    if executable is None:
        raise FileNotFoundError(
            f"rtk is required for {argv[0]} on this execution host; install RTK or provide its PATH (no native fallback)"
        )
    return [executable, *argv]
