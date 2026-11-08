# Session token cost

The CLI footer shows estimated session-wide USD to the right of cached tokens,
for every provider. `~$1.23` is a catalog-rate estimate, not an invoice or account
balance; subscription, promotional, negotiated and provider-specific billing may
differ. Positive amounts below one cent display as `~$<0.01`.

The estimate uses the durable request ledger, including tool-loop calls,
compaction summaries, background warmups and metered failed attempts. It survives
resume and includes requests from earlier models and providers in the session.
It excludes child sessions, which have their own totals.

Prices come from the existing models.dev cache. Cached reads, cache writes and
long-context tiers are priced separately. Subscription/proxy transports use a
canonical public model price when available. Codex and OpenCode Go prefer that
API rate over subscription catalog rates, including zero rates. OpenCode Go's
GLM, Kimi and MiniMax models resolve to ZAI, Moonshot AI and MiniMax API prices;
model ID case differences do not prevent a match. Other providers retain their
own catalog rates.

Ambiguous prices, missing token usage or an unavailable catalog display
`cost n/a`, never an invented zero. Older trimmed catalogs need `/reload models`
to acquire pricing fields. Parsed indexes from before pricing support are
rebuilt automatically; reloading is still necessary if prices were already
removed from the cached JSON.

No provider billing endpoint is queried. The session status resource, full
snapshot and live usage events carry the same nullable `session_cost_usd` field.
