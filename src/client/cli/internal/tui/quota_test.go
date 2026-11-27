// Quota screen unit tests verify boundary durations, stale/failed standing
// classifications, bar fill and heat styling thresholds, sparkline column
// gaps, trend pace projection, and asynchronous generation-guarded state
// transitions. These catch arithmetic, rounding, and race-ordering bugs that
// the daemon end-to-end suite cannot drive or inspect.
package tui

import (
	"errors"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/tui/chrome"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestQuotaSpan(t *testing.T) {
	cases := []struct {
		name     string
		duration time.Duration
		want     string
	}{
		{
			name:     "durations under one minute render as less than one minute",
			duration: 45 * time.Second,
			want:     "<1m",
		},
		{
			name:     "fifty nine minutes renders without hour component",
			duration: 59 * time.Minute,
			want:     "59m",
		},
		{
			name:     "exact one hour renders without minute remainder",
			duration: time.Hour,
			want:     "1h",
		},
		{
			name:     "two hours and fourteen minutes renders both units",
			duration: 2*time.Hour + 14*time.Minute,
			want:     "2h14m",
		},
		{
			name:     "twenty three hours and fifty nine minutes renders below day threshold",
			duration: 23*time.Hour + 59*time.Minute,
			want:     "23h59m",
		},
		{
			name:     "twenty four hours renders as one day",
			duration: 24 * time.Hour,
			want:     "1d",
		},
		{
			name:     "four days and three hours renders day and hour units",
			duration: 4*24*time.Hour + 3*time.Hour,
			want:     "4d3h",
		},
		{
			name:     "negative durations clamp to zero and render as under one minute",
			duration: -10 * time.Minute,
			want:     "<1m",
		},
		{
			name:     "exact zero duration renders as under one minute",
			duration: 0,
			want:     "<1m",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := quotaSpan(tc.duration)
			if got != tc.want {
				t.Fatalf("quotaSpan(%v) = %q, want %q", tc.duration, got, tc.want)
			}
		})
	}
}

func TestQuotaStandingOf(t *testing.T) {
	testStandingOf(t)
}

func testStandingOf(t *testing.T) {
	at := quotaNow
	t.Run("observation with error reports failed standing even when used percentage is present", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 85, "1 hour", 3600, time.Hour, 5*time.Minute)
		r.Error = &protocol.SafeReason{Code: "quota_failed", Detail: "rejected"}
		if got := standingOf(r, at); got != quotaFailed {
			t.Fatalf("standingOf() = %v, want quotaFailed", got)
		}
	})

	t.Run("observation without error and without used percentage reports unknown standing", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 0, "1 hour", 3600, time.Hour, 5*time.Minute)
		r.UsedPercent = nil
		if got := standingOf(r, at); got != quotaUnknown {
			t.Fatalf("standingOf() = %v, want quotaUnknown", got)
		}
	})

	t.Run("observation older than stale threshold reports old standing", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "1 hour", 3600, time.Hour, quotaStale+time.Second)
		if got := standingOf(r, at); got != quotaOld {
			t.Fatalf("standingOf() = %v, want quotaOld", got)
		}
	})

	t.Run("observation just under stale threshold with future reset reports fresh standing", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "1 hour", 3600, time.Hour, quotaStale-time.Second)
		if got := standingOf(r, at); got != quotaFresh {
			t.Fatalf("standingOf() = %v, want quotaFresh", got)
		}
	})

	t.Run("observation with reset time in the past reports old standing", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "1 hour", 3600, -5*time.Minute, 5*time.Minute)
		if got := standingOf(r, at); got != quotaOld {
			t.Fatalf("standingOf() = %v, want quotaOld", got)
		}
	})

	t.Run("observation with reset time exactly equal to clock boundary reports old standing", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "1 hour", 3600, 0, 5*time.Minute)
		if got := standingOf(r, at); got != quotaOld {
			t.Fatalf("standingOf() = %v, want quotaOld", got)
		}
	})

	t.Run("observation polled recently with future reset reports fresh standing", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "1 hour", 3600, time.Hour, 2*time.Minute)
		if got := standingOf(r, at); got != quotaFresh {
			t.Fatalf("standingOf() = %v, want quotaFresh", got)
		}
	})

	t.Run("observation observed exactly stale threshold ago reports fresh standing", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "1 hour", 3600, time.Hour, 0)
		r.ObservedAt = at.Add(-quotaStale).Format(time.RFC3339)
		if got := standingOf(r, at); got != quotaFresh {
			t.Fatalf("standingOf() = %v, want quotaFresh", got)
		}
	})

}

