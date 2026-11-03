package tui

import (
	"fmt"
	"slices"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// The transcript and the composer have independent focus. The action anchor
// survives row reflow; ordinary row movement clears it deliberately.
type transcriptNavigation struct {
	active    bool
	row       int
	anchor    rowAction
	count     int
	pending   string
	searching bool
	search    textinput.Model
	query     string
}

func (m *ChatModel) readerFocus(active bool) {
	m.reader.active = active
	m.vim.resetInput()
	m.reader.count, m.reader.pending = 0, ""
	if active {
		m.TextArea.Blur()
		m.reader.anchor = rowAction{}
		m.reader.row = min(max(m.reader.row, m.scrollOffset), max(0, min(len(m.frameLines)-1, m.scrollOffset+m.Viewport.Height()-1)))
		m.Follow = false
	} else {
		m.TextArea.Focus()
	}
}

func (m *ChatModel) readerAnchor() {
	if m.reader.anchor.key != "" {
		for i, line := range m.frameLines {
			if action, ok := actionOf(line); ok && action == m.reader.anchor {
				m.reader.row = i
				break
			}
		}
	}
	m.reader.row = min(max(0, m.reader.row), max(0, len(m.frameLines)-1))
}

func (m *ChatModel) readerReveal() {
	m.readerAnchor()
	m.Follow = false
	if m.reader.row < m.scrollOffset {
		m.scrollOffset = m.reader.row
	}
	if m.reader.row >= m.scrollOffset+m.Viewport.Height() {
		m.scrollOffset = max(0, m.reader.row-m.Viewport.Height()+1)
	}
	m.refreshViewportContent()
}

func (m *ChatModel) readerAction(by int) {
	m.readerAnchor()
	start := m.reader.row
	last := rowAction{}
	if start < len(m.frameLines) {
		last, _ = actionOf(m.frameLines[start])
	}
	for i := start + by; i >= 0 && i < len(m.frameLines); i += by {
		act, ok := actionOf(m.frameLines[i])
		if ok && act != last {
			m.reader.row, m.reader.anchor = i, act
			m.readerReveal()
			return
		}
	}
}

func (m *ChatModel) readerFind(by int) {
	if m.reader.query == "" || len(m.frameLines) == 0 {
		return
	}
	m.readerAnchor()
	total := len(m.frameLines)
	query := strings.ToLower(m.reader.query)
	for step := 1; step <= total; step++ {
		at := (m.reader.row + by*step%total + total) % total
		if strings.Contains(strings.ToLower(ansi.Strip(m.frameLines[at])), query) {
			m.reader.row, m.reader.anchor = at, rowAction{}
			m.readerReveal()
			return
		}
	}
	m.AddNotice("No transcript match: " + m.reader.query)
}

func (m *ChatModel) handleReader(msg tea.KeyPressMsg) (tea.Cmd, bool) {
	key := msg.String()
	if m.reader.searching {
		switch key {
		case "esc":
			m.reader.searching = false
		case "enter":
			m.reader.query = m.reader.search.Value()
			m.reader.searching = false
			m.readerFind(1)
		default:
			var cmd tea.Cmd
			m.reader.search, cmd = m.reader.search.Update(msg)
			return cmd, true
		}
		return nil, true
	}
	// Tab changes pane only in normal mode, never while typing or completing.
	if key == "tab" && m.vim.normal && len(m.CommandMenu.Matches(m.TextArea.Value())) == 0 {
		m.readerFocus(!m.reader.active)
		return nil, true
	}
	if !m.reader.active {
		return nil, false
	}
	m.readerAnchor()
	if key == "esc" && (m.reader.count > 0 || m.reader.pending != "") {
		m.reader.count, m.reader.pending = 0, ""
		return nil, true
	}
	if key == "esc" || key == "ctrl+c" {
		return nil, false
	}
	if len(key) == 1 && key[0] >= '1' && key[0] <= '9' || key == "0" && m.reader.count > 0 {
		m.reader.count = min(999, m.reader.count*10+int(key[0]-'0'))
		return nil, true
	}
	count := max(1, m.reader.count)
	m.reader.count = 0
	previous := m.reader.pending
	m.reader.pending = ""
	switch key {
	case "i", "a", "I", "A":
		m.readerFocus(false)
		return nil, false
	case "h", "q":
		return func() tea.Msg { return ChatBackToSessionsMsg{} }, true
	case "/":
		m.reader.search = newFilter("Find in transcript")
		m.reader.search.SetValue(m.reader.query)
		m.reader.search.CursorEnd()
		m.reader.search.SetWidth(max(1, m.chatWidth()-10))
		m.reader.searching = true
	case "n":
		m.readerFind(1)
	case "N":
		m.readerFind(-1)
	case "]":
		for range count {
			m.readerAction(1)
		}
	case "[":
		for range count {
			m.readerAction(-1)
		}
	case "g":
		if previous != "g" {
			m.reader.pending = "g"
			return nil, true
		}
		if m.droppedSettledLines > 0 {
			m.rebuildSettledLines()
			m.refreshViewportContent()
		}
		m.reader.row, m.reader.anchor = 0, rowAction{}
		m.readerReveal()
	case "G":
		m.reader.row, m.reader.anchor = max(0, len(m.frameLines)-1), rowAction{}
		m.Follow = true
		m.refreshViewportContent()
	case "j", "down", "k", "up", "ctrl+d", "ctrl+u", "pgdown", "pgup":
		delta := count
		if key == "ctrl+d" || key == "ctrl+u" {
			delta *= max(1, m.Viewport.Height()/2)
		}
		if key == "pgdown" || key == "pgup" {
			delta *= max(1, m.Viewport.Height())
		}
		if key == "k" || key == "up" || key == "ctrl+u" || key == "pgup" {
			delta = -delta
		}
		m.reader.row += delta
		m.reader.anchor = rowAction{}
		m.readerReveal()
	case "enter", "l":
		if m.reader.row < len(m.frameLines) {
			if act, ok := actionOf(m.frameLines[m.reader.row]); ok {
				// Destructive shell cancellation remains on its explicit stop chord.
				if act.verb == "cancel" {
					m.AddNotice("Use ctrl+shift+x to stop a running shell")
					return nil, true
				}
				m.reader.anchor = act
				return m.actAt(m.reader.row), true
			}
		}
	case "y":
		if m.reader.row < len(m.frameLines) {
			return m.copied(strings.TrimSpace(ansi.Strip(m.frameLines[m.reader.row]))), true
		}
	case "o":
		if m.reader.row < len(m.frameLines) {
			line := ansi.Strip(m.frameLines[m.reader.row])
			for col := railWidth; col < ansi.StringWidth(line); col++ {
				if target, ok := fileTargetAt(line, col, m.Workspace); ok {
					return m.openFileCmd(target), true
				}
			}
			if target, ok := m.diffTargetAt(m.reader.row); ok {
				return m.openFileCmd(target), true
			}
		}
	case "ctrl+shift+o", "ctrl+shift+x", "ctrl+j", "ctrl+k", "ctrl+o", "ctrl+n":
		return nil, false
	}
	return nil, true
}

func (m *ChatModel) readerRows(rows []string) []string {
	if !m.reader.active {
		return rows
	}
	m.readerAnchor()
	at := m.reader.row - m.scrollOffset
	if at < 0 || at >= len(rows) {
		return rows
	}
	rows = slices.Clone(rows)
	// Use the existing rail cell: focus must not shift wrapping or the sidebar.
	rows[at] = DefaultStyles.You.Render("▎") + ansi.Cut(rows[at], 1, m.chatWidth())
	return rows
}

func (m ChatModel) readerStatus() string {
	if m.reader.searching {
		return "FIND  /" + m.reader.search.View()
	}
	if !m.reader.active {
		return m.vimMode()
	}
	follow := ""
	if m.Follow {
		follow = " · LIVE"
	}
	return fmt.Sprintf("NORMAL · TRANSCRIPT %d/%d%s", min(m.reader.row+1, len(m.frameLines)), len(m.frameLines), follow)
}
