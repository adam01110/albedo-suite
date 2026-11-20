"""Calibrate the discovery properties: plant defects, confirm each is caught.

Every mutation is applied to a throwaway copy of src/server/python, so the
worktree is never modified. Run the harness under a python with hypothesis:

  PYTHONPATH=<hypothesis...> python3.14 test/proptest/calibrate.py

A mutation row is "caught" when the targeted property test class fails. The known
finding (IdleBookkeepingTests) is already red on the unmutated base because its
fix lives on a separate change, so the control run uses SnapshotPositionTests;
merging that fix turns the whole suite green.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SOURCE = REPO / "src/server/python"
MODULES = ("albedo_lsp.py", "albedo_formatter.py", "albedo_rtk.py")

MUTATIONS = [
    (
        "SnapshotPositionTests",
        "lsp: count every character as one UTF-16 unit",
        "albedo_lsp.py",
        "units += 2 if ord(ch) > 0xFFFF else 1",
        "units += 1",
    ),
    (
        "SnapshotPositionTests",
        "lsp: accept a position inside a surrogate pair",
        "albedo_lsp.py",
        "if character != 0 and character != units:",
        "if character > units:",
    ),
    (
        "ValidateTests",
        "lsp: skip rootMarkers traversal rejection",
        "albedo_lsp.py",
        'Path(v).is_absolute() or ".." in Path(v).parts',
        "Path(v).is_absolute()",
    ),
    (
        "ValidateTests",
        "lsp: return the caller's own server dicts",
        "albedo_lsp.py",
        "servers = json.loads(_json(servers))",
        "servers = list(servers)",
    ),
    (
        "SyncTests",
        "lsp: bump the version for unchanged text",
        "albedo_lsp.py",
        "if previous and previous[1] == digest:",
        "if False and previous and previous[1] == digest:",
    ),
    (
        "SyncTests",
        "lsp: never evict beyond the document window",
        "albedo_lsp.py",
        "if not previous and len(self.docs) >= 32:",
        "if False:",
    ),
    (
        "FormatterSnapshotTests",
        "formatter: copy project context instead of linking it",
        "albedo_formatter.py",
        "target.symlink_to(source)",
        "target.write_bytes(source.read_bytes())",
    ),
    (
        "FormatterCommandTests",
        "formatter: ignore treefmt.toml on the search path",
        "albedo_formatter.py",
        'for name in ("treefmt.toml", ".treefmt.toml"):',
        'for name in (".treefmt.toml",):',
    ),
    (
        "FormatterFinishTests",
        "formatter: publish past a stale postimage",
        "albedo_formatter.py",
        "                        if current != expected:\n                            raise ValueError(",
        "                        if False:\n                            raise ValueError(",
    ),
    (
        "MissingFormatterTests",
        "formatter: match any nix error as a missing formatter",
        "albedo_formatter.py",
        'r"error: flake \'[^\\n]+\' does not provide attribute "',
        'r".*"',
    ),
    (
        "FinishBookkeepingTests",
        "lsp: classify every selected path as unmatched",
        "albedo_lsp.py",
        "(checked if servers else unmatched).append(str(path))",
        "unmatched.append(str(path))",
    ),
    (
        "FormatterAdoptTests",
        "formatter: ignore adopt=True and refuse an edited postimage",
        "albedo_formatter.py",
        "                if adopt:",
        "                if False:",
    ),
    (
        "FormatterReadRaceTests",
        "formatter: accept a file that changed while reading",
        "albedo_formatter.py",
        "or identity(after) != identity(path.stat())",
        "or False",
    ),
    (
        "RecordScopeTests",
        "lsp: resolve a recorded path against the workspace",
        "albedo_lsp.py",
        "        path = Path(os.path.abspath(Path(path).expanduser()))",
        "        path = Path(os.path.abspath(self.cwd / Path(path).expanduser()))",
    ),
    (
        "FormatterRecordScopeTests",
        "formatter: resolve a recorded path against the workspace",
        "albedo_formatter.py",
        "    target = Path(os.path.abspath(Path(path).expanduser()))",
        "    target = Path(os.path.abspath(_root / Path(path).expanduser()))",
    ),
    (
        "RtkRoutingTests",
        "rtk: allow --json through the router",
        "albedo_rtk.py",
        'arg in {"--json", "--null", "-0", "-z", "--null-data"}',
        'arg in {"--null", "-0", "-z", "--null-data"}',
    ),
    (
        "RtkRoutingTests",
        "rtk: route a program that consumes stdin",
        "albedo_rtk.py",
        "    if stdin:\n        return False",
        "    if False:\n        return False",
    ),
]


def run_harness(source: Path, pattern: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(HERE / "py_lsp_formatter_rtk.py"), "-k", pattern],
        env={**os.environ, "ALBEDO_PY_SOURCE": str(source), "PROPTEST_EXAMPLES": "200"},
        capture_output=True,
        text=True,
        timeout=900,
    )


def main() -> int:
    failures = 0
    with tempfile.TemporaryDirectory(prefix="calibrate-") as directory:
        pristine = Path(directory) / "pristine"
        pristine.mkdir()
        for name in MODULES:
            shutil.copy2(SOURCE / name, pristine / name)
        for index, (pattern, description, module, old, new) in enumerate(MUTATIONS):
            target = Path(directory) / f"mutation{index}"
            target.mkdir()
            for name in MODULES:
                shutil.copy2(pristine / name, target / name)
            text = (target / module).read_text()
            if old not in text:
                print(f"SKIP  {description}: mutation site not found in {module}")
                failures += 1
                continue
            (target / module).write_text(text.replace(old, new, 1))
            result = run_harness(target, pattern)
            # unittest exits 5 when the filter matched nothing, which must not
            # look like a caught defect.
            caught = result.returncode not in (0, 5)
            print(f"{'CAUGHT' if caught else 'MISSED'} {description} ({pattern}) exit={result.returncode}")
            if not caught:
                failures += 1
                print(result.stdout[-2000:], result.stderr[-2000:])
        control = run_harness(pristine, "SnapshotPositionTests")
        print(f"{'PASS' if control.returncode == 0 else 'FAIL'}  control: unmutated sources")
        if control.returncode != 0:
            failures += 1
            print(control.stdout[-2000:])
    print(f"\n{len(MUTATIONS)} mutations, {failures} unexpected results")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
