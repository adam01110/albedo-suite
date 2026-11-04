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

Follow the [maintenance guide](agent-maintenance.md#updating-to-newer-albedo)
for source merges, pin/checksum rules and verification. The
[automated updater](#automated-sparse-upstream-updates) prepares a candidate;
it does not replace compatibility review.

## Packaged licenses and source

Packages retain licenses, attribution and exact source snapshots under
`share/doc/albedo-suite/`; the standalone web package uses
`share/doc/albedo-web/`. See [corresponding source](package-sources.md) for
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
Python formatter, LSP and MCP bindings, RTK routing and FFF search,
native MCP lifecycle, and the shell helpers.
The files under `src/` keep upstream formatting and are excluded from the suite's
treefmt run.

## Terminal UX

[Vim-first terminal interface](vim-ux.md) defines modes, focus, navigation and
action discovery, including intentionally changed control-key bindings.

## Daemon tests

```console
python3 scripts/test-e2e.py --source /path/to/pinned/upstream --package /path/to/built/package
```

Use the selected package's `server.src` and actual built output, not an
installed package from another pin. The runner copies the source into a
writable temporary directory and uses the supplied binaries. `SUITE_CASES` and
`UPSTREAM_CASES` in `scripts/test-e2e.py` are the authoritative case lists.
Use `--case <name>` for focused work; omit it for the full upstream-update run.

Tests use fake providers, temporary homes and local servers. They do not
activate your configuration, read your credentials or contact live providers.
The runner adjusts two checksum-guarded upstream fixtures: it waits for kernel
reattachment before testing a forced upgrade and filters skill discovery to
avoid extension-count-dependent pagination. Changed fixtures require review.

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

`src/server/src/albedo/openai_api/request.gleam` replaces the upstream Responses
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
`items`, `prefixItems`, `anyOf`, `oneOf`, `allOf`, `not`, `if`/`then`/`else`,
`dependentSchemas`, `$defs` and `definitions`; a schema that nests an object
behind one of those keywords and omits the rule is sent non-strict. The claim is
emitted only when the schema meets those rules, so a provider that enforces them
no longer refuses the whole request (`Invalid schema for function 'python': ...
'required' is required to be supplied and to be an array including every key in
properties`). `test/suite_zed_test.gleam` pins both the rules and the traversal.

OpenCode Go's Responses route shares this encoder and gets the same typed items.
The server package runs `test/suite_zed_test.gleam`, which asserts every family's
`provider_request` field by field and fails when an input item or a message
content part loses its discriminator. Remove this source replacement, its
baseline checksum and its inventory entry when upstream emits typed items.

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

## Provider and web integration

The pristine upstream provider handles OpenCode Go OAuth, account rotation and
protocol selection. Suite wire/catalog additions preserve SDK-metadata routing;
package checks exercise rotation, OAuth organization headers and all four wire
routes. See [provider configuration](configuration.md#opencode-go).

`upstream/pin.json` records the current Albedo revision; `flake.lock` records
NUR. Do not maintain a second pin history here. Lazy MCP uses upstream's native
client, and Zed uses native transport method selection.

NUR does not yet bundle the native web assets. `nix/modules/web.nix` builds the
pinned upstream web client with upstream's dependency hash; both suite packages
set `ALBEDO_WEB_DIST` on the CLI wrapper. Retire that bridge when NUR supplies
its own web derivation and wrapper. No web source is replaced.

`albedo web` serves through a daemon-owned child and keeps running after the
command exits; `--stop` disables it. Packaging tests use `--foreground --local`
to isolate the listener and verify per-command `ALBEDO_WEB_DIST` overrides.
Managed serving uses the daemon's environment, not an invoking CLI's override.

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
type changes, not guessed by similarity. No conflict markers are written.
All plans must resolve before any source, checksum or pin is written; write
errors roll back. No files outside the existing overlay are copied into `src`.

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
0 for updated/no-change, 2 for unresolved merges, and 1 for operational errors.
The report lists old/candidate NUR and Albedo identities, automatically merged
paths and unresolved reasons. Reproduce a conflict with its exact candidate NUR
SHA, obtain both source paths with the `source_expr` expression in the script,
and compare the reported path in the old source, suite and candidate. Resolve in
a separate human branch, update pristine manifests and run the full checks.

After a successful local update, run `bash scripts/validate-upstream.sh`. This
runs updater fixtures, formatting verification, both builds, all flake checks,
and the complete isolated E2E case set using the candidate package's actual
`server.src` and built output. It sets Erlang's explicit CA bundle as required by
the existing checks. No live providers or personal credentials are used.

### Publication boundary

The updater is a local preparation tool, not an unattended update service.
GitHub is a mirror: no scheduled Actions updater, publishing token, bot branch
or pull request publisher is installed. Review candidate changes and run the
validation script before publishing through the canonical repository. A clean
text merge does not establish API compatibility or retire suite features.
