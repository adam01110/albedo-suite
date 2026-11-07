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
func activityLabel(name, title string) string {
	label := cmp.Or(title, name, "tool")
	return ansi.Truncate(oneLine(ansi.Strip(label)), 160, "…")
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
	entries := m.History.Entries()
	seenContent, skippedEnd := false, false
	for i := len(entries) - 1; i >= 0 && len(rows) < activityLimit; i-- {
		e := &entries[i]
		if e.Kind == EntryUser && (e.Source == "" || e.Source == "chat") {
			break
		}
		// The newest turn-end closes the displayed turn; earlier ends bound it.
		if e.Kind == EntryTurnEnd {
			if seenContent || skippedEnd {
				break
			}
			skippedEnd = true
		}
		if e.Kind == EntryUser {
			seenContent = true
		}
		if e.Kind != EntryTool {
			continue
		}
		seenContent = true
		if e.activity == nil {
			_, tone := activityResult(*e)
			e.activity = &PageRow{Text: activityLabel(e.ToolName, e.ToolTitle), Tone: tone}
		}
		rows = append(rows, *e.activity)
	}
	return rows
}

// activityCount uses the transcript's turn total so history eviction and the
// six-row display limit do not stop the counter.
func (m ChatModel) activityCount() int {
	completed := 0
	if m.transcript.turn != nil {
		completed = m.transcript.turn.tools
	} else if m.History != nil {
		entries := m.History.Entries()
		for i := len(entries) - 1; i >= 0; i-- {
			e := entries[i]
			if e.Kind == EntryTurnEnd {
				completed = max(completed, e.Tools)
				break
			}
			if e.Kind == EntryUser && (e.Source == "" || e.Source == "chat") {
				break
			}
			if e.Kind == EntryTool {
				completed++
			}
		}
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

// Only retain a count of calls with no observed result, not a second event log.
func (m *ChatModel) observeActivity(evt daemon.StreamEvent) {
	if evt.Replayed && evt.Type != daemon.EventReset {
		return
	}
	switch evt.Type {
	case daemon.EventReset:
		m.activityRemainder = PageRow{}
		m.activityEnded = evt.Snapshot == nil
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
			if evt.Type == daemon.EventInterrupted || evt.Source == "interrupted" {
				state = "interrupted"
			}
			m.activityRemainder = PageRow{Text: fmt.Sprintf("%s · %d unfinished calls", state, n), Tone: ToneWarning}
		}
	}
}
