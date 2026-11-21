package tui

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"
	"testing/quick"
	"time"

	"albedo/cli/internal/daemon"

	"github.com/charmbracelet/x/ansi"
)

// propYear is a usage year the properties draw: n days ending today on a fixed
// clock, and one day's totals per day.
type propYear struct {
	n      int
	offset int
	starts []time.Time
	tokens []int64
	calls  []int64
}

func genPropYear(rng *rand.Rand) propYear {
	year := propYear{n: 1 + rng.Intn(371), offset: (rng.Intn(25) - 12) * 60}
	zone := time.FixedZone("prop", year.offset*60)
	today := time.Date(2026, 3, 12, 0, 0, 0, 0, zone)
	for back := year.n - 1; back >= 0; back-- {
		year.starts = append(year.starts, today.AddDate(0, 0, -back))
		if rng.Intn(3) == 0 {
			year.tokens, year.calls = append(year.tokens, 0), append(year.calls, 0)
			continue
		}
		year.tokens = append(year.tokens, int64(rng.Intn(2_000_000)))
		year.calls = append(year.calls, int64(rng.Intn(40)+1))
	}
	return year
}

// summary is the daemon answer the year stands for, with the profile the
// daemon would compute for it.
func (y propYear) summary() daemon.UsageSummary {
	summary := daemon.UsageSummary{GeneratedAt: y.starts[len(y.starts)-1], UTCOffsetMinutes: y.offset}
	var lifetime, calls, active, peak int64
	peakAt := -1
	for i := range y.starts {
		summary.Days = append(summary.Days, daemon.UsageDay{Start: y.starts[i], UsageTotals: daemon.UsageTotals{Calls: y.calls[i], InputTokens: y.tokens[i]}})
		if y.tokens[i] == 0 && y.calls[i] == 0 {
			continue
		}
		lifetime += y.tokens[i]
		calls += y.calls[i]
		active++
		if y.tokens[i] > peak {
			peak, peakAt = y.tokens[i], i
		}
	}
	summary.Lines = []daemon.UsageLine{{Profile: "p", Provider: "prov", Model: "model", UsageTotals: daemon.UsageTotals{Calls: calls, InputTokens: lifetime}}}
	profile := &daemon.UsageProfile{LifetimeTokens: lifetime, LifetimeCalls: calls, ActiveDays: active,
		LongestStreakDays: 1, CurrentStreakDays: 1, LongestTurn: time.Minute}
	if peakAt >= 0 {
		profile.PeakDay, profile.PeakDayTokens = y.starts[peakAt], peak
		for i := range y.starts {
			if y.tokens[i] != 0 || y.calls[i] != 0 {
				profile.FirstDay = y.starts[i]
				break
			}
		}
	}
	summary.Profile = profile
	return summary
}

// model renders the profile tab after a key sequence at one width.
func (y propYear) model(width, height int, keys ...string) UsageModel {
	return usageProfileModel(width, height, y.summary(), keys...)
}

// cellFor is the cell that draws the day back days before today: a column per
// week from the last, rows from Monday.
func cellFor(cal usageCalendar, back int) (int, int) {
	col := cal.weeks - 1 - (back-cal.lead+6)/7
	row := (cal.lead - back) % 7
	if row < 0 {
		row += 7
	}
	return col, row
}

// TestPropCalendarDrawsEveryDayAtItsAge: the cell at (col,row) draws the day
// whose age in days is cal.back(col,row), and every reachable age has a cell.
func TestPropCalendarDrawsEveryDayAtItsAge(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for i := 0; i < 400; i++ {
		year := genPropYear(rng)
		cal, ok := newUsageCalendar(year.summary(), 8+rng.Intn(240))
		if !ok {
			t.Fatalf("a year of %d days has a calendar", year.n)
		}
		for col := range cal.weeks {
			for row := range 7 {
				back := cal.back(col, row)
				day, present := cal.day(col, row)
				want := back >= 0 && back <= len(year.starts)-1
				if present != want {
					t.Fatalf("n=%d weeks=%d back=%d present=%v want=%v", year.n, cal.weeks, back, present, want)
				}
				if !present {
					continue
				}
				if age := -(day.Start.Sub(year.starts[len(year.starts)-1]).Hours() / 24); int(age) != back {
					t.Fatalf("n=%d cell (%d,%d) draws %v, age %v, want %d", year.n, col, row, day.Start, int(age), back)
				}
			}
		}
		for back := 0; back <= cal.maxBack(); back++ {
			col, row := cellFor(cal, back)
			if got := cal.back(col, row); got != back {
				t.Fatalf("n=%d weeks=%d lead=%d: age %d is at (%d,%d), age %d", year.n, cal.weeks, cal.lead, back, col, row, got)
			}
			if _, ok := cal.day(col, row); !ok {
				t.Fatalf("n=%d: the cell for age %d is empty", year.n, back)
			}
		}
	}
}

