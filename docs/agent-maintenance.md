# Agent maintenance guide

## Intent and boundaries

albedo-suite is a small source overlay and Nix integration for
[Albedo](https://tangled.org/okami.mom/albedo), not an independent rewrite of
Albedo. Keep it usable with newer upstream versions without freezing old upstream
behavior in copied files. Prefer upstream implementations when they satisfy the
suite's behavior; keep local changes narrow, removable and tested.

This repository owns reusable runtime changes, packaging and Home Manager options.
Personal providers, skills, instructions, MCP server declarations and SOPS settings
belong in Infra at `/home/adam0/Infra/modules/programs/tui/albedo/`. Do not copy
personal settings or secrets here. Do not edit generated runtime files, the Nix
store, or a sibling Albedo checkout to implement suite changes.

Read [development](development.md), the relevant feature documentation and tests
before editing. Existing source and checks determine current implementation;
this guide describes the constraints to preserve, not a frozen file inventory.

## Behavior to preserve

- MCP connections are lazy unless explicitly configured otherwise. Preserve
  explicit discovery, tool calls, operation lifecycle and cleanup.
- Formatting is deferred until final-reply acceptance, not run after every edit.
  LSP starts on demand. Both remain optional and isolated compatibility layers;
  disabling them must preserve ordinary file, Python, MCP and streaming behavior.
- Questions are durable and answerable through `/questions`, resuming the asking
  session. Preserve streaming replay and session/operation lifecycle behavior.
- Supported commands use RTK; file search uses FFF. Preserve daemon-owned worker
  sharing and local/SSH isolation, bounded indexes, timeouts and shutdown. Do not
  silently substitute another search engine or create a worker per Python kernel.
- Preserve OpenCode Go discovery, login and protocol routing. Provider state must
  reflect the selected protocol before history projection; catalog trimming must
  retain SDK metadata needed for routing.
- Preserve CLI resume behavior and the two package variants: `albedo-defaults`
  enables diffs by default; `albedo-patched` retains upstream's diff default.
  Both include the server changes and the existing diff toggle.
- Home Manager merges configuration without overwriting runtime authentication.
  Respect its running-daemon guard and existing data; do not introduce implicit
  deletion or migration. MCP, formatting and LSP remain opt-in.

Use [the feature docs](../README.md#what-it-changes) and regression tests to check
these contracts. When upstream changes the public API, adapt the integration and
update documentation/tests together rather than retaining an obsolete API by
accident. Flag intentional behavior changes for the user.

## Source and pin model

`src/server/` and `src/client/` are sparse replacements and additions using
upstream-relative paths. They are not complete, independently buildable checkouts.
`nix/modules/packages.nix` obtains `albedo-git` from the locked NUR input, verifies its
source hash and original-file checksums, copies suite sources, then runs NUR's
post-patch hooks. Preserve upstream dependencies and build hooks.

`upstream/pin.json` records the upstream revision, whole-source NAR hash and server
source inventory. `upstream/server.sha256` and `upstream/client.sha256` describe
original upstream files, never the edited suite copies. New suite-only files have
no baseline checksum; if upstream later adds the same path, review the collision
as a merge, not an unconditional overwrite.

## Updating to newer Albedo

Here, rebasing on upstream means merging new upstream code into this sparse
overlay and updating its locked package base. It does not mean rebasing suite
history onto an unrelated upstream repository.

1. Inspect working-copy status and preserve unrelated changes. Use Jujutsu when
   `.jj` exists; do not mutate that repository with Git. Keep the update separate
   from unrelated features. Do not push or activate a configuration without an
   explicit request.
2. Record the current pin and retain a readable copy of that exact upstream
   source before changing inputs. Select a specific new upstream revision and
   review its changelog, source changes, dependencies and NUR package definitions.
   Avoid resolving "latest" independently at different steps.
3. Update the NUR lock only as needed to obtain the selected Albedo source. Inspect
   the resolved `albedo-git` revision and hash; NUR's revision is not Albedo's
   revision. If NUR does not supply the target yet, report that blocker rather than
   weakening the pin assertion. Avoid unrelated input upgrades.
4. For **every** replaced file, perform a three-way comparison: old pristine
   upstream, current suite source, and new pristine upstream. Carry forward the
   suite's intentional delta while retaining upstream fixes and refactors.
   Review renames, deleted APIs, all additions and path collisions too. Passing
   checksums alone does not prove this merge is correct.
5. Review each local feature for native upstream support. Remove superseded code
   only after the native implementation meets its contract and passes relevant
   lifecycle and disabled-feature tests. Consult
   [retirement details](development.md#temporary-compatibility-layers) and
   [the temporary Codex decoder](development.md#temporary-codex-error-decoding).
   Shared replacement files can contain other suite features; do not delete
   those changes with the retired layer.
6. After merging, update the pin revision/NAR hash, source inventory and both
   checksum manifests from the selected pristine source. Remove obsolete entries
   and add baselines for newly replaced upstream files. Never regenerate hashes
   from suite files, bless drift merely to unblock a build, or disable the guards.
7. Reconcile NUR hook changes with `nix/modules/packages.nix`; keep applicable upstream
   checks as well as suite checks. Update tests, feature docs and source
   attribution in `THIRD_PARTY_NOTICES.md` when affected. Remove retired settings,
   registration and tests together; coordinate any Infra configuration changes
   rather than silently changing personal configuration.
8. Run the verification below. Report the old/new Albedo revisions, retained and
   retired suite behavior, commands and results, and any untested platform or
   blocked check. A package build is not an activation.

## Verification and handoff

For source or upstream updates, run from the suite root:

```console
nix develop
nix fmt
nix build .#albedo-defaults .#albedo-patched
nix flake check
python3 scripts/test-e2e.py --source /path/to/upstream --package /path/to/package
```

The paths in the last command are placeholders: use the selected package's
`server.src` and its actual built output, never a mutable sibling checkout or an
installed package from a different pin. The development shell materializes
`.direnv/albedo-upstream` for Python tooling; it is not an editable source tree.
Inspect formatter changes. `src/**` is excluded from treefmt, so validate source
formatting using the relevant upstream tools after edits are complete.

Flake checks cover baseline integrity, packaging, Home Manager and focused
regressions; the E2E runner additionally exercises isolated daemon behavior with
fake providers, temporary homes and local servers. Run its full default case set
for upstream updates, not just one affected feature. Where Erlang needs explicit
CA roots, use the `ERL_AFLAGS` public-key `cacerts_path` setup in
`nix/modules/checks.nix`; `SSL_CERT_FILE` alone is insufficient.

For documentation-only changes, validate relative links and command/path claims
against the current tree and run formatting; runtime builds are not required.
Do not claim checks that were not run. Leave a concise handoff with changed paths,
actual check results and unresolved limitations. Do not switch the system, restart
the user's daemon, migrate data or contact live providers as a verification step.
