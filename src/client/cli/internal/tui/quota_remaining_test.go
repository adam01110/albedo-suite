package tui

import (
	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
	"time"
)

func TestQuotaRemainingDisplay(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		used float64
		want string
	}{{0, "100% left"}, {25, "75% left"}, {100, "0% left"}, {120, "0% left"}} {
		r := daemon.QuotaObservation{UsedPercent: &tc.used, ObservedAt: now.Format(time.RFC3339)}
		m := QuotaModel{at: now}
		if got := ansi.Strip(m.summary(r)); !strings.Contains(got, tc.want) {
			t.Errorf("used %v: %q", tc.used, got)
		}
	}
	// The details fact clamps above 100% rather than going negative.
	used := 120.0
	clamped := daemon.QuotaObservation{UsedPercent: &used, ObservedAt: now.Format(time.RFC3339)}
	if got := ansi.Strip(strings.Join((QuotaModel{at: now}).details(clamped, 80), " ")); !strings.Contains(got, "0%") || strings.Contains(got, "-") {
		t.Fatalf("details: %q", got)
	}
}
