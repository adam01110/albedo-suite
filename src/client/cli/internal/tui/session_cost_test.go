package tui

import (
	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
	"math"
	"strings"
	"testing"
)

func TestVimFooterSessionCost(t *testing.T) {
	for _, provider := range []string{"openai", "claude", "codex", "zed", "custom"} {
		for _, width := range []int{40, 60, 80, 120} {
			m := newTestChatModel(t, &daemon.Session{ID: "s", Provider: provider})
			m.SetSize(width, 24)
			prompt, cached, cost := 396000, 392000, 1.234
			m.Usage = &daemon.Usage{Model: "old-model", PromptTokens: &prompt, CachedPromptTokens: &cached, SessionCostUSD: &cost}
			m.Model = "new-model"
			footer := ansi.Strip(m.renderFooter())
			if !strings.Contains(footer, "$1.23") || ansi.StringWidth(footer) > m.chatWidth() {
				t.Fatalf("provider=%s width=%d footer=%q", provider, width, footer)
			}
			if strings.Index(footer, "$") < strings.Index(footer, "—/—") {
				t.Fatal(footer)
			}
		}
	}
}

func TestVimFooterCostFormatting(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	if got := m.costStat(); got != "cost n/a" {
		t.Fatal(got)
	}
	for _, tc := range []struct {
		cost float64
		want string
	}{
		{0, "$0.00"}, {0.001, "$<0.01"}, {0.01, "$0.01"}, {1234.567, "$1234.57"},
		{-1, "cost n/a"}, {math.NaN(), "cost n/a"}, {math.Inf(1), "cost n/a"},
	} {
		m.Usage = &daemon.Usage{SessionCostUSD: &tc.cost}
		if got := m.costStat(); got != tc.want {
			t.Fatalf("got %q want %q", got, tc.want)
		}
	}
}
