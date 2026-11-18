package tui

import (
	"albedo/cli/internal/daemon"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
)

// notifyChat is a blurred chat whose session is named, with one turn open
// since start.
func notifyChat(t *testing.T, start int64) ChatModel {
	t.Helper()
	t.Setenv("TMUX", "")
	m := activityChat(t)
	m.notifyMode = notifyOn
	m.notifyTitle = func() string { return "fix flaky upload tests" }
	m.focus(false)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "user-1", Source: "chat", Text: "fix it", Timestamp: &start})
	return m
}

func notifyReply(m *ChatModel, at int64, text string) {
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventMessage, EntryID: "reply", Text: text, Timestamp: &at})
}

// rawWrites runs cmd and every command it batches, collecting what tea.Raw
// would write. Commands that block (ticks, reads) are abandoned after a wait.
func rawWrites(cmd tea.Cmd) []string {
	if cmd == nil {
		return nil
	}
	done := make(chan tea.Msg, 1)
	go func() { done <- cmd() }()
	select {
	case msg := <-done:
		switch msg := msg.(type) {
		case tea.RawMsg:
			return []string{msg.Msg.(string)}
		case tea.BatchMsg:
			var out []string
			for _, c := range msg {
				out = append(out, rawWrites(c)...)
			}
			return out
		}
	case <-time.After(200 * time.Millisecond):
	}
	return nil
}

func TestTurnNotifyCompletedWhileBlurred(t *testing.T) {
	start := time.Now().Add(-time.Hour).UnixMilli()
	m := notifyChat(t, start)
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTool, EntryID: "tool-1", ToolName: "python"})
	notifyReply(&m, start+252_000, "## **Root cause** was the `retry` timer; fixed <now> & tested")
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTurnCompleted, Outcome: daemon.OutcomeCompleted})
	want := "\x1b]777;notify;albedo · fix flaky upload tests;Done in 4m 12s · 1 tool — Root cause was the retry timer, fixed &lt;now&gt; &amp; tested\x1b\\\a"
	if m.notifyPending != want {
		t.Fatalf("got %q\nwant %q", m.notifyPending, want)
	}
	cmd := m.takeTurnNotification()
	if got := rawWrites(cmd); len(got) != 1 || got[0] != want || m.notifyPending != "" {
		t.Fatalf("take: %q pending %q", got, m.notifyPending)
	}
	if m.takeTurnNotification() != nil {
		t.Fatal("sent twice")
	}
}

func TestTurnNotifyThroughUpdate(t *testing.T) {
	start := time.Now().Add(-time.Hour).UnixMilli()
	m := notifyChat(t, start)
	notifyReply(&m, start+30_000, "done")
	m, cmd := m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: daemon.StreamEvent{Type: daemon.EventTurnCompleted}})
	got := rawWrites(cmd)
	if len(got) != 1 || !strings.Contains(got[0], ";Done in 30s — done\x1b\\") || m.notifyPending != "" {
		t.Fatalf("stream: %q", got)
	}

	// A turn the status poll finds idle notifies the same way.
	m = notifyChat(t, start)
	notifyReply(&m, start+30_000, "polled")
	idle := daemon.AgentStatus{Idle: true}
	m, cmd = m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation, Revision: m.statusRevision, Status: &idle})
	if got := rawWrites(cmd); len(got) != 1 || !strings.Contains(got[0], "— polled") {
		t.Fatalf("status: %q", got)
	}
}

func TestTurnNotifyOutcomes(t *testing.T) {
	start := time.Now().Add(-time.Hour).UnixMilli()
	cases := []struct {
		name string
		end  daemon.StreamEvent
		want string
	}{
		{"failed", daemon.StreamEvent{Type: daemon.EventError, Text: "provider; overloaded\n\x1b[31mretry\x1b[0m"}, ";Failed after 1m 3s — provider, overloaded retry\x1b\\"},
		{"interrupted", daemon.StreamEvent{Type: daemon.EventInterrupted}, ";Interrupted after 1m 3s\x1b\\"},
		{"outcome interrupted", daemon.StreamEvent{Type: daemon.EventTurnCompleted, Outcome: daemon.OutcomeInterrupted}, ";Interrupted after 1m 3s\x1b\\"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := notifyChat(t, start)
			notifyReply(&m, start+63_000, "partial")
			m.handleStreamEvent(tc.end)
			if !strings.HasSuffix(m.notifyPending, tc.want+"\a") {
				t.Fatalf("got %q", m.notifyPending)
			}
		})
	}
}

func TestTurnNotifySuppressed(t *testing.T) {
	start := time.Now().Add(-time.Hour).UnixMilli()
	completed := daemon.StreamEvent{Type: daemon.EventTurnCompleted}

	m := notifyChat(t, start)
	m.focus(true)
	notifyReply(&m, start+60_000, "seen")
	m.handleStreamEvent(completed)
	if m.notifyPending != "" {
		t.Fatal("focused terminal notified")
	}

	m = notifyChat(t, start)
	notifyReply(&m, start+9_000, "quick")
	m.handleStreamEvent(completed)
	if m.notifyPending != "" {
		t.Fatal("short turn notified")
	}

	m = notifyChat(t, start)
	m.notifyMode = notifyOff
	notifyReply(&m, start+60_000, "off")
	m.handleStreamEvent(completed)
	if m.notifyPending != "" {
		t.Fatal("disabled mode notified")
	}

	m = notifyChat(t, start)
	replayed := completed
	replayed.Replayed = true
	notifyReply(&m, start+60_000, "history")
	m.handleStreamEvent(replayed)
	if m.notifyPending != "" {
		t.Fatal("replayed signoff notified")
	}

	// Your next message closing an unfinished turn is not a finish.
	m = notifyChat(t, start)
	notifyReply(&m, start+60_000, "first")
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventUser, EntryID: "user-2", Source: "chat", Text: "more"})
	if m.notifyPending != "" {
		t.Fatal("user message notified")
	}
}

func TestTurnNotifyBriefAndTitle(t *testing.T) {
	start := time.Now().Add(-time.Hour).UnixMilli()
	m := notifyChat(t, start)
	m.notifyMode = notifyBrief
	m.notifyTitle = func() string { return "a;b\n\x1b]0;evil\a" + strings.Repeat("x", 200) }
	notifyReply(&m, start+60_000, "secret reply")
	m.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	if strings.Contains(m.notifyPending, "secret") || strings.Contains(m.notifyPending, "evil") {
		t.Fatalf("leaked: %q", m.notifyPending)
	}
	title := strings.TrimPrefix(m.notifyPending, "\x1b]777;notify;")
	title = title[:strings.Index(title, ";")]
	if !strings.HasPrefix(title, "albedo · a,b ") || !strings.HasSuffix(title, "…") || len([]rune(title)) > 90 {
		t.Fatalf("title %q", title)
	}
	if !strings.HasSuffix(m.notifyPending, ";Done in 1m 0s\x1b\\\a") {
		t.Fatalf("brief body: %q", m.notifyPending)
	}
}

func TestTurnNotifyTmuxPassthrough(t *testing.T) {
	got := notificationSequence("t", "b", true)
	want := "\x1bPtmux;\x1b\x1b]777;notify;t;b\x1b\x1b\\\x1b\\\a"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestTurnNotifyMode(t *testing.T) {
	for value, want := range map[string]notifyMode{"": notifyOn, "on": notifyOn, " Brief ": notifyBrief, "off": notifyOff, "0": notifyOff} {
		t.Setenv("ALBEDO_NOTIFY", value)
		if got := turnNotifyMode(); got != want {
			t.Fatalf("%q: %v", value, got)
		}
	}
}
