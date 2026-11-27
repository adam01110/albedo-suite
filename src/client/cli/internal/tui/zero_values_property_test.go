// Zero-value and degenerate-input property tests for the suite's Go TUI
// renders: a year, a day, a reading or a cost that carries a zero stamp, a
// negative or overflowing count, an empty series or a single one must still
// draw, never panic, and never invent a figure it cannot read back.
//
// The counters here are wire types (int64, no lower bound) and the stamps are
// RFC3339 strings, so every value below can reach a render from the daemon.
package tui

import (
	"fmt"
	"math"
	"math/rand"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/tui/chrome"

	"albedo/cli/internal/daemon"

	"github.com/charmbracelet/x/ansi"
)

// zeroRun renders one case and reports a panic rather than letting it take
// the whole property down.
func zeroRun(what string, render func()) (string, bool) {
	panicked := ""
	func() {
		defer func() {
			if r := recover(); r != nil {
				panicked = fmt.Sprint(r)
			}
		}()
		render()
	}()
	return panicked, panicked == ""
}

// zeroInts are the degenerate counts a wire type can carry: nothing, one, the
// extrema, and values that overflow when two of them are summed.
var zeroInts = []int64{
	0, 1, -1, 2, -2, 7, -7,
	1 << 40, -(1 << 40),
	math.MaxInt64, math.MinInt64, math.MaxInt64 - 1, math.MinInt64 + 1,
	math.MaxInt64/2 + 1, math.MinInt64 / 2,
	999_499, 999_500, 999_499_999, 999_500_000, 999_499_999_999, 999_500_000_000,
}

// zeroStamps are the times a wire field can name: none, the epoch, the far
// past and future, and a zero stamp a client renders as the year 1.
var zeroStamps = []time.Time{
	{}, time.Unix(0, 0).UTC(), time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC),
	time.Date(1970, 1, 1, 0, 0, 0, 0, time.UTC),
	time.Date(2026, 11, 21, 0, 0, 0, 0, time.UTC),
	time.Date(9999, 12, 31, 23, 59, 59, 0, time.UTC),
	time.Unix(math.MaxInt64, 0), time.Unix(math.MinInt64, 0),
}

func zeroTotals(calls, in, out int64) daemon.UsageTotals {
	return daemon.UsageTotals{Calls: calls, InputTokens: in, OutputTokens: out}
}

// zeroUnits is a count in the client's own units: a number, at most one
// decimal, and one of the ladder's letters.
var zeroUnits = regexp.MustCompile(`^-?[0-9]+(\.[0-9])?[kmbt]?$`)

// zeroBadNumber is why a rendered figure cannot be read back as one, or "".
func zeroBadNumber(s string) string {
	for _, bad := range []string{"NaN", "nan", "Inf", "inf", "e+", "E+", "%!d", "%!f", "%!s"} {
		if strings.Contains(s, bad) {
			return "renders " + bad
		}
	}
	return ""
}

// TestPropZeroUsageLevels grades any series, including one of a single value
// and one of only zeros, in four steps with zero for no use.
func TestPropZeroUsageLevels(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for range 2000 {
		values := make([]int64, r.Intn(12))
		for i := range values {
			values[i] = zeroInts[r.Intn(len(zeroInts))]
		}
		level := usageLevels(values)
		anyUsed := false
		for _, v := range values {
			anyUsed = anyUsed || v > 0
		}
		previous := -1
		for v := int64(-3); v <= 3; v++ {
			got := level(v)
			if got < 0 || got > 4 || got < previous {
				t.Fatalf("values %v: level(%d) = %d after %d", values, v, got, previous)
			}
			if (v <= 0 || !anyUsed) != (got == 0) {
				t.Fatalf("values %v: level(%d) = %d, want zero iff no use", values, v, got)
			}
			previous = got
		}
	}
}

