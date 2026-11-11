# Session token cost

The CLI footer shows estimated session-wide USD to the right of cached tokens,
for every provider. The session list shows the same estimate for each session,
left of its last-activity age; `—` marks a session it cannot price, and lists
narrower than 40 columns omit the column. The right end of the session screen's
title shows `total $12.34`, the estimate over every stored session, including
archived and child sessions; `≥` marks a lower bound that leaves out sessions it
cannot price. `$1.23` is a catalog-rate estimate,
not an invoice or account balance; subscription, promotional, negotiated and
provider-specific billing may differ. Positive amounts below one cent display
as `$<0.01`.

The estimate uses the durable request ledger, including tool-loop calls,
compaction summaries, background warmups and metered failed attempts. Failed
attempts the provider rejected without reporting usage, such as 429 and 5xx
responses, cost nothing and leave the total known. It survives
resume and includes requests from earlier models and providers in the session.
It excludes child sessions, which have their own totals.

Prices come from the existing models.dev cache. Cached reads, cache writes and
long-context tiers are priced separately. Each request is priced by its profile
name, then by the catalog provider serving its endpoint (Anthropic, OpenAI,
OpenRouter, OpenCode Zen or OpenCode Go), then by the model vendor's public API,
so renamed profiles and models many providers resell still resolve. Claude, Codex,
Zed and OpenCode Go are subscription transports and prefer the public API rate
over subscription catalog rates, including zero rates. OpenCode Go's
GLM, Kimi and MiniMax models resolve to ZAI, Moonshot AI and MiniMax API prices;
model ID case differences do not prevent a match. Other providers retain their
own catalog rates.

Ambiguous prices, a successful request without token usage or an unavailable
catalog display
`cost n/a`, never an invented zero. Older trimmed catalogs need `/reload models`
to acquire pricing fields. Parsed indexes from before pricing support are
rebuilt automatically; reloading is still necessary if prices were already
removed from the cached JSON.

No provider billing endpoint is queried. The session status resource, full
snapshot and live usage events carry the same nullable `session_cost_usd` field
inside `usage`. Session summaries in `GET /sessions` pages and the full session
resource carry it at the top level; a list page prices all its sessions with one
ledger read. The first page of every `GET /sessions` listing also carries
`total_cost` (`usd` and `partial`), computed over the whole ledger regardless of
the listing's filters.

Upstream separately reports provider-named spend (`usage.spent`, such as
gateway charges or plan allowances). Few providers report it, so the footer
shows only the suite estimate; `usage.spent` remains in the HTTP API and
events unchanged.
