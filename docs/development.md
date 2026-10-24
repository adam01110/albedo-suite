# Development

## Source files

`src/server/` and `src/client/` use the same paths as upstream. They contain the
files the suite replaces and the files it adds. Edit them as ordinary Gleam,
Erlang, Python and Go source.

`nix/modules/packages.nix` uses the locked NUR package definitions. It checks the
source hash in `upstream/pin.json` and the original files in
`upstream/*.sha256`. It then copies the suite files before NUR's existing
post-patch hooks run. Upstream dependencies, patches and build checks remain
in use.

## Updating upstream

Compare each replacement with its old upstream version to identify the suite's
changes. Then compare old and new upstream versions to identify upstream changes
that the replacement must retain.

Merge both sets of changes before updating the pin and checksums. Do not change
a checksum merely to make a failing check pass. New files have no individual
baseline checksum. The whole-source hash still pins their upstream base.

## Checks

Run `nix develop` before using Python tooling. The shell exposes the pinned
upstream Python modules and E2E harness under `.direnv/albedo-upstream`, which
`ty.toml` uses to resolve dependencies absent from the source overlays.

```console
nix build .#albedo-defaults .#albedo-patched
nix flake check
nix fmt
```

The checks exercise Home Manager options, source checksums, package contents,
Python formatter, LSP, MCP and question bindings, RTK routing and FFF search,
native MCP lifecycle, and the shell helpers. The server check phase exercises
question answer/cancel writes through the store writer, including in-memory,
file-backed and restarted databases; revision checks reject stale transitions.
The files under `src/` keep upstream formatting and are excluded from the suite's
treefmt run.

## Daemon tests

```console
python3 scripts/test-e2e.py \
  --source /path/to/pinned/upstream \
  --package /nix/store/...-albedo-git-...
```

The package exposes its pinned source through `.src`. The runner copies that
source into a writable temporary directory and uses the supplied binaries.
It runs formatter, LSP, lazy and eager MCP, operation lifecycle, and streaming replay
and user-question cases plus OpenCode Go routing/discovery and RTK/FFF daemon
checks, plus upstream cache-miss, provider-timeout, speechless-response,
context-window, hooks, rewind, trace, job output, kernel restoration/upgrade
and provider-catalog regressions, plus native atomic file edits, job text/readiness,
kernel working-directory changes, image limits, artifacts, durable history,
push session status and detached-kernel recovery, plus native event follows,
profile renaming, session names and daemon-managed web lifecycle.
Additional supervised RTK
and FFF integration tests run in the flake Python check against the packaged
runtime.

FFF searches share one daemon-owned worker for local sessions and one per SSH
target for remote sessions. Workers start on demand, retain at most four root
indexes, and exit after 60 seconds without a search. Search requests, including
queue time, have a 30-second worker deadline. Closing a session does not stop
another session's search worker. FFF is not listed as a session background job.
The Python adapter only calls the managed `files.fff` RPC; the daemon talks to
`albedo-fff --stdio` over versioned, newline-delimited JSON. There is no standalone
Unix-socket or per-kernel worker path. `test/fff_test.py` exercises all search
semantics through the production Erlang registry and stdin worker using a small
isolated RPC bridge; `test/fff_stdio_test.py` checks protocol bounds, four-root
eviction, idle exit and watchdog deadlines with a fake native SDK.

The tests use fake providers, temporary homes and local stdio servers. They do
not activate your configuration, read your credentials or contact live
providers.

## Agent context

[Prompt context](prompt-context.md) documents static reference reductions and
append-only documentation retrieval. Cache regression tests assert unchanged
instructions, schemas and prior request input after ordinary tool operations;
never replace this with dynamic prompt rewriting or silent evidence eviction.

## Kernel startup recovery

Fresh local kernels validate the working directory before launching Python.
A missing directory, unavailable mount, or file in place of the directory
produces an error naming the path and suggesting restoration or `/cd`.
Albedo never creates an empty substitute or silently moves the session.
The check is in the queued-turn owner, before kernel creation, so a failed
preflight cannot leave an unverified kernel record that blocks `/cd`.

Kernel startup failures retain queued inputs and pause automatic retries.
After fixing startup, send another message to retry; replaying the same input
ID does not retry. Applying a workspace move resumes the retained queue.
A daemon restart makes one new attempt. Other transient preparation failures
keep the upstream 15-second retry.

The `kernel-workspace` flake check runs the real-daemon regression cases in
`test/kernel_workspace_e2e_test.py`, including the former retry deadline and
recovery after restoring or moving a workspace.