func TestQuotaTagAndBar(t *testing.T) {
	at := quotaNow

	t.Run("zero percent leaves all slots empty", func(t *testing.T) {
		bar := quotaBar(0, true)
		stripped := ansi.Strip(bar)
		if stripped != strings.Repeat("▱", quotaBarSlots) {
			t.Fatalf("quotaBar(0, true) = %q, want ten empty slots", stripped)
		}
		if width := ansi.StringWidth(stripped); width != quotaBarSlots {
			t.Fatalf("bar width = %d, want %d", width, quotaBarSlots)
		}
	})

	t.Run("four percent fills at least one slot minimum", func(t *testing.T) {
		bar := quotaBar(4, true)
		stripped := ansi.Strip(bar)
		want := "▰" + strings.Repeat("▱", quotaBarSlots-1)
		if stripped != want {
			t.Fatalf("quotaBar(4, true) = %q, want %q", stripped, want)
		}
	})

	t.Run("seventy nine point nine percent uses normal brand styling", func(t *testing.T) {
		bar := quotaBar(79.9, true)
		if strings.Contains(bar, chrome.DefaultStyles.Warning.Render("▰")) {
			t.Fatal("79.9% should not have warning style")
		}
		if strings.Contains(bar, chrome.DefaultStyles.Error.Render("▰")) {
			t.Fatal("79.9% should not have error style")
		}
		stripped := ansi.Strip(bar)
		if strings.Count(stripped, "▰") != 8 {
			t.Fatalf("slot fill count = %d, want 8", strings.Count(stripped, "▰"))
		}
	})

	t.Run("twenty percent remaining switches bar fill to warm warning style", func(t *testing.T) {
		bar := quotaBar(20.0, true)
		if !strings.Contains(bar, chrome.DefaultStyles.Warning.Render("▰")) {
			t.Fatal("80% should contain warning styled fill")
		}
		if strings.Contains(bar, chrome.DefaultStyles.Error.Render("▰")) {
			t.Fatal("80% should not contain error style")
		}
		stripped := ansi.Strip(bar)
		if strings.Count(stripped, "▰") != 2 {
			t.Fatalf("slot fill count = %d, want 2", strings.Count(stripped, "▰"))
		}
	})

	t.Run("five percent remaining switches bar fill to hot error style", func(t *testing.T) {
		bar := quotaBar(5.0, true)
		if !strings.Contains(bar, chrome.DefaultStyles.Error.Render("▰")) {
			t.Fatal("95% should contain error styled fill")
		}
		if strings.Contains(bar, chrome.DefaultStyles.Warning.Render("▰")) {
			t.Fatal("95% should not contain warning style")
		}
		stripped := ansi.Strip(bar)
		if strings.Count(stripped, "▰") != 1 {
			t.Fatalf("slot fill count = %d, want 1", strings.Count(stripped, "▰"))
		}
	})

	t.Run("rendered bar width is exactly ten cells across percentages and states", func(t *testing.T) {
		percents := []float64{0, 4, 15, 50, 79.9, 80, 94.9, 95, 100}
		for _, p := range percents {
			for _, current := range []bool{true, false} {
				bar := quotaBar(p, current)
				width := ansi.StringWidth(ansi.Strip(bar))
				if width != quotaBarSlots {
					t.Fatalf("quotaBar(%v, %v) width = %d, want %d", p, current, width, quotaBarSlots)
				}
			}
		}
	})

	t.Run("stale observation tag shows seen duration and omits reset countdown", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "1 hour", 3600, time.Hour, 2*time.Hour)
		tag := quotaTag(r, at)
		stripped := ansi.Strip(tag)
		if !strings.Contains(stripped, "seen 2h") {
			t.Fatalf("stale tag %q should contain seen duration", stripped)
		}
		if strings.Contains(stripped, "in ") {
			t.Fatalf("stale tag %q should not contain countdown", stripped)
		}
	})

	t.Run("failed observation tag shows no reading text", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "1 hour", 3600, time.Hour, 5*time.Minute)
		r.Error = &protocol.SafeReason{Code: "failed", Detail: "rejected"}
		tag := quotaTag(r, at)
		stripped := ansi.Strip(tag)
		if stripped != "no reading" {
			t.Fatalf("failed tag = %q, want 'no reading'", stripped)
		}
	})
}