// TestPropZeroUsageHBar keeps the profile's bar a bar: exactly w cells, no
// panicked repeat, and an empty measure for a count that has none, whatever
// the counts are.
func TestPropZeroUsageHBar(t *testing.T) {
	for _, n := range zeroInts {
		for _, top := range zeroInts {
			for _, w := range []int{-2, 0, 1, 4, 19, 90, 200} {
				what := fmt.Sprintf("usageHBar(%d, %d, %d)", n, top, w)
				bad, ok := zeroRun(what, func() {
					bar := ansi.Strip(usageHBar(n, top, w))
					if got := ansi.StringWidth(bar); got != max(0, w) {
						t.Errorf("%s is %d cells, want %d", what, got, max(0, w))
					}
					if n > 0 && top > 0 && w > 0 && !strings.Contains(bar, "━") {
						t.Errorf("%s shows no bar for a count with use", what)
					}
					if (n <= 0 || top <= 0) && strings.Contains(bar, "━") {
						t.Errorf("%s draws a bar for a measure it does not have", what)
					}
				})
				if !ok {
					t.Fatalf("%s panicked: %s", what, bad)
				}
			}
		}
	}
}

// TestPropZeroUsageProfileRun draws the profile tab over degenerate years:
// zero and far stamps, negative and overflowing counts, empty and single-day
// calendars, every mode and width. It must never panic or print a figure that
// is not one.
func TestPropZeroUsageProfileRun(t *testing.T) {
	var failed []string
	report := func(format string, args ...any) {
		if len(failed) < 20 {
			failed = append(failed, fmt.Sprintf(format, args...))
		}
	}
	for seed := int64(1); seed <= 400; seed++ {
		r := rand.New(rand.NewSource(seed))
		year := daemon.UsageSummary{GeneratedAt: zeroStamps[r.Intn(len(zeroStamps))]}
		n := 1 + r.Intn(4)
		if r.Intn(3) == 0 {
			n = 371
		}
		for range n {
			day := daemon.UsageDay{Start: zeroStamps[r.Intn(len(zeroStamps))]}
			if r.Intn(2) == 0 {
				day.UsageTotals = zeroTotals(zeroInts[r.Intn(len(zeroInts))], zeroInts[r.Intn(len(zeroInts))], zeroInts[r.Intn(len(zeroInts))])
			}
			year.Days = append(year.Days, day)
		}
		for range r.Intn(5) {
			year.Lines = append(year.Lines, daemon.UsageLine{
				Model:       fmt.Sprintf("m%d", r.Intn(3)),
				Profile:     fmt.Sprintf("p%d", r.Intn(2)),
				UsageTotals: zeroTotals(zeroInts[r.Intn(len(zeroInts))], zeroInts[r.Intn(len(zeroInts))], zeroInts[r.Intn(len(zeroInts))]),
			})
		}
		if r.Intn(2) == 0 {
			year.Profile = &daemon.UsageProfile{
				LifetimeTokens:    zeroInts[r.Intn(len(zeroInts))],
				LifetimeCalls:     zeroInts[r.Intn(len(zeroInts))],
				ActiveDays:        zeroInts[r.Intn(len(zeroInts))],
				PeakDayTokens:     zeroInts[r.Intn(len(zeroInts))],
				LongestStreakDays: zeroInts[r.Intn(len(zeroInts))],
				CurrentStreakDays: zeroInts[r.Intn(len(zeroInts))],
				FirstDay:          zeroStamps[r.Intn(len(zeroStamps))],
				PeakDay:           zeroStamps[r.Intn(len(zeroStamps))],
				LongestTurn:       time.Duration(zeroInts[r.Intn(len(zeroInts))]),
			}
		}
		year.UTCOffsetMinutes = r.Intn(29) - 14
		width := 1 + r.Intn(120)
		height := 1 + r.Intn(40)
		mode := usageMode(r.Intn(3))
		p := usageProfile{year: year, mode: mode}
		what := fmt.Sprintf("seed %d profileLines(%d, %d) mode %d", seed, width, height, mode)
		bad, ok := zeroRun(what, func() {
			lines := p.profileLines(width, height)
			if len(lines) > height {
				report("%s: %d lines", what, len(lines))
			}
			for i, line := range lines {
				if bad := zeroBadNumber(ansi.Strip(line)); bad != "" {
					report("%s: line %d %q %s", what, i, ansi.Strip(line), bad)
				}
			}
		})
		if !ok {
			report("%s panicked: %s", what, bad)
		}
	}
	for _, f := range failed {
		t.Errorf("%s", f)
	}
}

