package tui

import (
	"strings"
	"testing"
	"time"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// usageYear is a year ending on usageNow's day: quiet until spring, then
// busier, lighter at weekends, with a few days off and one huge day.
func usageYear() daemon.UsageSummary {
	var days []daemon.UsageDay
	var lifetime, calls, active int64
	seed := uint32(7)
	end := time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)
	for back := usageProfileDays - 1; back >= 0; back-- {
		start := end.AddDate(0, 0, -back)
		seed = seed*1664525 + 1013904223
		var t daemon.UsageTotals
		if back < 220 && seed%9 != 0 {
			scale := int64(220-back) * 40_000
			if wd := start.Weekday(); wd == time.Saturday || wd == time.Sunday {
				scale /= 4
			}
			in := scale * int64(1+seed%37)
			if back == 9 {
				in *= 12
			}
			t = usageTotals(int64(20+seed%90), 0, in, in*4/5, 0, in/40, in/200)
			lifetime += usageSize(t)
			calls += t.Calls
			active++
		}
		days = append(days, daemon.UsageDay{Start: start, UsageTotals: t})
	}
	return daemon.UsageSummary{
		GeneratedAt: usageNow,
		Days:        days,
		Lines: []daemon.UsageLine{
			{Profile: "work", Provider: "claude", Model: "example-opus", UsageTotals: usageTotals(900, 0, lifetime*3/5, 0, 0, 0, 0)},
			{Profile: "home", Provider: "claude", Model: "example-opus", UsageTotals: usageTotals(100, 0, lifetime/10, 0, 0, 0, 0)},
			{Profile: "codex", Provider: "responses:https://chatgpt.com/backend-api", Model: "example-large", UsageTotals: usageTotals(400, 0, lifetime/5, 0, 0, 0, 0)},
			{Profile: "go", Provider: "chat_completions:https://opencode.ai/zen/go/v1", Model: "example-flash-with-a-long-name", UsageTotals: usageTotals(300, 0, lifetime/10, 0, 0, 0, 0)},
		},
		Profile: &daemon.UsageProfile{
			LifetimeTokens: lifetime + 400_000_000, LifetimeCalls: calls, ActiveDays: active,
			FirstDay: end.AddDate(0, 0, -219), PeakDay: end.AddDate(0, 0, -9), PeakDayTokens: 469_200_000,
			LongestStreakDays: 37, CurrentStreakDays: 9, LongestTurn: 93*time.Minute + 12*time.Second,
		},
	}
}

func usageProfileModel(width, height int, year daemon.UsageSummary, keys ...string) UsageModel {
	m := NewUsageModel(nil)
	m.SetSize(width, height)
	m, _ = m.Update(usageLoadedMsg{Gen: m.Generation, Today: usageToday(), Week: usageWeek()})
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	if cmd == nil || !m.profile.loading {
		panic("opening the profile did not read the year")
	}
	m, _ = m.Update(usageYearMsg{Gen: m.Generation, Year: year})
	for _, key := range keys {
		m, _ = m.Update(tea.KeyPressMsg{Code: []rune(key)[0], Text: key})
	}
	return m
}

func init() {
	registerShots("usage-profile",
		shotState{"daily", func(w, h int) string { return usageProfileModel(w, h, usageYear()).View() }},
		shotState{"weekly", func(w, h int) string { return usageProfileModel(w, h, usageYear(), "w", "h", "h").View() }},
		shotState{"cumulative", func(w, h int) string { return usageProfileModel(w, h, usageYear(), "c").View() }},
		shotState{"new", func(w, h int) string {
			year := usageYear()
			for i := range year.Days {
				year.Days[i].UsageTotals = daemon.UsageTotals{}
			}
			year.Lines, year.Profile = nil, &daemon.UsageProfile{}
			return usageProfileModel(w, h, year).View()
		}},
	)
}