func TestQuotaPace(t *testing.T) {
	at := quotaNow
	ref := quotaReading("anthropic", "user", "limit", "Limit", 50, "5 hour", 5*3600, 2*time.Hour, 5*time.Minute)

	t.Run("empty history produces no pace projection", func(t *testing.T) {
		if pace := quotaPace(nil, ref, at); pace != "" {
			t.Fatalf("pace = %q, want empty", pace)
		}
	})

	t.Run("points spanning less than twenty minutes produce no pace projection", func(t *testing.T) {
		points := []quotaPoint{
			{At: at.Add(-19 * time.Minute), Percent: 20},
			{At: at, Percent: 30},
		}
		if pace := quotaPace(points, ref, at); pace != "" {
			t.Fatalf("pace = %q, want empty", pace)
		}
	})

	t.Run("rate below half a percent an hour reports holding steady", func(t *testing.T) {
		points := []quotaPoint{
			{At: at.Add(-60 * time.Minute), Percent: 20.0},
			{At: at, Percent: 20.2}, // 0.2% in 1 hour < 0.5%/h
		}
		if pace := quotaPace(points, ref, at); pace != "holding steady" {
			t.Fatalf("pace = %q, want 'holding steady'", pace)
		}
	})

	t.Run("climb that fills before reset projects full duration", func(t *testing.T) {
		// climb from 60% to 80% over 30 minutes: rate = 20% / 0.5h = 40%/h.
		// remaining to 100% is 20%. Time until full is 20 / 40 = 0.5h = 30m.
		// resets in 2 hours -> fills before reset (30m < 2h).
		points := []quotaPoint{
			{At: at.Add(-30 * time.Minute), Percent: 60},
			{At: at, Percent: 80},
		}
		r := quotaReading("anthropic", "user", "limit", "Limit", 80, "5 hour", 5*3600, 2*time.Hour, 0)
		if pace := quotaPace(points, r, at); pace != "empty in ~30m" {
			t.Fatalf("pace = %q, want 'empty in ~30m'", pace)
		}
	})

	t.Run("climb that ends below full before reset projects ending percentage matching arithmetic", func(t *testing.T) {
		// climb from 40% to 50% over 30 minutes: rate = 10% / 0.5h = 20%/h.
		// remaining to 100% is 50%, until full = 50 / 20 = 2.5h.
		// resets in 1 hour -> ends before full (2.5h >= 1h).
		// predicted end = 50 + 20 * 1.0 = 70%.
		points := []quotaPoint{
			{At: at.Add(-30 * time.Minute), Percent: 40},
			{At: at, Percent: 50},
		}
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "5 hour", 5*3600, time.Hour, 0)
		if pace := quotaPace(points, r, at); pace != "ends near 30% left" {
			t.Fatalf("pace = %q, want %q", pace, "ends near 30% left")
		}
	})

	t.Run("window reset decrease inside lookback discards earlier points", func(t *testing.T) {
		// 50m ago: 90%
		// 30m ago: 10% (reset occurred!)
		// now: 30%
		// after reset: climbs from 10% to 30% in 30 minutes = 40%/h.
		// until full = (100 - 30) / 40 = 1.75h = 1h45m.
		// resets in 3 hours -> empty in ~1h45m.
		points := []quotaPoint{
			{At: at.Add(-50 * time.Minute), Percent: 90},
			{At: at.Add(-30 * time.Minute), Percent: 10},
			{At: at, Percent: 30},
		}
		r := quotaReading("anthropic", "user", "limit", "Limit", 30, "5 hour", 5*3600, 3*time.Hour, 0)
		if pace := quotaPace(points, r, at); pace != "empty in ~1h45m" {
			t.Fatalf("pace = %q, want %q", pace, "empty in ~1h45m")
		}
	})

	t.Run("points older than ninety minutes are ignored in lookback", func(t *testing.T) {
		points := []quotaPoint{
			{At: at.Add(-100 * time.Minute), Percent: 10},
			{At: at.Add(-30 * time.Minute), Percent: 40},
			{At: at, Percent: 50},
		}
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "5 hour", 5*3600, time.Hour, 0)
		if pace := quotaPace(points, r, at); pace != "ends near 30% left" {
			t.Fatalf("pace = %q, want %q", pace, "ends near 30% left")
		}
	})

	t.Run("pace without reset timestamp uses an hour wording", func(t *testing.T) {
		points := []quotaPoint{
			{At: at.Add(-30 * time.Minute), Percent: 40},
			{At: at, Percent: 50},
		}
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "5 hour", 5*3600, time.Hour, 0)
		r.ResetsAt = nil
		if pace := quotaPace(points, r, at); pace != "~20% an hour" {
			t.Fatalf("pace = %q, want %q", pace, "~20% an hour")
		}
	})

	t.Run("duplicate timestamps do not divide by zero or panic", func(t *testing.T) {
		duplicates := []quotaPoint{
			{At: at, Percent: 20},
			{At: at, Percent: 20},
			{At: at, Percent: 20},
		}
		if pace := quotaPace(duplicates, ref, at); pace != "" {
			t.Fatalf("pace = %q, want empty", pace)
		}
	})

}