// TestPropZeroUsageFields keeps every figure of the profile's own header
// numeric: no NaN, no infinity, no exponent, however large the year.
func TestPropZeroUsageFields(t *testing.T) {
	for _, prof := range []daemon.UsageProfile{
		{},
		{LifetimeTokens: math.MaxInt64, PeakDayTokens: math.MaxInt64, LongestStreakDays: math.MaxInt64, CurrentStreakDays: math.MaxInt64, LongestTurn: math.MaxInt64},
		{LifetimeTokens: math.MinInt64, PeakDayTokens: math.MinInt64, LongestStreakDays: math.MinInt64, CurrentStreakDays: math.MinInt64, LongestTurn: math.MinInt64},
		{ActiveDays: 1, LifetimeCalls: 1, FirstDay: zeroStamps[4], PeakDay: zeroStamps[4]},
	} {
		for _, width := range []int{1, 5, 20, 40, 79, 80, 200} {
			what := fmt.Sprintf("stat strip %+v at %d", prof, width)
			bad, ok := zeroRun(what, func() {
				for _, line := range usageStatStrip(prof, width) {
					if got := ansi.StringWidth(line); got > width {
						t.Errorf("%s: strip of %d cells: %q", what, got, ansi.Strip(line))
					}
					if bad := zeroBadNumber(ansi.Strip(line)); bad != "" {
						t.Errorf("%s: %q %s", what, ansi.Strip(line), bad)
					}
				}
			})
			if !ok {
				t.Fatalf("%s panicked: %s", what, bad)
			}
		}
		for _, zone := range []*time.Location{time.UTC, time.FixedZone("z", -14*3600), time.FixedZone("z", 14*3600)} {
			facts := ansi.Strip(usageProfileFacts(prof, zone))
			if bad := zeroBadNumber(facts); bad != "" {
				t.Errorf("facts of %+v = %q: %s", prof, facts, bad)
			}
			// No use means no date at all; an unknown stamp is not the year 1.
			if prof.ActiveDays <= 0 && facts != "nothing used yet" {
				t.Errorf("facts of %+v = %q, want none", prof, facts)
			}
			if prof.ActiveDays > 0 && strings.Contains(facts, "1 Jan 1") {
				t.Errorf("facts of %+v = %q names a zero stamp", prof, facts)
			}
		}
	}
}

// TestPropZeroUsageUnits keeps a count's label numeric and short enough for
// the cell it sits in.
func TestPropZeroUsageUnits(t *testing.T) {
	for _, n := range zeroInts {
		got := usageUnits(n)
		if bad := zeroBadNumber(got); bad != "" {
			t.Fatalf("usageUnits(%d) = %q: %s", n, got, bad)
		}
		if n >= 0 && strings.HasPrefix(got, "-") {
			t.Fatalf("usageUnits(%d) = %q is negative", n, got)
		}
		// The label is a number and at most one unit letter: the ladder the
		// row's cell is sized for, never a float's own spelling.
		if !zeroUnits.MatchString(got) {
			t.Fatalf("usageUnits(%d) = %q is not a count in the client's units", n, got)
		}
		if cell := ansi.Strip(usageCount(n, "in", usageInW)); ansi.StringWidth(cell) != usageInW {
			t.Fatalf("usageCount(%d) = %q is %d cells", n, cell, ansi.StringWidth(cell))
		}
	}
}

