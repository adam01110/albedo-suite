package tui

import (
	tea "charm.land/bubbletea/v2"
	"testing"

	"albedo/cli/internal/daemon"
)

func TestDefaultDiffVisibility(t *testing.T) {
	model := newTestChatModel(t, &daemon.Session{ID: "default-diffs"})
	if !model.Flags.Diffs {
		t.Fatal("new chats must show diffs by default")
	}
	if model.Flags.Tools || model.Flags.Thinking || model.Flags.Compaction {
		t.Fatal("other display defaults must remain unchanged")
	}
	app := &AppModel{State: AppStateChat, Chat: model, ActiveSession: &daemon.Session{ID: "default-diffs"}, Width: 80, Height: 24}
	app.Chat.SetSize(80, 24)
	for _, expected := range []bool{false, true} {
		app.Update(tea.KeyPressMsg{Code: 'j', Mod: tea.ModCtrl})
		if app.Chat.Flags.Diffs != expected {
			t.Fatal("Ctrl+J did not toggle default diffs")
		}
	}
}
