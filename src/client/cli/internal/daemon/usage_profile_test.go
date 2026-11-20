package daemon

import (
	"net/http"
	"testing"
	"time"
)

func TestGetUsageDecodesTheProfile(t *testing.T) {
	conn := usageConnection(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"generated_at":"2026-10-25T18:00:00Z","utc_offset_minutes":0,"days":[],"lines":[],"scopes":[],"lines_truncated":false,"scopes_truncated":false,` +
			`"profile":{"lifetime_tokens":2840000000,"lifetime_calls":30125,"active_days":36,"first_day":"2026-10-12T00:00:00.000Z","peak_day":"2026-11-03T00:00:00.000Z","peak_day_tokens":469157915,"longest_streak_days":19,"current_streak_days":19,"longest_turn_ms":5592000}}`))
	})
	summary, err := GetUsage(t.Context(), conn, UsageQuery{Days: 371})
	if err != nil {
		t.Fatal(err)
	}
	p := summary.Profile
	if p == nil || p.LifetimeTokens != 2_840_000_000 || p.ActiveDays != 36 || p.LongestStreakDays != 19 || p.CurrentStreakDays != 19 {
		t.Fatalf("profile = %+v", p)
	}
	if !p.PeakDay.Equal(time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC)) || p.LongestTurn != 93*time.Minute+12*time.Second {
		t.Fatalf("peak %v, turn %v", p.PeakDay, p.LongestTurn)
	}

	before := usageConnection(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"generated_at":"2026-10-25T18:00:00Z","utc_offset_minutes":0,"days":[],"lines":[],"scopes":[],"lines_truncated":false,"scopes_truncated":false,` +
			`"profile":{"lifetime_tokens":0,"lifetime_calls":0,"active_days":0,"first_day":null,"peak_day":null,"peak_day_tokens":0,"longest_streak_days":0,"current_streak_days":0,"longest_turn_ms":null}}`))
	})
	summary, err = GetUsage(t.Context(), before, UsageQuery{})
	if err != nil {
		t.Fatal(err)
	}
	if p := summary.Profile; p == nil || !p.FirstDay.IsZero() || p.LongestTurn != 0 {
		t.Fatalf("a profile before any use = %+v", p)
	}
}