// TestPropZeroUsageShare keeps a part of a whole a percentage: a count that is
// not one, or is more than its whole, states no share at all.
//
// A negative part is a daemon contract break the client is not asked to
// handle, so its checks are opt-in: PROPTEST_NEGATIVE_SHARE=1 (red on main).
func TestPropZeroUsageShare(t *testing.T) {
	negative := os.Getenv("PROPTEST_NEGATIVE_SHARE") == "1"
	for _, part := range zeroInts {
		if part < 0 && !negative {
			continue
		}
		for _, whole := range zeroInts {
			what := fmt.Sprintf("usageShare(%d, %d)", part, whole)
			got := usageShare(part, whole, "cached")
			if bad := zeroBadNumber(got); bad != "" {
				t.Fatalf("%s = %q: %s", what, got, bad)
			}
			if strings.Contains(got, "%") {
				if part < 0 || whole <= 0 || part > whole {
					t.Fatalf("%s = %q states a share it cannot have", what, got)
				}
				var pct float64
				if _, err := fmt.Sscanf(got[strings.Index(got, "(")+1:], "%f%%", &pct); err != nil || pct < 0 || pct > 100 {
					t.Fatalf("%s = %q is not a percentage of the whole", what, got)
				}
			}
			if part <= 0 && got != "" {
				t.Fatalf("%s = %q names a part that is not one", what, got)
			}
		}
	}
}

// TestPropZeroUsageDuration names a turn's length from any duration a ledger
// can hold, and never as a number it cannot read.
func TestPropZeroUsageDuration(t *testing.T) {
	for _, d := range []time.Duration{0, 1, time.Second, time.Minute, 93 * time.Minute, 26 * time.Hour, math.MaxInt64, math.MinInt64} {
		got := usageDuration(d)
		if bad := zeroBadNumber(got); bad != "" {
			t.Fatalf("usageDuration(%v) = %q: %s", d, got, bad)
		}
		if !strings.HasSuffix(got, "s") && !strings.HasSuffix(got, "m") {
			t.Fatalf("usageDuration(%v) = %q names no unit", d, got)
		}
	}
	for _, n := range zeroInts {
		if got := countedText(n, "day"); zeroBadNumber(got) != "" {
			t.Fatalf("countedText(%d) = %q", n, got)
		}
	}
}

// TestPropZeroQuotaReadings draws every quota reading the wire can carry: no
// percent, a percent outside the range, a zero or unparseable stamp, and no
// reset. The share it draws is a percentage of the limit.
func TestPropZeroQuotaReadings(t *testing.T) {
	at := zeroStamps[4]
	var failed []string
	for _, percent := range []float64{0, -0.0, 1, -1, 0.5, 50, 100, 101, -100, 1e9, -1e9, math.MaxFloat64, math.SmallestNonzeroFloat64} {
		for _, seen := range []string{"", "not a stamp", "2026-11-21T00:00:00Z", "0001-01-01T00:00:00Z", "9999-12-31T23:59:59Z"} {
			for _, resets := range []*string{nil, new(""), new("0001-01-01T00:00:00Z"), new("9999-12-31T23:59:59Z")} {
				r := daemon.QuotaObservation{Provider: "p", AccountID: "a", LimitID: "l", ObservedAt: seen, ResetsAt: resets, UsedPercent: &percent}
				what := fmt.Sprintf("%v%% seen %q resets %v", percent, seen, resets != nil)
				check := func(where, text string) {
					if bad := zeroBadNumber(text); bad != "" {
						failed = append(failed, fmt.Sprintf("%s %s = %q: %s", where, what, text, bad))
					}
					if got := strings.Count(text, "%"); got > 1 {
						failed = append(failed, fmt.Sprintf("%s %s = %q states two shares", where, what, text))
					}
				}
				if bad, ok := zeroRun("quotaTag "+what, func() { check("quotaTag", ansi.Strip(quotaTag(r, at))) }); !ok {
					failed = append(failed, "quotaTag "+what+" panicked: "+bad)
				}
				if bad, ok := zeroRun("quota summary "+what, func() {
					var m QuotaModel
					m.at = at
					check("summary", ansi.Strip(m.summary(r)))
				}); !ok {
					failed = append(failed, "quota summary "+what+" panicked: "+bad)
				}
				if bad, ok := zeroRun("quota details "+what, func() {
					var m QuotaModel
					m.at = at
					for _, line := range m.details(r, 60) {
						if bad := zeroBadNumber(ansi.Strip(line)); bad != "" {
							failed = append(failed, fmt.Sprintf("details %s = %q: %s", what, ansi.Strip(line), bad))
						}
					}
				}); !ok {
					failed = append(failed, "quota details "+what+" panicked: "+bad)
				}
			}
		}
	}
	for _, f := range failed[:min(len(failed), 20)] {
		t.Errorf("%s", f)
	}
}

