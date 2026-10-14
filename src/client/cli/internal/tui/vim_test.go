package tui

import (
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
)

func vimKeys(m *ChatModel, keys ...string) {
	for _, k := range keys {
		msg := tea.KeyPressMsg{}
		switch k {
		case "esc":
			msg.Code = tea.KeyEscape
		case "ctrl+r":
			msg.Code = 'r'
			msg.Mod = tea.ModCtrl
		default:
			msg.Code = []rune(k)[0]
			msg.Text = k
		}
		*m, _ = m.Update(msg)
	}
}

func TestVimModesAndUndo(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	if m.vimMode() != "INSERT" {
		t.Fatal(m.vimMode())
	}
	vimKeys(&m, "a", "b", "c", "esc", "0", "x")
	if m.TextArea.Value() != "bc" || m.vimMode() != "NORMAL" {
		t.Fatal(m.TextArea.Value(), m.vimMode())
	}
	vimKeys(&m, "u")
	if m.TextArea.Value() != "abc" {
		t.Fatal(m.TextArea.Value())
	}
	vimKeys(&m, "ctrl+r")
	if m.TextArea.Value() != "bc" {
		t.Fatal(m.TextArea.Value())
	}
	vimKeys(&m, "i", "z", "esc", "u")
	if m.TextArea.Value() != "bc" {
		t.Fatal(m.TextArea.Value())
	}
}

func TestVimMotions(t *testing.T) {
	for _, tc := range []struct {
		text, key        string
		pos, count, want int
	}{
		{"one two!", "w", 0, 1, 4}, {"one two!", "e", 0, 1, 2},
		{"one two!", "b", 4, 1, 0}, {"   word", "b", 3, 1, 0},
		{"αβ γδ", "w", 0, 1, 3}, {"one two three", "w", 0, 2, 8},
		{"abc\ndef", "j", 1, 1, 5}, {"abc\ndef", "k", 5, 1, 1},
		{"abc\ndef", "$", 4, 1, 6}, {"   x", "^", 0, 1, 3},
	} {
		got, ok := vimMotion([]rune(tc.text), tc.pos, tc.key, tc.count)
		if !ok || got != tc.want {
			t.Errorf("%q %s: got %d want %d", tc.text, tc.key, got, tc.want)
		}
	}
}

func TestVimOperators(t *testing.T) {
	for _, tc := range []struct {
		keys   []string
		want   string
		normal bool
	}{
		{[]string{"d", "w"}, "two three", true},
		{[]string{"d", "2", "w"}, "three", true},
		{[]string{"c", "w"}, " two three", false},
		{[]string{"d", "d"}, "", true},
		{[]string{"2", "x"}, "e two three", true},
		{[]string{"y", "w", "P"}, "one one two three", true},
	} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(80, 24)
		m.TextArea.SetValue("one two three")
		m.vim.normal = true
		m.vimPosition(0)
		vimKeys(&m, tc.keys...)
		if m.TextArea.Value() != tc.want || m.vim.normal != tc.normal {
			t.Errorf("%v: %q normal %v", tc.keys, m.TextArea.Value(), m.vim.normal)
		}
	}
}

func TestVimMultilineUnicode(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(30, 24)
	m.TextArea.SetValue("αβγ\nδεζ\nend")
	m.vim.normal = true
	m.vimPosition(1)
	vimKeys(&m, "j")
	if m.TextArea.Line() != 1 || m.TextArea.Column() != 1 {
		t.Fatal(m.vimSnapshot())
	}
	vimKeys(&m, "d", "d")
	if m.TextArea.Value() != "αβγ\nend" {
		t.Fatal(m.TextArea.Value())
	}
	vimKeys(&m, "g", "g", "O")
	if m.TextArea.Value() != "\nαβγ\nend" || m.TextArea.Line() != 0 {
		t.Fatal(m.vimSnapshot())
	}
}

