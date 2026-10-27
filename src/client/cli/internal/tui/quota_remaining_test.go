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
		if got := ansi.Strip(strings.Join(m.details(r, 80), " ")); !strings.Contains(got, strings.TrimSuffix(tc.want, " left")) || !strings.Contains(got, "left") {
			t.Errorf("details: %q", got)
		}
	}
}
