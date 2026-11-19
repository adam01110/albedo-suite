# Agents sidebar

The chat sidebar lists the session's open child agents as `agents`, directly
below background jobs and above activity. Each row is the child's family name:

- `●` working: its stored stage is mid-turn (`model` or `tool`).
- `○` idle: open but waiting for input or mail.

Closed children, peers, grandchildren and other sessions' children are not
listed. The rows come from a glance the agents extension adds
(`albedo_ext_agents/sidebar.gleam`), read with the other glances while a
client watches the session. It reads the stage the daemon persists at turn
boundaries and the family table, so it wakes no child and adds no request.
A turn shows as working from its first committed input until it finishes.

The client keeps the extension glance order otherwise and only moves `agents`
after background jobs (`chat_footer.go`). Narrow or short screens fold it into
the footer counts like any other glance.

Tests: `test/suite_agents_glance_test.gleam` (server rows and tones) and
`go test ./internal/tui -run '^TestAgentsGlance'` (sidebar placement).
