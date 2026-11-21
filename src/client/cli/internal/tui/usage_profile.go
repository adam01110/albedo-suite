package tui

import (
	"context"
	"errors"
	"fmt"
	"math"
	"slices"
	"strings"
	"time"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// usageProfileDays is the profile's calendar: a year of whole weeks, the most
// GET /usage answers.
const usageProfileDays = 371

// usageTab is which of the screen's two views is up.
type usageTab int

const (
	usageDaysTab usageTab = iota
	usageProfileTab
)

// usageMode is what the calendar measures: each day, each week, or the running
// total through each week.
type usageMode int

const (
	usageDaily usageMode = iota
	usageWeekly
	usageCumulative
)

var usageModeNames = [...]string{"daily", "weekly", "cumulative"}

// usageProfile is the profile tab: the year's answer, the calendar's mode, and
// the cursor as days before today, so a resize keeps it on the same day.
type usageProfile struct {
	year            daemon.UsageSummary
	loaded, loading bool
	mode            usageMode
	back            int
}

// usageCalendar lays the year out as GitHub does: a column per week, Monday at
// the top, the current week last.
type usageCalendar struct {
	days  []daemon.UsageDay // oldest first, today last
	weeks int
	lead  int // today's row, Monday being 0
	zone  *time.Location
}

const (
	usageGutter = 4 // "Mon " before the first column
	usageCellW  = 2 // a square and the gap after it
)

func newUsageCalendar(year daemon.UsageSummary, width int) (usageCalendar, bool) {
	n := len(year.Days)
	if n == 0 {
		return usageCalendar{}, false
	}
	zone := time.FixedZone("local", year.UTCOffsetMinutes*60)
	today := year.Days[n-1].Start.In(zone)
	lead := (int(today.Weekday()) + 6) % 7
	weeks := min((width-usageGutter)/usageCellW, (n-1-lead)/7+1)
	return usageCalendar{days: year.Days, weeks: max(1, weeks), lead: lead, zone: zone}, true
}

// back is how many days before today a cell is.
func (c usageCalendar) back(col, row int) int { return (c.weeks-1-col)*7 + c.lead - row }

// day is the cell's day, false for a cell after today or before the answer.
func (c usageCalendar) day(col, row int) (daemon.UsageDay, bool) {
	back := c.back(col, row)
	i := len(c.days) - 1 - back
	if back < 0 || i < 0 {
		return daemon.UsageDay{}, false
	}
	return c.days[i], true
}

// maxBack is the oldest day the calendar draws.
func (c usageCalendar) maxBack() int { return min(c.back(0, 0), len(c.days)-1) }

// week is a column's tokens and calls, and the Monday it begins on.
func (c usageCalendar) week(col int) (tokens, calls int64, monday time.Time) {
	monday = c.days[len(c.days)-1].Start.In(c.zone).AddDate(0, 0, -c.back(col, 0))
	for row := range 7 {
		if day, ok := c.day(col, row); ok {
			tokens += usageSize(day.UsageTotals)
			calls += day.Calls
		}
	}
	return tokens, calls, monday
}

// key moves the cursor or switches the mode; width is the terminal's, which
// decides how many weeks the calendar has.
func (p usageProfile) key(key string, width int) usageProfile {
	switch key {
	case "d":
		p.mode = usageDaily
	case "w":
		p.mode = usageWeekly
	case "c":
		p.mode = usageCumulative
	case "h", "left":
		p.back += 7
	case "l", "right":
		p.back -= 7
	case "k", "up":
		p.back++
	case "j", "down":
		p.back--
	case "g", "home":
		p.back = 1 << 30
	case "G", "end":
		p.back = 0
	}
	cal, ok := newUsageCalendar(p.year, usageInner(width))
	if !ok {
		p.back = 0
		return p
	}
	p.back = min(max(0, p.back), cal.maxBack())
	return p
}

// usageInner is the width the profile draws in, inside the frame's edge.
func usageInner(width int) int { return max(1, width-2) }

// usageHeat is a calendar level's ink: Decor for a day without use, then four
// steps mixed from Decor toward the brand.
func usageHeat(level int) lipgloss.Style {
	from, to := parseHex(transcriptInk.decor), parseHex(transcriptInk.brandFrom)
	if from == nil || to == nil {
		switch level {
		case 0:
			return DefaultStyles.Decor
		case 1:
			return DefaultStyles.Agent.Faint(true)
		case 4:
			return DefaultStyles.Agent.Bold(true)
		}
		return DefaultStyles.Agent
	}
	if level == 0 {
		// An empty day steps back from Decor toward the background, so a
		// mostly idle year reads as quiet, not as a grid of noise.
		if bg := parseHex(transcriptInk.bg); bg != nil {
			return lipgloss.NewStyle().Foreground(lipgloss.Color(bg.mix(*from, 0.55).hex()))
		}
		return DefaultStyles.Decor
	}
	t := 0.3 + 0.7*float64(level-1)/3
	return lipgloss.NewStyle().Foreground(lipgloss.Color(from.mix(*to, t).hex()))
}

// usageLevels are the quartiles of the days with use, as GitHub grades its
// calendar, so one huge day does not wash every other day out.
func usageLevels(values []int64) func(int64) int {
	var used []int64
	for _, v := range values {
		if v > 0 {
			used = append(used, v)
		}
	}
	slices.Sort(used)
	if len(used) == 0 {
		return func(int64) int { return 0 }
	}
	q := [3]int64{used[len(used)/4], used[len(used)/2], used[len(used)*3/4]}
	return func(v int64) int {
		if v <= 0 {
			return 0
		}
		level := 1
		for _, edge := range q {
			if v > edge {
				level++
			}
		}
		return level
	}
}

var usageEighths = []rune(" ▁▂▃▄▅▆▇█")

// usageSquare is a calendar day: Nerd Font's rounded square, nf-md-square_rounded.
const usageSquare = "\U000F14FB"

// profileLines is the tab's body in at most height rows of width cells.
func (p usageProfile) profileLines(width, height int) []string {
	w := usageInner(width)
	cal, ok := newUsageCalendar(p.year, w)
	if !ok {
		return nil
	}
	p.back = min(p.back, cal.maxBack())
	var out []string
	if prof := p.year.Profile; prof != nil {
		out = append(out, usageStatStrip(*prof, w)...)
		out = append(out, "", DefaultStyles.Faint.Render(ansi.Truncate(usageProfileFacts(*prof, cal.zone), w, "…")), "")
	}
	out = append(out, usageHeading("Token activity", p.modeTabs(), w))
	out = append(out, p.grid(cal)...)
	out = append(out, usageMonths(cal), p.detailLine(cal, w))
	if room := height - len(out) - 2; room >= 3 {
		out = append(out, "")
		out = append(out, p.panels(cal, w, min(7, room-1))...)
	}
	return inset(out[:min(len(out), height)])
}

// usageStatStrip is the five headline numbers as a borderless row: each value
// bold over its faint label, centred in an equal share of the width, or one
// line of them where the labels would not fit.
func usageStatStrip(prof daemon.UsageProfile, w int) []string {
	turn := "–"
	if prof.LongestTurn > 0 {
		turn = usageDuration(prof.LongestTurn)
	}
	stats := []struct{ value, label, short string }{
		{usageUnits(prof.LifetimeTokens), "lifetime tokens", "lifetime"},
		{usageUnits(prof.PeakDayTokens), "peak day", "peak day"},
		{turn, "longest turn", "longest turn"},
		{usageDaysText(prof.LongestStreakDays), "longest streak", "best streak"},
		{usageDaysText(prof.CurrentStreakDays), "current streak", "streak"},
	}
	cell := w / len(stats)
	if cell < 12 {
		parts := make([]string, len(stats))
		for i, s := range stats {
			parts[i] = DefaultStyles.Bold.Render(s.value) + " " + DefaultStyles.Faint.Render(s.short)
		}
		return []string{ansi.Truncate(strings.Join(parts, DefaultStyles.Decor.Render(" · ")), w, "…")}
	}
	center := func(s string) string {
		s = ansi.Truncate(s, cell, "…")
		pad := cell - ansi.StringWidth(s)
		return strings.Repeat(" ", pad/2) + s + strings.Repeat(" ", pad-pad/2)
	}
	var values, labels strings.Builder
	for _, s := range stats {
		label := s.label
		if len(label) > cell-2 {
			label = s.short
		}
		values.WriteString(DefaultStyles.Bold.Render(center(s.value)))
		labels.WriteString(DefaultStyles.Faint.Render(center(label)))
	}
	return []string{values.String(), labels.String()}
}

// usageProfileFacts is the line under the strip: what the numbers rest on.
func usageProfileFacts(prof daemon.UsageProfile, zone *time.Location) string {
	if prof.ActiveDays == 0 {
		return "nothing used yet"
	}
	parts := []string{
		countedText(prof.LifetimeCalls, "call"),
		countedText(prof.ActiveDays, "active day"),
		"since " + prof.FirstDay.In(zone).Format("2 Jan 2006"),
	}
	// A day whose calls all failed without usage has no peak to name, and its
	// zero stamp would read as a date in year 1.
	if !prof.PeakDay.IsZero() {
		parts = append(parts, "peak "+prof.PeakDay.In(zone).Format("Mon 2 Jan"))
	}
	return strings.Join(parts, " · ")
}

func usageDaysText(n int64) string { return countedText(n, "day") }

// usageDuration is a turn's length in its two largest units: "1h 33m", "11m 26s".
func usageDuration(d time.Duration) string {
	d = d.Round(time.Second)
	h, m, s := int(d/time.Hour), int(d/time.Minute)%60, int(d/time.Second)%60
	switch {
	case h > 0:
		return fmt.Sprintf("%dh %02dm", h, m)
	case m > 0:
		return fmt.Sprintf("%dm %02ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}

// usageHeading heads a block the way a list's section rule does, with right at
// its end.
func usageHeading(label, right string, w int) string {
	head := DefaultStyles.Muted.Bold(true).Render(label)
	n := w - ansi.StringWidth(label) - ansi.StringWidth(right) - 2
	if n < 1 {
		return ansi.Truncate(head+" "+right, w, "…")
	}
	return head + " " + DefaultStyles.Decor.Render(strings.Repeat("─", n)) + " " + right
}

// modeTabs names the modes, the current one in bold.
func (p usageProfile) modeTabs() string {
	parts := make([]string, len(usageModeNames))
	for i, name := range usageModeNames {
		if usageMode(i) == p.mode {
			parts[i] = DefaultStyles.Bold.Render(name)
		} else {
			parts[i] = DefaultStyles.Faint.Render(name)
		}
	}
	return strings.Join(parts, "  ")
}

var usageWeekdays = [7]string{"Mon", "", "Wed", "", "Fri", "", "Sun"}

// grid is the calendar's seven rows: squares graded by day in daily mode, and
// a column of eighth blocks per week in the other two.
func (p usageProfile) grid(cal usageCalendar) []string {
	rows := make([]strings.Builder, 7)
	for row := range 7 {
		label := ""
		if p.mode == usageDaily {
			label = usageWeekdays[row]
		}
		rows[row].WriteString(DefaultStyles.Faint.Render(fmt.Sprintf("%-*s", usageGutter, label)))
	}
	cursorCol := cal.weeks - 1 - (p.back-cal.lead+6)/7
	if p.mode == usageDaily {
		values := make([]int64, 0, cal.weeks*7)
		for col := range cal.weeks {
			for row := range 7 {
				if day, ok := cal.day(col, row); ok {
					values = append(values, usageSize(day.UsageTotals))
				}
			}
		}
		level := usageLevels(values)
		for col := range cal.weeks {
			for row := range 7 {
				day, ok := cal.day(col, row)
				switch {
				case !ok:
					rows[row].WriteString("  ")
				case cal.back(col, row) == p.back:
					// The cursor keeps its level on the selection surface.
					rows[row].WriteString(usageHeat(max(1, level(usageSize(day.UsageTotals)))).Inherit(DefaultStyles.Selected).Render(usageSquare) + " ")
				default:
					rows[row].WriteString(usageHeat(level(usageSize(day.UsageTotals))).Render(usageSquare) + " ")
				}
			}
		}
	} else {
		heights := p.columnSizes(cal)
		top := slices.Max(heights)
		for col := range cal.weeks {
			eighths := 0
			if top > 0 && heights[col] > 0 {
				eighths = max(1, int(heights[col]*56/top))
			}
			for row := range 7 {
				fill := min(8, max(0, eighths-(6-row)*8))
				style := usageHeat(3)
				if col == cursorCol {
					style = usageHeat(4).Inherit(DefaultStyles.Selected)
				}
				glyph := string(usageEighths[fill])
				if fill == 0 {
					style = usageHeat(0)
					if col == cursorCol {
						style = style.Inherit(DefaultStyles.Selected)
					}
				}
				rows[row].WriteString(style.Render(glyph) + " ")
			}
		}
	}
	out := make([]string, 7)
	for i := range rows {
		out[i] = rows[i].String()
	}
	return out
}

// columnSizes are what each week's column measures: its total, or in
// cumulative mode everything used through its end, so the last column is the
// lifetime total.
func (p usageProfile) columnSizes(cal usageCalendar) []int64 {
	sizes := make([]int64, cal.weeks)
	var drawn int64
	for col := range cal.weeks {
		sizes[col], _, _ = cal.week(col)
		drawn += sizes[col]
	}
	if p.mode != usageCumulative {
		return sizes
	}
	run := int64(0)
	if prof := p.year.Profile; prof != nil {
		run = max(0, prof.LifetimeTokens-drawn)
	}
	for col := range sizes {
		run += sizes[col]
		sizes[col] = run
	}
	return sizes
}

// usageMonths labels the columns a month begins in, under the calendar. A
// month cut to a column or two at the calendar's start gives way to the next.
func usageMonths(cal usageCalendar) string {
	type label struct {
		at   int
		name string
	}
	var labels []label
	last := time.Month(0)
	end := usageGutter + cal.weeks*usageCellW
	for col := range cal.weeks {
		_, _, monday := cal.week(col)
		if month := monday.AddDate(0, 0, 6).Month(); month != last {
			// A month in the newest column ends its name at the grid's edge.
			labels = append(labels, label{min(usageGutter+col*usageCellW, end-3), month.String()[:3]})
			last = month
		}
	}
	line := []rune(strings.Repeat(" ", end))
	for i, l := range labels {
		if i+1 < len(labels) && labels[i+1].at-l.at < 5 {
			continue
		}
		copy(line[l.at:], []rune(l.name))
	}
	return DefaultStyles.Faint.Render(strings.TrimRight(string(line), " "))
}

// detailLine is what the cursor is on, with the calendar's legend at its end.
func (p usageProfile) detailLine(cal usageCalendar, w int) string {
	day := cal.days[len(cal.days)-1-p.back]
	start := day.Start.In(cal.zone)
	var text, legend string
	switch p.mode {
	case usageDaily:
		text = start.Format("Mon 2 Jan")
		if day.Calls == 0 {
			text += " · nothing used"
		} else {
			text += " · " + usageUnits(usageSize(day.UsageTotals)) + " tokens · " + countedText(day.Calls, "call")
		}
		squares := make([]string, 5)
		for level := range squares {
			squares[level] = usageHeat(level).Render(usageSquare)
		}
		legend = DefaultStyles.Faint.Render("less ") + strings.Join(squares, " ") + DefaultStyles.Faint.Render(" more")
	default:
		col := cal.weeks - 1 - (p.back-cal.lead+6)/7
		tokens, calls, monday := cal.week(col)
		if p.mode == usageWeekly {
			text = "week of " + monday.Format("Mon 2 Jan") + " · " + usageUnits(tokens) + " tokens · " + countedText(calls, "call")
			legend = DefaultStyles.Faint.Render("busiest week " + usageUnits(slices.Max(p.columnSizes(cal))))
		} else {
			sizes := p.columnSizes(cal)
			text = "through " + monday.AddDate(0, 0, 6).Format("Sun 2 Jan") + " · " + usageUnits(sizes[col]) + " of " + usageUnits(sizes[len(sizes)-1])
		}
	}
	text = DefaultStyles.Muted.Render(text)
	gap := w - ansi.StringWidth(text) - ansi.StringWidth(legend)
	if legend == "" || gap < 2 {
		return ansi.Truncate(text, w, "…")
	}
	return text + strings.Repeat(" ", gap) + legend
}

// usageHBar is n of top as a thin bar of w cells.
func usageHBar(n, top int64, w int) string {
	if top <= 0 || w <= 0 || n <= 0 {
		return strings.Repeat(" ", max(0, w))
	}
	// The share is taken in floats and kept inside the row: a count that is
	// not one, or one large enough that n*w overflows, would otherwise repeat
	// a negative or an absurd number of cells.
	cells := min(w, max(1, int(math.Round(float64(n)/float64(top)*float64(w)))))
	return strings.Repeat("━", cells) + strings.Repeat(" ", w-cells)
}

// usageModelTotal is one model's tokens across every profile and account.
type usageModelTotal struct {
	model  string
	tokens int64
}

// panels are the year's busiest models beside its weekdays, or the models
// alone where the two do not fit side by side.
func (p usageProfile) panels(cal usageCalendar, w, rows int) []string {
	byModel := map[string]int64{}
	var models []usageModelTotal
	for _, line := range p.year.Lines {
		if _, seen := byModel[line.Model]; !seen {
			models = append(models, usageModelTotal{model: line.Model})
		}
		byModel[line.Model] += usageSize(line.UsageTotals)
	}
	var all int64
	for i := range models {
		models[i].tokens = byModel[models[i].model]
		all += models[i].tokens
	}
	slices.SortStableFunc(models, func(a, b usageModelTotal) int {
		switch {
		case a.tokens > b.tokens:
			return -1
		case a.tokens < b.tokens:
			return 1
		}
		return strings.Compare(a.model, b.model)
	})
	models = models[:min(len(models), rows)]

	var weekdays [7]int64
	for _, day := range cal.days {
		weekdays[(int(day.Start.In(cal.zone).Weekday())+6)%7] += usageSize(day.UsageTotals)
	}

	sideBySide := w >= 96
	left := w
	if sideBySide {
		left = w * 3 / 5
	}
	block := []string{usageHeading("Models", DefaultStyles.Faint.Render("past year"), left)}
	nameW := min(28, max(10, left/3))
	barW := max(4, left-nameW-14)
	top := int64(0)
	if len(models) > 0 {
		top = models[0].tokens
	}
	for i, mt := range models {
		ink := usageHeat(2)
		if i == 0 {
			ink = usageHeat(4)
		}
		share := 0
		if all > 0 {
			share = int(mt.tokens * 100 / all)
		}
		block = append(block, svCell(mt.model, nameW, false)+" "+ink.Render(usageHBar(mt.tokens, top, barW))+" "+
			DefaultStyles.Muted.Render(fmt.Sprintf("%6s %3d%%", usageUnits(mt.tokens), share)))
	}
	if len(models) == 0 {
		block = append(block, DefaultStyles.Faint.Render("no models used this year"))
	}
	if !sideBySide {
		return block
	}
	right := w - left - 3
	week := []string{usageHeading("Weekdays", DefaultStyles.Faint.Render("past year"), right)}
	busiest := slices.Max(weekdays[:])
	names := [7]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
	for i := range min(7, rows) {
		ink := usageHeat(2)
		if weekdays[i] == busiest && busiest > 0 {
			ink = usageHeat(4)
		}
		week = append(week, DefaultStyles.Faint.Render(names[i])+" "+ink.Render(usageHBar(weekdays[i], busiest, max(4, right-12)))+" "+
			DefaultStyles.Muted.Render(fmt.Sprintf("%6s", usageUnits(weekdays[i]))))
	}
	out := make([]string, max(len(block), len(week)))
	for i := range out {
		var l, r string
		if i < len(block) {
			l = block[i]
		}
		if i < len(week) {
			r = week[i]
		}
		out[i] = l + strings.Repeat(" ", max(0, left-ansi.StringWidth(l))) + "   " + r
	}
	return out
}

// tabsText names the screen's two views, the current one in bold.
func (m UsageModel) tabsText() string {
	names := []string{"days", "profile"}
	for i, name := range names {
		if usageTab(i) == m.tab {
			names[i] = DefaultStyles.Bold.Render(name)
		} else {
			names[i] = DefaultStyles.Faint.Render(name)
		}
	}
	return strings.Join(names, DefaultStyles.Decor.Render(" · "))
}

// profileView is the profile tab in the frame every list screen shares.
func (m UsageModel) profileView(title string) string {
	width := max(1, m.Width)
	hints := []hint{{"tab", "days"}, {"hjkl", "move"}, {"d/w/c", "view"}, {"ctrl+r", "refresh"}, {"esc", "back"}}
	status, urgent := "", false
	switch {
	case m.Loading || m.profile.loading:
		status = DefaultStyles.Faint.Render("loading…")
	case m.Error != "":
		status, urgent = DefaultStyles.Error.Render(m.Error), true
	}
	f := listFrame{
		title:  title,
		right:  DefaultStyles.Faint.Render(m.stale()),
		footer: footerLine(width, hints, status, urgent),
		list: func(w, h int) []string {
			if lines := m.profile.profileLines(w, h); len(lines) > 0 {
				return lines
			}
			empty := "Nothing used yet."
			switch {
			case m.Loading || m.profile.loading:
				empty = "loading usage…"
			case m.Error != "":
				empty = "Could not read usage from the daemon."
			}
			return inset([]string{DefaultStyles.Faint.Render(empty)})
		},
	}
	return f.view(m.Width, m.Height)
}

// usageYearMsg is the profile's year, read under the screen's generation.
type usageYearMsg struct {
	Year daemon.UsageSummary
	Err  error
	Gen  int
}

// withYear adds the year's read to cmd when the profile tab is up and has no
// year yet, or always on a refresh, so the days tab never pays for it.
func (m UsageModel) withYear(cmd tea.Cmd, refresh bool) (UsageModel, tea.Cmd) {
	if m.tab != usageProfileTab || (m.profile.loaded && !refresh) || (m.profile.loading && !refresh) {
		return m, cmd
	}
	m.profile.loading = true
	gen, conn := m.Generation, m.Conn
	read := func() tea.Msg {
		if conn == nil {
			return usageYearMsg{Err: errors.New(usageUnreachable), Gen: gen}
		}
		_, seconds := time.Now().Zone()
		year, err := daemon.GetUsage(context.Background(), conn, daemon.UsageQuery{Days: usageProfileDays, UTCOffsetMinutes: seconds / 60})
		if err != nil {
			return usageYearMsg{Err: usageError{err}, Gen: gen}
		}
		return usageYearMsg{Year: year, Gen: gen}
	}
	return m, tea.Batch(cmd, read)
}

// settleYear takes the year's answer; a failed read keeps the year on screen
// and says why in the footer.
func (m UsageModel) settleYear(msg usageYearMsg) UsageModel {
	if msg.Gen != m.Generation {
		return m
	}
	m.profile.loading = false
	if msg.Err != nil {
		m.Error = msg.Err.Error()
		return m
	}
	m.profile.year, m.profile.loaded = msg.Year, true
	return m
}