func TestQuotaSpark(t *testing.T) {
	from := quotaNow.Add(-10 * time.Hour)
	to := quotaNow

	t.Run("width of one cell renders without panic", func(t *testing.T) {
		points := []quotaPoint{{At: to, Percent: 50}}
		rows := quotaSpark(points, from, to, 1)
		if len(rows) != 2 {
			t.Fatalf("len(rows) = %d, want 2", len(rows))
		}
		for i, row := range rows {
			if w := ansi.StringWidth(ansi.Strip(row)); w != 1 {
				t.Fatalf("row %d width = %d, want 1", i, w)
			}
		}
	})

	t.Run("large width renders without panic", func(t *testing.T) {
		points := []quotaPoint{
			{At: from.Add(time.Hour), Percent: 10},
			{At: to, Percent: 90},
		}
		rows := quotaSpark(points, from, to, 160)
		if len(rows) != 2 {
			t.Fatalf("len(rows) = %d, want 2", len(rows))
		}
		for i, row := range rows {
			if w := ansi.StringWidth(ansi.Strip(row)); w != 160 {
				t.Fatalf("row %d width = %d, want 160", i, w)
			}
		}
	})

	t.Run("columns before first reading are blank", func(t *testing.T) {
		// 10 columns over 10 hours: column 0 ends at from + 1h.
		// First point is at from + 3h, so column 0 and column 1 must be space ' '.
		points := []quotaPoint{
			{At: from.Add(3 * time.Hour), Percent: 50},
			{At: to, Percent: 60},
		}
		rows := quotaSpark(points, from, to, 10)
		topStrip := ansi.Strip(rows[0])
		bottomStrip := ansi.Strip(rows[1])
		if topStrip[0] != ' ' || bottomStrip[0] != ' ' {
			t.Fatalf("column 0 before first reading is not blank: top=%q, bottom=%q", string(topStrip[0]), string(bottomStrip[0]))
		}
		if topStrip[1] != ' ' || bottomStrip[1] != ' ' {
			t.Fatalf("column 1 before first reading is not blank: top=%q, bottom=%q", string(topStrip[1]), string(bottomStrip[1]))
		}
	})

	t.Run("columns after stale polling gap are blank", func(t *testing.T) {
		// Points at from + 2h and from + 9h.
		// Column 3 ends at from + 4h (2h after reading, which exceeds quotaStale of 30m).
		points := []quotaPoint{
			{At: from.Add(2 * time.Hour), Percent: 50},
			{At: from.Add(9 * time.Hour), Percent: 80},
		}
		rows := quotaSpark(points, from, to, 10)
		topRunes := []rune(ansi.Strip(rows[0]))
		bottomRunes := []rune(ansi.Strip(rows[1]))
		// Column 3 is index 3
		if topRunes[3] != ' ' || bottomRunes[3] != ' ' {
			t.Fatalf("column 3 after stale gap is not blank: top=%q, bottom=%q", string(topRunes[3]), string(bottomRunes[3]))
		}
	})

	t.Run("last column height reflects sixty two percent with two row blocks", func(t *testing.T) {
		// 62% maps to level 10: bottom '█', top '▂'.
		points := []quotaPoint{
			{At: to, Percent: 38},
		}
		rows := quotaSpark(points, from, to, 10)
		topRunes := []rune(ansi.Strip(rows[0]))
		bottomRunes := []rune(ansi.Strip(rows[1]))
		if topRunes[len(topRunes)-1] != '▂' {
			t.Fatalf("last column top rune = %q, want '▂'", string(topRunes[len(topRunes)-1]))
		}
		if bottomRunes[len(bottomRunes)-1] != '█' {
			t.Fatalf("last column bottom rune = %q, want '█'", string(bottomRunes[len(bottomRunes)-1]))
		}
	})

	t.Run("zero percent draws faint marker rune", func(t *testing.T) {
		points := []quotaPoint{
			{At: to, Percent: 100},
		}
		rows := quotaSpark(points, from, to, 10)
		topRunes := []rune(ansi.Strip(rows[0]))
		bottomRunes := []rune(ansi.Strip(rows[1]))
		if topRunes[len(topRunes)-1] != ' ' {
			t.Fatalf("zero percent top rune = %q, want ' '", string(topRunes[len(topRunes)-1]))
		}
		if bottomRunes[len(bottomRunes)-1] != '▁' {
			t.Fatalf("zero percent bottom rune = %q, want '▁'", string(bottomRunes[len(bottomRunes)-1]))
		}
	})

	t.Run("sparkline output has exactly two rows with matching cell width", func(t *testing.T) {
		points := []quotaPoint{
			{At: to.Add(-time.Hour), Percent: 40},
			{At: to, Percent: 75},
		}
		width := 25
		rows := quotaSpark(points, from, to, width)
		if len(rows) != 2 {
			t.Fatalf("len(rows) = %d, want 2", len(rows))
		}
		for i, r := range rows {
			if w := ansi.StringWidth(ansi.Strip(r)); w != width {
				t.Fatalf("row %d width = %d, want %d", i, w, width)
			}
		}
	})
}

