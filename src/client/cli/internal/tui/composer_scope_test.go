package tui

import (
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
)

func TestComposerScopeLiveListSearch(t *testing.T) {
	for _, query := range []string{"hjkl", "123gg", "a r"} {
		m := NewPickerModel("pick", []PickerItem{{ID: query, Label: query}}, true, "")
		m.SetSize(80, 24)
		for _, r := range query {
			m, _ = m.Update(navigationKey(r))
		}
		if m.SearchInput.Value() != query {
			t.Fatalf("literal filter: got %q, want %q", m.SearchInput.Value(), query)
		}
		if strings.Contains(ansi.Strip(m.View()), "NORMAL") || strings.Contains(ansi.Strip(m.View()), "SEARCH") {
			t.Fatal("list advertises composer modes")
		}
	}
}

func TestComposerScopeApplicationShortcuts(t *testing.T) {
	for _, normal := range []bool{false, true} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(100, 24)
		m.TextArea.SetValue("draft")
		m.vim.normal = normal
		before := m.vimSnapshot()
		for _, key := range []rune{'s', 'o'} {
			next, cmd := m.Update(tea.KeyPressMsg{Code: key, Mod: tea.ModCtrl})
			if cmd == nil {
				t.Fatalf("Ctrl+%c did not navigate", key)
			}
			switch msg := cmd().(type) {
			case ChatBackToSessionsMsg:
				if key != 's' {
					t.Fatal("wrong destination")
				}
			case ChatOpenAgentsMsg:
				if key != 'o' {
					t.Fatal("wrong destination")
				}
			default:
				t.Fatalf("Ctrl+%c returned %T", key, msg)
			}
			if next.vimSnapshot() != before || next.vim.normal != normal {
				t.Fatal("shortcut changed input")
			}
		}
	}
}

func TestComposerScopeNoGlobalVimOverlays(t *testing.T) {
	chat := newTestChatModel(t, &daemon.Session{ID: "s"})
	chat.SetSize(100, 24)
	chat.TextArea.SetValue("draft")
	chat.vimPosition(0)
	before := chat.vimSnapshot()
	app := &AppModel{State: AppStateChat, Chat: chat, ActiveSession: &daemon.Session{ID: "s"}, Width: 100, Height: 24}
	for _, key := range []tea.KeyPressMsg{navigationKey(' '), {Code: tea.KeyF1}, {Code: tea.KeyF2}, {Code: tea.KeyTab}} {
		app.Update(key)
		if app.Chat.vimSnapshot() != before || app.State != AppStateChat {
			t.Fatal("former global key changed draft or screen")
		}
		view := ansi.Strip(app.View().Content)
		if strings.Contains(view, "Keyboard reference") || strings.Contains(view, "Workspace destinations") {
			t.Fatal("retired overlay still opens")
		}
	}
}

func TestComposerScopeSlashEditsInput(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.TextArea.SetValue("draft")
	m.vimPosition(0)
	m, _ = m.Update(navigationKey('/'))
	if m.vim.normal || m.TextArea.Value() != "/draft" {
		t.Fatalf("slash did not edit input: %q", m.TextArea.Value())
	}
}

func TestComposerScopeShellFooterKeepsInputMode(t *testing.T) {
	for _, width := range []int{8, 40, 80, 120} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(width, 24)
		m.History.Append(HistoryEntry{Kind: EntryShell})
		for _, normal := range []bool{false, true} {
			m.vim.normal = normal
			footer := ansi.Strip(m.renderFooter())
			if !strings.Contains(footer, m.vimMode()) || ansi.StringWidth(footer) > m.chatWidth() {
				t.Fatalf("invalid input footer: %q", footer)
			}
		}
	}
}
