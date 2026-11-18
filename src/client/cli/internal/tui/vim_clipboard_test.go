package tui

import (
	"reflect"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
)

// Inspect only the terminal copy command: tests must not overwrite the user's
// clipboard or wait for the copy-status timer. CopyText also retains its native
// local clipboard command alongside this OSC 52 request.
func yankClipboardMessage(t *testing.T, cmd tea.Cmd) tea.Msg {
	t.Helper()
	if cmd == nil {
		t.Fatal("yank returned no clipboard command")
	}
	status, ok := cmd().(tea.BatchMsg)
	if !ok || len(status) != 2 {
		t.Fatal("missing copy feedback batch")
	}
	transports, ok := status[0]().(tea.BatchMsg)
	if !ok || len(transports) != 2 {
		t.Fatal("missing terminal and local clipboard transports")
	}
	return transports[0]()
}

func TestVimYanksWriteSystemClipboard(t *testing.T) {
	for _, tc := range []struct{ name, text, keys, want string }{
		{"line", "one two", "yy", "one two\n"},
		{"word", "one two", "yw", "one "},
		{"counted lines", "one\ntwo\nthree", "2yy", "one\ntwo\n"},
		{"text object", "αβ gamma", "yiw", "αβ"},
		{"find", "one two!", "yf!", "one two!"},
		{"till", "one two!", "yt!", "one two"},
		{"empty line", "", "yy", "\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 24)
			m.TextArea.SetValue(tc.text)
			m.vimPosition(0)
			before := m.vimSnapshot()
			var cmd tea.Cmd
			for _, r := range tc.keys {
				m, cmd = m.Update(navigationKey(r))
			}
			got := yankClipboardMessage(t, cmd)
			if !reflect.DeepEqual(got, tea.SetClipboard(tc.want)()) {
				t.Fatalf("clipboard %q, want %q", got, tc.want)
			}
			if m.vimSnapshot() != before || len(m.vim.undo) != 0 {
				t.Fatal("yank edited the draft or undo history")
			}
			// Repeating the same yank must still export it, not only update on change.
			for _, r := range tc.keys {
				m, cmd = m.Update(navigationKey(r))
			}
			if !reflect.DeepEqual(yankClipboardMessage(t, cmd), got) {
				t.Fatal("repeated yank was not exported")
			}
		})
	}
}

func TestVimDeletesWriteSystemClipboard(t *testing.T) {
	for _, tc := range []struct{ name, text, keys, want, left string }{
		{"line", "one\ntwo", "dd", "one\n", "two"},
		{"counted lines", "one\ntwo\nthree", "2dd", "one\ntwo\n", "three"},
		{"word", "one two", "dw", "one ", "two"},
		{"change word", "one two", "cw", "one", " two"},
		{"change line", "one two", "cc", "one two\n", ""},
		{"character", "one", "x", "o", "ne"},
		{"to end", "one two", "D", "one two", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 24)
			m.TextArea.SetValue(tc.text)
			m.vimPosition(0)
			var cmd tea.Cmd
			for _, r := range tc.keys {
				m, cmd = m.Update(navigationKey(r))
			}
			if got := yankClipboardMessage(t, cmd); !reflect.DeepEqual(got, tea.SetClipboard(tc.want)()) {
				t.Fatalf("clipboard %q, want %q", got, tc.want)
			}
			if m.TextArea.Value() != tc.left {
				t.Fatalf("draft %q, want %q", m.TextArea.Value(), tc.left)
			}
		})
	}
}

func TestVimRepeatedFindYankWritesClipboard(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m.TextArea.SetValue("a,b,c")
	m.vimPosition(0)
	vimKeys(&m, "f", ",")
	m, _ = m.Update(navigationKey('y'))
	m, cmd := m.Update(navigationKey(';'))
	if !reflect.DeepEqual(yankClipboardMessage(t, cmd), tea.SetClipboard(",b,")()) {
		t.Fatal("repeated find lost clipboard command")
	}
}

func TestVimUnfinishedYankDoesNotWriteClipboard(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m.TextArea.SetValue("word")
	for _, r := range "yf!" {
		var cmd tea.Cmd
		m, cmd = m.Update(navigationKey(r))
		if cmd != nil {
			t.Fatal("unsuccessful yank exported text")
		}
	}
}
