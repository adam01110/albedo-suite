#!/usr/bin/env python3
"""Stage a pinned NUR update and merge the sparse overlay.

Conflicts are never written unless --apply-conflicts is given; then every other
step of the update is applied and the conflicted files carry diff3 markers.
"""

import argparse
import collections
import difflib
import filecmp
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


def merge_overlay(suite, old, new, details=None):
    """Plan every replacement before writing anything. Return writes and diagnostics.

    When given, details collects diff3 text for conflicts and replacements whose
    merged bytes equal the candidate upstream file (retirement candidates).
    """
    writes, merged, unresolved, manifests = {}, [], [], {}
    details = {} if details is None else details
    conflicts = details.setdefault("conflicts", {})
    no_delta = details.setdefault("noDelta", [])
    deleted = details.setdefault("deleted", [])
    # Suite files whose upstream path vanished or now collides: path -> reference.
    set_aside = details.setdefault("setAside", {})
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
                    if regular(theirs):
                        set_aside[ours] = theirs
                continue
            if not regular(base) or digest(base) != baseline[name]:
                unresolved.append(f"{label}: old pristine baseline mismatch")
                continue
            if not regular(theirs):
                unresolved.append(
                    f"{label}: upstream deletion, rename or type change; review destination/API"
                )
                deleted.append((label, base))
                if not (theirs.exists() or theirs.is_symlink()):
                    set_aside[ours] = base
                continue
            if (base.stat().st_mode & 0o111) != (theirs.stat().st_mode & 0o111):
                unresolved.append(f"{label}: upstream executable mode change")
                continue
            hashes.append(f"{digest(theirs)}  {name}\n")
            if base.read_bytes() == theirs.read_bytes():
                if ours.read_bytes() == theirs.read_bytes():
                    no_delta.append(label)
                continue
            if any(b"\0" in p.read_bytes() for p in (base, ours, theirs)):
                unresolved.append(f"{label}: binary change requires review")
                continue
            result = subprocess.run(
                [
                    "git",
                    "merge-file",
                    "-p",
                    "--diff3",
                    *("-L", "suite", "-L", "old-upstream", "-L", "new-upstream"),
                    str(ours),
                    str(base),
                    str(theirs),
                ],
                capture_output=True,
                check=False,
            )
            if result.returncode:
                unresolved.append(
                    f"{label}: overlapping three-way conflict ({result.returncode}); compare old/ours/candidate"
                )
                if result.returncode > 0:
                    conflicts[ours] = result.stdout
            else:
                writes[ours] = result.stdout
                merged.append(label)
                if result.stdout == theirs.read_bytes():
                    no_delta.append(label)
        manifests[suite / "upstream" / f"{component}.sha256"] = "".join(hashes).encode()
    return writes | manifests, merged, unresolved


def upstream_changes(old, new):
    """Paths added, removed or modified between two pristine sources."""
    before, after = set(files(old)), set(files(new))
    modified = [
        name
        for name in sorted(before & after)
        if (old / name).is_symlink()
        or (new / name).is_symlink()
        or not filecmp.cmp(old / name, new / name, shallow=False)
    ]
    return {
        "added": sorted(after - before),
        "removed": sorted(before - after),
        "modified": modified,
    }


IDENTIFIER = re.compile(rb"[A-Za-z_][A-Za-z0-9_]{6,}")
SOURCE_SUFFIXES = {".erl", ".gleam", ".go", ".mjs", ".py", ".rs", ".ts"}


def rename_hints(deleted, new, limit=3, rare=20):
    """Rank candidate files by the share of a deleted file's rare identifiers they
    contain. Works across Erlang-to-Gleam ports where line similarity fails."""
    tokens = {
        name: set(IDENTIFIER.findall((new / name).read_bytes()))
        for name in files(new)
        if Path(name).suffix in SOURCE_SUFFIXES and regular(new / name)
    }
    frequency = collections.Counter(t for found in tokens.values() for t in found)
    hints = {}
    for label, base in deleted:
        wanted = {
            t for t in IDENTIFIER.findall(base.read_bytes()) if frequency[t] <= rare
        }
        if not wanted:
            continue
        ranked = sorted(
            ((len(wanted & found) / len(wanted), name) for name, found in tokens.items()),
            reverse=True,
        )
        hints[label] = [[round(score, 2), name] for score, name in ranked[:limit] if score]
    return hints


def port_patch(reference, ours, label):
    """The suite delta still to port, as a unified diff from its reference."""
    return "".join(
        difflib.unified_diff(
            reference.read_text(errors="replace").splitlines(keepends=True),
            ours.read_text(errors="replace").splitlines(keepends=True),
            f"upstream/{label}",
            f"suite/{label}",
        )
    )