func TestVimFooter(t *testing.T) {
	for _, width := range []int{40, 80, 120} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(width, 24)
		for _, normal := range []bool{false, true} {
			m.vim.normal = normal
			footer := ansi.Strip(m.renderFooter())
			a, b, c := strings.Index(footer, "sessions"), strings.Index(footer, m.vimMode()), strings.Index(footer, "commands")
			t.Logf("width=%d mode=%s footer=%q", width, m.vimMode(), footer)
			if b < 0 || !(a >= 0 && a < b && b < c) {
				t.Fatalf("width %d: %q", width, footer)
			}
			if width == 40 && !strings.HasSuffix(footer, "—/—") {
				t.Fatal(footer)
			}
			if width == 120 && !strings.Contains(footer, "your messages") {
				t.Fatal(footer)
			}
			if ansi.StringWidth(footer) > m.chatWidth() {
				t.Fatal(footer)
			}
		}
	}
}

func TestVimEscapePreservesStoppingAndMenus(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m.Status.Running = true
	vimKeys(&m, "esc")
	if !m.Stopping || m.vim.normal {
		t.Fatal("escape did not stop running turn")
	}
	m.Status.Running = false
	m.TextArea.SetValue("/model")
	vimKeys(&m, "esc")
	if m.vim.normal {
		t.Fatal("menu escape entered normal mode")
	}
	vimKeys(&m, "esc")
	if !m.vim.normal {
		t.Fatal("second escape did not enter normal mode")
	}
}

func TestVimMarkersAndLineRegister(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(30, 24)
	marker := m.Pastes.add("payload")
	m.TextArea.SetValue("a" + marker + "b")
	m.vim.normal = true
	m.vimPosition(2)
	vimKeys(&m, "x")
	if m.TextArea.Value() != "ab" {
		t.Fatal(m.TextArea.Value())
	}
	vimKeys(&m, "u")
	if m.TextArea.Value() != "a"+marker+"b" {
		t.Fatal(m.TextArea.Value())
	}
	m.TextArea.SetValue("one\ntwo")
	m.vimPosition(0)
	vimKeys(&m, "y", "y", "p")
	if m.TextArea.Value() != "one\none\ntwo" {
		t.Fatal(m.TextArea.Value())
	}
	m.TextArea.SetValue(strings.Repeat("abcdef", 20) + "\nnext")
	m.vimPosition(125)
	if m.TextArea.Line() != 1 || m.TextArea.Column() != 4 {
		t.Fatal(m.vimSnapshot())
	}
}

func TestVimTerminalKeysAndShortcuts(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m.TextArea.SetValue("one two")
	m.vim.normal = true
	m.vimPosition(0)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	if m.TextArea.Column() != 1 || !m.vim.normal {
		t.Fatal(m.vimSnapshot())
	}
	before := m.Flags.Diffs
	m, _ = m.Update(tea.KeyPressMsg{Code: 'j', Mod: tea.ModCtrl})
	if m.Flags.Diffs == before || !m.vim.normal {
		t.Fatal("Ctrl+J did not retain diff toggle")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'A', Text: "A", Mod: tea.ModShift})
	if m.vim.normal || m.TextArea.Column() != 7 || m.TextArea.Value() != "one two" {
		t.Fatal("Shift+A did not enter append mode", m.vimSnapshot())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: '!', Text: "!", Mod: tea.ModShift})
	if m.TextArea.Value() != "one two!" {
		t.Fatal(m.TextArea.Value())
	}
	vimKeys(&m, "esc")
	m.Status.Idle = true
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.TextArea.Value() != "" || len(m.vim.undo) != 0 || len(m.vim.redo) != 0 || m.vim.insert != nil {
		t.Fatal("submission retained draft/history")
	}
}

func TestVimFooterExpandedUsage(t *testing.T) {
	prompt, cached, window := 396000, 392000, 1000000
	for _, width := range []int{40, 80, 120} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(width, 24)
		m.Usage = &daemon.Usage{Model: "test", PromptTokens: &prompt, CachedPromptTokens: &cached}
		m.Model = "test"
		m.window = &window
		m.windowModel = &m.Model
		footer := ansi.Strip(m.renderFooter())
		t.Logf("width=%d expanded=%q", width, footer)
		if !strings.Contains(footer, "INSERT") || ansi.StringWidth(footer) > m.chatWidth() {
			t.Fatal(footer)
		}
		if width >= 80 {
			a, b, c := strings.Index(footer, "sessions"), strings.Index(footer, "INSERT"), strings.Index(footer, "commands")
			if !(a >= 0 && a < b && b < c) {
				t.Fatal(footer)
			}
		}
	}
}
