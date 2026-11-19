# TUI activity sidebar

The chat sidebar shows `activity` after extension glances, background jobs and
[agents](agents-sidebar.md).
It uses existing stream events, tool progress and bounded transcript history;
there is no model-maintained plan, extra request, setting or persistent log.

Up to six content rows show the current phase or three active calls plus an
additional-call count, followed by the most recent tool invocations across
turns. The activity counter totals every tool call in the session's loaded
history plus live calls, not just the six visible rows or the latest turn, and
is also used in the narrow-screen footer. New messages, mail and wakes add to
it rather than resetting it. A snapshot reset rebuilds the count from the
replayed history window, and loading older history pages adds their calls, so
calls older than the loaded window are not counted. Replayed settled tools
reconstruct recent rows, but replayed progress never becomes live work.

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

A deterministic example produced by `TestActivityRenderedExample` through the
actual sidebar renderer (32 columns):

```text
background jobs · 1
● go test ./...

activity · 3
● update tests
! check fixture
○ inspect inputs
```

Regression tests cover stream reduction, concurrency, neutral subprocess
outcomes, errors, interruption, reset/replay, recovery, turn/session/generation
boundaries, sanitization, clipping and equal-row-count frame-cache updates.
Both package variants run `go test ./internal/tui -run '^TestActivity'`.
