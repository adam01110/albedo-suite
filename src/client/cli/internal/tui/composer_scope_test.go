package tui

import (
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"testing"

	"github.com/charmbracelet/x/ansi"
	"strings"
)

// Only the suite's own ctrl+s destination is topical here: ctrl+o is an
// unchanged upstream binding with its own coverage.
func TestComposerScopeApplicationShortcuts(t *testing.T) {
	for _, normal := range []bool{false, true} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(100, 24)
		m.TextArea.SetValue("draft")
		m.vim.normal = normal
		before := m.vimSnapshot()
		next, cmd := m.Update(tea.KeyPressMsg{Code: 's', Mod: tea.ModCtrl})
		if cmd == nil {
			t.Fatal("Ctrl+S did not navigate")
		}
		if _, ok := cmd().(ChatBackToSessionsMsg); !ok {
			t.Fatal("Ctrl+S left the chat")
		}
		if next.vimSnapshot() != before || next.vim.normal != normal {
			t.Fatal("shortcut changed input")
		}
	}
}

func TestComposerScopeSlashEditsInput(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.TextArea.SetValue("draft")
	m.vimPosition(0)
	// NORMAL mode consumes printable keys, including space.
	m, _ = m.Update(navigationKey(' '))
	if m.TextArea.Value() != "draft" {
		t.Fatalf("NORMAL space reached the composer: %q", m.TextArea.Value())
	}
	m, _ = m.Update(navigationKey('/'))
	if m.vim.normal || m.TextArea.Value() != "/draft" {
		t.Fatalf("slash did not edit input: %q", m.TextArea.Value())
	}
}

func TestComposerScopeUnlabelledInputBoundary(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m.TextArea.SetValue("draft")
	m.syncLayout()
	if rule := ansi.Strip(m.composeRule(m.chatWidth())); strings.Contains(rule, "compose") {
		t.Fatalf("input boundary keeps a compose label: %q", rule)
	}
}
