package tui

import (
	"slices"
	"testing"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
)

func TestAgentsGlanceFollowsBackgroundJobs(t *testing.T) {
	started := time.Now().Add(-time.Minute).UnixMilli()
	m := ChatModel{
		Glances: []PageGlance{
			{Title: "agents", Rows: []PageRow{{ID: "scout", Text: "scout", Tone: ToneActive}, {ID: "coder", Text: "coder"}}},
			{Title: "skills", Rows: []PageRow{{ID: "jujutsu", Text: "jujutsu"}}},
		},
		Status: daemon.AgentStatus{RunningJobs: []protocol.KernelJob{{ID: "job-1", Command: "go test ./...", Kind: "command", StartedAt: started}}},
	}
	titles := func() []string {
		var titles []string
		for _, g := range m.activeGlances() {
			titles = append(titles, g.Title)
		}
		return titles
	}
	if got, want := titles(), []string{"skills", "background jobs", "agents"}; !slices.Equal(got, want) {
		t.Fatalf("glances = %v, want %v", got, want)
	}
	m.Status.RunningJobs = nil
	if got, want := titles(), []string{"skills", "agents"}; !slices.Equal(got, want) {
		t.Fatalf("glances without jobs = %v, want %v", got, want)
	}
	m.Glances[0].Rows = nil
	if got, want := titles(), []string{"skills"}; !slices.Equal(got, want) {
		t.Fatalf("glances without agents = %v, want %v", got, want)
	}
}
