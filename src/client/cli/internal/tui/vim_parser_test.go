package tui

import (
	"albedo/cli/internal/daemon"
	"testing"
)

func TestVimCountParser(t *testing.T) {
	for _, tc := range []struct {
		name, digits, pending string
		operatorCount, count  int
		explicit              bool
	}{
		{"default", "", "", 0, 1, false},
		{"prefix", "23", "", 0, 23, true},
		{"operator_prefix", "3", "d", 2, 6, true},
		{"operator_default", "", "d", 0, 1, false},
		{"bounded", "999999999", "", 999, 999, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := vimState{pending: tc.pending, operatorCount: tc.operatorCount}
			for _, digit := range tc.digits {
				if !state.accumulateCount(string(digit)) {
					t.Fatal("digit not consumed")
				}
			}
			input := state.takeInput("w")
			if input.count != tc.count || input.explicit != tc.explicit || input.operator != tc.pending {
				t.Fatalf("input=%+v", input)
			}
			if state.count != 0 || state.pending != "" || state.operatorCount != 0 {
				t.Fatalf("parser retained prefix: %+v", state)
			}
		})
	}
	state := vimState{}
	if state.accumulateCount("0") || state.accumulateCount("x") {
		t.Fatal("motion parsed as count")
	}
}

func TestVimPrefixCancellation(t *testing.T) {
	for _, tc := range []struct {
		keys []string
		want string
		pos  int
	}{
		{[]string{"d", "2", "g", "g"}, "three", 0},
		{[]string{"g", "x"}, "one\ntwo\nthree", 0},
		{[]string{"2", "d", "esc", "l"}, "one\ntwo\nthree", 1},
		{[]string{"l", "d", "0"}, "ne\ntwo\nthree", 0},
	} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(80, 24)
		m.TextArea.SetValue("one\ntwo\nthree")
		m.vim.normal = true
		m.vimPosition(0)
		vimKeys(&m, tc.keys...)
		if m.TextArea.Value() != tc.want || m.vimSnapshot().pos != tc.pos {
			t.Fatalf("%v: %q pos=%d", tc.keys, m.TextArea.Value(), m.vimSnapshot().pos)
		}
		if m.vim.pending != "" || m.vim.count != 0 || m.vim.operatorCount != 0 {
			t.Fatalf("%v left pending state", tc.keys)
		}
	}
}

func TestVimMotionDefinitions(t *testing.T) {
	for name, spec := range vimMotions {
		if (spec.step == nil) == (spec.resolve == nil) {
			t.Fatalf("motion %q needs exactly one resolver", name)
		}
	}
	for name, command := range vimCommands {
		if command == nil {
			t.Fatalf("nil command %q", name)
		}
	}
}