func TestQuotaTrailSpan(t *testing.T) {
	t.Run("observation without window seconds defaults to twenty four hours", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "none", 0, time.Hour, time.Minute)
		r.WindowSeconds = nil
		if got := quotaTrailSpan(r); got != 24*time.Hour {
			t.Fatalf("quotaTrailSpan() = %v, want 24h", got)
		}
	})

	t.Run("five hour window raises to minimum twenty four hours", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "5 hour", 5*3600, time.Hour, time.Minute)
		if got := quotaTrailSpan(r); got != 24*time.Hour {
			t.Fatalf("quotaTrailSpan() = %v, want 24h", got)
		}
	})

	t.Run("seven day window preserves seven days", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "7 day", 7*24*3600, time.Hour, time.Minute)
		if got := quotaTrailSpan(r); got != 7*24*time.Hour {
			t.Fatalf("quotaTrailSpan() = %v, want 7d", got)
		}
	})

	t.Run("thirty day window caps to maximum seven days", func(t *testing.T) {
		r := quotaReading("anthropic", "user", "limit", "Limit", 50, "30 day", 30*24*3600, time.Hour, time.Minute)
		if got := quotaTrailSpan(r); got != 7*24*time.Hour {
			t.Fatalf("quotaTrailSpan() = %v, want 7d", got)
		}
	})

	t.Run("a trail is read back as far as the pane draws it", func(t *testing.T) {
		m := quotaModel(120, 30)
		for _, r := range m.readings {
			if got, want := quotaNow.Sub(m.trailSince(r)), quotaTrailSpan(r); got != want {
				t.Fatalf("%s: trail reaches back %v, the pane draws %v", quotaKey(r), got, want)
			}
		}
	})
}