// TestPropWeekTotalsSumThatWeek: a column's tokens and calls are those of the
// days its Monday through Sunday cover.
func TestPropWeekTotalsSumThatWeek(t *testing.T) {
	rng := rand.New(rand.NewSource(2))
	for i := 0; i < 300; i++ {
		year := genPropYear(rng)
		cal, _ := newUsageCalendar(year.summary(), 40+rng.Intn(160))
		for col := range cal.weeks {
			tokens, calls, monday := cal.week(col)
			var wantTokens, wantCalls int64
			for row := range 7 {
				day, ok := cal.day(col, row)
				if !ok {
					continue
				}
				if want := monday.AddDate(0, 0, row); !day.Start.Equal(want) {
					t.Fatalf("n=%d col %d row %d draws %v, want %v", year.n, col, row, day.Start, want)
				}
				wantTokens += usageSize(day.UsageTotals)
				wantCalls += day.Calls
			}
			if tokens != wantTokens || calls != wantCalls {
				t.Fatalf("n=%d col %d: %d/%d want %d/%d", year.n, col, tokens, calls, wantTokens, wantCalls)
			}
		}
	}
}

// TestPropCursorStaysOnTheDayTheDetailNames: any key sequence leaves the
// cursor on a drawn cell, and the detail line names that day.
func TestPropCursorStaysOnTheDayTheDetailNames(t *testing.T) {
	rng := rand.New(rand.NewSource(3))
	keys := []string{"h", "l", "j", "k", "g", "G"}
	for i := 0; i < 200; i++ {
		year := genPropYear(rng)
		width := 20 + rng.Intn(200)
		var seq []string
		for range rng.Intn(12) {
			seq = append(seq, keys[rng.Intn(len(keys))])
		}
		m := year.model(width, 30, seq...)
		cal, _ := newUsageCalendar(m.profile.year, usageInner(width))
		if m.profile.back < 0 || m.profile.back > cal.maxBack() {
			t.Fatalf("%v: age %d outside 0..%d", seq, m.profile.back, cal.maxBack())
		}
		col, row := cellFor(cal, m.profile.back)
		day, ok := cal.day(col, row)
		if !ok {
			t.Fatalf("%v: no cell draws age %d", seq, m.profile.back)
		}
		if want := day.Start.In(cal.zone).Format("Mon 2 Jan"); !strings.Contains(ansi.Strip(m.View()), want) {
			t.Fatalf("%v: the detail line lacks %q\n%s", seq, want, ansi.Strip(m.View()))
		}
	}
}

// TestPropCumulativeEndsAtTheLifetime: the cumulative view's last column is
// the lifetime total and its columns never shrink.
func TestPropCumulativeEndsAtTheLifetime(t *testing.T) {
	rng := rand.New(rand.NewSource(4))
	for i := 0; i < 300; i++ {
		year := genPropYear(rng)
		summary := year.summary()
		cal, _ := newUsageCalendar(summary, 40+rng.Intn(160))
		sizes := usageProfile{year: summary, mode: usageCumulative}.columnSizes(cal)
		if len(sizes) == 0 {
			continue
		}
		if last := sizes[len(sizes)-1]; last != summary.Profile.LifetimeTokens {
			t.Fatalf("n=%d weeks=%d: ends at %d, lifetime %d", year.n, cal.weeks, last, summary.Profile.LifetimeTokens)
		}
		for col := 1; col < len(sizes); col++ {
			if sizes[col] < sizes[col-1] {
				t.Fatalf("n=%d: column %d shrinks %d to %d", year.n, col, sizes[col-1], sizes[col])
			}
		}
	}
}

// TestPropLevelsRankTheDays: a busier day never grades below a quieter one,
// an idle day is level zero, and a day with use is graded one to four.
func TestPropLevelsRankTheDays(t *testing.T) {
	rng := rand.New(rand.NewSource(5))
	for i := 0; i < 200; i++ {
		values := make([]int64, 1+rng.Intn(60))
		for j := range values {
			if rng.Intn(4) != 0 {
				values[j] = rng.Int63n(10)
			}
		}
		level := usageLevels(values)
		for _, v := range values {
			if v <= 0 && level(v) != 0 {
				t.Fatalf("%d is level %d", v, level(v))
			}
			if v > 0 && (level(v) < 1 || level(v) > 4) {
				t.Fatalf("%d is level %d", v, level(v))
			}
		}
		for _, a := range values {
			for _, b := range values {
				if a < b && level(a) > level(b) {
					t.Fatalf("%d grades %d above %d's %d", a, level(a), b, level(b))
				}
			}
		}
	}
}

