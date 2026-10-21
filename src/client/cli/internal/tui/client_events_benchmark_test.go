package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
)

func BenchmarkComposerBackgroundEvent(b *testing.B) {
	for _, size := range []int{0, 20000} {
		b.Run(fmt.Sprint(size), func(b *testing.B) {
			client := daemon.NewChatClient(daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil), "s")
			m := NewChatModel(&daemon.Session{ID: "s"}, client)
			defer m.Close()
			m.SetSize(80, 24)
			m.TextArea.SetValue(strings.Repeat("x", size))
			msg := ChatHostMsg{SessionID: "other"}
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				m.handleInput(msg)
			}
		})
	}
}

func BenchmarkChatUpdateNoImages(b *testing.B) {
	saved := terminalGraphics
	terminalGraphics = func() graphics { return graphics{supported: true} }
	defer func() { terminalGraphics = saved }()
	for _, count := range []int{0, 500, 5000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			client := daemon.NewChatClient(daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil), "s")
			m := NewChatModel(&daemon.Session{ID: "s"}, client)
			defer m.Close()
			m.SetSize(80, 24)
			m.History = NewBoundedHistory(count+1, 100*1024*1024)
			for i := 0; i < count; i++ {
				m.History.Append(HistoryEntry{Kind: EntryTool, ID: fmt.Sprint(i), Text: strings.Repeat("x", 100)})
			}
			msg := tea.Msg(ChatHostMsg{SessionID: "other"})
			m, _ = m.Update(msg)
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				m, _ = m.Update(msg)
			}
		})
	}
}

func BenchmarkChatTextStreamNoImages(b *testing.B) {
	saved := terminalGraphics
	terminalGraphics = func() graphics { return graphics{supported: true} }
	defer func() { terminalGraphics = saved }()
	for _, count := range []int{0, 500, 5000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			client := daemon.NewChatClient(daemon.NewConnection(daemon.ConnectionSnapshot{Port: 1}, nil), "s")
			m := NewChatModel(&daemon.Session{ID: "s"}, client)
			defer m.Close()
			m.SetSize(80, 24)
			m.History = NewBoundedHistory(count+1, 100*1024*1024)
			for i := 0; i < count; i++ {
				m.History.Append(HistoryEntry{Kind: EntryTool, ID: fmt.Sprint(i), Text: strings.Repeat("x", 100)})
			}
			m.TextArea.SetValue(strings.Repeat("draft ", 100))
			msg := ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: daemon.StreamEvent{Type: daemon.EventText, MessageID: "live", Text: "x"}}
			m, _ = m.Update(msg)
			m.liveDue = true
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				// Measure the same growing delta without eventually flushing the live cap.
				buffer := new(strings.Builder)
				buffer.WriteString("x")
				m.transcript.activeBuffer, m.transcript.activeText = buffer, "x"
				m.liveDrawn = time.Now()
				m, _ = m.Update(msg)
			}
		})
	}
}
