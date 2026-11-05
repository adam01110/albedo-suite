# TUI activity sidebar

The chat sidebar shows `activity` after extension glances and background jobs.
It uses existing stream events, tool progress and bounded transcript history;
there is no model-maintained plan, extra request, setting or persistent log.

Up to six content rows show the current phase or three active calls plus an
additional-call count, followed by recent tool invocations from the latest turn.
The activity counter includes the full latest-turn total, not just the six
visible rows, and is also used in the narrow-screen footer. Settled actions
remain visible while idle. A new user turn clears them; mail
injected into an existing turn does not. Replayed settled tools can reconstruct
recent rows, but replayed progress never becomes live work. Older history paging
preserves the latest turn.

Tool names and cell titles describe invocations, not verified accomplishments.
`finished` means the tool returned, not that tests passed or all subprocesses
exited zero. Explicit errors and interruptions use warning rows; backgrounded
Python cells remain neutral. If a stream or turn ends before a call result is
observed, an `unknown` or `interrupted` count records the missing outcomes.
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
● running · python · update tes…
! error · python · check fixture
○ finished · python · inspect i…
```

Regression tests cover stream reduction, concurrency, neutral subprocess
outcomes, errors, interruption, reset/replay, recovery, turn/session/generation
boundaries, sanitization, clipping and equal-row-count frame-cache updates.
Both package variants run `go test ./internal/tui -run '^TestActivity'`.