def write_review(directory, conflicts, root, changes, set_aside=None):
    """Write conflict merges, set-aside suite files with their port patches, and
    the upstream change list outside the checkout."""
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    for ours, reference in (set_aside or {}).items():
        name = ours.relative_to(root)
        target = directory / "set-aside" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ours, target)
        Path(f"{target}.patch").write_text(port_patch(reference, ours, name.as_posix()))
    for path, content in conflicts.items():
        target = directory / path.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    (directory / "upstream-changes.txt").write_text(
        "".join(
            f"{kind[0].upper()} {name}\n"
            for kind in ("added", "removed", "modified")
            for name in changes[kind]
        )
    )


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
    """Rollback all files if applying the fully resolved plan fails.

    A None content deletes the file."""
    saved = {p: p.read_bytes() for p in writes if p.exists()}
    try:
        for path, content in writes.items():
            if content is None:
                path.unlink()
            else:
                path.write_bytes(content)
    except BaseException:
        for path in writes:
            if path not in saved:
                path.unlink(missing_ok=True)
        for path, content in saved.items():
            path.write_bytes(content)
        raise


def sync_manifests(root):
    """Rewrite both manifests and the server inventory for the current overlay,
    hashing pristine files of the already pinned source. Run after porting a
    suite change into another upstream file or retiring a replacement."""
    pin = json.loads((root / "upstream/pin.json").read_text())
    identity, pristine = source(root)
    if any(pin[k] != identity[k] for k in ("rev", "narHash")):
        raise ValueError("current pin does not match locked NUR source")
    writes = {}
    for component in ("server", "client"):
        writes[root / "upstream" / f"{component}.sha256"] = "".join(
            f"{digest(pristine / name)}  {name}\n"
            for name in files(root / "src" / component)
            if regular(pristine / name)
        ).encode()
    writes[root / "upstream/pin.json"] = (
        json.dumps(pin | {"sourceFiles": files(root / "src/server")}, indent=2) + "\n"
    ).encode()
    apply(writes)
    return 0


def update(root, nur_rev, report, apply_conflicts=False):
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
            details = {}
            writes, summary["merged"], summary["unresolved"] = merge_overlay(
                root, old_source, candidate, details
            )
            conflicts, set_aside = details["conflicts"], details["setAside"]
            changes = upstream_changes(old_source, candidate)
            review = report.parent / (report.stem + "-review")
            write_review(review, conflicts, root, changes, set_aside)
            summary |= {
                "oldSource": str(old_source),
                "candidateSource": str(candidate),
                "review": str(review),
                "conflicts": [str(p.relative_to(root)) for p in conflicts],
                "setAside": [str(p.relative_to(root)) for p in set_aside],
                "noDelta": details["noDelta"],
                "renameHints": rename_hints(details["deleted"], candidate),
                "upstreamChanges": {k: len(v) for k, v in changes.items()},
            }
            # Text conflicts are finished in place and vanished or colliding
            # replacements are set aside; any other reason needs review first.
            in_place = apply_conflicts and len(conflicts) + len(set_aside) == len(
                summary["unresolved"]
            )
            if in_place:
                writes |= dict.fromkeys(set_aside)
            if summary["unresolved"] and not in_place:
                summary["status"] = "review-required"
            else:
                new_pin = pin | identity
                # This existing inventory lists server overlay paths, including suite additions.
                new_pin["sourceFiles"] = [
                    name
                    for name in files(root / "src/server")
                    if root / "src/server" / name not in set_aside
                ]
                writes[root / "upstream/pin.json"] = (
                    json.dumps(new_pin, indent=2) + "\n"
                ).encode()
                writes[root / "flake.lock"] = (
                    json.dumps(new_lock, indent=2) + "\n"
                ).encode()
                apply(writes | conflicts)
                summary["status"] = (
                    "conflicts-written" if conflicts or set_aside else "updated"
                )
        report.write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
        return 2 if summary["unresolved"] else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nur-rev", help="exact NUR commit; default resolves NUR once")
    parser.add_argument(
        "--report", type=Path, default=Path("/tmp/albedo-upstream-update.json")
    )
    parser.add_argument(
        "--apply-conflicts",
        action="store_true",
        help="apply the update and leave diff3 markers in text-conflicted files",
    )
    parser.add_argument(
        "--sync-manifests",
        action="store_true",
        help="only rewrite baselines and inventory for the current overlay",
    )
    args = parser.parse_args()
    try:
        if args.sync_manifests:
            return sync_manifests(ROOT)
        return update(
            ROOT, args.nur_rev, args.report.resolve(), args.apply_conflicts
        )
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        if not args.report.resolve().is_relative_to(ROOT.resolve()):
            args.report.write_text(
                json.dumps({"status": "error", "error": str(error)}, indent=2) + "\n"
            )
        print(f"upstream update failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
