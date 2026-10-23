# Source attribution

The files under `src/server/` and `src/client/` replace files from Albedo at
revision `49b3336f7e19f608e869943858cf652c11f719be`,
<https://tangled.org/okami.mom/albedo>. Albedo is copyright 2026 albedo contributors
(okami.mom & ptr.pet), licensed under WTFPL v2; the original license is retained
in `LICENSES/albedo-WTFPL.txt`. Source replacements and their extension-local
additions use WTFPL v2. Suite-authored material, including packaging, modules,
helpers and tests, also uses WTFPL v2 under the root `LICENSE`.

Modifications add opt-in lazy MCP lifecycle/bindings, explicit staged formatting
and local LSP batch checks, isolated local LSP compatibility tools, durable user
questions, mandatory RTK command filtering and FFF search,
OpenCode Go SDK-metadata routing and endpoint-scoped discovery caches on the
native OAuth, account rotation and portable wire implementation,
recoverable kernel startup failures with workspace validation,
cache-stable startup reference reductions with on-demand API documentation,
Vim-style CLI composer editing with a footer mode indicator,
and optional default CLI diff visibility. `upstream/pin.json` inventories server
replacements; the client
replacements live under `src/client/cli/`.
`test/model_catalogs_test.py` adapts upstream
`test/e2e/model_catalogs_test.py` at the same revision for endpoint-scoped cache
fixtures; its provider catalog assertions are retained.
`scripts/test-e2e.py` adds a kernel-reattachment readiness barrier to upstream
`test/e2e/kernel_upgrade_test.py` at that revision; its forced-swap assertions
are retained.

Upstream's complete third-party notices are preserved in
`LICENSES/albedo-THIRD_PARTY_NOTICES.md`. Dependencies and packaged runtime
components remain under their original licenses. Builds use upstream through
the independently locked NUR package definitions rather than vendoring all its
code or dependencies into this repository.
