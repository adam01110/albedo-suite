package tui

import (
	"strconv"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// searchNavigation separates query editing from commands. A retained filter
// never changes the meaning of a navigation key.
type searchNavigation struct {
	editing  bool
	count    int
	pendingG bool
	steps    int
}

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
	input.Blur()
	if key == "esc" && (n.count > 0 || n.pendingG) {
		n.count, n.pendingG = 0, false
		return msg, true
	}
	if key == "/" {
		n.count, n.pendingG = 0, false
		n.editing = true
		input.Focus()
		return msg, true
	}
	if len(key) == 1 && key[0] >= '1' && key[0] <= '9' || key == "0" && n.count > 0 {
		n.count = min(999, n.count*10+int(key[0]-'0'))
		return msg, true
	}
	if key == "g" && !n.pendingG {
		n.pendingG = true
		return msg, true
	}
	code := map[string]rune{"j": tea.KeyDown, "k": tea.KeyUp, "h": tea.KeyEsc, "l": tea.KeyEnter, "q": tea.KeyEsc, "G": tea.KeyEnd}[key]
	if n.pendingG {
		n.pendingG = false
		if key == "g" {
			code = tea.KeyHome
		}
	}
	if horizontal {
		if key == "h" {
			code = tea.KeyLeft
		}
		if key == "l" {
			code = tea.KeyRight
		}
	}
	switch key {
	case "ctrl+u":
		code = tea.KeyPgUp
	case "ctrl+d":
		code = tea.KeyPgDown
	}
	if code != 0 {
		n.steps, n.count = max(1, n.count), 0
		return tea.KeyPressMsg{Code: code}, false
	}
	// Already translated keys may pass through a containing screen and its list.
	if key != "up" && key != "down" && key != "home" && key != "end" && key != "pgup" && key != "pgdown" {
		n.steps, n.count = 0, 0
	}
	if msg.Text != "" {
		return msg, true
	}
	return msg, false
}

// move applies only list motions; callers keep ownership of activation and I/O.
func (n *searchNavigation) move(msg tea.KeyPressMsg, cursor *int, total, height int) bool {
	if n.editing && (msg.String() == "home" || msg.String() == "end") {
		return false
	}
	by, ok := map[string]int{"up": -1, "ctrl+p": -1, "down": 1, "ctrl+n": 1, "pgup": -max(1, height/2), "pgdown": max(1, height/2)}[msg.String()]
	switch msg.String() {
	case "home":
		*cursor = 0
	case "end":
		*cursor = max(0, total-1)
	default:
		if !ok {
			return false
		}
		*cursor = min(max(0, *cursor+by*max(1, n.steps)), max(0, total-1))
	}
	n.steps = 0
	return true
}

func (n *searchNavigation) paste(msg tea.Msg, input *textinput.Model) {
	if _, ok := msg.(tea.PasteMsg); ok {
		n.count, n.pendingG = 0, false
		n.editing = true
		input.Focus()
	}
}

func (n searchNavigation) filterLine(input textinput.Model) string {
	if !n.editing {
		input.Blur()
	}
	prefix := DefaultStyles.Faint.Render(n.hint()) + "  " + promptLead()
	input.SetWidth(max(1, input.Width()-ansi.StringWidth(prefix)))
	return prefix + input.View()
}

func (n searchNavigation) hint() string {
	if n.editing {
		return "SEARCH · esc navigate"
	}
	pending := ""
	if n.count > 0 {
		pending = " · " + strconv.Itoa(n.count)
	}
	if n.pendingG {
		pending += "g"
	}
	return "NORMAL · hjkl · gg/G · / search · F1 help" + pending
}