func TestQuotaModelFlow(t *testing.T) {
	t.Run("quota loaded message with current generation groups interleaved accounts", func(t *testing.T) {
		m := NewQuotaModel(nil)
		m.SetSize(120, 30)

		// Interleave readings intentionally: Anthropic, Google, Anthropic, Google
		rA1 := quotaReading("anthropic", "dawn@example.com", "limit_1", "Limit 1", 20, "1h", 3600, time.Hour, time.Minute)
		rG1 := quotaReading("google", "dawn@gmail.com", "gemini_1", "Gemini 1", 30, "1h", 3600, time.Hour, time.Minute)
		rA2 := quotaReading("anthropic", "dawn@example.com", "limit_2", "Limit 2", 40, "1h", 3600, time.Hour, time.Minute)
		rG2 := quotaReading("google", "dawn@gmail.com", "gemini_2", "Gemini 2", 50, "1h", 3600, time.Hour, time.Minute)

		m, _ = m.Update(quotaLoadedMsg{
			Gen:      m.Generation,
			At:       quotaNow,
			Readings: []daemon.QuotaObservation{rA1, rG1, rA2, rG2},
		})
		if len(m.readings) != 4 {
			t.Fatalf("readings count = %d, want 4", len(m.readings))
		}
		// Anthropic accounts are sorted together first.
		if m.readings[0].Provider != "anthropic" || m.readings[1].Provider != "anthropic" || m.readings[2].Provider != "google" || m.readings[3].Provider != "google" {
			t.Fatalf("rows are not grouped by provider: %s %s %s %s", m.readings[0].Provider, m.readings[1].Provider, m.readings[2].Provider, m.readings[3].Provider)
		}
	})

	t.Run("a failed load with no rows says it could not read, not that there are no readings", func(t *testing.T) {
		m := NewQuotaModel(nil)
		m.SetSize(120, 30)
		m, _ = m.Update(quotaLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
		view := ansi.Strip(m.View())
		if !strings.Contains(view, "Could not read quota") || strings.Contains(view, "No quota readings yet") {
			t.Fatalf("the empty list should blame the failed read:\n%s", view)
		}
	})

	t.Run("history message with current generation renders sparkline in pane", func(t *testing.T) {
		m := quotaModel(120, 30)
		r := m.readings[0]
		m, _ = m.Update(quotaHistoryMsg{Gen: m.Generation, Key: quotaKey(r), Points: quotaTrailFixture(r)})
		view := ansi.Strip(m.View())
		if !strings.ContainsAny(view, "▁▂▃▄▅▆▇█") {
			t.Fatalf("view should contain sparkline block glyphs:\n%s", view)
		}
	})

	t.Run("history message with error displays history unavailable in pane", func(t *testing.T) {
		m := quotaModel(120, 30)
		r := m.readings[0]
		m, _ = m.Update(quotaHistoryMsg{Gen: m.Generation, Key: quotaKey(r), Err: errors.New("timeout reading history")})
		if view := ansi.Strip(m.View()); !strings.Contains(view, "history unavailable") {
			t.Fatalf("view should contain 'history unavailable':\n%s", view)
		}
	})

	t.Run("cursor keeps its selected key across a reload", func(t *testing.T) {
		m := quotaModel(120, 30)
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyDown})
		selectedRow, ok := m.highlighted()
		if !ok {
			t.Fatal("cursor should have selected row")
		}
		expectedKey := selectedRow.key
		m, _ = m.Update(quotaLoadedMsg{Gen: m.Generation, At: quotaNow, Readings: quotaFixture()})
		if afterReload, ok := m.highlighted(); !ok || afterReload.key != expectedKey {
			t.Fatalf("cursor lost key after reload: got %q, want %q", afterReload.key, expectedKey)
		}
	})

	t.Run("detail pane for failed reading displays safe error detail without sparkline or pace", func(t *testing.T) {
		m := quotaModel(120, 30)
		for _, char := range "deepseek" {
			m, _ = m.Update(tea.KeyPressMsg{Code: char, Text: string(char)})
		}
		current, ok := m.current()
		if !ok || current.Error == nil {
			t.Fatal("current reading should be broken deepseek observation")
		}
		detailText := strings.Join(m.details(current, 80), "\n")
		if !strings.Contains(detailText, current.Error.Detail) {
			t.Fatalf("m.details should contain the error detail %q:\n%s", current.Error.Detail, detailText)
		}
		view := ansi.Strip(m.View())
		if strings.Contains(view, "full in") || strings.Contains(view, "ends near") || strings.Contains(view, "holding steady") {
			t.Fatalf("failed reading view should never show pace:\n%s", view)
		}
		if strings.Contains(view, "last 24h") || strings.Contains(view, "last 7d") {
			t.Fatalf("failed reading view should never show sparkline reach header:\n%s", view)
		}
	})
}

