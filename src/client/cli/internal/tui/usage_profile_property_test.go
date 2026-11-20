package tui

// Property tests for the usage profile calendar: an independent date-based
// oracle for cell placement, cursor clamping, week sums and rendering bounds.

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"math"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

func usageRandomYear(r *rand.Rand) daemon.UsageSummary {
	n := 1 + r.Intn(371)
	if r.Intn(3) == 0 {
		n = 371 - r.Intn(8)
	}
	offset := (r.Intn(26*4+1) - 12*4) * 15
	zone := time.FixedZone("z", offset*60)
	today := time.Date(2020+r.Intn(10), time.Month(1+r.Intn(12)), 1+r.Intn(28), 0, 0, 0, 0, zone)
	days := make([]daemon.UsageDay, n)
	var total int64
	for i := range days {
		d := daemon.UsageDay{Start: today.AddDate(0, 0, -(n - 1 - i)).UTC()}
		if r.Intn(3) > 0 {
			d.InputTokens = int64(r.Intn(5000)) * int64(1+r.Intn(1000))
			d.OutputTokens = int64(r.Intn(100))
			d.Calls = int64(1 + r.Intn(9))
		}
		total += d.InputTokens + d.OutputTokens
		days[i] = d
	}
	year := daemon.UsageSummary{Days: days, UTCOffsetMinutes: offset}
	if r.Intn(2) == 0 {
		year.Profile = &daemon.UsageProfile{LifetimeTokens: total + int64(r.Intn(3))*int64(r.Intn(1e6)) - int64(r.Intn(2))*total/2, ActiveDays: int64(n), FirstDay: days[0].Start, PeakDay: days[n-1].Start, LongestTurn: time.Duration(r.Intn(1e4)) * time.Second}
	}
	for range r.Intn(5) {
		year.Lines = append(year.Lines, daemon.UsageLine{Model: "model-" + strconv.Itoa(r.Intn(4)), UsageTotals: daemon.UsageTotals{InputTokens: int64(r.Intn(1e6))}})
	}
	return year
}