func TestUsageProfileTabDrawsStatsCalendarAndPanels(t *testing.T) {
	for _, size := range shotSizes {
		view := usageProfileModel(size.width, size.height, usageYear()).View()
		plain := ansi.Strip(view)
		lines := strings.Split(plain, "\n")
		if len(lines) > size.height {
			t.Fatalf("%s: %d rows in %d", size.name, len(lines), size.height)
		}
		for _, line := range lines {
			if w := ansi.StringWidth(line); w > size.width {
				t.Fatalf("%s: row of %d cells: %q", size.name, w, line)
			}
		}
		for _, want := range []string{"profile", "Token activity", usageSquare, "Mon", "less"} {
			if !strings.Contains(plain, want) {
				t.Fatalf("%s: no %q in\n%s", size.name, want, plain)
			}
		}
		// No boxes, rounded or square, and no dots standing in for empty days.
		for _, banned := range []string{"╭", "╮", "╰", "╯", "┌", "└", "·  ·", "· ·"} {
			if strings.Contains(plain, banned) {
				t.Fatalf("%s: drew %q in\n%s", size.name, banned, plain)
			}
		}
	}
	wide := ansi.Strip(usageProfileModel(120, 30, usageYear()).View())
	for _, want := range []string{"lifetime tokens", "1h 33m", "37 days", "9 days", "Models", "Weekdays", "example-opus"} {
		if !strings.Contains(wide, want) {
			t.Fatalf("wide profile lacks %q:\n%s", want, wide)
		}
	}
}

func TestUsageProfileCursorWalksTheCalendar(t *testing.T) {
	m := usageProfileModel(120, 30, usageYear())
	if m.profile.back != 0 {
		t.Fatalf("cursor starts %d days back", m.profile.back)
	}
	m = usageProfileModel(120, 30, usageYear(), "h", "h", "k", "j", "j")
	if m.profile.back != 13 {
		t.Fatalf("two weeks back, up, down twice: %d", m.profile.back)
	}
	// The future and the past beyond the calendar clamp.
	m = usageProfileModel(120, 30, usageYear(), "l", "j")
	if m.profile.back != 0 {
		t.Fatalf("past today: %d", m.profile.back)
	}
	m = usageProfileModel(80, 24, usageYear(), "g")
	cal, _ := newUsageCalendar(m.profile.year, usageInner(80))
	if m.profile.back != cal.maxBack() || cal.weeks >= 53 {
		t.Fatalf("oldest at 80 columns: back %d of %d, %d weeks", m.profile.back, cal.maxBack(), cal.weeks)
	}
	// Today, 25 Oct 2026, is a Sunday: the bottom row of the last column.
	if row := cal.lead; row != 6 {
		t.Fatalf("Sunday's row %d", row)
	}
	detail := ansi.Strip(usageProfileModel(120, 30, usageYear(), "k").View())
	if !strings.Contains(detail, "Sat 24 Oct") {
		t.Fatalf("cursor a day back is not Saturday:\n%s", detail)
	}
}

func TestUsageProfileModes(t *testing.T) {
	year := usageYear()
	m := usageProfileModel(120, 30, year, "c")
	cal, _ := newUsageCalendar(year, usageInner(120))
	sizes := m.profile.columnSizes(cal)
	if last := sizes[len(sizes)-1]; last != year.Profile.LifetimeTokens {
		t.Fatalf("cumulative ends at %d, lifetime %d", last, year.Profile.LifetimeTokens)
	}
	for i := 1; i < len(sizes); i++ {
		if sizes[i] < sizes[i-1] {
			t.Fatalf("cumulative falls at week %d", i)
		}
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "through Sun 25 Oct") || !strings.Contains(view, "█") {
		t.Fatalf("cumulative view:\n%s", view)
	}
	weekly := ansi.Strip(usageProfileModel(120, 30, year, "w").View())
	if !strings.Contains(weekly, "week of Mon 19 Oct") {
		t.Fatalf("weekly view:\n%s", weekly)
	}
	// Tab goes back to the days list.
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	if m.tab != usageDaysTab || !strings.Contains(ansi.Strip(m.View()), "by day") {
		t.Fatalf("tab did not return to the days")
	}
}

func TestUsageLevelsAreQuartilesOfUsedDays(t *testing.T) {
	level := usageLevels([]int64{0, 1, 2, 3, 4, 5, 6, 7, 8, 1_000_000})
	got := []int{level(0), level(1), level(4), level(6), level(8), level(1_000_000)}
	want := []int{0, 1, 2, 3, 4, 4}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("levels %v, want %v", got, want)
		}
	}
}

func TestUsageDuration(t *testing.T) {
	for d, want := range map[time.Duration]string{
		93*time.Minute + 12*time.Second: "1h 33m",
		11*time.Minute + 26*time.Second: "11m 26s",
		42 * time.Second:                "42s",
	} {
		if got := usageDuration(d); got != want {
			t.Fatalf("%v: %q, want %q", d, got, want)
		}
	}
}