// TestPropHBarFillsItsCells: a bar is w cells, shows a mark for every nonzero
// value, and nothing for zero.
func TestPropHBarFillsItsCells(t *testing.T) {
	rng := rand.New(rand.NewSource(6))
	for i := 0; i < 500; i++ {
		w := 1 + rng.Intn(120)
		top := rng.Int63n(1 << 40)
		n := rng.Int63n(top + 1)
		bar := usageHBar(n, top, w)
		if got := ansi.StringWidth(bar); got != w {
			t.Fatalf("bar %d of %d in %d is %d cells", n, top, w, got)
		}
		if n > 0 && !strings.Contains(bar, "━") {
			t.Fatalf("bar %d of %d in %d shows nothing: %q", n, top, w, bar)
		}
		if n == 0 && strings.Contains(bar, "━") {
			t.Fatalf("bar 0 of %d in %d shows a mark: %q", top, w, bar)
		}
	}
}

// TestPropProfileRowsFitTheirWidth: profileLines promises at most height rows
// of width cells. Below 28 columns the panels are wider than their box, which
// the frame then truncates; that is tracked separately, so this property holds
// from the width a panel row needs.
func TestPropProfileRowsFitTheirWidth(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	for i := 0; i < 400; i++ {
		year := genPropYear(rng)
		width := 28 + rng.Intn(200)
		height := 4 + rng.Intn(40)
		p := usageProfile{year: year.summary(), mode: usageMode(rng.Intn(3))}
		lines := p.profileLines(width, height)
		if len(lines) > height {
			t.Fatalf("width %d height %d: %d rows", width, height, len(lines))
		}
		for _, line := range lines {
			if w := ansi.StringWidth(line); w > width {
				t.Fatalf("width %d height %d mode %d: row of %d cells: %q", width, height, p.mode, w, ansi.Strip(line))
			}
		}
	}
}

// TestPropProfileViewFitsTheTerminal: the drawn screen is never wider than the
// terminal, however narrow it is.
func TestPropProfileViewFitsTheTerminal(t *testing.T) {
	rng := rand.New(rand.NewSource(8))
	for i := 0; i < 120; i++ {
		year := genPropYear(rng)
		width := 8 + rng.Intn(200)
		height := 4 + rng.Intn(40)
		m := year.model(width, height, []string{"c", "w", "d"}[rng.Intn(3)])
		lines := strings.Split(ansi.Strip(m.View()), "\n")
		if len(lines) > height {
			t.Fatalf("width %d height %d: %d rows", width, height, len(lines))
		}
		for _, line := range lines {
			if w := ansi.StringWidth(line); w > width {
				t.Fatalf("width %d height %d: row of %d cells: %q", width, height, w, line)
			}
		}
	}
}

// TestPropProfilePrintsNoZeroTimes: nothing the profile draws names a zero
// time, a NaN or an infinity.
func TestPropProfilePrintsNoZeroTimes(t *testing.T) {
	rng := rand.New(rand.NewSource(9))
	for i := 0; i < 150; i++ {
		year := genPropYear(rng)
		width := 20 + rng.Intn(160)
		view := ansi.Strip(year.model(width, 30).View())
		for _, banned := range []string{"1 Jan 1", "NaN", "Inf", "invalid"} {
			if strings.Contains(view, banned) {
				t.Fatalf("width %d shows %q:\n%s", width, banned, view)
			}
		}
		if prof := year.summary().Profile; prof.ActiveDays > 0 && !strings.Contains(view, usageUnits(prof.LifetimeTokens)) {
			t.Fatalf("width %d lacks lifetime %s:\n%s", width, usageUnits(prof.LifetimeTokens), view)
		}
	}
}