// The trail of the limit under the cursor is asked for once, when the cursor
// first reaches it: asking again on every key would hammer the daemon, and
// never asking would leave the pane's sparkline empty.
func TestQuotaTrailFetch(t *testing.T) {
	t.Run("esc is a bare cancel even when the highlighted trail has not been asked for", func(t *testing.T) {
		m := quotaModel(120, 30)
		m.trails = map[string]quotaTrail{} // nothing asked for yet: a fetch would ride along with any key
		for _, key := range []tea.KeyPressMsg{{Code: tea.KeyEscape}, {Code: 'c', Mod: tea.ModCtrl}} {
			_, cmd := m.Update(key)
			if cmd == nil {
				t.Fatalf("%v should cancel", key)
			}
			if _, ok := cmd().(QuotaCancelMsg); !ok {
				t.Fatalf("%v returned %T, want a bare QuotaCancelMsg (a batch means a fetch rode along)", key, cmd())
			}
		}
	})

	t.Run("a reading that failed but kept a percent still has no past to ask for", func(t *testing.T) {
		both := quotaReading("hyper", "charm-hyper", "primary", "Primary", 50, "1 hour", 3600, time.Hour, time.Minute)
		both.Error = &protocol.SafeReason{Code: "quota_failed", Detail: "rejected"}
		m := NewQuotaModel(nil)
		m.SetSize(120, 30)
		if _, cmd := m.Update(quotaLoadedMsg{Gen: m.Generation, At: quotaNow, Readings: []daemon.QuotaObservation{both}}); cmd != nil {
			t.Fatal("a failed reading must not ask for a trail even when it carries a percent")
		}
	})

}

