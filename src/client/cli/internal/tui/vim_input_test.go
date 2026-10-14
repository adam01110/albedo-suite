package tui

import (
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"strings"
	"testing"
)

func TestVimInputShiftEnter(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	vimKeys(&m, "a", "b", "c", "esc")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter, Mod: tea.ModShift})
	if !strings.Contains(m.TextArea.Value(), "\n") {
		t.Fatalf("Esc Shift+Enter: want newline, got %q normal=%v", m.TextArea.Value(), m.vim.normal)
	}
}
func TestVimInputCollapsedPasteUndo(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	m, _ = m.Update(tea.PasteMsg{Content: strings.Repeat("a", 10000)})
	vimKeys(&m, "esc", "u")
	if m.TextArea.Value() != "" {
		t.Fatalf("large Paste Esc u: want empty, got %q undo=%d", m.TextArea.Value(), len(m.vim.undo))
	}
}
func TestVimInputMenuSubmissionHistory(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	vimKeys(&m, "a", "b", "c", "esc", "0", "x", "i")
	m.TextArea.SetValue("/t")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	vimKeys(&m, "esc", "u")
	if m.TextArea.Value() != "" {
		t.Fatalf("menu submit /t Esc u: want empty, got %q", m.TextArea.Value())
	}
}
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
func TestVimInputEditorUndo(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	vimKeys(&m, "esc")
	m, _ = m.Update(ChatEditorFinishedMsg{SessionID: m.SessionID, Generation: m.Generation, Edited: true, Text: "edited"})
	vimKeys(&m, "u")
	if m.TextArea.Value() != "" {
		t.Fatalf("NORMAL editor u: %q", m.TextArea.Value())
	}
}
func TestVimInputMarkerControlUndo(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 24)
	marker := m.Pastes.add("payload")
	m.TextArea.SetValue(marker)
	m.vimPosition(len([]rune(marker)))
	vimKeys(&m, "esc", "$")
	m, _ = m.Update(tea.KeyPressMsg{Code: 'w', Mod: tea.ModCtrl})
	vimKeys(&m, "u")
	if m.TextArea.Value() != marker {
		t.Fatalf("NORMAL ctrl+w u: %q", m.TextArea.Value())
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