func TestPropUsageProfile(t *testing.T) {
	n := 1500
	if v, err := strconv.Atoi(os.Getenv("USAGE_PROP_CASES")); err == nil {
		n = v
	}
	overflow := map[string]string{}
	widest := map[string]int{}
	for seed := int64(1); seed <= int64(n); seed++ {
		r := rand.New(rand.NewSource(seed))
		year := usageRandomYear(r)
		width := 1 + r.Intn(200)
		height := 1 + r.Intn(45)
		w := usageInner(width)
		cal, ok := newUsageCalendar(year, w)
		if !ok {
			t.Fatalf("seed %d: no calendar", seed)
		}
		zone := time.FixedZone("z", year.UTCOffsetMinutes*60)
		nd := len(year.Days)
		today := year.Days[nd-1].Start.In(zone)
		fail := func(format string, args ...any) {
			t.Fatalf("seed %d (days %d, width %d, today %s): %s", seed, nd, width, today.Format("Mon 2006-01-02"), fmt.Sprintf(format, args...))
		}
		if w >= usageGutter+usageCellW && usageGutter+cal.weeks*usageCellW > w {
			fail("%d weeks overflow %d cells", cal.weeks, w)
		}
		// Placement: a cell's day is the calendar date its column and row name.
		seen := map[int]bool{}
		for col := range cal.weeks {
			for row := range 7 {
				day, ok := cal.day(col, row)
				// Date oracle: the last column's Monday, minus whole weeks, plus the row.
				thisMonday := today.AddDate(0, 0, -((int(today.Weekday()) + 6) % 7))
				date := thisMonday.AddDate(0, 0, -7*(cal.weeks-1-col)+row)
				back := int(math.Round(today.Sub(date).Hours() / 24))
				wantOK := back >= 0 && back < nd
				if ok != wantOK {
					fail("cell %d,%d (%s) ok=%v want %v", col, row, date.Format("2006-01-02"), ok, wantOK)
				}
				if !ok {
					continue
				}
				if got := day.Start.In(zone); got.Format("2006-01-02") != date.Format("2006-01-02") {
					fail("cell %d,%d holds %s want %s", col, row, got.Format("2006-01-02"), date.Format("2006-01-02"))
				}
				seen[back] = true
				if col < cal.weeks-1 && !ok {
					fail("incomplete older column %d", col)
				}
			}
		}
		maxBack := cal.maxBack()
		for b := 0; b <= maxBack; b++ {
			if !seen[b] {
				fail("day %d back not drawn (maxBack %d)", b, maxBack)
			}
		}
		if len(seen) != maxBack+1 {
			fail("drew %d days, maxBack %d", len(seen), maxBack)
		}
		// Week sums against a direct sum by Monday-based week.
		p := usageProfile{year: year}
		for _, mode := range []usageMode{usageWeekly, usageCumulative} {
			p.mode = mode
			sizes := p.columnSizes(cal)
			var run int64
			var drawn int64
			for col := range cal.weeks {
				var sum int64
				for row := range 7 {
					thisMonday := today.AddDate(0, 0, -((int(today.Weekday()) + 6) % 7))
					date := thisMonday.AddDate(0, 0, -7*(cal.weeks-1-col)+row)
					back := int(math.Round(today.Sub(date).Hours() / 24))
					if back >= 0 && back < nd {
						d := year.Days[nd-1-back]
						sum += d.InputTokens + d.OutputTokens
					}
				}
				drawn += sum
				if mode == usageWeekly && sizes[col] != sum {
					fail("week %d sums %d want %d", col, sizes[col], sum)
				}
				run += sum
				if mode == usageCumulative && col > 0 && sizes[col] < sizes[col-1] {
					fail("cumulative decreases at %d", col)
				}
			}
			if mode == usageCumulative && year.Profile != nil && sizes[len(sizes)-1] != max(drawn, year.Profile.LifetimeTokens) {
				fail("cumulative ends %d, drawn %d lifetime %d", sizes[len(sizes)-1], drawn, year.Profile.LifetimeTokens)
			}
		}
		// Cursor: keys keep it on a drawn day; the highlighted column holds it.
		p.mode = usageMode(r.Intn(3))
		model := 0
		for range 30 {
			key := []string{"h", "l", "j", "k", "g", "G", "left", "right", "up", "down", "d", "w", "c"}[r.Intn(13)]
			p = p.key(key, width)
			switch key {
			case "h", "left":
				model += 7
			case "l", "right":
				model -= 7
			case "k", "up":
				model++
			case "j", "down":
				model--
			case "g":
				model = maxBack
			case "G":
				model = 0
			}
			model = max(0, min(model, maxBack))
			if p.back != model {
				fail("after %s cursor back %d want %d", key, p.back, model)
			}
			// The weekly detail names the Monday of the cursor's own week.
			cursorDay := today.AddDate(0, 0, -p.back)
			monday := cursorDay.AddDate(0, 0, -((int(cursorDay.Weekday()) + 6) % 7))
			weekly := p
			weekly.mode = usageWeekly
			detail := ansi.Strip(weekly.detailLine(cal, 1000))
			if want := "week of " + monday.Format("Mon 2 Jan"); !strings.Contains(detail, want) {
				fail("cursor back %d detail %q, want %q", p.back, detail, want)
			}
		}
		// Months are whole three-letter names.
		months := ansi.Strip(usageMonths(cal))
		for _, f := range strings.Fields(months) {
			if _, err := time.Parse("Jan", f); err != nil || len(f) != 3 {
				key := "month label"
				if _, ok := overflow[key]; !ok {
					overflow[key] = fmt.Sprintf("seed %d width %d today %s: %q in %q", seed, width, today.Format("Mon 2006-01-02"), f, months)
				}
			}
		}
		// Rendered lines fit the screen. Below 30 columns the model panel's
		// fixed columns overflow, which listFrame clips; that is not asserted.
		lines := p.profileLines(width, height)
		if len(lines) > height {
			fail("%d lines for height %d", len(lines), height)
		}
		for i, line := range lines {
			if got := ansi.StringWidth(line); got > width && width >= 30 {
				key := fmt.Sprintf("line width (mode %d)", p.mode)
				if width > widest[key] {
					widest[key] = width
					overflow[key] = fmt.Sprintf("seed %d width %d line %d is %d cells: %q", seed, width, i, got, ansi.Strip(line))
				}
			}
		}
	}
	for key, example := range overflow {
		t.Errorf("%s: %s", key, example)
	}
}

func TestPropUsageLevels(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for range 5000 {
		values := make([]int64, r.Intn(30))
		for i := range values {
			values[i] = int64(r.Intn(20) - 3)
		}
		level := usageLevels(values)
		anyUsed := false
		for _, v := range values {
			anyUsed = anyUsed || v > 0
		}
		prev := -1
		for v := int64(-5); v <= 25; v++ {
			l := level(v)
			if (v <= 0 || !anyUsed) != (l == 0) || l < 0 || l > 4 || l < prev {
				t.Fatalf("values %v: level(%d)=%d after %d", values, v, l, prev)
			}
			prev = l
		}
	}
}
