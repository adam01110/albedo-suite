package tui

import (
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"testing"
)

func TestVimMotionRegressions(t *testing.T) {
	for _, tc := range []struct {
		name, text string
		pos        int
		keys       []string
		want       string
		wantPos    int
	}{
		{"repeat_delete_last", "abc", 2, []string{"x", "x"}, "a", 0},
		{"word_eof_cursor", "abc", 0, []string{"w", "x"}, "ab", 1},
		{"change_word_spacing", "one two", 0, []string{"c", "w", "z", "esc"}, "z two", 0},
		{"change_one_letter_word", "a two", 0, []string{"c", "w", "z", "esc"}, "z two", 0},
		{"change_final_letter", "one two", 2, []string{"c", "w", "z", "esc"}, "onz two", 2},
		{"change_two_words", "one two three", 0, []string{"c", "2", "w", "z", "esc"}, "z three", 0},
		{"change_undo", "one two", 0, []string{"c", "w", "z", "esc", "u"}, "one two", 0},
		{"change_redo", "one two", 0, []string{"c", "w", "z", "esc", "u", "ctrl+r"}, "z two", 0},
		{"open_undo", "abc", 0, []string{"o", "z", "esc", "u"}, "abc", 0},
		{"open_above_undo", "abc", 1, []string{"O", "z", "esc", "u"}, "abc", 1},
		{"delete_down", "abc\ndef\nghi", 1, []string{"d", "j"}, "ghi", 0},
		{"delete_up", "abc\ndef\nghi", 5, []string{"d", "k"}, "ghi", 0},
		{"delete_to_last", "abc\ndef\nghi", 0, []string{"d", "G"}, "", 0},
		{"delete_to_first", "abc\ndef\nghi", 8, []string{"d", "g", "g"}, "", 0},
		{"delete_to_numbered_line", "abc\ndef\nghi", 0, []string{"d", "2", "G"}, "ghi", 0},
		{"yank_down", "abc\ndef\nghi", 1, []string{"y", "j", "P"}, "abc\ndef\nabc\ndef\nghi", 0},
		{"count_line_end", "abc\ndef\nghi", 0, []string{"2", "$"}, "abc\ndef\nghi", 6},
		{"count_goto", "abc\ndef\nghi", 0, []string{"2", "G"}, "abc\ndef\nghi", 4},
		{"count_goto_first", "abc\ndef\nghi", 8, []string{"2", "g", "g"}, "abc\ndef\nghi", 4},
		{"linewise_paste_cursor", "one\ntwo", 0, []string{"y", "y", "p", "x"}, "one\nne\ntwo", 4},
		{"character_paste_cursor", "abc", 0, []string{"y", "l", "p", "x"}, "abc", 1},
		{"undo_repeat", "abc", 0, []string{"x", "x", "2", "u"}, "abc", 0},
		{"redo_repeat", "abc", 0, []string{"x", "x", "2", "u", "2", "ctrl+r"}, "c", 0},
		{"count_multiply", "one two three four five six seven", 0, []string{"2", "d", "3", "w"}, "seven", 0},
		{"change_lines_undo", "abc\ndef\nghi", 1, []string{"c", "j", "z", "esc", "u"}, "abc\ndef\nghi", 1},
		{"change_to_end_undo", "abc", 1, []string{"C", "z", "esc", "u"}, "abc", 1},
		{"delete_last_line_register", "one\ntwo", 4, []string{"d", "d", "p"}, "one\ntwo", 4},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 24)
			m.TextArea.SetValue(tc.text)
			m.vim.normal = true
			m.vimPosition(tc.pos)
			vimKeys(&m, tc.keys...)
			if m.TextArea.Value() != tc.want || m.vimSnapshot().pos != tc.wantPos {
				t.Fatalf("keys %v: text=%q pos=%d, want text=%q pos=%d", tc.keys, m.TextArea.Value(), m.vimSnapshot().pos, tc.want, tc.wantPos)
			}
		})
	}
}

func TestVimMotionNewlinePassthrough(t *testing.T) {
	for _, mod := range []tea.KeyMod{tea.ModShift, tea.ModAlt} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(80, 24)
		m.TextArea.SetValue("abc")
		m.vim.normal = true
		m.vimPosition(1)
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter, Mod: mod})
		if m.TextArea.Value() != "a\nbc" {
			t.Fatalf("modifier %v: %q", mod, m.TextArea.Value())
		}
	}
}
