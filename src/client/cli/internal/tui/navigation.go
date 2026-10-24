package tui

import (
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// searchNavigation reserves hjkl for browsing until search is explicitly opened
// or another printable key starts a query. Esc keeps the query and resumes browsing.
type searchNavigation struct{ editing bool }

func (n *searchNavigation) key(msg tea.KeyPressMsg, input *textinput.Model, horizontal bool) (tea.KeyPressMsg, bool) {
	key := msg.String()
	if n.editing {
		if key == "esc" {
			n.editing = false
			input.Blur()
			return msg, true
		}
		return msg, false
	}
	if key == "/" {
		n.editing = true
		input.Focus()
		return msg, true
	}
	code := map[string]rune{"j": tea.KeyDown, "k": tea.KeyUp, "h": tea.KeyEsc, "l": tea.KeyEnter}[key]
	if horizontal {
		if key == "h" {
			code = tea.KeyLeft
		}
		if key == "l" {
			code = tea.KeyRight
		}
	}
	if code != 0 {
		return tea.KeyPressMsg{Code: code}, false
	}
	if msg.Text != "" {
		n.editing = true
		input.Focus()
	}
	return msg, false
}

func (n *searchNavigation) paste(msg tea.Msg, input *textinput.Model) {
	if _, ok := msg.(tea.PasteMsg); ok {
		n.editing = true
		input.Focus()
	}
}

func (n searchNavigation) filterLine(input textinput.Model) string {
	prefix := DefaultStyles.Faint.Render(n.hint()) + "  " + promptLead()
	input.SetWidth(max(1, input.Width()-ansi.StringWidth(prefix)))
	return prefix + input.View()
}

func (n searchNavigation) hint() string {
	if n.editing {
		return "SEARCH · esc navigate"
	}
	return "NORMAL · hjkl navigate · / search"
}
