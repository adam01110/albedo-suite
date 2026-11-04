package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type leaderEntry struct{ key, label, destination string }

func (o workspaceOverlay) leaderEntries() []leaderEntry {
	if o.group == "v" {
		return []leaderEntry{{"d", "Diffs", "diffs"}, {"c", "Compaction", "compaction"}, {"o", "Shell output", "shell"}}
	}
	entries := []leaderEntry{{"w", "Workspace", "workspace"}, {"s", "Sessions", "sessions"}, {"n", "New session", "new"}}
	if o.session {
		entries = append(entries, leaderEntry{"a", "Agents", "agents"}, leaderEntry{"m", "Model", "model"})
	}
	if o.chat {
		entries = append(entries, leaderEntry{"v", "View +", "view"})
	}
	return append(entries, leaderEntry{"?", "Keyboard reference", "keys"})
}

func (o workspaceOverlay) leaderRows(width, height int) []string {
	title := "space · actions"
	if o.group != "" {
		title = "space " + o.group + " · view"
	}
	rows := []string{DefaultStyles.Bold.Render(title)}
	if height >= len(o.leaderEntries())+4 {
		rows = append(rows, "")
	}
	for _, entry := range o.leaderEntries() {
		rows = append(rows, keyHints(hint{entry.key, entry.label}))
	}
	if height > len(rows) {
		if height > len(rows)+1 {
			rows = append(rows, "")
		}
		footer := "esc / backspace close"
		if o.group != "" {
			footer = "esc / backspace parent"
		}
		rows = append(rows, DefaultStyles.Faint.Render(footer))
	}
	for i := range rows {
		rows[i] = ansi.Truncate(rows[i], width, "…")
		rows[i] += strings.Repeat(" ", max(0, width-ansi.StringWidth(rows[i])))
	}
	return scrollWindow(rows, -1, width, height)
}

func (m *AppModel) closeWorkspaceOverlay() {
	m.workspaceOverlay = nil
	if m.Chat.leader != nil {
		m.Chat.leader = nil
		m.Chat.SetSize(m.Width, m.Height)
	}
}

func (m *AppModel) openLeader() {
	m.closeWorkspaceOverlay()
	o := &workspaceOverlay{leader: true, session: m.ActiveSession != nil, chat: m.State == AppStateChat}
	o.picker.SetSize(m.Width, m.Height)
	m.workspaceOverlay = o
	if m.State == AppStateChat {
		m.Chat.leader = o
		m.Chat.SetSize(m.Width, m.Height)
	}
}

func (m *AppModel) updateLeader(key tea.KeyPressMsg) tea.Cmd {
	o := m.workspaceOverlay
	switch key.String() {
	case "ctrl+c", "f2":
		m.closeWorkspaceOverlay()
		return nil
	case "esc", "backspace", "ctrl+h":
		if o.group != "" {
			o.group = ""
		} else {
			m.closeWorkspaceOverlay()
		}
		return nil
	}
	for _, entry := range o.leaderEntries() {
		if key.Mod & ^tea.ModShift != 0 || key.Text != entry.key {
			continue
		}
		switch entry.destination {
		case "view":
			o.group = "v"
			return nil
		case "workspace":
			m.openWorkspaceOverlay(false)
			return nil
		case "keys":
			m.openWorkspaceOverlay(true)
			return nil
		}
		m.closeWorkspaceOverlay()
		switch entry.destination {
		case "diffs", "compaction":
			if entry.destination == "diffs" {
				m.Chat.Flags.Diffs = !m.Chat.Flags.Diffs
			} else {
				m.Chat.Flags.Compaction = !m.Chat.Flags.Compaction
			}
			m.Chat.rebuildSettledLines()
			m.Chat.refreshViewportContent()
			return nil
		case "shell":
			return m.Chat.toggleLatestShell()
		default:
			return m.workspaceDestination(entry.destination)
		}
	}
	// Unmapped keys stay local; they must never edit or submit the draft.
	return nil
}
