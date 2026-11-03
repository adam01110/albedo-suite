# Passive TUI activity sidebar

## Goal

Show what the selected agent is doing and what it recently did, below the existing
background/running jobs section of the chat sidebar. Derive the view from events
Albedo already receives. Do not ask the model to maintain a plan or checklist.

## Design

Visual thesis: a quiet, compact activity ledger using the existing sidebar's
spacing, tones, and typography; current activity is more prominent than history.
Content hierarchy: existing extension glances, existing background jobs, Activity.
Interaction: updates follow existing stream/status refreshes; resize uses existing
sidebar clipping/fallback; the transcript remains the detailed evidence view.
Do not add decorative animation, new shortcuts, clickable controls, or a second
job/agent management surface for this first version.

## Behavior

- Add an `activity` section immediately after background jobs, or in that same
  position when no jobs are present. Keep existing glances and job behavior.
- Show a compact current activity when the session is running, using observed tool
  progress or agent phase. When there are concurrent calls, avoid reporting that
  only one exists; show bounded active entries or an explicit additional count.
- Show a small recent history of settled tool actions, newest relevant actions
  first. Keep the display to approximately six content rows and storage bounded.
  Prefer existing bounded history/progress structures over a duplicate event log.
- Use existing labels/trace metadata for tool/cell descriptions and command/file
  summaries. Python-cell titles are useful labels, but are descriptions supplied
  by the model, not verified semantic accomplishments. Never invent summaries of
  code intent or claim a test passed just because a tool invocation completed.
- Use neutral labels such as `finished` or the existing tool action label for
  settled invocations. Mark an explicit tool error as an error, not success. A
  successful Python invocation is not evidence every subprocess exited zero.
- Generic tools must still produce useful bounded labels. Do not display raw
  Python bodies, full tool arguments/results, secrets, raw thinking, or arbitrary
  terminal control sequences in this new surface. Sanitize to one terminal row
  and truncate by display width using the project's existing helpers.
- Distinguish active, settled, failed, and interrupted/unknown where the available
  events support it. On idle/turn completion, errors, interruption, and stream
  reset, no stale entry may continue to appear active.
- Scope history to the current/latest observed turn. A genuine next user turn
  clears prior activity. Replay/reset/reconnect must not turn historical work
  into live activity or duplicate items; replayed settled rows can be rebuilt
  from the existing bounded transcript if that is reliable. Older-history paging
  must not replace the latest activity with an old turn.
- Session switches must not leak another session's activity. Preserve existing
  generation checks and cached-frame correctness; updates must invalidate the
  sidebar when its activity changes even if row counts stay the same.
- When idle, retain recent settled activity where available; show no empty section
  for a fresh session with no observed activity. When the sidebar cannot fit,
  use the existing compact omission/fallback behavior without overflow or damage
  to transcript/composer sizing.

## Boundaries

Client-side only unless existing event data makes a requirement impossible; raise
that limitation before expanding scope. No provider calls, prompt/tool schema
changes, model-generated task state, new dependencies, percentage/ETA, inferred
future steps, source-code parsing of Python to guess behavior, new persistent
storage, automatic system activation, or changes to personal Albedo settings.
No package/upstream pin updates. Sparse source-overlay conventions still apply:
new replacements require pristine baseline manifest entries, never suite hashes.

## Acceptance and verification

1. Deterministic tests show activity below jobs and after extension glances, and
   present when jobs are absent. Existing job grace behavior stays unchanged.
2. Event-driven tests cover tool start/update/finish, overlapping calls, explicit
   failures, turn completion, interruption/error, next-turn clearing, reset and
   replay, and session/generation isolation. Test the actual stream reducer and
   rendered sidebar, not only an isolated helper.
3. Tests cover narrow/short layouts, Unicode/truncation and control characters,
   bounded output/history, and sidebar-cache invalidation at equal row counts.
4. Run focused regressions, the full client Go test suite in a materialized copy
   of the pinned upstream with overlays applied, source formatting, and explicit
   files.check. Wire new tests into package checks if existing filters omit them.
5. Build both suite package variants and run relevant flake checks where feasible.
   Use temporary homes/fake services; never contact live model providers, restart
   the user's daemon, or rebuild/switch the system for verification.
6. Provide a deterministic rendered example from the actual view code for review,
   including a running job, an active action, and settled/error rows.

## Workspace delivery

Implement and review in the isolated `albedo-suite-activity-sidebar` Jujutsu
workspace. Leave the described change there for user review; do not silently
merge it into the default workspace or publish it.
