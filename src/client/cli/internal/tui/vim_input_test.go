package tui

import (
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"strings"
	"testing"
)

func TestVimInputRegisterPayloadAfterSubmit(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m.Status.Idle = true
	marker := m.Pastes.add("original payload")
	m.TextArea.SetValue(marker)
	m.vim.normal = true
	m.vimPosition(0)
	vimKeys(&m, "y", "y")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	vimKeys(&m, "p")
	_, payloads := m.Pastes.resolve(m.TextArea.Value())
	if len(payloads) != 0 || strings.Contains(m.TextArea.Value(), "[Paste #") {
		t.Fatalf("yy Enter p: marker=%q payloads=%v register=%q", m.TextArea.Value(), payloads, m.vim.register)
	}
}

// External composer mutations share one snapshot hook, so paste, a collapsing
// paste and an editor result all undo as one step in NORMAL mode.
func TestVimInputNormalPasteUndo(t *testing.T) {
	for _, text := range []string{"small", strings.Repeat("large", 300)} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(80, 24)
		vimKeys(&m, "esc")
		m, _ = m.Update(tea.PasteMsg{Content: text})
		vimKeys(&m, "u")
		if m.TextArea.Value() != "" {
			t.Fatalf("NORMAL Paste u: %q", m.TextArea.Value())
		}
	}
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	vimKeys(&m, "esc")
	m, _ = m.Update(ChatEditorFinishedMsg{SessionID: m.SessionID, Generation: m.Generation, Edited: true, Text: "edited"})
	vimKeys(&m, "u")
	if m.TextArea.Value() != "" {
		t.Fatalf("NORMAL editor u: %q", m.TextArea.Value())
	}
}

func TestVimInputImagePasteUndo(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m, _ = m.Update(ClipboardImagePastedMsg{SessionID: m.SessionID, Generation: m.Generation, Image: &daemon.ImageAttachment{}})
	vimKeys(&m, "esc", "u")
	if m.TextArea.Value() != "" {
		t.Fatalf("image paste Esc u: %q", m.TextArea.Value())
	}
	vimKeys(&m, "ctrl+r")
	if len(m.Images.referenced(m.TextArea.Value())) != 1 {
		t.Fatalf("redo image lost payload: %q", m.TextArea.Value())
	}
}

func TestVimInputEmptyDeleteKeepsMarker(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	marker := m.Pastes.add("payload")
	m.TextArea.SetValue(marker)
	m.vim.normal = true
	m.vimPosition(len([]rune(marker)) - 1)
	m.vim.register = "keep"
	vimKeys(&m, "d", "l")
	if m.TextArea.Value() != marker || m.vim.register != "keep" || len(m.vim.undo) != 0 {
		t.Fatalf("empty dl: text=%q register=%q undo=%d", m.TextArea.Value(), m.vim.register, len(m.vim.undo))
	}
}
