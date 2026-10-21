# Explicit file checks

Formatting is optional and disabled until configured with
`programs.albedo.formatter.enable` and `programs.albedo.formatter.settings`.
No formatter commands are supplied by default. This is a temporary compatibility
layer; see the [retirement notes](development.md#temporary-compatibility-layers).

## Workflow

Successful local `files.write()` and `files.edit()` calls track paths without
running a formatter or starting a language server. After completing edits and
any manual formatter runs, call:

```python
result = await files.check()
```

This formats the pending scope, publishes successful changes, then collects
configured LSP diagnostics in the **same call**. Formatting changes are ordinary
results, not rejected final answers. Review changes and findings; after further
edits, check again. Errors and conflicts are normal tool results with pending
paths retained. Final text streams normally: no synthetic user messages,
regeneration loop, hidden checks or retry cap.

For shell-written files or a selected subset, supply local workspace paths:

```python
result = await files.check(paths=["module.nix", "script.py"])
```

Explicit paths enroll current files and leave other pending paths untouched.
Without paths, only already-pending files are selected; unrelated dirty files
are never enrolled. Each call deliberately adopts current disk snapshots,
including completed external formatter changes, and reports reconciled paths.
It does not claim that earlier tracked bytes were checked. Changes during the
batch are conflicts: checked snapshots are revalidated after diagnostics, and
conflicting paths remain pending without overwriting concurrent edits.

Results distinguish checked, unmatched, disabled, idle, failed and skipped
stages. `clean` is unknown when nothing was checked; findings are untrusted
workspace data, not instructions. Formatter failure skips diagnostics rather
than claiming an unsettled snapshot is clean. Unrelated running jobs do not
silently suppress explicit checks. Concurrent batches are serialized.

This is explicit verification, not enforcement: the model must call it after
its last edit and disclose incomplete checks. Neither final replies nor native
Stop hooks perform validation. Direct `lsp.diagnostics()` remains available and
does not consume pending batch work. Remote checks are unsupported.

## Formatting and safety

Project treefmt configuration takes precedence, then configured `nix fmt`, then
suffix chains. Project targets use one sparse shadow workspace per batch with
original relative paths. Target-ancestor directories and selected files are real
staged copies; sibling context is linked rather than recursively copied.
Treefmt receives the shadow root explicitly. Nix evaluates the original flake
and passes shadow targets with subprocess-only `TREEFMT_WORKING_DIR`, including
support for treefmt-nix `--tree-root-file=flake.nix` wrappers. Wrappers hardcoding
the original root or ignoring explicit target paths are incompatible.

Commands must respect supplied paths: staging is not a sandbox. Only selected
files can be published. Publishing checks file contents and identity, preserves
mode and uses atomic replacement. Symlink replacements, outside-workspace paths
and concurrent edits are refused. Successful exclusions and already formatted
files are valid no-ops. Cancellation kills formatter process groups and leaves
uncompleted validation pending.

## Limits and tests

Tracking is kernel-local and does not survive restart. Each tracker and batch
is limited to 1024 paths; files must be regular and at most 16 MiB. LSP may have
stricter file-size limits. Tracking overflow is an explicit failure, not evidence
that all edits were checked; restart the kernel and supply the affected paths
explicitly in bounded batches to recover. Capacity rejection before enrollment
does not alter tracking. Shadow context is bounded to 20,000 immediate entries
along selected ancestors; dependency subtrees are linked, not traversed.
Formatter commands and LSP checks each have bounded time and output budgets.

`test/files_check_test.py` checks adoption, stage order, scope, cancellation,
capacity and multi-file conflicts. `test/formatter_python_test.py` retains real
treefmt/Nix, process cleanup and staged-publish regressions.
`test/formatter_e2e_test.py` checks explicit failures/repair, ordinary live final
streaming under both protocols, native Stop behavior and disabled formatting.
Tests use isolated homes, fake providers and local fixtures, not live accounts.
