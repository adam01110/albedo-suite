package daemon

import (
	"slices"
	"testing"

	"albedo/cli/internal/daemon/protocol"
)

func TestSuiteGlancesListMCPBelowSkills(t *testing.T) {
	var wire []protocol.Glance
	for _, title := range []string{"active work", "scheduled", "skills", "mcp", "tasks"} {
		wire = append(wire, protocol.Glance{Title: title})
	}
	var titles []string
	for _, glance := range glancesValue(wire) {
		titles = append(titles, glance.Title)
	}
	want := []string{"active work", "scheduled", "skills", "mcp", "tasks"}
	if !slices.Equal(titles, want) {
		t.Fatalf("glance order = %v, want %v", titles, want)
	}
}
