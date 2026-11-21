# Usage profile

`/usage` has two tabs; `tab` switches between them. **days** is upstream's list
of today's models and the last seven days. **profile** is a year at a glance:

- A borderless row of lifetime tokens, the peak day, the longest turn, and the
  longest and current streaks of days with use. The current streak
  counts today, or ends yesterday while today has no use yet. Below it, the
  calls, active days, first day and peak day those numbers rest on.
- **Token activity**: up to 53 weeks as columns, Monday at the top, the
  current week last. `d` grades each day by the quartiles of the days with
  use, so one huge day does not wash the rest out; days without use are dim
  squares. A day is Nerd Font's rounded square (`nf-md-square_rounded`,
  U+F14FB), so the terminal font needs Nerd Font glyphs. `w` draws each week as a column of eighth blocks, and `c` the
  running total through each week, which ends at the lifetime total. The
  calendar keeps as many weeks as the terminal has room for.
- Under the calendar, the cursor's day or week; then, when the terminal has
  rows for them, the year's busiest models and its tokens by weekday, side by
  side from 96 columns.

`h`/`l` (or the arrows) move a week, `j`/`k` a day, `g`/`G` to the oldest day and
today. Tokens are input plus output, as upstream's bars measure them. Colours
are mixed from the theme's Decor ink toward the brand colour, so they follow
the base16 theme.

## Daemon

`GET /usage` accepts `days` up to 371 instead of 90, and every answer carries a
`profile` object computed over all of `usage_hours` and the turn ledger,
whatever `days`, `provider` and `account` narrow:
`lifetime_tokens`, `lifetime_calls`, `active_days`, `first_day`, `peak_day`,
`peak_day_tokens`, `longest_streak_days`, `current_streak_days` and
`longest_turn_ms`. Days follow `utc_offset_minutes`. The longest turn is the
longest completed `input_turns` row still kept; upstream prunes turns of
deleted sessions. The profile tab reads the year only when it is first opened
and on `ctrl+r`, so the days tab costs what it did.

The profile sums the hours itself instead of with SQLite's `SUM()`, which
raises `integer overflow` once a day leaves the int64 range; an hour whose
upstream trigger already added past int64 holds a REAL, read as the integer it
approximates. Totals are exact below the int64 ceiling, and
`lifetime_tokens`, `lifetime_calls`, `peak_day_tokens` and `longest_turn_ms`
saturate at 9223372036854775807 rather than refuse. The peak day is chosen on
the exact totals. Upstream's window (`days`, `lines`, `scopes`) still refuses
with 503 when its own sums overflow, and then the profile is not sent either.

Source: `apps/albedo/src/albedo/usage/usage_profile.gleam`, the
`http/http_resources.gleam` overlay, `cli/internal/daemon/usage.go`,
`cli/internal/tui/usage_profile.go` and the `usage.go`/`usage_view.go`
overlays. Tests: `test/suite_usage_profile_test.gleam`,
`test/suite_usage_profile_overflow_test.gleam`,
`test/usage_profile_e2e_test.py`, `TestUsage*` and `TestGetUsageDecodesTheProfile`.
The E2E runner patches upstream `e2e/usage_test.py` for the 371-day cap
(`test/fixtures/usage-window-fixtures.json`).
