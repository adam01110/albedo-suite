package tui

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/presentation"
	"albedo/cli/internal/terminalui"
	"cmp"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"albedo/cli/internal/tui/chrome"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// ── logo ───────────────────────────────────────────────────────────────────

// A four-point sparkle with a small companion star, drawn with half blocks so
// each pixel is roughly square.
var svLogoPixels = []string{
	"........#...............",
	"........#...........#...",
	".......###..........#...",
	".......###........#####.",
	"......#####.........#...",
	".....#######........#...",
	"...###########..........",
	"#################.......",
	"...###########..........",
	".....#######............",
	"......#####.............",
	".......###.........#....",
	".......###..............",
	"........#...............",
	"........#...............",
	"........................",
}

func svLogo() []string {
	rows := len(svLogoPixels) / 2
	width := len(svLogoPixels[0])
	lines := make([]string, rows)
	for r := range rows {
		var b strings.Builder
		for c := range width {
			top := svLogoPixels[2*r][c] == '#'
			bottom := svLogoPixels[2*r+1][c] == '#'
			ch := " "
			switch {
			case top && bottom:
				ch = "█"
			case top:
				ch = "▀"
			case bottom:
				ch = "▄"
			}
			// Diagonal sweep so the gradient reads as light glancing off the mark.
			if ch != " " {
				t := (float64(c)/float64(width) + float64(r)/float64(rows)) / 2
				ch = chrome.BrandInk(t).Render(ch)
			}
			b.WriteString(ch)
		}
		lines[r] = b.String()
	}
	return lines
}

// ── helpers ────────────────────────────────────────────────────────────────

func svCompactAge(ts *int64, now time.Time) string {
	if ts == nil {
		return "—"
	}
	d := now.Sub(time.Unix(*ts, 0))
	switch {
	case d < time.Minute:
		return "now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	case d < 14*24*time.Hour:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	case d < 60*24*time.Hour:
		return fmt.Sprintf("%dw", int(d.Hours()/24/7))
	}
	return fmt.Sprintf("%dmo", int(d.Hours()/24/30))
}

type svColumns struct {
	title, model, workspace, cost, age int
}

func svLayout(width int) svColumns {
	// Row: bar(1) icon(2) space(1) title … model … workspace … cost … age, two-space gaps.
	cols := svColumns{}
	rest := width - 4
	if width >= 32 {
		cols.age = 4
		rest -= cols.age + 2
	}
	if width >= 40 {
		cols.cost = 8
		rest -= cols.cost + 2
	}
	if width >= 48 {
		cols.model = min(20, max(12, width/5))
		rest -= cols.model + 2
	}
	if width >= 90 {
		cols.workspace = min(18, max(10, width/8))
		rest -= cols.workspace + 2
	}
	cols.title = max(1, rest-1)
	return cols
}

// svSep divides the columns.
func svSep() string { return chrome.DefaultStyles.Decor.Render(" │ ") }

// ── view ───────────────────────────────────────────────────────────────────

// Page shows the grouped session list beside its preview when there is room,
// and the list alone on narrow terminals.
func (m *SessionViewer) Page() terminalui.Page {
	m.ensure()
	width := cmp.Or(m.Width, 80)
	now := m.clock()
	filter := chrome.PromptLead() + m.SearchInput.View()
	if chips := m.filterChips(); chips != "" {
		filter += "\n" + chips
	}
	return terminalui.Page{
		Title:       chrome.Located(m.brandName(), sessionText(m.workspacePlace())),
		Meta:        m.totalCost(),
		Filter:      filter,
		List:        func(w, h int) []string { return m.column(w, h, now) },
		Detail:      func(w, h int) []string { return m.preview(w, h, now) },
		DetailWidth: halfPane,
		Footer:      m.footer(width, now),
	}
}