## Temporary Codex error decoding

`src/server/src/albedo/openai_api/responses.gleam` retains upstream support for
nested `error.message` and top-level `message`, and temporarily adds string
`error` and code-only error events. Messages take precedence over codes. Unknown
or non-string shapes retain typed malformed-error diagnostics without dumping raw
payloads. This exposes provider failures; it does not retry or suppress them.
The original failing payload was not captured, so its exact shape is unverified.

The server package runs `test/suite_codex_error_test.gleam` during its check phase.
Remove this source replacement, its baseline checksum and inventory entry, and
its package check when upstream handles these envelopes without dumping raw
payloads.

The offline runner adds one readiness barrier to the pinned forced-kernel-upgrade
fixture: daemon listener readiness does not imply asynchronous kernel reattachment
has finished. It waits for an idle session, no pending inputs and an attached
kernel, then asserts the stale bundle and single live job before the original
single upgrade request. It does not retry a 409, change product admission rules
or weaken the forced-swap assertions. A changed fixture fails closed for review.

## Job readiness

The suite preserves upstream `Job.text()` and `Job.wait_for()`. The readiness
reader yields when an incomplete UTF-8 character prevents byte progress, so
later output can complete the character and the timeout remains reachable.
Regression tests exercise both paths through real supervised jobs.

## Temporary compatibility layers

Formatter and LSP support are local stopgaps for the pinned upstream version.
Do not add unrelated editor features or make other extensions depend on them.
Remove each layer when upstream covers its useful behavior and the native path
passes the relevant lifecycle tests. `files.check()` runs an explicit ordered
formatting/diagnostics batch. It is not a final-reply veto or a native Stop hook.
Disabling either feature must leave ordinary files, Python, MCP and streaming
behavior intact.

LSP servers shut down after 60 seconds without an LSP operation, including
batch diagnostics. Active requests are never interrupted by idle cleanup.
Healthy servers restart lazily on the next operation with fresh document state;
failed servers still require explicit `lsp.close()` before retrying. Idle cleanup
does not discard pending edit checks or run as a session background job.

LSP owns `albedo_lsp.py`, `albedo_plugins/lsp.py`,
`harness/extensions/lsp/extension.gleam` and `nix/home-manager/lsp.nix`.
Retirement also removes its file-write tracking in `albedo_plugins/files.py`,
its import/registration in `extensions.gleam`, its
settings/enable wiring in `runtime.nix`, its Home Manager import, and its tests
and fixture. Replace Infra's `albedo/lsp.nix` declaration with native settings
before removing its suite options.

Formatter owns `albedo_formatter.py`, `albedo_plugins/formatter.py`,
`harness/extensions/formatter/extension.gleam` and
`nix/home-manager/formatter.nix`. Retirement also removes file-write tracking in
`albedo_plugins/files.py`, its optional stage in `files.check()`, and formatter
registration/settings. Final-acceptance hook support has been retired; native
streaming and Stop behavior are unchanged. Compare replacements before deletion;
other suite changes may share a file. Keep lazy MCP and diff-display changes.

Remove retired cases from the flake checks and E2E runner, update documentation
and source inventories, and rerun disabled-feature, ordinary streaming and MCP
regressions against the native implementation. No runtime data migration is
required by either layer; their settings are additive public configuration.

## Native provider and web integration

The current base includes native OpenCode Go OAuth, account rotation, portable
cross-protocol replay, Gemini routing, OpenCode Zen, Discord, `/config`, native
artifacts, push kernel/sidebar status and demand-driven terminal rendering.
Go's provider extension uses pristine upstream code; the suite no longer
replaces the daemon's profile protocol selection. Narrow Go wire/catalog
additions preserve SDK-metadata
routing and endpoint-scoped one-hour discovery caches. Package checks exercise
native Go rotation, OAuth organization headers and all four wire routes.

NUR does not yet bundle the native web assets. `nix/modules/web.nix` builds the
pinned upstream web client with upstream's dependency hash; both suite packages
set `ALBEDO_WEB_DIST` on the CLI wrapper. Retire that packaging bridge when NUR
supplies its own web derivation and wrapper. No web source is replaced.

`albedo web` now serves through a daemon-owned child and keeps running after the
command exits; `--stop` disables it. The packaging tests use `--foreground --local`
to keep their listener isolated and verify per-command `ALBEDO_WEB_DIST` overrides.
Managed serving uses the daemon's environment, not an invoking CLI's override.
