# Source attribution

The files under `src/server/` and `src/client/` replace files from Albedo at
revision `c0d04285b16b73fdf1fa7bdd874e50797061e57c`,
<https://tangled.org/okami.mom/albedo>. Albedo is copyright 2026 albedo contributors
(okami.mom & ptr.pet), licensed under WTFPL v2; the original license is retained
in `LICENSES/albedo-WTFPL.txt`. Source replacements and their extension-local
additions use WTFPL v2;
the root GPL-3.0 license covers the suite's original packaging/module/helper code,
not a blanket relicensing of upstream material.

Modifications add opt-in lazy MCP lifecycle/bindings, the managed pre-final
acceptance hook and local deferred formatter, isolated local LSP compatibility
tools, durable user questions, mandatory RTK command filtering and FFF search,
OpenCode Go authentication, model discovery and per-model protocol routing,
and optional default CLI diff visibility. `upstream/pin.json` inventories server
replacements; the client
replacements live under `src/client/cli/internal/tui/`.

Upstream's complete third-party notices are preserved in
`LICENSES/albedo-THIRD_PARTY_NOTICES.md`. Dependencies and packaged runtime
components remain under their original licenses. Builds use upstream through
the independently locked NUR package definitions rather than vendoring all its
code or dependencies into this repository.