// A trail the daemon could only partly fill must say how far back it reaches,
// not the span it was asked for: a busy limit fills the client's row cap
// before the window is covered, and a header reading "last 7d" over four days
// of picture is a wrong number a person would act on.
func TestQuotaTrailFrom(t *testing.T) {
	since := quotaNow.Add(-24 * time.Hour)
	point := func(after time.Duration) []quotaPoint {
		return []quotaPoint{{At: since.Add(after), Percent: 10}}
	}
	cases := []struct {
		name   string
		points []quotaPoint
		want   time.Time
	}{
		{"no points keeps the bound", nil, since},
		{"a first reading at the bound keeps it", point(0), since},
		{"a first reading just inside the stale margin keeps the bound", point(quotaStale), since},
		{"a first reading just past the stale margin starts the picture there", point(quotaStale + time.Second), since.Add(quotaStale + time.Second)},
		{"a trail that starts a day late starts there", point(20 * time.Hour), since.Add(20 * time.Hour)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := quotaTrailFrom(tc.points, since); !got.Equal(tc.want) {
				t.Fatalf("quotaTrailFrom = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestQuotaPaneLabelsWhatTheTrailCovers(t *testing.T) {
	label := func(t *testing.T, firstReadingAge time.Duration) string {
		t.Helper()
		m := quotaModel(120, 30)
		r, _ := m.current() // the 5 hour limit: a 24h trail
		var points []quotaPoint
		for at := quotaNow.Add(-firstReadingAge); !at.After(quotaNow); at = at.Add(10 * time.Minute) {
			points = append(points, quotaPoint{At: at, Percent: 20})
		}
		m, _ = m.Update(quotaHistoryMsg{Gen: m.Generation, Key: quotaKey(r), Points: points})
		return ansi.Strip(m.View())
	}
	t.Run("a trail that reaches the bound says last 24h", func(t *testing.T) {
		if view := label(t, 24*time.Hour); !strings.Contains(view, "last 24h") || !strings.Contains(view, "24h ago") {
			t.Fatalf("a full trail should keep its round label:\n%s", view)
		}
	})
	t.Run("a trail that only reaches back nine hours says so on both labels", func(t *testing.T) {
		view := label(t, 9*time.Hour)
		if !strings.Contains(view, "last 9h") || !strings.Contains(view, "9h ago") || strings.Contains(view, "24h") {
			t.Fatalf("a short trail must not claim the span it was asked for:\n%s", view)
		}
	})
}

// The daemon's own labels, not the fixtures': a window label of "5h window"
// would read "the 5h window window", and a poll that failed with no limits has
// no label at all, which drew an empty highlighted row.
func TestQuotaRowsFromTheDaemonsOwnLabels(t *testing.T) {
	for _, tc := range []struct {
		label string
		want  string
	}{
		{"5h window", "76% of the 5h window"},
		{"7 days", "of the 7 days window"},
	} {
		t.Run("window label "+tc.label, func(t *testing.T) {
			r := quotaReading("anthropic", "acct", "session", "Session", 24, tc.label, 5*3600, 2*time.Hour, time.Minute)
			view := ansi.Strip(strings.Join(quotaModel(120, 30).details(r, 60), "\n"))
			if !strings.Contains(view, tc.want) || strings.Contains(view, "window window") {
				t.Fatalf("the window should be named once:\n%s", view)
			}
		})
	}

	names := []struct {
		name string
		edit func(r *daemon.QuotaObservation)
		want string
	}{
		{"a label names the row", func(r *daemon.QuotaObservation) {}, "Primary"},
		{"a failed poll with no label says what happened", func(r *daemon.QuotaObservation) {
			r.Label, r.UsedPercent = "", nil
			r.Error = &protocol.SafeReason{Code: "quota_failed", Detail: "HTTP 403"}
		}, "last check failed"},
		{"an unlabelled limit is named by its id", func(r *daemon.QuotaObservation) { r.Label = "" }, "primary"},
		{"nothing to name it by says so", func(r *daemon.QuotaObservation) { r.Label, r.LimitID = "", "" }, "no limits reported"},
	}
	for _, tc := range names {
		t.Run(tc.name, func(t *testing.T) {
			r := quotaReading("hyper", "charm-hyper", "primary", "Primary", 50, "1 hour", 3600, time.Hour, time.Minute)
			tc.edit(&r)
			if got := quotaName(r); got != tc.want {
				t.Fatalf("quotaName = %q, want %q", got, tc.want)
			}
		})
	}

	t.Run("the highlighted row of a failed account is not blank", func(t *testing.T) {
		failed := daemon.QuotaObservation{
			Provider: "alibaba", AccountID: "alibaba", LimitID: "", Status: "", Source: "poll",
			ObservedAt: quotaNow.Add(-time.Minute).Format(time.RFC3339),
			Error:      &protocol.SafeReason{Code: "quota_failed", Detail: "bailian CLI failed (exit 3)"},
		}
		m := NewQuotaModel(nil)
		m.SetSize(120, 30)
		m, _ = m.Update(quotaLoadedMsg{Gen: m.Generation, At: quotaNow, Readings: []daemon.QuotaObservation{failed}})
		pane := ansi.Strip(strings.Join(m.details(failed, 60), "\n"))
		if !strings.HasPrefix(pane, "last check failed") {
			t.Fatalf("the pane should be titled by what happened, not left blank:\n%s", pane)
		}
	})
}

// A Zed account's only reading is account-level edit-prediction usage, so the
// row names that and shows no window or reset: the service reports neither, and
// hosted-model spend is not available through the inference credential.
func TestQuotaZedAccountRow(t *testing.T) {
	used := 25.0
	zed := daemon.QuotaObservation{
		Provider: "zed", AccountID: "okami", LimitID: "edit-predictions", Label: "Edit predictions",
		UsedPercent: &used, Status: "ok", Source: "poll",
		ObservedAt: quotaNow.Add(-time.Minute).Format(time.RFC3339),
	}
	m := NewQuotaModel(nil)
	m.SetSize(120, 30)
	m, _ = m.Update(quotaLoadedMsg{Gen: m.Generation, At: quotaNow, Readings: []daemon.QuotaObservation{zed}})
	if len(m.shown) != 1 {
		t.Fatalf("one zed reading should be one row, got %d", len(m.shown))
	}
	row := m.entry(zed)
	if row.section != "zed · okami" {
		t.Fatalf("row section = %q, want the zed account", row.section)
	}
	if row.name != "Edit predictions" {
		t.Fatalf("row name = %q, want the edit-prediction reading", row.name)
	}
	if row.desc != "" {
		t.Fatalf("row desc = %q, want no window", row.desc)
	}
	tag := ansi.Strip(row.tag)
	if !strings.Contains(tag, "75% left") || strings.Contains(tag, "in ") {
		t.Fatalf("row tag = %q, want the remaining share and no reset", tag)
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "zed · okami") || !strings.Contains(view, "Edit predictions") {
		t.Fatalf("the zed account should be listed:\n%s", view)
	}
	pane := ansi.Strip(strings.Join(m.details(zed, 60), "\n"))
	if strings.Contains(pane, "resets") || strings.Contains(pane, "window") {
		t.Fatalf("the pane should claim neither a refresh window nor a reset:\n%s", pane)
	}
}
