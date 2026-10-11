package tui

import (
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
)

func TestDefaultDiffVisibility(t *testing.T) {
	model := newTestChatModel(t, &daemon.Session{ID: "default-diffs"})
	if !model.Flags.Diffs {
		t.Fatal("new chats must show diffs by default")
	}
	if model.Flags.Tools || model.Flags.Thinking || model.Flags.Compaction {
		t.Fatal("other display defaults must remain unchanged")
	}
	model, _ = model.Update(tea.KeyPressMsg{Code: 'j', Mod: tea.ModCtrl})
	if model.Flags.Diffs {
		t.Fatal("Ctrl+J must still hide diffs")
	}
	model, _ = model.Update(tea.KeyPressMsg{Code: 'j', Mod: tea.ModCtrl})
	if !model.Flags.Diffs {
		t.Fatal("Ctrl+J must still show diffs again")
	}
}