// totalCost is the title rule's right end: what every stored session cost,
// marked as a lower bound when some sessions could not be priced.
func (m SessionViewer) totalCost() string {
	if m.TotalCost == nil {
		return ""
	}
	cost, known := estimatedCost(&m.TotalCost.USD, false)
	if !known {
		return ""
	}
	if m.TotalCost.Partial {
		cost = "≥" + cost
	}
	return chrome.DefaultStyles.Faint.Render("total ") + chrome.DefaultStyles.Muted.Render(cost)
}

// filterChips is the active listing filter below the search line.
func (m *SessionViewer) filterChips() string {
	if m.ArchiveView || len(m.Filter) == 0 {
		return ""
	}
	chips := make([]string, len(m.Filter))
	for i, chip := range m.Filter {
		chips[i] = chrome.Chip(chip.Token, chip.Typed)
	}
	return " " + strings.Join(chips, " ")
}

// filterOverlay composites the filter menu or typeahead over the rendered page.
func (m *SessionViewer) filterOverlay(base string) string {
	if m.ArchiveView {
		return base
	}
	if m.filterMenu {
		return m.floatPopup(base, daemon.SessionFilterOptions(), 0, true)
	}
	if start, _, items := m.suggestions(); len(items) > 0 {
		return m.floatPopup(base, items, start, false)
	}
	return base
}

func (m *SessionViewer) floatPopup(base string, items []daemon.FilterSuggestion, start int, menu bool) string {
	width, height := cmp.Or(m.Width, 80), cmp.Or(m.Height, 24)
	y := 2
	if height >= 12 {
		y++
	}
	if len(m.Filter) > 0 {
		y++
	}
	if len(items) == 0 || width < 18 || height-y < 3 {
		return base
	}
	maxTok, maxDesc := 0, 0
	for _, item := range items {
		maxTok = max(maxTok, ansi.StringWidth(item.Token))
		maxDesc = max(maxDesc, ansi.StringWidth(item.Description))
	}
	capacity := min(len(items), height-y-2)
	selected := max(0, min(m.suggestIdx, len(items)-1))
	first := min(max(0, selected-capacity/2), len(items)-capacity)
	visible := items[first : first+capacity]
	selected -= first
	hintText := "tab"
	if menu {
		hintText = "space"
	}
	inner := min(width-4, maxTok+2+maxDesc+len(hintText)+6)
	rows := make([]string, len(visible))
	for i, item := range visible {
		token := item.Token
		if menu && slices.ContainsFunc(m.Filter, func(chip daemon.FilterChip) bool {
			return chip.Token == item.Token
		}) {
			token = chrome.DefaultStyles.Prompt.Bold(true).Render(item.Token)
		}
		pad := strings.Repeat(" ", maxTok-ansi.StringWidth(item.Token)+2)
		row := token + pad + chrome.DefaultStyles.Faint.Render(item.Description)
		if i == selected {
			hint := ""
			maxLabel := max(1, inner-4)
			if inner >= 22 {
				hint = chrome.DefaultStyles.Faint.Render(hintText) + " "
				maxLabel = max(1, inner-4-ansi.StringWidth(hint))
			}
			label := ansi.Truncate(row, maxLabel, "…")
			gap := strings.Repeat(" ", max(1, inner-2-ansi.StringWidth(label)-ansi.StringWidth(hint)))
			rows[i] = chrome.SelectedLine(chrome.SelectBar()+" "+label+gap+hint, inner)
		} else {
			text := "  " + ansi.Truncate(row, max(1, inner-4), "…")
			if padRight := inner - ansi.StringWidth(text); padRight > 0 {
				text += strings.Repeat(" ", padRight)
			}
			rows[i] = text
		}
	}
	popup := chrome.PopoverStyle().Render(strings.Join(rows, "\n"))
	xOff := 0
	if runes := []rune(m.SearchInput.Value()); start > 0 && start <= len(runes) {
		xOff = ansi.StringWidth(string(runes[:start]))
	}
	margin := 1
	if width >= terminalui.SideWidth {
		margin = 2
	}
	x := max(1, min(margin+ansi.StringWidth(chrome.PromptLead())+xOff, width-lipgloss.Width(popup)-1))
	return lipgloss.NewCompositor(
		lipgloss.NewLayer(base),
		lipgloss.NewLayer(popup).X(x).Y(y).Z(1),
	).Render()
}

