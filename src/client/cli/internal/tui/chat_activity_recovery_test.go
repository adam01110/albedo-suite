package tui

import (
	"albedo/cli/internal/daemon"
	"errors"
	"strings"
	"testing"
)

func TestActivityStreamShutdownAndResume(t *testing.T) {
	for _, recovering := range []bool{false, true} {
		m := activityChat(t)
		activityStart(&m, "unfinished", "working")
		m, _ = m.Update(ChatStreamResultMsg{SessionID: m.SessionID, Generation: m.Generation, Recovering: recovering, Err: errors.New("disconnected")})
		for _, row := range m.activityRows() {
			if row.Tone == ToneActive {
				t.Fatal("stream error left live activity")
			}
		}
		if !strings.Contains(activityText(m), "unknown") {
			t.Fatal("lost unfinished call count")
		}
	}
	m := activityChat(t)
	activityStart(&m, "unfinished", "working")
	m, _ = m.Update(ChatStreamClosedMsg{SessionID: m.SessionID, Generation: m.Generation})
	for _, row := range m.activityRows() {
		if row.Tone == ToneActive {
			t.Fatal("closed stream left live activity")
		}
	}
	activityStart(&m, "resumed", "resumed work")
	activityFinish(&m, "resumed", "resumed work", `{"status":"ok"}`)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	if strings.Contains(activityText(m), "unfinished") {
		t.Fatal("resolved turn revived stale unfinished count")
	}
}

func TestActivityHistoricalTerminalDoesNotPoisonLiveTurn(t *testing.T) {
	for _, old := range []daemon.StreamEvent{
		{Type: daemon.EventTurnCompleted, Outcome: daemon.OutcomeFailed},
		{Type: daemon.EventTurnCompleted, Outcome: daemon.OutcomeInterrupted},
		{Type: daemon.EventError},
		{Type: daemon.EventInterrupted},
	} {
		m := activityChat(t)
		activityStart(&m, "current", "current")
		old.Replayed = true
		activityEvent(&m, old)
		activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "newer", Source: "chat", Replayed: true})
		if len(m.progressOrder) != 1 || m.Stopped || m.TurnFailed {
			t.Fatalf("historical %s changed live flags", old.Type)
		}
		activityStart(&m, "current", "new progress")
		if rows := m.activityRows(); len(rows) == 0 || rows[0].Tone != ToneActive {
			t.Fatalf("historical %s suppressed live work: %#v", old.Type, rows)
		}
	}
}

func TestActivityCanonicalReplacementInvalidatesProjection(t *testing.T) {
	m := activityChat(t)
	activityFinish(&m, "a", "cached row", `{"status":"ok"}`)
	before := activityText(m)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: "tool-a", ToolName: "python", ToolTitle: "cached row", ToolResult: `{"status":"error"}`})
	after := activityText(m)
	if before == after || !strings.Contains(after, "! cached row") {
		t.Fatal("canonical replacement retained cached result state")
	}
}

func TestActivityRenderedCacheAndLayout(t *testing.T) {
	m := activityChat(t)
	activityStart(&m, "a", "first label")
	if m.layoutSidebar != m.sidebarWidth() || m.layoutSidebar == 0 {
		t.Fatal("first activity did not reserve sidebar layout")
	}
	before := m.View()
	activityStart(&m, "a", "new label")
	after := m.View()
	if before == after {
		t.Fatal("equal-row activity update reused cached frame")
	}
	if after != fromScratch(m) {
		t.Fatal("activity frame differs from uncached view")
	}
	activityFinish(&m, "a", "new label", `{"status":"error"}`)
	if m.View() != fromScratch(m) {
		t.Fatal("finished activity reused stale frame")
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	if m.View() != fromScratch(m) {
		t.Fatal("terminal activity reused stale frame")
	}
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "next", Source: "chat"})
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	if m.layoutSidebar == 0 || m.View() != fromScratch(m) {
		t.Fatal("empty next turn dropped earlier activity layout")
	}
}

func TestActivityOlderHistoryAndReplayPreserveLatest(t *testing.T) {
	m := activityChat(t)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "current", Source: "chat", Text: "current"})
	activityFinish(&m, "current", "current label", `{"status":"ok"}`)
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
	older := ChatOlderLoadedMsg{SessionID: m.SessionID, Generation: m.Generation, Page: &daemon.HistoryPage{Events: []daemon.StreamEvent{
		{Type: daemon.EventUser, EntryID: "old-user", Source: "chat", Replayed: true},
		{Type: daemon.EventTool, EntryID: "old-tool", ToolName: "older-tool", Replayed: true},
		{Type: daemon.EventTool, EntryID: "tool-current", ToolName: "python", ToolTitle: "current label", Replayed: true},
	}}}
	m.loadingOlder = true
	m, _ = m.Update(older)
	// A page arriving twice is ignored once loading has finished.
	m, _ = m.Update(older)
	rows := m.activityRows()
	if len(rows) != 2 || rows[0].Text != "current label" || rows[1].Text != "older-tool" || m.activityCount() != 2 {
		t.Fatalf("older paging: %#v count %d", rows, m.activityCount())
	}
	activityStart(&m, "live", "live label")
	activityEvent(&m, daemon.StreamEvent{Type: daemon.EventMessage, EntryID: "historical-message", Replayed: true, Text: "old message"})
	if len(m.progressOrder) != 1 {
		t.Fatal("replayed message cleared live calls")
	}
	for _, status := range []string{"interrupted", "cancelled"} {
		state, tone := activityResult(HistoryEntry{ToolName: "python", ToolResult: `{"status":"` + status + `"}`})
		if state != "interrupted" || tone != ToneWarning {
			t.Fatalf("%s: %s %s", status, state, tone)
		}
	}
}
