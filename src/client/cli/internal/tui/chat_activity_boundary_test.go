package tui

import (
	"albedo/cli/internal/daemon"
	"strings"
	"testing"
)

func TestActivityMailTurnBoundaries(t *testing.T) {
	m := activityChat(t)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "first", Source: "chat", Text: "first"})
	activityStart(&m, "a", "prior")
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "injected", Source: "mail", Text: "in flight"})
	if len(m.progressOrder) != 1 {
		t.Fatal("in-flight mail discarded activity")
	}
	activityFinish(&m, "a", "prior", `{"status":"ok"}`)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "mail-turn", Source: "mail", Text: "new turn"})
	for _, row := range m.activityRows() {
		if strings.Contains(row.Text, "prior") {
			t.Fatal("old tool leaked into tool-free mail turn")
		}
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	for _, row := range m.activityRows() {
		if strings.Contains(row.Text, "prior") {
			t.Fatal("old tool leaked after mail turn completion")
		}
	}
}

func TestActivityGenericAndBackgrounded(t *testing.T) {
	m := activityChat(t)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: "generic", ToolName: "custom.lookup", ToolArgs: map[string]any{"secret": "do-not-display"}, ToolResult: "do-not-display"})
	if rows := m.activityRows(); len(rows) == 0 || rows[len(rows)-1].Text != "finished · custom.lookup" {
		t.Fatalf("generic: %#v", rows)
	}
	activityFinish(&m, "bg", "long cell", `{"status":"backgrounded"}`)
	rows := m.activityRows()
	if !strings.HasPrefix(rows[len(rows)-2].Text, "backgrounded") || rows[len(rows)-2].Tone == ToneWarning {
		t.Fatalf("backgrounded: %#v", rows)
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{CallID: "bad", Name: "custom", Phase: "running\x1b]52;c;secret\a\n"}})
	if text := activityText(m); strings.Contains(text, "secret") || strings.Contains(text, "do-not-display") {
		t.Fatal(text)
	}
}
