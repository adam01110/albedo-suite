package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testutil/tuishots"

	tea "charm.land/bubbletea/v2"
)

// Shots of albedo-suite's context picture: the inspector's bar, a preview
// of a session that has sent nothing, and a whole section in the reader.
func init() {
	inspector := func(snap *daemon.ContextSnapshot) func(int, int) string {
		return func(width, height int) string {
			m := NewContextInspectorModel(nil, "s")
			m.SetSize(width, height)
			m, _ = m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Snapshot: snap})
			return m.View()
		}
	}
	preview := usageSnapshot()
	preview.Sections = []daemon.ContextSection{preview.Sections[0], preview.Sections[2]}
	preview.Compaction.Size = &daemon.Size{Tokens: 11_000, Estimated: &daemon.EstimatedSize{Tokens: 11_000}}
	tuishots.Register("contextusage",
		tuishots.State{Name: "measured", View: inspector(usageSnapshot())},
		tuishots.State{Name: "preview", View: inspector(preview)},
		tuishots.State{Name: "reader-whole", View: func(width, height int) string {
			m := contextModel(width, height)
			m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
			m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
			m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
			page := historyPage()
			m, _ = m.Update(contextPageLoadedMsg{Gen: m.Generation, SectionID: "history", Data: &page})
			m.View()
			m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyPgDown})
			return m.View()
		}},
	)
}