// A day's tokens are the daemon's own sum of what the providers reported, so
// a model or a weekday can carry a count that is not one: a negative count, or
// one large enough that multiplying it by the bar's width overflows. The
// profile's bar is a share of the busiest row, and drawing such a count
// repeated a negative or an absurd number of cells: the screen panicked on the
// repeat, or asked for terabytes of them.
func TestUsageProfileBarOnACountThatIsNotOne(t *testing.T) {
	monday := time.Date(2026, 11, 16, 0, 0, 0, 0, time.UTC)
	days := make([]daemon.UsageDay, 0, 7)
	for i := range 7 {
		totals := daemon.UsageTotals{}
		switch i {
		case 0:
			totals = daemon.UsageTotals{Calls: 1, InputTokens: 10}
		case 1:
			totals = daemon.UsageTotals{Calls: 1, InputTokens: -100}
		}
		days = append(days, daemon.UsageDay{Start: monday.AddDate(0, 0, i), UsageTotals: totals})
	}
	year := daemon.UsageSummary{
		GeneratedAt: monday.AddDate(0, 0, 6),
		Days:        days,
		Lines: []daemon.UsageLine{
			{Model: "spent", Profile: "work", UsageTotals: daemon.UsageTotals{Calls: 1, InputTokens: 10}},
			{Model: "refunded", Profile: "work", UsageTotals: daemon.UsageTotals{Calls: 1, InputTokens: -100}},
		},
	}
	p := usageProfile{year: year}
	for _, line := range p.profileLines(120, 40) {
		plain := ansi.Strip(line)
		if got := ansi.StringWidth(plain); got > 120 {
			t.Fatalf("row of %d cells: %q", got, plain)
		}
		// The count with no share of the busiest row draws no bar, and the
		// busiest one still does.
		switch {
		case strings.HasPrefix(plain, "Tue "):
			if strings.Contains(plain, "━") {
				t.Fatalf("a negative weekday drew a bar: %q", plain)
			}
		case strings.HasPrefix(plain, "Mon "):
			if !strings.Contains(plain, "━") {
				t.Fatalf("the busiest weekday drew no bar: %q", plain)
			}
		case strings.Contains(plain, "refunded "):
			if strings.Contains(plain, "━") {
				t.Fatalf("a negative model drew a bar: %q", plain)
			}
		case strings.Contains(plain, "spent "):
			if !strings.Contains(plain, "━") {
				t.Fatalf("the busiest model drew no bar: %q", plain)
			}
		}
	}
}

// A profile with active days but no tokens has no peak day: every call of it
// failed without usage, so the daemon reports a null peak. The facts line must
// not print the zero stamp as a date in year 1.
func TestUsageProfileFactsSkipAnUnknownPeak(t *testing.T) {
	prof := daemon.UsageProfile{
		LifetimeCalls: 1,
		ActiveDays:    1,
		FirstDay:      time.Date(2026, 11, 20, 0, 0, 0, 0, time.UTC),
	}
	got := usageProfileFacts(prof, time.UTC)
	if strings.Contains(got, "peak") || strings.Contains(got, "1 Jan") {
		t.Fatalf("an unknown peak drawn as %q", got)
	}
	if want := "1 call · 1 active day · since 20 Nov 2026"; got != want {
		t.Fatalf("facts %q, want %q", got, want)
	}
	// A known peak keeps its place at the end.
	prof.PeakDay = time.Date(2026, 11, 18, 0, 0, 0, 0, time.UTC)
	if got, want := usageProfileFacts(prof, time.UTC), " · peak Wed 18 Nov"; !strings.HasSuffix(got, want) {
		t.Fatalf("facts %q, want the peak %q", got, want)
	}
}

// A month that begins in the newest week keeps its whole name at the end of
// the calendar instead of losing its last letter past the grid.
func TestUsageMonthsKeepWholeNamesAtTheEnd(t *testing.T) {
	end := time.Date(2024, 3, 3, 0, 0, 0, 0, time.UTC)
	var days []daemon.UsageDay
	for back := usageProfileDays - 1; back >= 0; back-- {
		days = append(days, daemon.UsageDay{Start: end.AddDate(0, 0, -back)})
	}
	cal, _ := newUsageCalendar(daemon.UsageSummary{Days: days}, 120)
	months := ansi.Strip(usageMonths(cal))
	names := strings.Fields(months)
	if len(names) == 0 || names[len(names)-1] != "Mar" {
		t.Fatalf("newest label: %q", months)
	}
	for _, name := range names {
		if len(name) != 3 {
			t.Fatalf("cut label %q in %q", name, months)
		}
	}
	if width := ansi.StringWidth(months); width > usageGutter+cal.weeks*usageCellW {
		t.Fatalf("labels run %d cells past a %d-cell grid", width, usageGutter+cal.weeks*usageCellW)
	}
}
