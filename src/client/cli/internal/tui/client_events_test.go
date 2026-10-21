package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestComposerBackgroundEventsDoNotSnapshot(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	text := strings.Repeat("draft line\n", 100)
	m.TextArea.SetValue(text)
	for _, msg := range []tea.Msg{ChatHostMsg{}, ChatProgressTickMsg{}, ChatClearCopyStatusMsg{}, tea.MouseMotionMsg{}} {
		if allocs := testing.AllocsPerRun(20, func() { m.handleInput(msg) }); allocs != 0 {
			t.Fatalf("%T allocated %.0f times without a composer edit", msg, allocs)
		}
	}
	if m.TextArea.Value() != text || m.vim.insert != nil || len(m.vim.undo) != 0 {
		t.Fatal("background event changed composer or undo history")
	}
}

func TestToolImageSelectionInvalidation(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.History = NewBoundedHistory(100, 1024*1024)
	entry := func(id int) HistoryEntry {
		return HistoryEntry{ID: fmt.Sprint(id), Kind: EntryTool, Timestamp: int64(id), Images: []daemon.ImageMetadata{{Reference: fmt.Sprint(id)}}}
	}
	for i := 0; i < 30; i++ {
		m.History.Append(entry(i))
	}
	first := m.selectToolImages()
	if len(first.order) != maxToolImagePreviews || first.order[0] != "29" || first.wanted["0"].Reference != "" {
		t.Fatal("latest-image priority changed")
	}
	m, _ = m.Update(ChatHostMsg{SessionID: "other"})
	if m.selectToolImages() != first {
		t.Fatal("unrelated event invalidated selection")
	}
	m.Renderer.Open = map[string]bool{entryKey(entry(0)): true}
	expanded := m.selectToolImages()
	if expanded == first || expanded.order[0] != "0" {
		t.Fatal("expansion did not prioritize older image")
	}
	delete(m.Renderer.Open, entryKey(entry(0)))
	if m.selectToolImages().order[0] != "29" {
		t.Fatal("collapse retained old priority")
	}
	replacement := entry(29)
	replacement.Images[0].Reference = "replacement"
	m.History.Replace(replacement)
	if m.selectToolImages().order[0] != "replacement" {
		t.Fatal("in-place replacement retained stale reference")
	}
	m.History.Clear()
	m.History.Prepend([]HistoryEntry{entry(1)})
	if got := m.selectToolImages(); len(got.order) != 1 || got.order[0] != "1" {
		t.Fatal("older history did not refresh selection")
	}
	m.History.MaxEntries = 1
	m.History.Append(entry(2))
	m.History.Trim()
	if got := m.selectToolImages(); len(got.order) != 1 || got.order[0] != "2" {
		t.Fatal("eviction retained old selection")
	}
	m.History.Clear()
	if len(m.selectToolImages().order) != 0 {
		t.Fatal("reset retained old selection")
	}
	other := NewBoundedHistory(100, 1024*1024)
	other.Append(entry(3))
	m.History = other
	if m.selectToolImages().order[0] != "3" {
		t.Fatal("history swap retained old selection")
	}
	live := entry(4)
	live.MessageID = "live"
	m.History.Append(live)
	m.selectToolImages()
	m.History.retireLive([]string{"live"}, false)
	if len(m.selectToolImages().order) != 1 {
		t.Fatal("retired live entry retained image")
	}
}

func TestToolImagePendingCompletionAfterEvictionAndResize(t *testing.T) {
	mockToolGraphics(t, true)
	for _, resize := range []bool{false, true} {
		t.Run(fmt.Sprint(resize), func(t *testing.T) {
			m := newTestChatModel(t, &daemon.Session{ID: "s"})
			m.SetSize(80, 24)
			m.History.Append(HistoryEntry{ID: "image", Kind: EntryTool, Images: []daemon.ImageMetadata{{Reference: "image"}}})
			if m.loadToolImage() == nil {
				t.Fatal("missing initial fetch")
			}
			width := m.Renderer.ToolImages["image"].width
			if resize {
				m.SetSize(40, 24)
			} else {
				m.History.Clear()
			}
			if m.loadToolImage() != nil || !m.Renderer.ToolImages["image"].pending {
				t.Fatal("pending fetch was replaced before completion")
			}
			var cmd tea.Cmd
			m, cmd = m.Update(toolImageLoadedMsg{SessionID: m.SessionID, Generation: m.Generation, Reference: "image", Preview: toolImagePreview{width: width, failed: true}, transmit: "must not upload"})
			if cmd == nil && resize {
				t.Fatal("resize did not queue replacement")
			}
			preview, retained := m.Renderer.ToolImages["image"]
			if resize {
				if !retained || !preview.pending || preview.width == width {
					t.Fatal("resize retained completed stale preview")
				}
			} else if retained {
				t.Fatal("evicted pending preview survived completion")
			}
			if cmd != nil && !resize {
				t.Fatal("evicted preview queued stale upload")
			}
			if resize {
				// Only the replacement fetch remains; no sequence uploads the old size.
				if _, ok := cmd().(toolImageLoadedMsg); !ok {
					t.Fatal("resized pending preview queued stale upload")
				}
			}
		})
	}
}

func TestToolImageSelectionHistoryEvents(t *testing.T) {
	mockToolGraphics(t, true)
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m.loadToolImage()
	before := m.toolImageSelection
	event := daemon.StreamEvent{Type: daemon.EventTool, EntryID: "42", ToolName: "python", ToolResult: "attached", Images: []daemon.ImageMetadata{{Reference: "live-image"}}}
	m, _ = m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: event})
	if m.toolImageSelection == before || m.toolImageSelection.wanted["live-image"].Reference == "" {
		t.Fatal("stream event did not invalidate image selection")
	}
	before = m.toolImageSelection
	m, _ = m.Update(ChatProgressTickMsg{SessionID: m.SessionID, Generation: m.Generation})
	if m.toolImageSelection != before {
		t.Fatal("animation invalidated image selection")
	}
	event.EntryID, event.Images[0].Reference = "1", "older-image"
	m.loadingOlder = true
	m, _ = m.Update(ChatOlderLoadedMsg{SessionID: m.SessionID, Generation: m.Generation, Page: &daemon.HistoryPage{Events: []daemon.StreamEvent{event}}})
	if m.toolImageSelection == before || m.toolImageSelection.wanted["older-image"].Reference == "" {
		t.Fatal("loaded older page did not invalidate image selection")
	}
}
