#!/usr/bin/env python3
"""Stage a pinned NUR update and merge the sparse overlay without touching conflicts."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(root):
    return sorted(
        p.relative_to(root).as_posix()
        for p in root.rglob("*")
        if (not p.is_dir() or p.is_symlink())
        and "__pycache__" not in p.relative_to(root).parts
        and p.suffix != ".pyc"
    )


def regular(path):
    return path.is_file() and not any(p.is_symlink() for p in (path, *path.parents))


def merge_overlay(suite, old, new):
    """Plan every replacement before writing anything. Return writes and diagnostics."""
    writes, merged, unresolved, manifests = {}, [], [], {}
    for component in ("server", "client"):
        overlay = suite / "src" / component
        baseline = {}
        for line in (
            (suite / "upstream" / f"{component}.sha256").read_text().splitlines()
        ):
            checksum, name = line.split("  ", 1)
            if name.startswith("/") or ".." in Path(name).parts:
                raise ValueError(f"unsafe baseline path: {name}")
            baseline[name] = checksum
        names = files(overlay)
        for name in sorted(set(baseline) - set(names)):
            unresolved.append(f"{component}/{name}: baseline has no suite replacement")
        hashes = []
        for name in names:
            ours, base, theirs = overlay / name, old / name, new / name
            label = f"{component}/{name}"
            if not regular(ours):
                unresolved.append(
                    f"{label}: suite symlink or non-regular file needs review"
                )
                continue
            if name not in baseline:
                if base.exists() or base.is_symlink():
                    unresolved.append(
                        f"{label}: missing old baseline; refusing to bless drift"
                    )
                elif (
                    theirs.exists()
                    or theirs.is_symlink()
                    or any(
                        p.is_symlink() or (p.exists() and not p.is_dir())
                        for p in theirs.parents
                        if p != new.parent
                    )
                ):
                    unresolved.append(
                        f"{label}: upstream collides with suite-only addition"
                    )
                continue
            if not regular(base) or digest(base) != baseline[name]:
                unresolved.append(f"{label}: old pristine baseline mismatch")
                continue
            if not regular(theirs):
                unresolved.append(
                    f"{label}: upstream deletion, rename or type change; review destination/API"
                )
                continue
            if (base.stat().st_mode & 0o111) != (theirs.stat().st_mode & 0o111):
                unresolved.append(f"{label}: upstream executable mode change")
                continue
            hashes.append(f"{digest(theirs)}  {name}\n")
            if base.read_bytes() == theirs.read_bytes():
                continue
            if any(b"\0" in p.read_bytes() for p in (base, ours, theirs)):
                unresolved.append(f"{label}: binary change requires review")
                continue
            result = subprocess.run(
                ["git", "merge-file", "-p", str(ours), str(base), str(theirs)],
                capture_output=True,
                check=False,
            )
            if result.returncode:
                unresolved.append(
                    f"{label}: overlapping three-way conflict ({result.returncode}); compare old/ours/candidate"
                )
            else:
                writes[ours] = result.stdout
                merged.append(label)
        manifests[suite / "upstream" / f"{component}.sha256"] = "".join(hashes).encode()
    return writes | manifests, merged, unresolved


def source_expr(root):
    # Evaluate the unmodified NUR package, bypassing only the suite pin assertion.
    return f"""let f = builtins.getFlake {json.dumps(str(root))};
      system = builtins.currentSystem;
      pkgs = import f.inputs.nixpkgs {{ inherit system; }};
      p = (import f.inputs.nur {{ inherit pkgs; nurpkgs = pkgs; }}).repos.adam0.albedo-git;
      in p.src"""


def source(root):
    expr = source_expr(root)
    identity = json.loads(
        run(
            "nix",
            "eval",
            "--impure",
            "--json",
            "--expr",
            f"let s = {expr}; in {{ rev = s.rev; narHash = s.outputHash; }}",
        )
    )
    if not re.fullmatch("[0-9a-f]{40}", identity["rev"]):
        raise ValueError("NUR must select an exact 40-character Albedo revision")
    path = Path(
        run(
            "nix", "build", "--impure", "--no-link", "--print-out-paths", "--expr", expr
        )
    )
    actual = run("nix", "hash", "path", str(path))
    if actual != identity["narHash"]:
        raise ValueError("realized source NAR hash differs from pinned NUR source")
    return identity, path


def check_lock(old, new):
    if {k: v for k, v in old["nodes"].items() if k != "nur"} != {
        k: v for k, v in new["nodes"].items() if k != "nur"
    } or old["nodes"]["nur"]["inputs"] != new["nodes"]["nur"]["inputs"]:
        raise ValueError("NUR update changed unrelated lock nodes or input wiring")


def apply(writes):
    """Rollback all files if applying the fully resolved plan fails."""
    saved = {p: p.read_bytes() for p in writes}
    try:
        for path, content in writes.items():
            path.write_bytes(content)
    except BaseException:
        for path, content in saved.items():
            path.write_bytes(content)
        raise


def update(root, nur_rev, report):
    report = report.resolve()
    if report.is_relative_to(root.resolve()):
        raise ValueError("report must be outside the checkout")
    if (root / ".jj").exists():
        dirty = run("jj", "diff", "--summary", cwd=root)
    else:
        dirty = run(
            "git", "status", "--porcelain", "--untracked-files=normal", cwd=root
        )
    if dirty:
        raise ValueError("working copy must be clean; preserve existing changes first")
    pin = json.loads((root / "upstream/pin.json").read_text())
    old_lock = json.loads((root / "flake.lock").read_text())
    old_identity, old_source = source(root)
    if any(pin[k] != old_identity[k] for k in ("rev", "narHash")):
        raise ValueError("current pin does not match locked NUR source")
    with tempfile.TemporaryDirectory(prefix="albedo-update-") as temporary:
        stage = Path(temporary) / "suite"
        shutil.copytree(
            root,
            stage,
            ignore=shutil.ignore_patterns(
                ".git", ".jj", ".workspaces", ".direnv", "result*", "__pycache__"
            ),
        )
        if nur_rev:
            if not re.fullmatch("[0-9a-f]{40}", nur_rev):
                raise ValueError("--nur-rev must be an exact NUR commit SHA")
            run(
                "nix",
                "flake",
                "lock",
                "--override-input",
                "nur",
                f"github:nix-community/NUR/{nur_rev}",
                cwd=stage,
            )
        else:
            run("nix", "flake", "update", "nur", cwd=stage)
        new_lock = json.loads((stage / "flake.lock").read_text())
        check_lock(old_lock, new_lock)
        # Keep the original input URL for subsequent updates.
        new_lock["nodes"]["nur"]["original"] = old_lock["nodes"]["nur"]["original"]
        (stage / "flake.lock").write_text(json.dumps(new_lock, indent=2) + "\n")
        identity, candidate = source(stage)
        summary = {
            "oldAlbedo": old_identity,
            "candidateAlbedo": identity,
            "oldNur": old_lock["nodes"]["nur"]["locked"]["rev"],
            "candidateNur": new_lock["nodes"]["nur"]["locked"]["rev"],
            "merged": [],
            "unresolved": [],
            "status": "no-change",
        }
        if identity != old_identity:
            writes, summary["merged"], summary["unresolved"] = merge_overlay(
                root, old_source, candidate
            )
            if summary["unresolved"]:
                summary["status"] = "review-required"
            else:
                new_pin = pin | identity
                # This existing inventory lists server overlay paths, including suite additions.
                new_pin["sourceFiles"] = files(root / "src/server")
                writes[root / "upstream/pin.json"] = (
                    json.dumps(new_pin, indent=2) + "\n"
                ).encode()
                writes[root / "flake.lock"] = (
                    json.dumps(new_lock, indent=2) + "\n"
                ).encode()
                apply(writes)
                summary["status"] = "updated"
        report.write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
        return 2 if summary["unresolved"] else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nur-rev", help="exact NUR commit; default resolves NUR once")
    parser.add_argument(
        "--report", type=Path, default=Path("/tmp/albedo-upstream-update.json")
    )
    args = parser.parse_args()
    try:
        return update(ROOT, args.nur_rev, args.report.resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        if not args.report.resolve().is_relative_to(ROOT.resolve()):
            args.report.write_text(
                json.dumps({"status": "error", "error": str(error)}, indent=2) + "\n"
            )
        print(f"upstream update failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