// brandName is the title's brand: the archive says so.
func (m SessionViewer) brandName() string {
	if m.ArchiveView {
		return "albedo  archive"
	}
	return "albedo"
}

// footer is the keys and the status, or the question while one is asked.
func (m SessionViewer) footer(width int, now time.Time) string {
	if m.confirm.Asking() {
		return m.confirm.Footer(width, "")
	}
	status, urgent := m.counts(now), false
	switch {
	case m.notice != "":
		status, urgent = chrome.DefaultStyles.Error.Render(m.notice), true
	case m.Loading:
		status = chrome.DefaultStyles.Faint.Render("loading…")
	}
	return chrome.FooterLine(width, m.hints(), status, urgent)
}

// hints are the keys for the list, the archive, or a rename in progress.
func (m SessionViewer) hints() []chrome.Hint {
	switch {
	case m.rename.Active():
		return []chrome.Hint{{Key: "enter", Does: "save"}, {Key: "esc", Does: "cancel"}, {Key: "", Does: "empty restores the automatic title"}}
	case m.ArchiveView:
		if _, ok := m.Highlighted(); !ok {
			return []chrome.Hint{{Key: "esc", Does: "back"}}
		}
		return []chrome.Hint{{Key: "↑↓", Does: "move"}, {Key: "enter", Does: "open"}, {Key: "ctrl+x", Does: "delete"}, {Key: "ctrl+r", Does: "rename"}, {Key: "ctrl+a", Does: "restore"}, {Key: "esc", Does: "back"}}
	}
	esc := "quit"
	if m.HasActive {
		esc = "back"
	}
	if m.filterMenu {
		return []chrome.Hint{{Key: "↑↓", Does: "move"}, {Key: "space", Does: "toggle"}, {Key: "enter", Does: "apply"}, {Key: "esc", Does: "close"}}
	}
	if item, ok := m.Highlighted(); !ok || m.section[item.ID] == secAction {
		return []chrome.Hint{{Key: "↑↓", Does: "move"}, {Key: "tab", Does: "switch"}, {Key: "enter", Does: "open"}, {Key: "ctrl+t", Does: "filters"}, {Key: "ctrl+f", Does: "folders"}, {Key: "@", Does: "hosts"}, {Key: "esc", Does: esc}}
	}
	return []chrome.Hint{{Key: "↑↓", Does: "move"}, {Key: "tab", Does: "switch"}, {Key: "enter", Does: "open"}, {Key: "ctrl+r", Does: "rename"}, {Key: "ctrl+s", Does: "pin"}, {Key: "ctrl+a", Does: "archive"}, {Key: "ctrl+t", Does: "filters"}, {Key: "ctrl+f", Does: "folders"}, {Key: "@", Does: "hosts"}, {Key: "esc", Does: esc}}
}

// counts is how many sessions the list holds, and how many of them today.
func (m SessionViewer) counts(now time.Time) string {
	count, today := len(m.order), 0
	if m.ArchiveView {
		count = len(m.archivedIDs)
	} else {
		for _, s := range m.order {
			if dateSection(s, now) == secToday {
				today++
			}
		}
	}
	out := chrome.DefaultStyles.Faint.Render(counted(count, "session"))
	if today > 0 {
		out += chrome.DefaultStyles.Decor.Render(" · ") + chrome.DefaultStyles.Success.Render(fmt.Sprintf("%d today", today))
	}
	return out
}

