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
	if text := activityText(m); !strings.Contains(text, "activity · 20") {
		t.Fatal(text)
	}
	// Later chat and mail turns keep adding to the session counter.
	for i, source := range []daemon.InputSource{"chat", "mail"} {
		activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, Source: source, Text: "more"})
		activityFinish(&m, fmt.Sprint("next", source), "same label", `{"status":"ok"}`)
		activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
		if text, want := activityText(m), fmt.Sprint("activity · ", 21+i); !strings.Contains(text, want) {
			t.Fatalf("%s turn: %s", source, text)
		}
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
	activityFinish(&m, "extra", "same label", `{"status":"ok"}`)
	if text := activityText(m); !strings.Contains(text, "activity · 32") {
		t.Fatalf("evicted history dropped count: %s", text)
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	if got := m.activityCount(); got != 31 {
		t.Fatalf("settled count: %d", got)
	}
	m.SetSize(60, 12)
	if text := strings.Join(m.glanceCounts(), " "); !strings.Contains(text, "activity 31") {
		t.Fatal(text)
	}
}