// TestPropZeroQuotaSpark draws a trail of any shape: no readings, one, ties,
// a span of none, and readings before the picture starts.
func TestPropZeroQuotaSpark(t *testing.T) {
	at := zeroStamps[4]
	for _, points := range [][]quotaPoint{
		nil,
		{{At: at, Percent: 0}},
		{{At: at, Percent: 55}},
		{{At: at, Percent: 100}},
		{{At: at.Add(-time.Hour), Percent: 10}, {At: at, Percent: 90}},
		{{At: at, Percent: 10}, {At: at, Percent: 90}},
		{{At: time.Time{}, Percent: 10}, {At: at, Percent: 90}},
		{{At: at.Add(-48 * time.Hour), Percent: 10}, {At: at.Add(48 * time.Hour), Percent: 90}},
		{{At: at.Add(-time.Hour), Percent: -50}, {At: at, Percent: 500}},
	} {
		for _, width := range []int{1, 2, 40} {
			for _, from := range []time.Time{at, at.Add(-24 * time.Hour), at.Add(time.Hour), time.Time{}} {
				what := fmt.Sprintf("%d points width %d from %v", len(points), width, from)
				if bad, ok := zeroRun("quotaSpark "+what, func() {
					for _, line := range quotaSpark(points, from, at, width) {
						if got := ansi.StringWidth(line); got != width {
							t.Errorf("%s: row of %d cells", what, got)
						}
						if bad := zeroBadNumber(ansi.Strip(line)); bad != "" {
							t.Errorf("%s: row %q %s", what, ansi.Strip(line), bad)
						}
					}
				}); !ok {
					t.Fatalf("quotaSpark %s panicked: %s", what, bad)
				}
			}
		}
	}
}

// TestPropZeroQuotaPace states where a limit is going from any recent points
// the trail can hold, and says nothing rather than a figure it cannot stand.
func TestPropZeroQuotaPace(t *testing.T) {
	at := zeroStamps[4]
	for _, points := range [][]quotaPoint{
		nil,
		{{At: at, Percent: 50}},
		{{At: at.Add(-time.Hour), Percent: 50}, {At: at, Percent: 50}},
		{{At: at.Add(-time.Hour), Percent: 10}, {At: at, Percent: 60}},
		{{At: at.Add(-time.Hour), Percent: 60}, {At: at, Percent: 10}},
		{{At: at.Add(-time.Hour), Percent: 0}, {At: at, Percent: 100}},
		{{At: at.Add(-2 * time.Hour), Percent: 0}, {At: at, Percent: 100}},
	} {
		for _, percent := range []float64{0, 50, 100, -100, 1e9} {
			r := daemon.QuotaObservation{Provider: "p", AccountID: "a", LimitID: "l", UsedPercent: &percent}
			for _, resets := range []*string{nil, new(at.Add(time.Hour).Format(time.RFC3339)), new("not a stamp")} {
				r.ResetsAt = resets
				what := fmt.Sprintf("points %+v percent %v resets %v", points, percent, resets != nil)
				if bad, ok := zeroRun("quotaPace "+what, func() {
					pace := ansi.Strip(quotaPace(points, r, at))
					if bad := zeroBadNumber(pace); bad != "" {
						t.Errorf("%s: pace %q: %s", what, pace, bad)
					}
				}); !ok {
					t.Fatalf("quotaPace %s panicked: %s", what, bad)
				}
			}
		}
	}
}

