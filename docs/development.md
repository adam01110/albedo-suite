# Development

## Source files

`src/server/` and `src/client/` use the same paths as upstream. They contain the
files the suite replaces and the files it adds. Edit them as ordinary Gleam,
Erlang, Python and Go source.

`flake/packages.nix` uses the locked NUR package definitions. It checks the
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

```console
nix build .#albedo-defaults .#albedo-patched
nix flake check
nix fmt
```

The checks exercise Home Manager options, source checksums, package contents,
Python formatter, LSP, MCP and question bindings, RTK routing and FFF search, native MCP lifecycle, and the shell helpers.
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
and user-question cases plus RTK/FFF daemon checks. Additional supervised
RTK and FFF integration tests run in the
flake Python check against the packaged runtime.

The tests use fake providers, temporary homes and local stdio servers. They do
not activate your configuration, read your credentials or contact live
providers.


## Temporary compatibility layers

Formatter and LSP support are local stopgaps for the pinned upstream version.
Do not add unrelated editor features or make other extensions depend on them.
Remove each layer when upstream covers its useful behavior and the native path
passes the relevant lifecycle tests. Disabling one must leave ordinary files,
Python, MCP and streaming behavior intact.

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
`albedo_plugins/files.py`, formatter registration/settings and the managed
pre-final hook additions in the session, loop, runtime, extension and composition
source replacements. Compare each replacement with upstream before deleting it;
other suite changes may share a file. Keep lazy MCP and diff-display changes.

Remove retired cases from the flake checks and E2E runner, update documentation
and source inventories, and rerun disabled-feature, ordinary streaming and MCP
regressions against the native implementation. No runtime data migration is
required by either layer; their settings are additive public configuration.
