package tui

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
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

func TestVimYankLocalClipboard(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Wayland clipboard transport is Linux-specific")
	}
	if os.Getenv("ALBEDO_VIM_CLIPBOARD_CHILD") == "1" {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(80, 24)
		m.TextArea.SetValue("copy outside albedo")
		m, _ = m.Update(navigationKey('y'))
		_, cmd := m.Update(navigationKey('y'))
		status, ok := cmd().(tea.BatchMsg)
		if !ok {
			t.Fatal("missing clipboard batch")
		}
		transports, ok := status[0]().(tea.BatchMsg)
		if !ok || len(transports) != 2 {
			t.Fatal("missing local clipboard command")
		}
		transports[1]()
		return
	}
	// A child process lets the clipboard library detect fake Wayland tools at
	// initialization. Neither the desktop clipboard nor a live compositor is used.
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Fatal(err)
	}
	cat, err := exec.LookPath("cat")
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	capture := filepath.Join(directory, "clipboard")
	script := fmt.Sprintf("#!%s\nexec %q > \"$ALBEDO_VIM_CLIPBOARD_CAPTURE\"\n", shell, cat)
	for _, name := range []string{"wl-copy", "wl-paste"} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	child := exec.CommandContext(ctx, executable, "-test.run=^TestVimYankLocalClipboard$")
	child.Env = append(os.Environ(), "PATH="+directory, "WAYLAND_DISPLAY=isolated-test", "ALBEDO_VIM_CLIPBOARD_CHILD=1", "ALBEDO_VIM_CLIPBOARD_CAPTURE="+capture)
	if output, err := child.CombinedOutput(); err != nil {
		t.Fatalf("clipboard child: %v\n%s", err, output)
	}
	text, err := os.ReadFile(capture)
	if err != nil || string(text) != "copy outside albedo\n" {
		t.Fatalf("native clipboard received %q: %v", text, err)
	}
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

func TestVimUnlabelledInputBoundary(t *testing.T) {
	for _, width := range []int{8, 40, 80, 120} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(width, 24)
		m.TextArea.SetValue("draft")
		m.syncLayout()
		rule := ansi.Strip(m.composeRule(m.chatWidth()))
		if strings.Contains(rule, "compose") || !strings.Contains(rule, "─") || ansi.StringWidth(rule) != m.chatWidth() {
			t.Fatalf("width=%d rule=%q", width, rule)
		}
		footer := ansi.Strip(m.renderFooter())
		if strings.Contains(footer, "COMPOSER") || strings.Contains(footer, "COMPOSE") {
			t.Fatal("uppercase compose label remains in footer")
		}
		rows := strings.Split(ansi.Strip(m.View()), "\n")
		if len(rows) != 24 {
			t.Fatalf("width=%d rows=%d: %q", width, len(rows), rows)
		}
		if !strings.Contains(strings.Join(rows, "\n"), rule) || slices.Contains(strings.Fields(strings.Join(rows, "\n")), "compose") {
			t.Fatal("redundant compose label remains")
		}
	}
}
