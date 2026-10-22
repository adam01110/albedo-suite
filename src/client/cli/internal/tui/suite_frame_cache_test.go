package tui

import (
	"albedo/cli/internal/daemon"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi/kitty"
)

func TestSuiteImageCompletionAndFoldInvalidateFrameCache(t *testing.T) {
	mockToolGraphics(t, true)
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 40)
	ref := "/sessions/s/history/42/image-0"
	entry := HistoryEntry{Kind: EntryTool, ID: "42", Timestamp: 42, ToolName: "python",
		Images: []daemon.ImageMetadata{{Reference: ref, Width: 120, Height: 80, MimeType: daemon.ImagePNG}}}
	m.appendSettledEntry(entry)
	width := max(1, m.Renderer.BodyWidth-railWidth)
	m.Renderer.ToolImages = map[string]toolImagePreview{ref: {pending: true, width: width}}
	m.transcript.activeKind, m.transcript.activeText = StreamKindText, "A reply still **streaming**."
	m.refreshViewportContent()
	before := m.View()
	preview, _ := prepareToolPreview(toolPreviewPNG(t), graphics{supported: true}, width)
	preview.width = width
	m, _ = m.acceptToolImage(toolImageLoadedMsg{SessionID: m.SessionID, Generation: m.Generation, Reference: ref, Preview: preview})
	shown := m.View()
	if before == shown || !strings.ContainsRune(shown, kitty.Placeholder) || shown != fromScratch(m) {
		t.Fatal("completed image left a stale cached frame")
	}
	if m.toolImageSelection == nil {
		t.Fatal("image selection was not cached")
	}
	selection := m.toolImageSelection
	m.actAt(rowWith(t, m.frameLines, "click to expand"))
	if m.selectToolImages() == selection {
		t.Fatal("fold change retained the old image selection")
	}
	shown = m.View()
	if !strings.Contains(shown, "show less") || shown != fromScratch(m) {
		t.Fatal("fold change left a stale cached frame")
	}
}

func TestSuiteVimModesAndEditsInvalidateFrameCache(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 30)
	m.View()
	for _, key := range []string{"i", "a", "b", "c", "esc", "0", "l", "x", "u", "ctrl+r", "a"} {
		vimKeys(&m, key)
		shown := m.View()
		if shown != fromScratch(m) || !strings.Contains(shown, m.vimMode()) {
			t.Fatalf("stale composer or mode after %q", key)
		}
	}
}
