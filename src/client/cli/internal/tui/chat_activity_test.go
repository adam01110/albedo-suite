package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

func activityChat(t *testing.T) ChatModel {
	t.Helper()
	m := newTestChatModel(t, &daemon.Session{ID: "activity"})
	m.SetSize(120, 32)
	return m
}

func activityEvent(m *ChatModel, evt daemon.StreamEvent) {
	*m, _ = m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: evt})
}

func activityText(m ChatModel) string {
	rows, _ := m.sidebarRows()
	return ansi.Strip(strings.Join(rows, "\n"))
}

func activityStart(m *ChatModel, id, title string) {
	activityEvent(m, daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{CallID: id, Name: "python", Phase: "running", Title: title}})
}

func activityFinish(m *ChatModel, id, title, result string) {
	activityEvent(m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: "tool-" + id, ProgressCallID: id, ToolName: "python", ToolTitle: title, ToolResult: result})
}

func TestActivityLifecycleAndCache(t *testing.T) {
	m := activityChat(t)
	if text := activityText(m); text != "" {
		t.Fatalf("fresh sidebar: %s", text)
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "user-1", Source: "chat", Text: "work"})
	activityStart(&m, "a", "inspect inputs")
	before := activityText(m)
	if !strings.Contains(before, "inspect inputs") || strings.Contains(before, "python") || strings.Contains(before, "running ·") {
		t.Fatal(before)
	}
	activityStart(&m, "a", "updated label")
	if text := activityText(m); text == before || !strings.Contains(text, "updated la") {
		t.Fatal(text)
	}
	activityStart(&m, "b", "second call")
	if rows := m.activityRows(); len(rows) != 2 {
		t.Fatalf("concurrent: %#v", rows)
	}
	activityFinish(&m, "b", "second call", `{"status":"ok","output":"exit_code=1; tests failed"}`)
	if text := activityText(m); !strings.Contains(text, "second call") || strings.Contains(text, "finished ·") || strings.Contains(text, "python") {
		t.Fatal(text)
	}
	activityFinish(&m, "a", "updated label", `{"status":"error","error":"failed"}`)
	if rows := m.activityRows(); len(rows) < 2 || rows[1].Tone != ToneWarning || rows[1].Text != "updated label" {
		t.Fatalf("error: %#v", rows)
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	for _, row := range m.activityRows() {
		if row.Tone == ToneActive {
			t.Fatalf("stale active: %#v", row)
		}
	}
	if text := activityText(m); !strings.Contains(text, "second call") {
		t.Fatal(text)
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "user-2", Source: "chat", Text: "next"})
	for _, row := range m.activityRows() {
		if row.Text == "updated label" || row.Text == "second call" {
			t.Fatalf("old turn: %#v", row)
		}
	}
}

func TestActivityTerminalAndResetReplay(t *testing.T) {
	for _, kind := range []daemon.EventType{daemon.EventInterrupted, daemon.EventError, daemon.EventTurnCompleted, daemon.EventRetry} {
		t.Run(string(kind), func(t *testing.T) {
			m := activityChat(t)
			activityStart(&m, "live", "unfinished")
			activityEvent(&m, daemon.StreamEvent{Type: kind})
			text := activityText(m)
			if !strings.Contains(text, "unfinished") {
				t.Fatal(text)
			}
			for _, row := range m.activityRows() {
				if row.Tone == ToneActive {
					t.Fatalf("active: %#v", row)
				}
			}
			activityEvent(&m, daemon.StreamEvent{Type: daemon.EventReset})
			if text := activityText(m); text != "" {
				t.Fatalf("reset: %s", text)
			}
			replay := daemon.StreamEvent{Type: daemon.EventTool, EntryID: "replayed", ToolName: "python", ToolTitle: "historical", ToolResult: `{"status":"ok"}`, Replayed: true}
			activityEvent(&m, replay)
			activityEvent(&m, replay)
			if rows := m.activityRows(); len(rows) != 1 || rows[0].Tone == ToneActive {
				t.Fatalf("replay: %#v", rows)
			}
			activityEvent(&m, daemon.StreamEvent{Type: daemon.EventToolProgress, Replayed: true, Progress: &daemon.ToolProgress{CallID: "old", Name: "python"}})
			if len(m.progressOrder) != 0 {
				t.Fatal("replayed progress became live")
			}
		})
	}
}

