package tui

import (
	"slices"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// listEntry is one entry of a list screen: how it draws, what the filter
// matches, and what its detail pane says.
type listEntry struct {
	key     string                             // names the row across reloads, so the cursor stays on it
	group   string                             // sections of one group sit together under its heading
	section string                             // rows of one section sit together under its rule
	lead    string                             // styled state before the name, padded to the widest
	name    string                             // what the filter underlines
	desc    string                             // faint after the name, and searched
	tag     string                             // styled, at the right edge
	detail  func(width int) []string           // the pane's lines; nil leaves it blank
	draw    func(width int, hits []int) string // optional row contents, without selection
	search  []string
	heading bool // selectable heading for a foldable group
	hidden  bool // hidden only while the filter is empty
	faint   bool // a row that is done with, drawn faint unless selected
}

type listShown struct {
	hits []int
	row  int
}

// listView shares filtering, navigation and rendering across list screens.
type listView struct {
	navigation searchNavigation
	rows       []listEntry
	shown      []listShown
	// Empty is said when there are no rows at all.
	Empty      string
	groupTitle func(group string, width int) string
	input      textinput.Model
	Cursor     int
	height     int
}

// newFilter is a focused search field.
func newFilter(placeholder string) textinput.Model {
	input := newField()
	input.Placeholder = placeholder
	st := input.Styles()
	st.Focused.Placeholder, st.Blurred.Placeholder = DefaultStyles.Faint, DefaultStyles.Faint
	input.SetStyles(st)
	input.Focus()
	return input
}

func newListView(placeholder string) listView {
	return listView{input: newFilter(placeholder)}
}

func (l *listView) setSize(width, height int) {
	l.input.SetWidth(max(1, width-6))
	l.height = height
}

// setRows replaces the rows and filters them again, keeping the cursor on
// its row when that is still shown.
func (l *listView) setRows(rows []listEntry) {
	keep := ""
	if r, ok := l.highlighted(); ok {
		keep = r.key
	}
	l.rows = rows
	l.refilter(keep)
}

// refilter ranks the rows against the filter. Rows rank within their
// section, sections within their group by their best row, and groups by
// their best section; an empty filter keeps the order the rows came in.
func (l *listView) refilter(keep string) {
	words := searchWords(l.input.Value())
	type scored struct {
		shown listShown
		rank  matchRank
	}
	type bucket struct{ group, section string }
	var order []bucket
	buckets := map[bucket][]scored{}
	for i, r := range l.rows {
		if r.heading {
			if len(words) == 0 {
				b := bucket{r.group, r.section}
				order = append(order, b)
				buckets[b] = []scored{{shown: listShown{row: i}}}
			}
			continue
		}
		if r.hidden && len(words) == 0 {
			continue
		}
		rank, hits, ok := matchFields(words, append([]string{r.name, r.desc}, r.search...)...)
		if !ok {
			continue
		}
		b := bucket{r.group, r.section}
		if _, seen := buckets[b]; !seen {
			order = append(order, b)
		}
		buckets[b] = append(buckets[b], scored{listShown{row: i, hits: hits}, rank})
	}
	if len(words) > 0 {
		for _, g := range buckets {
			slices.SortStableFunc(g, func(a, b scored) int { return b.rank.compare(a.rank) })
		}
		slices.SortStableFunc(order, func(a, b bucket) int { return buckets[b][0].rank.compare(buckets[a][0].rank) })
	}
	// A group stands where its best section stands, its other sections after.
	var groups []string
	sections := map[string][]bucket{}
	for _, b := range order {
		if _, seen := sections[b.group]; !seen {
			groups = append(groups, b.group)
		}
		sections[b.group] = append(sections[b.group], b)
	}
	// Foldable headings stay with matching children; closed groups remain browsable.
	for i, r := range l.rows {
		if !r.heading || len(words) == 0 {
			continue
		}
		b := bucket{r.group, r.section}
		if _, exists := buckets[b]; !exists {
			continue
		}
		buckets[b] = append([]scored{{shown: listShown{row: i}}}, buckets[b]...)
	}
	l.shown = l.shown[:0]
	for _, group := range groups {
		for _, b := range sections[group] {
			for _, s := range buckets[b] {
				l.shown = append(l.shown, s.shown)
			}
		}
	}
	l.Cursor = max(0, slices.IndexFunc(l.shown, func(s listShown) bool { return l.rows[s.row].key == keep }))
	if keep == "" && len(words) > 0 && len(l.shown) > 1 && l.rows[l.shown[0].row].heading {
		l.Cursor = 1
	}
}

func (l listView) highlighted() (listEntry, bool) {
	if l.Cursor < 0 || l.Cursor >= len(l.shown) {
		return listEntry{}, false
	}
	return l.rows[l.shown[l.Cursor].row], true
}

func (l *listView) move(by int) {
	l.Cursor = min(max(l.Cursor+by, 0), max(0, len(l.shown)-1))
}

// update takes the keys that move through the list and everything else
// into the filter.
func (l *listView) update(msg tea.Msg) tea.Cmd {
	if key, ok := msg.(tea.KeyPressMsg); ok {
		var done bool
		key, done = l.navigation.key(key, &l.input, false)
		if done {
			return nil
		}
		msg = key
		if l.navigation.move(key, &l.Cursor, len(l.shown), l.height) {
			return nil
		}
		page := max(1, l.height/2)
		if by, moves := map[string]int{"up": -1, "ctrl+p": -1, "down": 1, "ctrl+n": 1, "pgup": -page, "pgdown": page}[key.String()]; moves {
			l.move(by)
			return nil
		}
	}
	l.navigation.paste(msg, &l.input)
	before := l.input.Value()
	var cmd tea.Cmd
	l.input, cmd = l.input.Update(msg)
	if l.input.Value() != before {
		l.refilter("")
	}
	return cmd
}

func (l listView) filterLine() string {
	return l.navigation.filterLine(l.input)
}

// frame is the screen's layout around this list and the highlighted row's
// detail.
func (l listView) frame(title, right, footer string) listFrame {
	f := listFrame{title: title, right: right, filter: l.filterLine(), list: l.list, footer: footer}
	if len(l.shown) > 0 {
		f.pane = l.pane
	}
	return f
}

// list draws the rows under their group headings and section rules at
// exactly width × height.
func (l listView) list(width, height int) []string {
	if len(l.shown) == 0 {
		note := []string{"no matches"}
		if len(l.rows) == 0 {
			note = svWrap(l.Empty, max(1, width-3), height)
		}
		for i, line := range note {
			note[i] = DefaultStyles.Faint.Render("  " + line)
		}
		return scrollWindow(note, -1, width, height)
	}
	leadW, nameW, tagW, described := 0, 0, 0, false
	for _, s := range l.shown {
		r := l.rows[s.row]
		leadW = max(leadW, ansi.StringWidth(r.lead))
		nameW = max(nameW, ansi.StringWidth(r.name))
		tagW = max(tagW, ansi.StringWidth(r.tag))
		described = described || r.desc != ""
	}
	if described {
		nameW = min(nameW, max(12, width/3))
	} else {
		nameW = min(nameW, width-leadW-6-tagW)
	}

	type line struct {
		text  string
		shown int // the row it draws, or -1 for a heading or rule
	}
	var all []line
	selectedAt := -1
	for i, s := range l.shown {
		r := l.rows[s.row]
		var prev *listEntry
		if i > 0 {
			prev = &l.rows[l.shown[i-1].row]
		}
		newGroup := r.group != "" && (prev == nil || prev.group != r.group)
		if newGroup {
			// A group's heading has no rule of its own, so it keeps its gap.
			if len(all) > 0 {
				all = append(all, line{shown: -1})
			}
			heading := groupHeading(r.group, width)
			if l.groupTitle != nil {
				heading = l.groupTitle(r.group, width)
			}
			if heading != "" {
				all = append(all, line{text: heading, shown: -1})
			}
		}
		if r.section != "" && (prev == nil || prev.group != r.group || prev.section != r.section) {
			run := 1
			for i+run < len(l.shown) {
				next := l.rows[l.shown[i+run].row]
				if next.group != r.group || next.section != r.section {
					break
				}
				run++
			}
			if !newGroup && len(all) > 0 && height >= 10 {
				all = append(all, line{shown: -1})
			}
			all = append(all, line{text: sectionRule(r.section, run, width), shown: -1})
		}
		if i == l.Cursor {
			selectedAt = len(all)
		}
		all = append(all, line{shown: i})
	}
	// A window never ends on a heading with none of its rows under it, and
	// one that starts inside a group shows that group's heading on top.
	start, cut := windowStart(len(all), selectedAt, height), len(all) > height && height >= 3
	headingAt := func(at int) bool {
		if all[at].shown < 0 {
			return true
		}
		r := l.rows[l.shown[all[at].shown].row]
		if !r.heading || at+1 >= len(all) || all[at+1].shown < 0 {
			return false
		}
		return l.rows[l.shown[all[at+1].shown].row].group == r.group
	}
	orphan := func() bool { return cut && start < len(all)-height && headingAt(start+height-2) }
	for orphan() && start > 0 && selectedAt < start+height-3 {
		start--
	}
	for orphan() && selectedAt > start+1 {
		start++
	}
	out := drawFrom(len(all), func(i int) string {
		if all[i].shown < 0 {
			return all[i].text
		}
		return l.row(l.shown[all[i].shown], all[i].shown == l.Cursor, width, leadW, nameW)
	}, start, width, height)
	if cut && start > 0 && all[start+1].shown >= 0 {
		for i := start; i >= 0; i-- {
			if all[i].shown >= 0 && l.rows[l.shown[all[i].shown].row].heading {
				out[0] = svFit(l.row(l.shown[all[i].shown], false, width, leadW, nameW), width)
				break
			}
			if all[i].shown < 0 && all[i].text != "" {
				out[0] = svFit(all[i].text, width)
				break
			}
		}
	}
	return out
}

func (l listView) row(s listShown, selected bool, width, leadW, nameW int) string {
	r := l.rows[s.row]
	if r.draw != nil {
		bar := " "
		if selected {
			bar = selectBar()
		}
		line := bar + " " + r.draw(max(1, width-3), s.hits)
		if selected {
			return selectedLine(line, width)
		}
		return line
	}
	bar, nameStyle := " ", lipgloss.NewStyle()
	switch {
	case selected:
		bar, nameStyle = selectBar(), DefaultStyles.Bold
	case r.faint:
		nameStyle = DefaultStyles.Faint
	}
	line := bar + " "
	if leadW > 0 {
		line += r.lead + strings.Repeat(" ", leadW-ansi.StringWidth(r.lead)+2)
	}
	line += markedCell(r.name, s.hits, nameW, nameStyle)
	room := width - ansi.StringWidth(line) - 3
	if r.tag != "" {
		room -= ansi.StringWidth(r.tag) + 2
	}
	if r.desc != "" && room >= 4 {
		line += DefaultStyles.Faint.Render("  " + ansi.Truncate(r.desc, room, "…"))
	}
	if r.tag != "" {
		line += strings.Repeat(" ", max(2, width-ansi.StringWidth(line)-ansi.StringWidth(r.tag)-1)) + r.tag
	}
	if selected {
		return selectedLine(line, width)
	}
	return line
}

// pane is the highlighted row's detail at exactly width × height.
func (l listView) pane(width, height int) []string {
	if r, ok := l.highlighted(); ok && r.detail != nil {
		return detailPane(r.detail)(width, height)
	}
	return paneBox(nil, max(1, width-2), width, height)
}

// detailPane draws detail lines as a pane at exactly width × height.
func detailPane(detail func(width int) []string) func(width, height int) []string {
	return func(width, height int) []string {
		inner := max(1, width-2)
		return paneBox(detail(inner), inner, width, height)
	}
}

// paneTitle opens a detail pane: the name in bold, a description under it,
// and a rule.
func paneTitle(name, description string, width int) []string {
	var lines []string
	for _, l := range svWrap(name, width, 2) {
		lines = append(lines, DefaultStyles.Bold.Render(l))
	}
	for _, l := range svWrap(description, width, 3) {
		if l != "" {
			lines = append(lines, DefaultStyles.Muted.Render(l))
		}
	}
	return append(lines, DefaultStyles.Decor.Render(strings.Repeat("─", width)))
}

// factLabelW is the label column of a detail pane's facts.
const factLabelW = 11

// factRows is one labelled fact of a detail pane; a long value wraps under
// itself.
func factRows(label, value string, width int) []string {
	var lines []string
	for i, l := range svWrap(value, max(1, width-factLabelW), 4) {
		cell := strings.Repeat(" ", factLabelW)
		if i == 0 {
			cell = DefaultStyles.Muted.Render(svCell(label, factLabelW, false))
		}
		lines = append(lines, cell+l)
	}
	return lines
}

// paneNote is faint explanatory text at the foot of a detail pane.
func paneNote(text string, width int) []string {
	var lines []string
	for _, l := range svWrap(text, width, 6) {
		lines = append(lines, DefaultStyles.Faint.Render(l))
	}
	return lines
}
