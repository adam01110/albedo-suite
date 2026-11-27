package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/tui/chrome"
)

func TestCallGlyphFollowsIcons(t *testing.T) {
	saved := chrome.Icon
	t.Cleanup(func() { chrome.UseIcons(saved) })
	icons := chrome.DefaultIcons
	icons.CallSucceeded, icons.CallFailed, icons.CallPending = "Y", "N", "?"
	chrome.UseIcons(icons)
	ok, failed := true, false
	for _, c := range []struct {
		act  daemon.ToolActivity
		want string
	}{{daemon.ToolActivity{OK: &ok}, "Y"}, {daemon.ToolActivity{OK: &failed}, "N"}, {daemon.ToolActivity{}, "?"}} {
		if got := callGlyph(c.act); !strings.Contains(got, c.want) {
			t.Errorf("callGlyph = %q, want %q", got, c.want)
		}
	}
}
