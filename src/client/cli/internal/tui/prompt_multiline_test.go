// The composer breaks its frame in ways only keystrokes and a real wrapping
// layout reveal: the e2e harness drives the TUI in process with no PTY, so wrap
// boundaries and the prompt height cap cannot be observed there.
package tui

import (
	"fmt"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// composer sizes a chat like a small terminal.
func composer(t *testing.T, width, height int) ChatModel {
	t.Helper()
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(width, height)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'i', Text: "i"})
	return m
}

func typePrompt(m ChatModel, text string) ChatModel {
	for _, r := range text {
		m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
	return m
}

// frame checks the chat view is exactly height rows with the separator
// directly above the footer, and hands back the stripped rows.
func frame(t *testing.T, m ChatModel, height int) []string {
	t.Helper()
	lines := strings.Split(ansi.Strip(m.View()), "\n")
	if len(lines) != height {
		t.Fatalf("view is %d rows, want %d", len(lines), height)
	}
	if !strings.Contains(lines[len(lines)-2], "─") {
		t.Fatalf("expected the separator above the footer, got %q", lines[len(lines)-2])
	}
	if !strings.Contains(lines[len(lines)-1], m.vimMode()) {
		t.Fatalf("expected the footer last, got %q", lines[len(lines)-1])
	}
	return lines
}

// A long prompt wraps without losing text or adding a blank row, submit and
// the six-row cap reset the frame, and alt+enter adds a line.
func TestComposerScopePromptFrame(t *testing.T) {
	const width, height = 60, 25
	altEnter := tea.KeyPressMsg{Code: tea.KeyEnter, Mod: tea.ModAlt}
	m := composer(t, width, height)
	m.Status.Phase = &phaseResting
	if m.promptHeight() != 1 {
		t.Fatalf("initial promptHeight %d, want 1", m.promptHeight())
	}
	frame(t, m, height)

	long := "this is a very long prompt sentence that should definitely wrap across multiple lines in a sixty column terminal"
	m = typePrompt(m, long)
	if m.promptHeight() <= 1 {
		t.Fatalf("promptHeight %d, want the long line wrapped", m.promptHeight())
	}
	lines := frame(t, m, height)
	if view := ansi.Strip(m.View()); !strings.Contains(view, "this is a very long prompt") {
		t.Fatalf("the prompt's first row vanished from the view:\n%s", view)
	}
	if m.TextArea.Value() != long {
		t.Fatalf("typing lost input: %q", m.TextArea.Value())
	}
	if last := strings.TrimSpace(lines[len(lines)-3]); last == "" {
		t.Fatalf("the prompt has an empty row above the separator: %q", lines[len(lines)-3])
	}

	// Submit resets the prompt to one line.
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.promptHeight() != 1 {
		t.Fatalf("promptHeight %d after Enter, want 1", m.promptHeight())
	}

	// Alt+enter adds a line instead of submitting.
	m = typePrompt(m, "hello")
	m, _ = m.Update(altEnter)
	m = typePrompt(m, "world")
	if m.promptHeight() != 2 {
		t.Fatalf("promptHeight %d after alt+enter, want 2", m.promptHeight())
	}
	frame(t, m, height)

	// Past the cap the prompt scrolls inside six rows and keeps every character.
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	for i := 1; i <= 10; i++ {
		m = typePrompt(m, fmt.Sprintf("line %d with plenty of characters to exceed 400 total chars across all lines", i))
		if i < 10 {
			m, _ = m.Update(altEnter)
		}
	}
	if len(m.TextArea.Value()) <= 400 {
		t.Fatalf("prompt kept only %d chars, want every line", len(m.TextArea.Value()))
	}
	if m.promptHeight() != 6 {
		t.Fatalf("promptHeight %d, want the six-row cap", m.promptHeight())
	}
	frame(t, m, height)
	if view := ansi.Strip(m.View()); !strings.Contains(view, "line 10") {
		t.Fatalf("line 10 is not visible in the scrolled view:\n%s", view)
	}
}

// The order of a reset and status replies is controlled here: real HTTP cannot
// deterministically deliver a superseded status after a snapshot arrives.
func TestComposerScopeStaleStatus(t *testing.T) {
	const draft = "keep this draft"
	m := composer(t, 80, 22)
	defer m.Close()
	status := ChatStatusMsg{
		SessionID: m.SessionID, Generation: m.Generation,
		Revision: m.statusRevision, Status: &daemon.AgentStatus{Idle: true},
	}
	m, _ = m.Update(ChatStreamEventMsg{
		SessionID: m.SessionID, Generation: m.Generation,
		Event: daemon.StreamEvent{Type: daemon.EventReset},
	})
	m, _ = m.Update(status)
	m = typePrompt(m, draft)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.TextArea.Value() != draft || len(m.pendingUsers) != 0 {
		t.Fatal("a stale status unblocked the composer")
	}
}
