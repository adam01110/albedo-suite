package tui

import (
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
}