// column renders items with section headings at exactly width × height,
// scrolled to keep the cursor visible.
func (m SessionViewer) column(width, height int, now time.Time) []string {
	if len(m.Filtered) == 0 {
		message := "   No matching sessions"
		switch {
		case m.ArchiveView && m.SearchInput.Value() == "":
			message = "   No archived sessions yet"
		case m.Loading:
			message = "   loading sessions…"
		}
		return scrollWindow([]string{chrome.DefaultStyles.Faint.Render(message)}, -1, width, height)
	}

	selectedAt, total := -1, 0
	for _, group := range m.groups {
		if group.section != secAction {
			if total > 0 && height >= 10 {
				total++
			}
			total++
		}
		if m.Cursor >= group.first && m.Cursor < group.first+group.count {
			selectedAt = total + m.Cursor - group.first
		}
		total += group.count
	}
	start := 0
	if total > height {
		start = min(max(0, selectedAt-height/2), total-height)
	}
	end := min(total, start+height)
	out := make([]string, height)
	blank := strings.Repeat(" ", width)
	for i := range out {
		out[i] = blank
	}
	// Overflow markers replace edge rows rather than adding to the window.
	first, last := start, end
	if total > height && height >= 3 {
		more := chrome.Fit(chrome.DefaultStyles.Faint.Render("   ···"), width)
		if start > 0 {
			out[0] = more
			first++
		}
		if end < total {
			out[height-1] = more
			last--
		}
	}

	cols := svLayout(width)
	position := 0
	for _, group := range m.groups {
		if group.section != secAction {
			if position > 0 && height >= 10 {
				position++
			}
			if position >= first && position < last {
				out[position-start] = chrome.Fit(chrome.SectionRule(sectionTitles[group.section], m.sectionCounts[group.section], width), width)
			}
			position++
		}
		for offset := max(0, first-position); offset < min(group.count, last-position); offset++ {
			index := group.first + offset
			item := m.Filtered[index]
			session, _ := m.session(item.ID)
			out[position+offset-start] = chrome.Fit(m.row(item, session, group.section, index == m.Cursor, width, cols, now), width)
		}
		position += group.count
	}
	return out
}

// scrollWindow shows exactly width × height of lines, centred on selectedAt
// when they overflow, with ··· where lines were cut off.
func scrollWindow(all []string, selectedAt, width, height int) []string {
	return drawWindow(len(all), func(i int) string { return all[i] }, selectedAt, width, height)
}

// drawWindow is scrollWindow over n lines that line draws on demand, so a
// long list draws only the lines that show.
func drawWindow(n int, line func(int) string, selectedAt, width, height int) []string {
	return drawFrom(n, line, windowStart(n, selectedAt, height), width, height)
}

// windowStart is the first of n lines a window of height shows, centred on
// selectedAt.
func windowStart(n, selectedAt, height int) int {
	if n <= height {
		return 0
	}
	return min(max(0, selectedAt-height/2), n-height)
}

// drawFrom draws the window of n lines that starts at start.
func drawFrom(n int, line func(int) string, start, width, height int) []string {
	cut := n > height && height >= 3
	out := make([]string, height)
	for i := range out {
		switch at := start + i; {
		case cut && (i == 0 && start > 0 || i == height-1 && at < n-1):
			out[i] = chrome.Fit(chrome.DefaultStyles.Faint.Render("   ···"), width)
		case at < n:
			out[i] = chrome.Fit(line(at), width)
		default:
			out[i] = strings.Repeat(" ", width)
		}
	}
	return out
}

