package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestVimModeFooterColor(t *testing.T) {
	saveBase16State(t)
	original := DefaultStyles
	for _, themed := range []bool{false, true} {
		t.Run(fmt.Sprintf("base16=%t", themed), func(t *testing.T) {
			DefaultStyles = original
			if themed {
				_, palette := base16Fixture(t)
				useBase16Theme(palette)
			}
			for _, width := range []int{160, 40, 12, 8} {
				t.Run(fmt.Sprintf("width=%d", width), func(t *testing.T) {
					m := newTestChatModel(t, &daemon.Session{ID: "s"})
					m.SetSize(width, 30)
					for _, key := range []string{"", "i", "esc"} {
						if key != "" {
							vimKeys(&m, key)
						}
						style := DefaultStyles.You
						if !m.vim.normal {
							style = DefaultStyles.Success
						}
						want := style.Bold(true).Render(m.vimMode())
						got := m.renderFooter()
						if !strings.Contains(got, want) {
							t.Fatalf("footer lacks colored mode after %q: %q; want %q", key, got, want)
						}
						if !strings.Contains(ansi.Strip(got), m.vimMode()) || lipgloss.Width(got) > m.chatWidth() {
							t.Fatalf("mode label or footer width changed: %q", got)
						}
					}
				})
			}
		})
	}
}