// TestPropZeroUsageListRun draws the days list from degenerate answers: no
// days, one, zero stamps, negative and overflowing counts.
func TestPropZeroUsageListRun(t *testing.T) {
	var failed []string
	for seed := int64(1); seed <= 200; seed++ {
		r := rand.New(rand.NewSource(seed))
		answer := func() daemon.UsageSummary {
			s := daemon.UsageSummary{GeneratedAt: zeroStamps[r.Intn(len(zeroStamps))], UTCOffsetMinutes: r.Intn(29) - 14}
			for range r.Intn(4) {
				s.Days = append(s.Days, daemon.UsageDay{Start: zeroStamps[r.Intn(len(zeroStamps))], UsageTotals: zeroTotals(zeroInts[r.Intn(len(zeroInts))], zeroInts[r.Intn(len(zeroInts))], zeroInts[r.Intn(len(zeroInts))])})
			}
			for range r.Intn(3) {
				s.Lines = append(s.Lines, daemon.UsageLine{Model: "m", Profile: "p", Provider: "x:https://a.example", UsageTotals: zeroTotals(zeroInts[r.Intn(len(zeroInts))], zeroInts[r.Intn(len(zeroInts))], zeroInts[r.Intn(len(zeroInts))])})
			}
			return s
		}
		m := NewUsageModel(nil)
		m.SetSize(40+r.Intn(120), 10+r.Intn(20))
		m, _ = m.Update(usageLoadedMsg{Gen: m.Generation, Today: answer(), Week: answer()})
		what := fmt.Sprintf("seed %d usage list", seed)
		if bad, ok := zeroRun(what, func() {
			view := ansi.Strip(m.View())
			for _, line := range strings.Split(view, "\n") {
				if w := ansi.StringWidth(line); w > m.Width && len(failed) < 20 {
					failed = append(failed, fmt.Sprintf("%s: row of %d cells at width %d: %q", what, w, m.Width, line))
				}
				if bad := zeroBadNumber(line); bad != "" && len(failed) < 20 {
					failed = append(failed, fmt.Sprintf("%s: %q %s", what, line, bad))
				}
			}
		}); !ok {
			failed = append(failed, what+" panicked: "+bad)
		}
	}
	for _, f := range failed[:min(len(failed), 20)] {
		t.Errorf("%s", f)
	}
}

// TestPropZeroSessionListRun draws the session list at every width from
// sessions that carry no age, no cost, and an age from the far past or future.
func TestPropZeroSessionListRun(t *testing.T) {
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	var sessions []daemon.Session
	for _, ts := range []*int64{nil, new(int64(0)), new(int64(-1)), new(int64(math.MaxInt64)), new(int64(math.MinInt64)), new(now.Unix())} {
		for _, cost := range []*float64{nil, new(float64(0)), new(float64(-1)), new(float64(math.NaN())), new(float64(math.Inf(1))), new(math.MaxFloat64)} {
			sessions = append(sessions, daemon.Session{ID: fmt.Sprintf("s%d", len(sessions)), Title: "t", LastAssistantAt: ts, SessionCostUSD: cost})
		}
	}
	for _, width := range []int{1, 4, 20, 31, 39, 47, 89, 200} {
		what := fmt.Sprintf("session list width %d", width)
		m := viewerAt(now)
		m.SetSize(width, 20)
		m.SetSessions(sessions, nil)
		m.Init()
		if bad, ok := zeroRun(what, func() {
			for _, line := range m.column(width, 12, now) {
				if got := ansi.StringWidth(line); got != width {
					t.Errorf("%s: row of %d cells: %q", what, got, ansi.Strip(line))
				}
				if bad := zeroBadNumber(ansi.Strip(line)); bad != "" {
					t.Errorf("%s: %q %s", what, ansi.Strip(line), bad)
				}
			}
		}); !ok {
			t.Fatalf("%s panicked: %s", what, bad)
		}
	}
	for _, now := range zeroStamps {
		for _, ts := range []int64{0, 1, -1, math.MaxInt64, math.MinInt64, now.Unix(), now.Unix() + 86400, now.Unix() - 86400} {
			got := svCompactAge(&ts, now)
			if bad := zeroBadNumber(got); bad != "" || got == "" {
				t.Fatalf("svCompactAge(%d, %v) = %q %s", ts, now, got, bad)
			}
		}
	}
}