func (m SessionViewer) row(item PickerItem, s daemon.Session, sec int, selected bool, width int, cols svColumns, now time.Time) string {
	// A row being renamed drops the selection surface and takes the prompt's
	// color, so it reads as a place to type rather than a highlight.
	editing := m.rename.ID == item.ID
	selected = selected && !editing
	st := func(style lipgloss.Style) lipgloss.Style {
		if selected {
			return style.Inherit(chrome.DefaultStyles.Selected)
		}
		return style
	}
	bar := " "
	if selected {
		bar = st(chrome.DefaultStyles.Agent).Render("▌")
	}
	titleStyle := lipgloss.NewStyle()
	if selected {
		titleStyle = chrome.DefaultStyles.Bold
	}
	fill := func(line string) string {
		if pad := width - ansi.StringWidth(line); pad > 0 {
			line += st(lipgloss.NewStyle()).Render(strings.Repeat(" ", pad))
		}
		return line
	}

	if sec == secAction {
		glyph, title, hint, fg := "✦ ", "New session", "in "+sessionText(filepath.Base(m.Workspace)), chrome.DefaultStyles.You
		switch item.ID {
		case "settings":
			glyph, title, hint, fg = "◇ ", "settings", "connections and preferences", chrome.DefaultStyles.Muted
		case "archive":
			glyph, title, hint, fg = "▤ ", "Archive", counted(len(m.archivedIDs), "session"), chrome.DefaultStyles.Muted
		case "login":
			glyph, title, hint, fg = "◇ ", "Accounts", "sign-ins", chrome.DefaultStyles.Muted
		}
		titleWidth := min(ansi.StringWidth(title), cols.title)
		return fill(bar + st(fg).Render(glyph) + st(lipgloss.NewStyle()).Render(" ") +
			st(titleStyle.Inherit(fg)).Render(chrome.Cell(title, titleWidth, false)) +
			st(chrome.DefaultStyles.Faint).Render(chrome.Cell("  "+hint, max(0, width-4-titleWidth), false)))
	}

	glyph, iconStyle := "· ", chrome.DefaultStyles.Faint
	switch {
	case editing:
		bar, glyph, iconStyle = chrome.DefaultStyles.Prompt.Render("▌"), "✎ ", chrome.DefaultStyles.Prompt
	case selected:
		glyph, iconStyle = "◆ ", chrome.DefaultStyles.Agent
	case sec == secPinned:
		glyph, iconStyle = "★ ", chrome.DefaultStyles.Agent
	case s.Moved != nil:
		glyph = "↗ "
	case s.MovePending != nil:
		glyph, iconStyle = "↗ ", chrome.DefaultStyles.Warning
	case warm(s, now):
		glyph, iconStyle = "● ", chrome.DefaultStyles.Success
	}
	gap := st(lipgloss.NewStyle()).Render("  ")
	title := st(titleStyle).Render(chrome.Cell(item.Label, cols.title, false))
	if editing {
		title = m.rename.View(cols.title)
	}
	line := bar + st(iconStyle).Render(glyph) + st(lipgloss.NewStyle()).Render(" ") + title
	if cols.model > 0 {
		ms := chrome.DefaultStyles.Muted
		if selected {
			ms = lipgloss.NewStyle()
		}
		model := cmp.Or(sessionText(s.Model), "—")
		switch {
		case s.Moved != nil:
			ms, model = chrome.DefaultStyles.Faint, "↗ "+sessionText(s.Moved.Host)
		case s.MovePending != nil:
			ms, model = chrome.DefaultStyles.Faint, "↗ "+sessionText(s.MovePending.Host)+" · pending"
			if ansi.StringWidth(model) > cols.model {
				model = "↗ pending"
			}
		}
		line += gap + st(ms).Render(chrome.Cell(model, cols.model, false))
	}
	if cols.workspace > 0 {
		ws := chrome.DefaultStyles.Muted
		if s.Workspace == m.Workspace {
			ws = chrome.DefaultStyles.Faint
		}
		line += gap + st(ws).Render(chrome.Cell(sessionText(filepath.Base(s.Workspace)), cols.workspace, false))
	}
	if cols.cost > 0 {
		cost, known := estimatedCost(s.SessionCostUSD, true)
		cs := chrome.DefaultStyles.Muted
		if !known {
			cost, cs = "—", chrome.DefaultStyles.Faint
		}
		line += gap + st(cs).Render(chrome.Cell(cost, cols.cost, true))
	}
	if cols.age > 0 {
		as := chrome.DefaultStyles.Faint
		if warm(s, now) {
			as = chrome.DefaultStyles.Success
		}
		line += gap + st(as).Render(chrome.Cell(svCompactAge(s.LastAssistantAt, now), cols.age, true))
	}
	return fill(line)
}

// ── preview ────────────────────────────────────────────────────────────────

