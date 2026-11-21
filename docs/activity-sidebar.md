# TUI activity sidebar

The chat sidebar shows `activity` after extension glances, background jobs and
[agents](agents-sidebar.md).
It uses stream events, tool progress, bounded transcript history and the
daemon's session tool count; there is no model-maintained plan, extra request,
setting or persistent log.

Up to six content rows show the current phase or three active calls plus an
additional-call count, followed by the most recent tool invocations across
turns. The activity counter totals every tool call in the session plus live
calls, not just the six visible rows, the latest turn or the loaded history
window, and is also used in the narrow-screen footer. New messages, mail and
wakes add to it rather than resetting it.

The daemon supplies the total, so leaving and re-entering a session keeps the
same count. The session snapshot carries `session_tool_calls`, the committed
tool results in the session's transcript, and each live `tool` event carries
the updated total including that result (suite-only fields in
`src/server/docs/openapi.yaml`, counted by `albedo/history/tool_count.gleam`).
If a live event's ledger read fails, the client adds that one call to the last
total. A daemon without the field falls back to counting loaded history: a
snapshot reset rebuilds the count from the replayed window and older pages add
their calls. Replayed settled tools reconstruct recent rows, but replayed
progress never becomes live work.

Rows show the agent's cell title without a tool-name or status prefix. Titles
describe activity, not verified accomplishments. Active work retains its active
marker; explicit errors and interruptions use warning markers, while returned
and backgrounded Python cells remain neutral. If a stream or turn ends before a
call result is observed, an `unknown` or `interrupted` count records the missing
outcomes.
Resumed work replaces that uncertainty count.

Labels are single-line, terminal-control-stripped and display-width-truncated.
The sidebar does not show Python bodies, tool arguments, result bodies or raw
thinking. Generic tools fall back to their name. The transcript remains the
place to inspect detailed evidence. Existing narrow/short-screen omission and
footer counts apply.

An illustrative sidebar at 32 columns:

```text
background jobs · 1
● go test ./...

activity · 3
● update tests
! check fixture
○ inspect inputs
```

`test/suite_tool_count_test.gleam` checks the server count, and
`TestActivityCountFollowsDaemonSessionTotal` and `TestSessionToolCallsDecode`
check the client. Regression tests also cover stream reduction, concurrency,
neutral subprocess outcomes, errors, interruption, reset/replay, recovery,
turn/session/generation boundaries, sanitization, clipping and equal-row-count
frame-cache updates.
Both package variants run the `TestActivity` cases in the client check's single
`go test` over `internal/terminal` and `internal/tui`.
