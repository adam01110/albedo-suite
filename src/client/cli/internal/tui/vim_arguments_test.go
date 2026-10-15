package tui

import (
	"albedo/cli/internal/daemon"
	"testing"
)

func TestVimLiteralArguments(t *testing.T) {
	for _, tc := range []struct {
		name, text string
		pos        int
		keys       []string
		want       string
		cursor     int
		mode       string
	}{
		{"find digit", "a1b1c", 0, []string{"2", "f", "1"}, "a1b1c", 3, "NORMAL"},
		{"find forward delete", "a,b,c", 0, []string{"d", "f", ","}, "b,c", 0, "NORMAL"},
		{"till forward delete", "a,b,c", 0, []string{"d", "t", ","}, ",b,c", 0, "NORMAL"},
		{"find backward delete", "a,b,c", 4, []string{"d", "F", ","}, "a,b", 2, "NORMAL"},
		{"till backward delete", "a,b,c", 4, []string{"d", "T", ","}, "a,b,c", 4, "NORMAL"},
		{"find repeat", "a,b,c", 0, []string{"f", ",", ";"}, "a,b,c", 3, "NORMAL"},
		{"till repeat", "a,b,c", 0, []string{"t", ",", ";"}, "a,b,c", 2, "NORMAL"},
		{"reverse does not change find", "a,b,c,d", 0, []string{"f", ",", ";", ",", ";"}, "a,b,c,d", 3, "NORMAL"},
		{"reverse repeat", "a,b,c", 0, []string{"f", ",", ";", ","}, "a,b,c", 1, "NORMAL"},
		{"no crossing lines", "abc\nx", 0, []string{"f", "x"}, "abc\nx", 0, "NORMAL"},
		{"replace unicode", "abc", 0, []string{"2", "r", "λ"}, "λλc", 1, "NORMAL"},
		{"replace space", "abc", 0, []string{"r", " "}, " bc", 0, "NORMAL"},
		{"find space", "a b", 0, []string{"f", " "}, "a b", 1, "NORMAL"},
		{"replace digit", "abc", 0, []string{"r", "2"}, "2bc", 0, "NORMAL"},
		{"replace too many", "abc", 0, []string{"4", "r", "z"}, "abc", 0, "NORMAL"},
		{"cancel", "abc", 0, []string{"d", "f", "esc", "l"}, "abc", 1, "NORMAL"},
		{"inside word", "one two", 1, []string{"d", "i", "w"}, " two", 0, "NORMAL"},
		{"around whitespace", "one  two rest", 4, []string{"d", "a", "w"}, "one rest", 3, "NORMAL"},
		{"around word", "one two", 1, []string{"d", "a", "w"}, "two", 0, "NORMAL"},
		{"inside WORD", "one-two rest", 4, []string{"d", "i", "W"}, " rest", 0, "NORMAL"},
		{"count words", "one two rest", 0, []string{"d", "2", "i", "w"}, " rest", 0, "NORMAL"},
		{"nested pair", "a(b(c)d)e", 4, []string{"d", "i", "("}, "a(b()d)e", 4, "NORMAL"},
		{"outer pair", "a(b(c)d)e", 4, []string{"d", "2", "a", "("}, "ae", 1, "NORMAL"},
		{"change quotes", "say \"hello\"", 6, []string{"c", "i", "\""}, "say \"\"", 5, "INSERT"},
		{"yank object", "one two", 0, []string{"y", "i", "w", "P"}, "oneone two", 2, "NORMAL"},
		{"undo object", "one two", 0, []string{"d", "a", "w", "u"}, "one two", 0, "NORMAL"},
		{"missing pair", "one two", 0, []string{"d", "i", "("}, "one two", 0, "NORMAL"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 24)
			m.TextArea.SetValue(tc.text)
			m.vimPosition(tc.pos)
			vimKeys(&m, tc.keys...)
			if got := m.vimSnapshot(); got.text != tc.want || got.pos != tc.cursor || m.vimMode() != tc.mode {
				t.Fatalf("got %#v %s, want %q @%d %s", got, m.vimMode(), tc.want, tc.cursor, tc.mode)
			}
		})
	}
}