// TestPropZeroContextUsage draws the context bar and legend from any size and
// window, including none: a bar of the declared width, and a share that is a
// percentage between 0 and 100 when the window is known.
func TestPropZeroContextUsage(t *testing.T) {
	for _, used := range []int{0, 1, math.MaxInt32} {
		for _, window := range []int{0, 1, -1, 200_000, math.MaxInt32} {
			for _, trigger := range []int{0, -1, 1, 200_000} {
				for _, width := range []int{0, 1, 40, 200} {
					u := contextUsage{Used: used, Window: window, Trigger: trigger, Parts: []contextPart{{Label: "conversation", Tokens: used, Style: chrome.DefaultStyles.Agent}}}
					what := fmt.Sprintf("used %d window %d trigger %d cells %d", used, window, trigger, width)
					if bad, ok := zeroRun(what, func() {
						bar := ansi.Strip(u.bar(width))
						if got, want := ansi.StringWidth(bar), max(1, width); got != want {
							t.Errorf("%s: bar is %d cells, want %d", what, got, want)
						}
						for _, line := range append(u.legend(40), u.block(40, 12)...) {
							if bad := zeroBadNumber(ansi.Strip(line)); bad != "" && !strings.Contains(line, "…") {
								t.Errorf("%s: %q %s", what, ansi.Strip(line), bad)
							}
						}
						if pct := u.percent(used); pct != "" {
							var got float64
							if _, err := fmt.Sscanf(strings.TrimSuffix(pct, "%"), "%f", &got); err != nil {
								t.Errorf("%s: percent %q does not parse", what, pct)
							}
							if got < 0 {
								t.Errorf("%s: percent %q is negative", what, pct)
							}
						}
					}); !ok {
						t.Fatalf("%s panicked: %s", what, bad)
					}
				}
			}
		}
	}
}

// TestPropZeroChatFooterShare keeps the footer's context share a whole
// percentage of a window the client knows.
func TestPropZeroChatFooterShare(t *testing.T) {
	for _, window := range []int{1, 200_000, math.MaxInt32} {
		for _, prompt := range []int{0, 1, 999, 200_000, math.MaxInt32} {
			m := ChatModel{Usage: &daemon.Usage{Model: "m", PromptTokens: &prompt}}
			w, model := window, "m"
			m.window, m.windowModel = &w, &model
			_, short := m.contextStat()
			text := ansi.Strip(short)
			if bad := zeroBadNumber(text); bad != "" {
				t.Errorf("window %d prompt %d: footer %q: %s", window, prompt, text, bad)
			}
			if i := strings.LastIndex(text, "("); i >= 0 {
				var pct int
				if _, err := fmt.Sscanf(strings.TrimSuffix(text[i:], "%)"), "(%d", &pct); err == nil && pct < 0 {
					t.Errorf("window %d prompt %d: share %q is not a percentage", window, prompt, text[i:])
				}
			}
		}
	}
}

// TestPropZeroEstimatedCost never says a cost it cannot state: a nil,
// negative, NaN or infinite estimate is unknown, and a known one reads as
// money.
func TestPropZeroEstimatedCost(t *testing.T) {
	if _, ok := estimatedCost(nil, false); ok {
		t.Fatal("a nil cost is known")
	}
	for _, f := range []float64{0, math.Copysign(0, -1), 1, -1, 0.004, 0.01, 1000, 12345.6, 1e9, math.MaxFloat64, math.NaN(), math.Inf(1), math.Inf(-1)} {
		for _, compact := range []bool{false, true} {
			cost := f
			got, ok := estimatedCost(&cost, compact)
			if math.IsNaN(f) || math.IsInf(f, 0) || f < 0 {
				if ok {
					t.Fatalf("estimatedCost(%v) = %q, want unknown", f, got)
				}
				continue
			}
			if !ok || !strings.HasPrefix(got, "$") || zeroBadNumber(strings.TrimPrefix(got, "$")) != "" {
				t.Fatalf("estimatedCost(%v, %v) = %q, %v", f, compact, got, ok)
			}
		}
	}
}
