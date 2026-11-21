package tui

import (
	"albedo/cli/internal/daemon"
	"testing"
)

// A reconnect reports an idle session: a call that outlived its turn and
// reports afterwards is history, not live work, so the count a client showed
// before it left survives in the session it re-enters.
func TestActivityReconnectKeepsIdleCount(t *testing.T) {
	history := []daemon.StreamEvent{
		{Type: daemon.EventUser, EntryID: "u1", Source: daemon.SourceChat, Text: "work"},
		{Type: daemon.EventTool, EntryID: "t1", ProgressCallID: "c1", ToolName: "python", ToolTitle: "first", ToolResult: `{"status":"ok"}`, SessionToolCalls: new(1)},
		{Type: daemon.EventTurnCompleted, Outcome: daemon.OutcomeFailed},
	}
	m := activityChat(t)
	for _, evt := range history {
		activityEvent(&m, evt)
	}
	// The daemon snapshots the session idle with one committed call.
	resumed := activityChat(t)
	activityEvent(&resumed, daemon.StreamEvent{Type: daemon.EventReset, Snapshot: &daemon.Session{Status: daemon.AgentStatus{Idle: true}, SessionToolCalls: new(1)}})
	for _, evt := range history {
		evt.Replayed = true
		activityEvent(&resumed, evt)
	}
	late := daemon.StreamEvent{Type: daemon.EventTool, EntryID: "t2", ProgressCallID: "c2", ToolName: "python", ToolTitle: "late", ToolResult: `{"status":"ok"}`, SessionToolCalls: new(2)}
	activityEvent(&m, late)
	activityEvent(&resumed, late)
	if got, want := resumed.activityCount(), m.activityCount(); got != want {
		t.Fatalf("reconnect counted %d calls, live session %d", got, want)
	}
	for _, row := range resumed.activityRows() {
		if row.Tone == ToneActive {
			t.Fatalf("reconnect invented live work: %#v", resumed.activityRows())
		}
	}
}
