# Source attribution

The files under `src/server/` and `src/client/` replace files from Albedo at
revision `2d0fac2cc4ff4bbd28b422dd1dd53e0ad81aa4a6`,
<https://tangled.org/okami.mom/albedo>. Albedo is copyright 2026 albedo contributors
(okami.mom, ptr.pet, aly.codes and other contributors), licensed under MPL 2.0;
the license is retained in `LICENSES/albedo-MPL-2.0.txt`. Updated source
replacements retain upstream MPL 2.0 coverage. The previous WTFPL v2 license
is retained in `LICENSES/albedo-WTFPL.txt` for earlier source versions.
Suite-authored code, packaging, modules, helpers, tests and documentation are
copyright 2026 Adam0 and licensed under MPL 2.0 in the root `LICENSE`, except
where third-party notices specify otherwise. Earlier versions retain their
original licenses.

Modifications add opt-in lazy MCP lifecycle/bindings, explicit staged formatting
and local LSP batch checks, isolated local LSP compatibility tools, durable user
questions, mandatory RTK command filtering and FFF search,
OpenCode Go SDK-metadata routing and endpoint-scoped discovery caches on the
native OAuth, account rotation and portable wire implementation,
recoverable kernel startup failures with workspace validation,
cache-stable startup reference reductions with on-demand API documentation,
Vim-style CLI composer editing with a footer mode indicator, recoverable queued
inputs on interruption and modal hjkl navigation across searchable CLI screens,
explicit Base16 terminal palettes, formatted CLI context inspection with a raw toggle,
and optional default CLI diff visibility. `upstream/pin.json` inventories server
replacements; the client
replacements live under `src/client/cli/`.
`test/model_catalogs_test.py` adapts upstream
`test/e2e/model_catalogs_test.py` from the current pinned revision for
endpoint-scoped cache
fixtures; its provider catalog assertions are retained.
`scripts/test-e2e.py` adds a kernel-reattachment readiness barrier to upstream
`test/e2e/kernel_upgrade_test.py` from the current pinned revision; its
forced-swap assertions are retained.

Upstream's complete third-party notices are preserved in
`LICENSES/albedo-THIRD_PARTY_NOTICES.md`. Dependencies and packaged runtime
components remain under their original licenses. Builds use upstream through
the independently locked NUR package definitions rather than vendoring all its
code or dependencies into this repository.
