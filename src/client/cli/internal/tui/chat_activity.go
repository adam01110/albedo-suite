package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"encoding/json"
	"fmt"

	"github.com/charmbracelet/x/ansi"
)

const activityLimit = 6

// Activity labels deliberately exclude code, arguments and results. A cell title
// describes the invocation, not an independently verified accomplishment.
// A title with no visible text is not a label, so the name or the default wins.
func activityLabel(name, title string) string {
	label := cmp.Or(oneLine(ansi.Strip(title)), oneLine(ansi.Strip(name)), "tool")
	return ansi.Truncate(label, 160, "…")
}

func (m ChatModel) activityRows() []PageRow {
	var rows []PageRow
	live := m.Status.Running && !m.Status.Idle && !m.Stopped && !m.TurnFailed && !m.activityEnded
	if live {
		// Reserve history space, and account explicitly for every concurrent call.
		shown := min(len(m.progressOrder), 3)
		for i := len(m.progressOrder) - 1; i >= len(m.progressOrder)-shown; i-- {
			p := m.progressByCallID[m.progressOrder[i]]
			rows = append(rows, PageRow{Text: activityLabel(p.Name, p.Title), Tone: ToneActive})
		}
		if extra := len(m.progressOrder) - shown; extra > 0 {
			rows = append(rows, PageRow{Text: fmt.Sprintf("+%d active calls", extra), Tone: ToneActive})
		}
		if len(rows) == 0 {
			phase := "working"
			if m.Status.Phase != nil {
				phase = string(*m.Status.Phase)
			}
			rows = append(rows, PageRow{Text: activityLabel(phase, ""), Tone: ToneActive})
		}
	} else if m.activityRemainder.Text != "" {
		rows = append(rows, m.activityRemainder)
	} else if len(m.progressOrder) > 0 {
		rows = append(rows, PageRow{Text: fmt.Sprintf("unknown · %d unfinished calls", len(m.progressOrder)), Tone: ToneWarning})
	}
	if m.History == nil {
		return rows
	}
	// Recent calls span turns, so a new message or wake does not empty the list.
	entries := m.History.Entries()
	for i := len(entries) - 1; i >= 0 && len(rows) < activityLimit; i-- {
		e := &entries[i]
		if e.Kind != EntryTool {
			continue
		}
		if e.activity == nil {
			_, tone := activityResult(*e)
			e.activity = &PageRow{Text: activityLabel(e.ToolName, e.ToolTitle), Tone: tone}
		}
		rows = append(rows, *e.activity)
	}
	return rows
}

// activityCount totals the session's tool calls, so turn boundaries, history
// eviction, re-entry and the six-row display limit do not change the counter.
// Without the daemon's count it falls back to the calls in loaded history.
func (m ChatModel) activityCount() int {
	completed := m.activityTools
	if m.sessionTools != nil {
		completed = *m.sessionTools
	}
	pending := len(m.progressOrder)
	if pending == 0 && (m.activityRemainder.Text != "" ||
		(m.Status.Running && !m.Status.Idle && !m.Stopped && !m.TurnFailed && !m.activityEnded)) {
		pending = 1
	}
	return completed + pending
}

// Python status is an invocation outcome, never a subprocess exit-code verdict.
func activityResult(e HistoryEntry) (string, PageTone) {
	if e.ToolName == "python" {
		var result struct {
			Status string `json:"status"`
		}
		if json.Unmarshal([]byte(e.ToolResult), &result) == nil {
			switch result.Status {
			case "ok":
				return "finished", TonePlain
			case "backgrounded":
				return "backgrounded", TonePlain
			case "interrupted", "cancelled":
				return "interrupted", ToneWarning
			case "error":
				return "error", ToneWarning
			}
		}
	}
	if toolFailed(e) {
		return "error", ToneWarning
	}
	return "finished", TonePlain
}

// countOlderActivity adds the calls an older history page reveals; it mirrors
// showOlder's acceptance and de-duplication so a page is counted once.
func (m *ChatModel) countOlderActivity(msg ChatOlderLoadedMsg) {
	if msg.SessionID != m.SessionID || msg.Generation != m.Generation || !m.loadingOlder || msg.Err != nil || msg.Page == nil {
		return
	}
	for _, evt := range msg.Page.Events {
		if evt.Type == daemon.EventTool && (evt.EntryID == "" || m.History.Find(evt.EntryID) < 0) {
			m.activityTools++
		}
	}
}

// Only retain counts of calls, not a second event log. Replayed tools count
// because a snapshot reset rebuilds the loaded total from loaded history; the
// snapshot and each live tool event carry the daemon's session total.
func (m *ChatModel) observeActivity(evt daemon.StreamEvent) {
	switch evt.Type {
	case daemon.EventReset:
		m.activityTools = 0
		m.sessionTools = nil
		if evt.Snapshot != nil {
			m.sessionTools = evt.Snapshot.SessionToolCalls
		}
	case daemon.EventTool:
		m.activityTools++
		if evt.Replayed {
			break
		}
		if evt.SessionToolCalls != nil {
			m.sessionTools = new(*evt.SessionToolCalls)
		} else if m.sessionTools != nil {
			// A failed ledger read still adds this call to the known total.
			m.sessionTools = new(*m.sessionTools + 1)
		}
	}
	if evt.Replayed && evt.Type != daemon.EventReset {
		return
	}
	switch evt.Type {
	case daemon.EventReset:
		m.activityRemainder = PageRow{}
		// An idle snapshot says the turn is over, so a call that reports
		// afterwards is history rather than work happening now.
		m.activityEnded = evt.Snapshot == nil || evt.Snapshot.Status.Idle
	case daemon.EventUser:
		if evt.Source == "" || evt.Source == "chat" || m.transcript.turn == nil {
			m.activityRemainder = PageRow{}
			m.activityEnded = false
		}
	case daemon.EventText, daemon.EventThinking, daemon.EventToolProgress:
		m.activityRemainder = PageRow{}
		m.activityEnded = false
	case daemon.EventTurnCompleted, daemon.EventError, daemon.EventInterrupted, daemon.EventRetry:
		m.activityEnded = true
		if n := len(m.progressOrder); n > 0 {
			state := "unknown"
			if evt.Type == daemon.EventInterrupted || evt.Outcome == daemon.OutcomeInterrupted {
				state = "interrupted"
			}
			m.activityRemainder = PageRow{Text: fmt.Sprintf("%s · %d unfinished calls", state, n), Tone: ToneWarning}
		}
	}
}
