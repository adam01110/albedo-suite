package tui

import (
	"strings"
	"testing"
)

func BenchmarkActivityRowsLargeResults(b *testing.B) {
	m := ChatModel{History: NewBoundedHistory(500, 4<<20)}
	for range activityLimit {
		m.History.Append(HistoryEntry{Kind: EntryTool, ToolName: "python", ToolTitle: "inspect fixture", ToolResult: `{"status":"ok","output":"` + strings.Repeat("x", 64<<10) + `"}`})
	}
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		_ = m.activityRows()
	}
}