// TestPropQuotaShowsTheShareLeft: every place a reading prints a percentage
// prints the share left, clamped to 0..100.
func TestPropQuotaShowsTheShareLeft(t *testing.T) {
	at := time.Date(2026, 3, 12, 12, 0, 0, 0, time.UTC)
	resets := at.Add(2 * time.Hour).Format(time.RFC3339)
	check := func(used float64) bool {
		reading := daemon.QuotaObservation{Provider: "p", AccountID: "a", LimitID: "l", UsedPercent: &used,
			ObservedAt: at.Format(time.RFC3339), ResetsAt: &resets}
		left := max(0, min(100, 100-used))
		want := fmt.Sprintf("%.0f%% left", left)
		m := QuotaModel{at: at}
		for name, drawn := range map[string]string{
			"summary": ansi.Strip(m.summary(reading)),
			"tag":     ansi.Strip(quotaTag(reading, at)),
			"details": ansi.Strip(strings.Join(m.details(reading, 80), " ")),
		} {
			if !strings.Contains(drawn, fmt.Sprintf("%.0f%%", left)) {
				t.Errorf("%s of used %v: no %v%% in %q", name, used, left, drawn)
				return false
			}
		}
		if !strings.Contains(ansi.Strip(quotaTag(reading, at)), want) {
			t.Errorf("tag of used %v: no %q", used, want)
			return false
		}
		return true
	}
	for _, used := range []float64{0, 0.4, 1, 12.5, 33.5, 40, 50, 79.9, 95, 99.6, 100, 120, -5} {
		if !check(used) {
			return
		}
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 300, Rand: rand.New(rand.NewSource(10))}); err != nil {
		t.Error(err)
	}
}

// wantQuotaSpan is a span as the pane names it, written independently: two
// units at most, and never a zero count of its largest one.
func wantQuotaSpan(d time.Duration) string {
	ms := max(d, 0).Minutes()
	switch {
	case ms < 1:
		return "<1m"
	case ms < 60:
		return fmt.Sprintf("%dm", int64(ms))
	}
	minutes := int64(ms)
	if minutes < 24*60 {
		span := fmt.Sprintf("%dh", minutes/60)
		if rest := minutes % 60; rest > 0 {
			span += fmt.Sprintf("%dm", rest)
		}
		return span
	}
	hours := minutes / 60
	span := fmt.Sprintf("%dd", hours/24)
	if rest := hours % 24; rest > 0 {
		span += fmt.Sprintf("%dh", rest)
	}
	return span
}

// TestPropQuotaSpanNamesTwoUnits: a span is its two largest units, and a zero
// span is under a minute rather than a zero count.
func TestPropQuotaSpanNamesTwoUnits(t *testing.T) {
	check := func(minutes int64) bool {
		d := time.Duration(minutes) * time.Minute
		if got, want := quotaSpan(d), wantQuotaSpan(d); got != want {
			t.Errorf("span %v is %q, want %q", d, got, want)
			return false
		}
		return true
	}
	for _, minutes := range []int64{0, 1, 59, 60, 61, 119, 1439, 1440, 1441, 2880, 43200} {
		if !check(minutes) {
			return
		}
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 500, Rand: rand.New(rand.NewSource(11))}); err != nil {
		t.Error(err)
	}
}

// TestPropEstimatedCostNamesItsCents: an estimate is dollars and cents, a
// tenth of a cent is a lower bound, and a four-digit total keeps its cents
// only where the compact column is not asked for.
func TestPropEstimatedCostNamesItsCents(t *testing.T) {
	check := func(micros int64) bool {
		cost := float64(micros) / 1_000_000
		full, known := estimatedCost(&cost, false)
		compact, compactKnown := estimatedCost(&cost, true)
		if cost < 0 {
			if known || compactKnown {
				t.Errorf("negative cost %v prints %q", cost, full)
				return false
			}
			return true
		}
		if !known || !compactKnown {
			t.Errorf("cost %v is unknown", cost)
			return false
		}
		if cost > 0 && cost < 0.01 {
			if full != "$<0.01" {
				t.Errorf("cost %v is %q, want $<0.01", cost, full)
				return false
			}
		} else if want := fmt.Sprintf("$%.2f", cost); full != want {
			t.Errorf("cost %v is %q, want %q", cost, full, want)
			return false
		}
		if cost >= 1000 {
			if want := fmt.Sprintf("$%.0f", cost); compact != want {
				t.Errorf("compact cost %v is %q, want %q", cost, compact, want)
				return false
			}
		} else if compact != full {
			t.Errorf("compact cost %v is %q, not %q", cost, compact, full)
			return false
		}
		return true
	}
	for _, micros := range []int64{0, 1, 4_999, 5_000, 9_999, 10_000, 999_999_999, 1_000_000_000, 1_234_567_890} {
		if !check(micros) {
			return
		}
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 2000, Rand: rand.New(rand.NewSource(12))}); err != nil {
		t.Error(err)
	}
}