// paneBox frames lines into width × height with a one-column side margin.
func paneBox(lines []string, inner, width, height int) []string {
	out := make([]string, 0, height)
	for _, l := range lines[:min(len(lines), height)] {
		out = append(out, " "+chrome.Fit(l, inner)+" ")
	}
	for len(out) < height {
		out = append(out, strings.Repeat(" ", width))
	}
	return out
}

// preview renders the highlighted row's pane at exactly width × height: the
// session's title and metadata over its latest turns, newest at the bottom.
func (m SessionViewer) preview(width, height int, now time.Time) []string {
	inner := max(1, width-2)
	item, ok := m.Highlighted()
	s, isSession := m.session(item.ID)
	switch {
	case !ok && m.SearchInput.Value() == "":
		return paneBox([]string{"", chrome.DefaultStyles.Muted.Render("Nothing listed here")}, inner, width, height)
	case !ok:
		return paneBox(nil, inner, width, height)
	case !isSession:
		return paneBox(m.actionPreview(item.ID, inner, height), inner, width, height)
	}

	var top []string
	for _, l := range svWrap(sessionTitle(s), inner, 2) {
		top = append(top, chrome.DefaultStyles.Bold.Render(l))
	}
	meta := []string{}
	if s.Pinned {
		meta = append(meta, chrome.DefaultStyles.Agent.Render("★ pinned"))
	}
	if s.Model != "" {
		meta = append(meta, chrome.DefaultStyles.Muted.Render(sessionText(s.Model)))
	}
	if s.Workspace != "" {
		meta = append(meta, chrome.DefaultStyles.Muted.Render(sessionText(sessionPlace(s))))
	}
	meta = append(meta, chrome.DefaultStyles.Faint.Render(presentation.AssistantAge(s.LastAssistantAt, now)))
	if c := m.previews[s.ID]; c != nil && !c.loading && !c.err {
		meta = append(meta, chrome.DefaultStyles.Faint.Render(fmt.Sprintf("%d messages", s.TranscriptCount)))
	}
	top = append(top, strings.Join(meta, chrome.DefaultStyles.Decor.Render(" · ")))
	switch {
	case s.Moved != nil:
		top = append(top, chrome.DefaultStyles.Muted.Render("moved to "+sessionText(s.Moved.Host))+chrome.DefaultStyles.Faint.Render(" · "+sessionText(s.Moved.Workspace)))
	case s.MovePending != nil:
		top = append(top, chrome.DefaultStyles.Warning.Render("moving to "+sessionText(s.MovePending.Host)+" · checklist pending"), chrome.DefaultStyles.Faint.Render("open it, then enter or /cd reopens the checklist"))
	}
	top = append(top, chrome.DefaultStyles.Decor.Render(strings.Repeat("─", inner)))
	bottom := m.transcript(s, inner, max(0, height-len(top)-1))
	return paneBox(append(top, bottom...), inner, width, height)
}

// actionPreview is a centred splash for the New session and Accounts rows.
func (m SessionViewer) actionPreview(id string, inner, height int) []string {
	var lines []string
	switch id {
	case "new":
		if logo := svLogo(); height >= len(logo)+8 {
			lines = append(append(lines, ""), logo...)
		}
		lines = append(lines, "", chrome.GradientText("New session", true), "",
			chrome.DefaultStyles.Muted.Render("start fresh in ")+lipgloss.NewStyle().Render(sessionText(m.workspacePlace())), "",
			chrome.DefaultStyles.Faint.Render("enter ")+chrome.DefaultStyles.Muted.Render("begin"))
	case "settings":
		lines = []string{"", chrome.DefaultStyles.Bold.Render("settings"), "", chrome.DefaultStyles.Muted.Render("connections and preferences"), "", chrome.DefaultStyles.Faint.Render("enter open")}
	case "archive":
		lines = []string{"", "", chrome.DefaultStyles.Muted.Bold(true).Render("▤ Archive"), "",
			chrome.DefaultStyles.Muted.Render("Sessions kept out of the main list."), "",
			chrome.DefaultStyles.Faint.Render("enter ") + chrome.DefaultStyles.Muted.Render("browse")}
	default:
		lines = []string{"", "", chrome.DefaultStyles.Muted.Bold(true).Render("◇ Accounts"), "",
			chrome.DefaultStyles.Muted.Render("sign in to Claude, ChatGPT, Gemini"), chrome.DefaultStyles.Muted.Render("or a key; rotation and sign-out."), "",
			chrome.DefaultStyles.Faint.Render("enter ") + chrome.DefaultStyles.Muted.Render("manage")}
	}
	for i, l := range lines {
		lines[i] = strings.Repeat(" ", max(0, (inner-ansi.StringWidth(l))/2)) + l
	}
	return lines
}

