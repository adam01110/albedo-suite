# Source attribution

The files under `src/server/` and `src/client/` replace files from Albedo at
revision `ff9d6dc0b83d4ee917f0e4b4dbf365a42684364d`,
<https://tangled.org/okami.mom/albedo>. Albedo is copyright 2026 okami.mom,
ptr.pet, aly.codes and the other contributors in its git history, licensed under
the GNU Affero General Public License v3.0 only with the Classpath exception.
The root `LICENSE` reproduces that revision's license and exception verbatim;
`LICENSES/albedo-AUTHORS.md` preserves its authors notice. The suite extends the
same Classpath exception to its modifications.

Suite-authored code, packaging, modules, helpers, tests and documentation are
copyright 2026 Adam0 and licensed under the same AGPL-3.0-only with Classpath
exception, except where third-party notices specify otherwise. The license update
is dated 2026-11-02 and the suite modifications described below are dated
2026-11-03. Earlier versions retain their original licenses.

The previous upstream pin was `154c6911d6a491aeeecacf26a06b6ae8c4bc70e1`,
licensed under MPL 2.0. Original MPL-covered portions retained from that source
remain subject to their MPL notices and source-availability requirements; the
new upstream license does not erase those obligations or relicense third-party
code. The MPL text is retained in `LICENSES/albedo-MPL-2.0.txt`. The earlier
WTFPL v2 text is retained in `LICENSES/albedo-WTFPL.txt`. Separately licensed
components, including the MPL-covered madoromi colours identified by upstream,
retain their own terms.

Modifications add opt-in lazy MCP lifecycle/bindings, explicit staged formatting
and local LSP batch checks, isolated local LSP compatibility tools, durable user
questions, mandatory RTK command filtering and FFF search,
a native Zed provider using existing protocol adapters and bounded NDJSON framing,
Zed browser callback/account confirmation and account-scoped inference JWT renewal,
narrow native OAuth confirmation and native HTTP transport integration,
explicit opt-in browser-session Zed USD budget inspection,
OpenCode Go SDK-metadata routing and endpoint-scoped discovery caches on the
native OAuth, account rotation and portable wire implementation,
recoverable kernel startup failures with workspace validation,
quota poller deadline recovery and newest-report projection,
reversible provider-profile availability and model-discovery filtering,
cache-stable startup reference reductions with on-demand API documentation,
Vim-style CLI composer editing with a footer mode indicator, recoverable queued
inputs on interruption and modal hjkl navigation across searchable CLI screens,
explicit Base16 terminal palettes, formatted CLI context inspection with a raw toggle,
a passive bounded TUI activity sidebar derived from existing stream events,
zoxide suggestions and successful local move tracking in the folder picker,
and optional default CLI diff visibility. `upstream/pin.json` inventories server
replacements; the client
replacements live under `src/client/cli/`.
`test/model_catalogs_test.py` adapts upstream
`test/e2e/model_catalogs_test.py` from the current pinned revision for
endpoint-scoped cache
fixtures; its provider catalog assertions are retained.
`scripts/test-e2e.py` adds a kernel-reattachment readiness barrier to upstream
`test/e2e/kernel_upgrade_test.py` from the current pinned revision; its
forced-swap assertions are retained. It also scopes the pinned
`test/e2e/skills_test.py` discovery query to skills so the suite's larger
extension inventory does not hide skill assertions behind pagination.

Upstream's complete third-party notices are preserved in
`LICENSES/albedo-THIRD_PARTY_NOTICES.md`. Dependencies and packaged runtime
components remain under their original licenses. Builds use upstream through
the independently locked NUR package definitions rather than vendoring all its
code or dependencies into this repository.
