package tui

import (
	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
	"math"
	"strings"
	"testing"
	"time"
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

func TestSessionListCostLeftOfAge(t *testing.T) {
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.Local)
	recent := now.Add(-5 * time.Minute).Unix()
	priced, small, large := 1.234, 0.001, 12345.6
	m := viewerAt(now)
	m.SetSize(160, 24)
	m.SetSessions([]daemon.Session{
		{ID: "priced", Title: "priced", Model: "gpt-5", Workspace: "/work/current", LastAssistantAt: &recent, SessionCostUSD: &priced},
		{ID: "small", Title: "small", Model: "gpt-5", Workspace: "/work/current", LastAssistantAt: &recent, SessionCostUSD: &small},
		{ID: "large", Title: "large", Model: "gpt-5", Workspace: "/work/current", LastAssistantAt: &recent, SessionCostUSD: &large},
		{ID: "unknown", Title: "unknown", Model: "gpt-5", Workspace: "/work/current", LastAssistantAt: &recent},
	}, nil)
	m.Init()
	view := ansi.Strip(strings.Join(m.column(80, 20, now), "\n"))
	for title, want := range map[string]string{"priced": "$1.23", "small": "$<0.01", "large": "$12346", "unknown": "  —  "} {
		found := false
		for line := range strings.SplitSeq(view, "\n") {
			if strings.Contains(line, " "+title+" ") {
				at := strings.Index(line, want)
				found = at >= 0 && at < strings.LastIndex(line, "5m")
				if !found {
					t.Fatalf("%s row %q lacks %q", title, line, want)
				}
			}
		}
		if !found {
			t.Fatalf("no %s row in\n%s", title, view)
		}
	}
	for _, width := range []int{40, 60} {
		cols := svLayout(width)
		if cols.cost == 0 || cols.title < 1 {
			t.Fatalf("width %d: %+v", width, cols)
		}
	}
	if cols := svLayout(39); cols.cost != 0 {
		t.Fatalf("narrow list keeps cost: %+v", cols)
	}
}
