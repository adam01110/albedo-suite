# Development

## Source files

`src/server/` and `src/client/` use the same paths as upstream, relative to the
repository root. They contain the files the suite replaces and the files it
adds. Edit them as ordinary Gleam, Erlang, Python and Go source.

Upstream is a Gleam workspace: the daemon is `apps/albedo`, extensions are
packages under `extensions/`, shared libraries under `packages/`, and kernel
Python under `python/`. A suite file goes
in the package whose dependencies it already uses: package manifests are not
changed, because NUR checks the daemon's `manifest.toml` against its vendored
copy. Suite-only providers and extensions that need core modules live in the
daemon as `apps/albedo/src/albedo_ext_<name>/`.

`nix/modules/packages.nix` uses the locked NUR package definitions. It checks the
source hash in `upstream/pin.json` and the original files in
`upstream/*.sha256`. It then copies the suite files before NUR's existing
post-patch hooks run. The server builds in NUR's `apps/albedo` source root, so
its overlay is copied two levels up, into the whole unpacked source. Upstream
dependencies, patches and build checks remain
in use.

## Updating upstream

Follow the [maintenance guide](agent-maintenance.md#updating-to-newer-albedo)
for source merges, pin/checksum rules and verification. The
[automated updater](#automated-sparse-upstream-updates) prepares a candidate;
it does not replace compatibility review.

## Packaged licenses and source

Packages retain licenses, attribution and exact source snapshots under
`share/doc/albedo-suite/`. See [corresponding source](package-sources.md) for
rebuild, distribution and network source-offer requirements.
`checks.package-licenses` verifies installed notices and source correspondence,
not an operator's network source offer.

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
Python formatter, LSP and MCP bindings, RTK routing and FFF search, and the
shell helpers. The server build's check phase also runs the suite Gleam tests,
including the lazy MCP manager lifecycle, catalog prices and memory index. It
builds them once in a copy of the source tree and runs each test main as its own
VM at once, so a new test also joins `suiteTests` in `nix/modules/packages.nix`;
the esqlite NIF builds once in its own derivation. The `python` check assembles
`priv/python` from the pinned source and the overlay and runs its files at once,
and `package-layout` diffs that tree against the installed one. The E2E checks
build at once, each with two private daemons. The client's own check tests only
`cmd/albedo`, so the client does not wait for the built server; the suite's
selections reuse the build's `-trimpath` objects.

The property suites run in the same places at small case counts, so every
check exercises them: the server's check phase runs each
`test/proptest/*_prop.gleam` main beside the suite tests, at `PROPTEST_COUNT=20`
and with a nice level so the suite tests' deadlines keep their CPU; qcheck and
its dependencies come from Hex at the checksums in
`test/proptest/hex-packages.txt`. The client's check runs every `TestProp*`
test, including `internal/config`, and the `python-properties` check runs the
hypothesis files apart from the deadline-sensitive `python` tests. Each property prints the seed it used. `test/proptest/README.md` shows
how to run them longer with `PROPTEST_COUNT`, `PROPTEST_SEED` and the other
knobs.
The files under `src/` keep upstream formatting and are excluded from the suite's
treefmt run.

## Terminal UX

[Composer editing](vim.md) defines input-only NORMAL/INSERT modes. Lists,
forms, agents and transcript navigation use the upstream keyboard controls.

The inline renderer overlays `cli/third_party/bubbletea/cursed_renderer.go`
with a port of [bubbletea#1868](https://github.com/charmbracelet/bubbletea/pull/1868).
Before a resize to a narrower width redraws the frame, it moves up past the rows
the terminal rewrapped. Without it, Ghostty's reflow of a full-width row, for
example when Hyprland narrows an unfocused window by one column, leaves one
stale header above the frame per narrowing. Go builds the replaced module from
`vendor/`, so `packages.nix` installs the overlay there after configure.
Alternate-screen frames and GNU screen (`STY` set), which truncates rather than
rewraps, are left alone.
`go test ./internal/terminal -run '^TestSuiteInline'` covers it. Drop the
overlay when upstream's vendored Bubble Tea contains an equivalent fix.

## Quota display

`/quota` rows, bars, details and projections show the share of each limit left
(`40% left`, `empty in ~2h`, `ends near 10% left`) instead of upstream's share
used. Values are clamped to 0-100%. The daemon's `used_percent` data is
unchanged; only `cli/internal/tui/quota_view.go` inverts it for display.

## Daemon tests

```console
python3 scripts/test-e2e.py --source /path/to/pinned/upstream --package /path/to/built/package
```

Use the selected package's `server.src` and actual built output, not an
installed package from another pin. The runner copies the source into a
writable temporary directory and uses the supplied binaries. `SUITE_CASES` and
`UPSTREAM_CASES` in `scripts/test-e2e.py` are the authoritative case lists.
Use `--case <name>` for focused work; omit it for the full upstream-update run.

The packaged `entrypoint.sh` caches the daemon's code path before `main` runs,
so a module load no longer probes every `ebin` directory; daemons booted with
`ALBEDO_PRELOAD=0`, as test daemons are, keep the cache, while production keeps
it until `boot_code.prepare` republishes the path.

Tests use fake providers, temporary homes and local servers. They do not
activate your configuration, read your credentials or contact live providers.
The runner waits for kernel reattachment before testing a forced upgrade. It
also adapts native harness, history-content, kernel-detach, image-limit and
repetition text extraction to the suite's typed Responses content parts,
preserving their assertions. These upstream fixtures are checksum-guarded and
require review when changed. Skill
discovery uses upstream's native catalog filter.

Additional supervised RTK/FFF tests run in the flake Python check.
`test/fff_test.py` exercises search through the production Erlang registry;
`test/fff_stdio_test.py` checks protocol bounds, root eviction, idle exit and
watchdog deadlines. See [RTK and FFF](tool-parity.md) for worker behavior.

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

## Zoxide folder suggestions

With `zoxide` on the CLI's `PATH`, `/cd` includes matching directories from its
existing database after recent session folders, without duplicates. Bare words
use `zoxide query --list` with zoxide's ranking and multi-word matching; explicit
paths and SSH locations retain normal browsing. `/cd words` also resolves a
zoxide shortcut when no relative directory with that name exists. Queries are
debounced in the picker and bounded
by a one-second timeout. Successful local `/cd` moves run `zoxide add`; failed
moves and remote locations do not update the database. Missing zoxide or an empty
database leaves the existing picker usable. The integration runs only when the
CLI and daemon share a machine; it does not query remote zoxide databases.

## Typed Responses input items

`src/server/packages/albedo_openai/src/albedo_openai/request.gleam` replaces
the upstream Responses
encoder, which writes messages it builds itself as `{"role": ..., "content":
...}` input items; a strict endpoint parses the input as a `type`-tagged union
and rejects the request before any model sees it (Zed's cloud answers
`missing field 'type'`). The replacement adds the `message` discriminator and
encodes message text as typed content parts (`input_text`, `output_text`,
`input_image`), which is what Zed's own client sends and what the Responses
schema documents. Locally built Chat Completions messages, and every other
encoder, are unchanged. Replayed items are already typed and pass through
verbatim.

The replacement also stops claiming OpenAI strict mode for a tool whose schema
cannot satisfy it: strict requires every object level to set
`additionalProperties: false` and to list every property as required, and the
built-in tools take optional parameters. "Every object level" means every schema
reachable through `properties`, `patternProperties`, `additionalProperties`,
`unevaluatedProperties`, `propertyNames`, `items`, `prefixItems`,
`additionalItems`, `contains`, `unevaluatedItems`, `anyOf`, `oneOf`, `allOf`,
`not`, `if`/`then`/`else`, `dependentSchemas`, `dependencies`, `$defs` and
`definitions`; a schema that nests an object
behind one of those keywords and omits the rule is sent non-strict. The claim is
emitted only when the schema meets those rules, so a provider that enforces them
no longer refuses the whole request (`Invalid schema for function 'python': ...
'required' is required to be supplied and to be an array including every key in
properties`). `test/suite_zed_test.gleam` pins both the rules and the traversal.

OpenCode Go's Responses route shares this encoder and gets the same typed items.
The server package runs `test/suite_zed_test.gleam`, which asserts the Responses
family's `provider_request` field by field and fails when an input item or a message
content part loses its discriminator. Remove this source replacement, its
baseline checksum and its inventory entry when upstream emits typed items.

## Temporary Codex error decoding

`src/server/packages/albedo_openai/src/albedo_openai/responses.gleam` retains
upstream support for
nested `error.message` and top-level `message`, and temporarily adds string
`error` and code-only error events. Messages take precedence over codes. Unknown
or non-string shapes retain typed malformed-error diagnostics without dumping raw
payloads. This exposes provider failures; it does not retry or suppress them.
The original failing payload was not captured, so its exact shape is unverified.

The server package runs `test/suite_codex_error_test.gleam` during its check phase.
Remove this source replacement, its baseline checksum and inventory entry, and
its package check when upstream handles these envelopes without dumping raw
payloads.

## Remote bundle staging

Concurrent SSH kernel starts publish their complete bundle with an atomic
directory rename. A connection that loses publication removes only its own
staging tree, including read-only directories shipped by Nix; it never moves a
second tree inside the winning bundle. A conflicting nonempty bundle is refused.
`test/remote_staging_test.py` covers writable/read-only duplicate staging,
concurrent first publication and incomplete-target rejection.

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
`apps/albedo/src/albedo_ext_lsp/extension.gleam` and `nix/home-manager/lsp.nix`.
Retirement also removes its file-write tracking in `albedo_plugins/files.py`,
its import/registration in `extensions.gleam`, its
settings/enable wiring in `runtime.nix`, its Home Manager import, and its tests
and fixture. Replace Infra's `albedo/lsp.nix` declaration with native settings
before removing its suite options.

Formatter owns `albedo_formatter.py`, `albedo_plugins/formatter.py`,
`apps/albedo/src/albedo_ext_formatter/extension.gleam` and
`nix/home-manager/formatter.nix`. Retirement also removes file-write tracking in
`albedo_plugins/files.py`, its optional stage in `files.check()`, and formatter
registration/settings. Final-acceptance hook support has been retired; native
streaming and Stop behavior are unchanged. Compare replacements before deletion;
other suite changes may share a file. Keep lazy MCP and diff-display changes.

Remove retired cases from the flake checks and E2E runner, update documentation
and source inventories, and rerun disabled-feature, ordinary streaming and MCP
regressions against the native implementation. No runtime data migration is
required by either layer; their settings are additive public configuration.

## Provider and web integration

For OpenCode Go, the suite-only `albedo_ext_opencode_go/routing.gleam` and the
wire/catalog replacements let cached models.dev SDK metadata choose the protocol
before the documented defaults. Package checks exercise all four wire routes.
The native Responses bridge replaces the old local adapter; its narrow
reasoning-detail extension preserves encrypted items in both existing histories
and new turns, without changing native sparse tool-call indices.
`test/suite_bridge_test.gleam` checks both replay paths and index correlation.
The `albedo_openai/request.gleam` replacement sends Chat Completions tool-result
images in call and attachment order; the pinned upstream reverses them.
See [provider configuration](configuration.md#opencode-go).

`upstream/pin.json` records the current Albedo revision; `flake.lock` records
NUR. Do not maintain a second pin history here. Lazy MCP uses upstream's native
client, and Zed uses native transport method selection.

The suite packages ship the CLI and daemon without building or bundling the
web UI or the Photon iMessage bridge: they override NUR's `albedo-git` with
`withWeb = false` and `withPhoton = false`. There is no `albedo-web` output or
packaged `ALBEDO_WEB_DIST` default, and `albedo-photon` is not on PATH.
Upstream's web-serving and `photon` commands remain, but their runtimes are not
supplied. `checks.package-layout` verifies that neither package's runtime
closure includes an `albedo-web` or `albedo-photon` derivation. No upstream web
source is replaced.

The client builds upstream's component commands (`albedo`, `albedo-acp`,
`albedo-server`, `albedo-tui`, `albedo-web`) into `libexec/albedo`; `albedo`
execs its siblings from there. The package-layout check compares every
launcher with the E2E package.

## Automated sparse upstream updates

`python3 scripts/update-upstream.py` selects the current NUR revision once in an
isolated temporary checkout. To reproduce a specific selection, use
`python3 scripts/update-upstream.py --nur-rev <40-character-NUR-commit>`.
The NUR commit is **not** the Albedo commit. The updater evaluates the unmodified
`nur.repos.adam0.albedo-git.src` from each locked NUR input, realizes both pristine
sources with Nix, verifies their NAR hashes, and records both identities in its
JSON report. Only the NUR lock node may change; unrelated lock updates fail closed.
Requires Nix with flakes enabled, Git and Python 3.11 or newer, and a clean
working copy. Jujutsu checkouts use `jj diff --summary` for the cleanliness
check; Git checkouts use `git status`. Neither path creates commits or pushes.

For each baseline replacement, `git merge-file` uses old pristine upstream as
base, suite as ours, and candidate pristine upstream as theirs. An unchanged
upstream file is a trivial merge retaining ours. Suite-only additions remain
unchanged. Conflicts, missing baselines, upstream deletions/possible renames,
file/directory collisions, symlinks, executable mode changes and changed binary
files require manual review. Renames are deliberately reported as deletions or
type changes, not applied by similarity; the report's `renameHints` only
suggests candidate destinations by shared identifiers. No conflict markers are written.
By default all plans must resolve before any source, checksum or pin is written;
write errors roll back. No files outside the existing overlay are copied into
`src`.

With `--apply-conflicts`, an update whose only unresolved items are text
conflicts is applied in full: clean merges, NUR lock, pin and both manifests
are written, and each conflicted replacement receives `git merge-file --diff3`
markers labelled `suite`, `old-upstream` and `new-upstream`. Resolve the markers
in place; `scripts/validate-upstream.sh` refuses to build while any remain in
`src` or `test`. Replacements whose upstream file was deleted, renamed or
collides with a suite-only addition are set aside: removed from `src` and
copied to `<report>-review/set-aside/` with a `.patch` describing the suite
delta to port. Missing baselines, symlinks, mode and binary changes still
write nothing.

The manifests are generated from pristine candidate bytes. The existing
`sourceFiles` inventory continues to list the server overlay (including its
suite-only additions); client replacements are tracked by
`upstream/client.sha256` alone and never appear in it. The whole-source NAR hash
pins the pristine candidate tree without a second file inventory. Generated
`__pycache__` directories and `.pyc` files are excluded from overlay discovery
and inventories. The package's
source hash assertion, checksum guards, original
NUR post-patch hooks and both package variants remain intact. Equal Albedo
revision/hash is a no-op, even if NUR moved: packaging-only NUR updates require
separate review. The updater does not retire compatibility features or rewrite
NUR hook integrations; package and daemon regressions must detect incompatibility.
Changes to the web dependency hash, E2E fixture guard or build API may therefore
require manual changes rather than an automatically successful update.

The default report is `/tmp/albedo-upstream-update.json`; choose another location
with `--report /absolute/path/report.json` outside the checkout. Exit status is
0 for updated/no-change, 2 for unresolved merges or written conflicts, and 1 for
operational errors. The report lists old/candidate NUR and Albedo identities and
their realized `oldSource`/`candidateSource` store paths, automatically merged
paths, unresolved reasons, `conflicts`, `setAside`, `renameHints`, `noDelta` and
`upstreamChanges` counts.
`noDelta` names replacements whose merged bytes equal the candidate upstream
file: retire them (delete the replacement and its baseline line) unless a test
documents why they stay. The sibling `<report>-review/` directory holds each
conflict's diff3 merge and `upstream-changes.txt`, one `A`, `R` or `M` line per
upstream path changed between the pins, for changelog and retirement review.

After a successful local update, run `bash scripts/validate-upstream.sh`. This
rejects leftover conflict markers, then runs updater fixtures, formatting
verification, both builds, all flake checks, and the isolated E2E case set using
the candidate package's actual `server.src` and built output. Cases that a flake
check already ran against the same package (`--case` in `nix/modules/checks.nix`)
are skipped. Extra arguments go to `scripts/test-e2e.py`, for example
`--case usage_test.py` to repeat one case. It sets Erlang's explicit CA bundle as
required by the existing checks. No live providers or personal credentials are
used.

`scripts/test-e2e.py` passes all selected cases to one upstream `run.py`
invocation, so they share daemon boots and its duration-ordered scheduler.
`-j`/`--jobs` and `-x`/`--exclusive-jobs`, or upstream's
`ALBEDO_TEST_EXCLUSIVE_JOBS`, set its shared and private lanes. Without either
exclusive choice the runner widens upstream's private daemons to the spare cores
its memory budget allows, keeping two cores free. Failed tests are rerun once,
serially; a pass there is printed as `FLAKY` and the run succeeds. `--no-retry`
keeps the first result.

Two helpers shorten the merge loop. `scripts/regen-api.sh` reruns upstream's
`cli/tools/apigen` on the pinned source with the suite's
`src/server/docs/openapi.yaml` and copies the generated `api.gen.go`,
`digest.gen.go`, `patches.gen.go` and `api_digest.gleam` back into the overlay,
so merge only the
contract and regenerate the rest. `scripts/overlay-tree.sh server|client [dir]`
runs the package's own unpack, patch (checksum guard and overlay copy),
configure and build phases once in `/tmp/albedo-overlay-<component>`, leaving a
tree with vendored dependencies even when the build fails. After edits,
`scripts/overlay-tree.sh sync <component> [dir]` recopies the overlay, and
`<dir>/shell gleam build` or `<dir>/shell go build ./...` compiles incrementally
in the build environment. Overlay files that still hold conflict markers are
compiled as pristine upstream, so several people can fix their own files
before every conflict is resolved. The client shell does not depend on a built
server. `python3 scripts/update-upstream.py --sync-manifests` then rewrites both
checksum manifests and the server inventory for the current overlay from the
pinned pristine source, after porting into a newly replaced upstream file or
retiring one.

Suite-wide license files and the `source/suite` link live in a symlink wrapper
around each component (`passthru.unwrapped` is the build). Components are built
against unwrapped dependencies, so editing docs, tests, scripts or Nix outside a
component's own inputs rebuilds only the wrappers, not render, server or client.

### Publication boundary

The updater is a local preparation tool, not an unattended update service.
GitHub is a mirror: no scheduled Actions updater, publishing token, bot branch
or pull request publisher is installed. Review candidate changes and run the
validation script before publishing through the canonical repository. A clean
text merge does not establish API compatibility or retire suite features.
