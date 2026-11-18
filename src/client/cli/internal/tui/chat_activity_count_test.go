package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"strings"
	"testing"
)

func TestActivityCountBeyondVisibleRows(t *testing.T) {
	m := activityChat(t)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, Source: "chat", Text: "work"})
	for i := 0; i < 20; i++ {
		activityFinish(&m, fmt.Sprint(i), "same label", `{"status":"ok"}`)
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	if rows := m.activityRows(); len(rows) != activityLimit {
		t.Fatalf("visible rows: %d", len(rows))
	}
	if text := activityText(m); !strings.Contains(text, "activity · 20") {
		t.Fatal(text)
	}
	// Later turns keep adding to the session counter.
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, Source: "chat", Text: "more"})
	activityFinish(&m, "next", "same label", `{"status":"ok"}`)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	if text := activityText(m); !strings.Contains(text, "activity · 21") {
		t.Fatal(text)
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, Source: "mail", Text: "wake"})
	activityFinish(&m, "woken", "same label", `{"status":"ok"}`)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	if text := activityText(m); !strings.Contains(text, "activity · 22") {
		t.Fatal(text)
	}
	// A snapshot reset rebuilds the count from replayed history.
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventReset})
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: "replayed", ToolName: "python", ToolResult: `{"status":"ok"}`, Replayed: true})
	if got := m.activityCount(); got != 1 {
		t.Fatalf("reset count: %d", got)
	}
}

func TestActivityCountRetentionAndFooter(t *testing.T) {
	m := activityChat(t)
	m.History.MaxEntries = 10
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, Source: "chat", Text: "work"})
	for i := 0; i < 30; i++ {
		activityFinish(&m, fmt.Sprint(i), "same label", `{"status":"ok"}`)
	}
	if got := m.activityCount(); got != 31 { // Includes the current working phase.
		t.Fatalf("live count: %d", got)
	}
	before := activityText(m)
	activityFinish(&m, "extra", "same label", `{"status":"ok"}`)
	if text := activityText(m); text == before || !strings.Contains(text, "activity · 32") {
		t.Fatalf("count-only cache change: %s", text)
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	if got := m.activityCount(); got != 31 {
		t.Fatalf("settled count: %d", got)
	}
	m.SetSize(60, 12)
	if text := strings.Join(m.glanceCounts(), " "); !strings.Contains(text, "activity 31") {
		t.Fatal(text)
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, Source: "chat", Text: "next"})
	if got := m.activityCount(); got < 31 {
		t.Fatalf("new turn dropped session count: %d", got)
	}
}