// transcript is the tail of the session's conversation in at most height lines.
func (m SessionViewer) transcript(s daemon.Session, width, height int) []string {
	if height <= 0 {
		return nil
	}
	c := m.previews[s.ID]
	note := func(lines ...string) []string {
		out := []string{""}
		for _, l := range lines {
			out = append(out, chrome.DefaultStyles.Faint.Render(l))
		}
		return out
	}
	switch {
	case m.Fetch == nil:
		return nil
	case c == nil || c.loading:
		return note("loading conversation…")
	case c.err:
		return note("Could not load this preview.", "Open the session to read its messages.")
	case len(c.Items) == 0:
		return note("no messages yet")
	}

	// Consecutive tool calls collapse into one line of names with counts.
	type block struct {
		counts     map[string]int
		kind, text string
		tools      []string
	}
	var blocks []*block
	for _, it := range c.Items {
		text := sessionText(it.Preview)
		if it.Type == "assistant" {
			text = svMarkdownMarks.Replace(text)
		}
		if it.Type != "tool" {
			blocks = append(blocks, &block{kind: it.Type, text: text})
			continue
		}
		if len(blocks) == 0 || blocks[len(blocks)-1].kind != "tool" {
			blocks = append(blocks, &block{kind: "tool", counts: map[string]int{}})
		}
		b := blocks[len(blocks)-1]
		for name := range strings.SplitSeq(text, ", ") {
			if b.counts[name] == 0 {
				b.tools = append(b.tools, name)
			}
			b.counts[name]++
		}
	}
	// the same rails as the transcript: one per turn, dimmer through tools
	r := NewTranscriptRenderer()
	lanes := map[string]lane{"user": laneYou, "assistant": laneAgent, "tool": laneBusy}
	var lines []string
	prev := laneNone
	for bi, b := range blocks {
		own := lanes[b.kind]
		textStyle, maxLines := lipgloss.NewStyle(), 3
		if b.kind == "tool" {
			textStyle, maxLines = chrome.DefaultStyles.Faint, 2
			for i, name := range b.tools {
				if n := b.counts[name]; n > 1 {
					b.tools[i] = fmt.Sprintf("%s ×%d", name, n)
				}
			}
			b.text = strings.Join(b.tools, ", ")
		}
		if bi > 0 && joint(prev, own) == laneNone {
			lines = append(lines, "")
		}
		for _, l := range svWrap(b.text, max(1, width-railWidth), maxLines) {
			lines = append(lines, r.rail(own)+textStyle.Render(l))
		}
		prev = own
	}
	lines = append([]string{""}, lines...)
	if len(lines) > height {
		lines = lines[len(lines)-height:]
		lines[0] = chrome.DefaultStyles.Faint.Render("··· earlier")
	}
	return lines
}

// svMarkdownMarks drops emphasis and code markers that only cost width in a
// one-paragraph excerpt.
var svMarkdownMarks = strings.NewReplacer("**", "", "__", "", "`", "")

// svWrap word-wraps plain text into at most maxLines lines of width columns.
func svWrap(text string, width, maxLines int) []string {
	lines := strings.Split(ansi.Wrap(text, width, " /"), "\n")
	if len(lines) > maxLines {
		lines = lines[:maxLines]
		last := strings.TrimRight(lines[maxLines-1], " ")
		lines[maxLines-1] = ansi.Truncate(last+" …", width, "…")
	}
	return lines
}