func TestActivityIsolationAndIdle(t *testing.T) {
	m := activityChat(t)
	for _, msg := range []ChatStreamEventMsg{
		{SessionID: "another", Generation: m.Generation},
		{SessionID: m.SessionID, Generation: m.Generation + 1},
	} {
		msg.Event = daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{CallID: "wrong", Name: "secret"}}
		m, _ = m.Update(msg)
	}
	if text := activityText(m); text != "" {
		t.Fatal(text)
	}
	activityStart(&m, "a", "live")
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "old-user", Source: "chat", Replayed: true})
	if len(m.progressOrder) != 1 {
		t.Fatal("historical user cleared live progress")
	}
	idle := daemon.AgentStatus{Idle: true}
	m, _ = m.Update(ChatStatusMsg{SessionID: m.SessionID, Generation: m.Generation, Revision: m.statusRevision, Status: &idle})
	for _, row := range m.activityRows() {
		if row.Tone == ToneActive {
			t.Fatal("idle remains active")
		}
	}
	other := activityChat(t)
	if text := activityText(other); text != "" {
		t.Fatal(text)
	}
}

func TestActivityOrderBoundsAndSanitization(t *testing.T) {
	m := activityChat(t)
	m.Glances = []PageGlance{{Title: "extension", Rows: []PageRow{{Text: "existing"}}}}
	m.Status.RunningJobs = []protocol.KernelJob{{ID: "j", Command: "go test ./...", StartedAt: time.Now().Add(-time.Minute).UnixMilli()}}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, Source: "chat", Text: "work"})
	for i := 0; i < 20; i++ {
		activityFinish(&m, fmt.Sprint(i), "label", `{"status":"ok"}`)
	}
	for i := 0; i < 8; i++ {
		activityStart(&m, fmt.Sprint(i), "界\n\t\x1b[31mred\x1b[0m\x1b]52;c;secret\a"+strings.Repeat("界", 200))
	}
	rows := m.activityRows()
	if len(rows) != activityLimit || rows[3].Text != "+5 active calls" {
		t.Fatalf("bounds: %#v", rows)
	}
	for _, row := range rows {
		if strings.ContainsAny(row.Text, "\x1b\n\t\a") || ansi.StringWidth(row.Text) > 180 || strings.Contains(row.Text, "secret") {
			t.Fatalf("unsafe: %q", row.Text)
		}
	}
	text := activityText(m)
	if !(strings.Index(text, "extension") < strings.Index(text, "background jobs") && strings.Index(text, "background jobs") < strings.Index(text, "activity")) {
		t.Fatal(text)
	}
	for _, line := range strings.Split(text, "\n") {
		if ansi.StringWidth(line) > m.sidebarWidth() {
			t.Fatalf("overflow: %q", line)
		}
	}
	m.Status.RunningJobs = nil
	if !strings.Contains(activityText(m), "activity") {
		t.Fatal("missing without jobs")
	}
	m.SetSize(120, 10)
	drawn, _ := m.sidebarRows()
	if len(drawn) > m.Viewport.Height() {
		t.Fatal("short sidebar overflow")
	}
	m.SetSize(60, 12)
	if m.sidebarWidth() != 0 || len(m.sidebarColumn()) != 0 || !strings.Contains(strings.Join(m.glanceCounts(), " "), "activity") {
		t.Fatal("narrow fallback")
	}
}

func TestActivityRenderedExample(t *testing.T) {
	m := activityChat(t)
	m.Status.RunningJobs = []protocol.KernelJob{{ID: "j", Command: "go test ./...", StartedAt: time.Now().Add(-time.Minute).UnixMilli()}}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, Source: "chat", Text: "work"})
	activityFinish(&m, "a", "inspect inputs", `{"status":"ok"}`)
	activityFinish(&m, "b", "check fixture", `{"status":"error"}`)
	activityStart(&m, "c", "update tests")
	want := "background jobs · 1\n● go test ./...\n\nactivity · 3\n● update tests\n! check fixture\n○ inspect inputs"
	if got := activityText(m); got != want {
		t.Fatalf("sidebar:\n%s\nwant:\n%s", got, want)
	}
}

func TestActivityDescriptionOnly(t *testing.T) {
	for _, status := range []string{"ok", "error", "interrupted", "cancelled", "backgrounded"} {
		t.Run(status, func(t *testing.T) {
			m := activityChat(t)
			activityStart(&m, "a", "inspect inputs")
			if rows := m.activityRows(); len(rows) != 1 || rows[0].Text != "inspect inputs" {
				t.Fatalf("live: %#v", rows)
			}
			activityFinish(&m, "a", "inspect inputs", `{"status":"`+status+`"}`)
			activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
			if rows := m.activityRows(); len(rows) != 1 || rows[0].Text != "inspect inputs" {
				t.Fatalf("settled: %#v", rows)
			}
		})
	}
}
