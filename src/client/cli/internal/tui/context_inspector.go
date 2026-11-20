package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"errors"
	"fmt"
	"math"
	"slices"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"golang.org/x/text/language"
	"golang.org/x/text/message"
)

// ContextDetail is one section's content, read as one document and scrolled
// line by line (albedo-suite). Pages stream in after the first and are
// appended to Value, so reading starts at once; formatting runs in chunks cut
// at blank lines outside code fences, only as far as the view has scrolled,
// because Markdown over a whole long section takes seconds.
type ContextDetail struct {
	Value   *daemon.ContextPage
	Error   string
	Section daemon.ContextSection
	Scroll  int
	Raw     bool
	// loaded counts the pages appended to Value.
	loaded int
	// visible is the body rows the last frame drew; page jumps move by it.
	visible int
	// wrapped holds the rows formatted so far from wrappedFrom's content, at
	// wrappedWidth; wrappedTo is how many bytes of it they cover and ends
	// marks, per chunk, its last row and the content offset it reached.
	wrapped      []string
	wrappedWidth int
	wrappedFrom  *daemon.ContextPage
	wrappedRaw   bool
	wrappedTo    int
	ends         []chunkEnd
}

type chunkEnd struct{ row, offset int }

// chunkBytes is about how much content one formatting step takes: a page's
// worth, which formats in about 10 ms.
const chunkBytes = 8000

// complete reports whether every page has arrived.
func (d *ContextDetail) complete() bool {
	return d.Value != nil && d.loaded >= max(1, d.Value.Pages)
}

// rows is the whole content wrapped to width.
func (d *ContextDetail) rows(width int) []string {
	return d.rowsTo(width, math.MaxInt)
}

// rowsTo formats chunks until at least need rows exist or the loaded content
// runs out, and returns the rows so far.
func (d *ContextDetail) rowsTo(width, need int) []string {
	if d.Value == nil {
		return nil
	}
	if d.wrappedFrom != d.Value || d.wrappedWidth != width || d.wrappedRaw != d.Raw || len(d.Value.Content) < d.wrappedTo {
		d.wrapped, d.wrappedTo, d.ends = nil, 0, nil
		d.wrappedWidth, d.wrappedFrom, d.wrappedRaw = width, d.Value, d.Raw
	}
	content := d.Value.Content
	complete := d.complete() || d.loaded == 0
	if d.Raw {
		// Raw wrapping is cheap; redo the loaded content when it grew.
		if d.wrappedTo != len(content) {
			d.wrapped = wrapContextContent(content, width)
			d.wrappedTo = len(content)
			d.ends = []chunkEnd{{len(d.wrapped), len(content)}}
		}
		return d.wrapped
	}
	for len(d.wrapped) < need && d.wrappedTo < len(content) {
		end, ok := chunkEnding(content, d.wrappedTo, complete)
		if !ok {
			break
		}
		if len(d.wrapped) > 0 {
			d.wrapped = append(d.wrapped, "")
		}
		d.wrapped = append(d.wrapped, formattedContextRows(strings.Trim(content[d.wrappedTo:end], "\n"), min(width, 100))...)
		d.wrappedTo = end
		d.ends = append(d.ends, chunkEnd{len(d.wrapped), end})
	}
	return d.wrapped
}

// chunkEnding is where the chunk starting at from ends: the first blank line
// outside a code fence past chunkBytes, or the content's end once it is
// complete. False when the loaded content holds no such point yet.
func chunkEnding(content string, from int, complete bool) (int, bool) {
	fence := ""
	at := from
	for at < len(content) {
		next := strings.IndexByte(content[at:], '\n')
		if next < 0 {
			break
		}
		line := content[at : at+next]
		fence = fenceAfter(fence, line)
		at += next + 1
		if fence == "" && strings.TrimSpace(line) == "" && at-from >= chunkBytes {
			return at, true
		}
	}
	if complete {
		return len(content), true
	}
	return 0, false
}

// formatted reports whether every row of the content exists.
func (d *ContextDetail) formatted() bool {
	return d.Value != nil && d.complete() && d.wrappedTo >= len(d.Value.Content)
}

// scroll moves the content by lines, formatting what the move reaches.
func (d *ContextDetail) scroll(by int) {
	if d.wrappedWidth == 0 {
		return
	}
	rows := d.rowsTo(d.wrappedWidth, d.Scroll+by+d.visible)
	d.Scroll = min(max(0, d.Scroll+by), max(0, len(rows)-d.visible))
}

// position is how far down the bottom row is, by content bytes until every
// row exists.
func (d *ContextDetail) position(bottom int) int {
	if d.formatted() {
		return 100 * min(len(d.wrapped), bottom) / max(1, len(d.wrapped))
	}
	total := max(1, d.Section.ByteCount, len(d.Value.Content))
	offset := 0
	for _, end := range d.ends {
		offset = end.offset
		if end.row >= bottom {
			break
		}
	}
	return min(99, 100*offset/total)
}

// list is the reader's body at exactly width × height: where the content
// comes from, any warning, then the scrolled rows.
func (d *ContextDetail) list(width, height int) []string {
	sec := d.Section
	mode := "formatted"
	if d.Raw {
		mode = "raw"
	}
	facts := []string{sec.Source, contextCount(sec.ByteCount, "byte"), mode}
	var rows []string
	var notes []string
	switch {
	case d.Error != "":
		notes = append(notes, DefaultStyles.Error.Render(d.Error))
	case d.Value == nil:
		notes = append(notes, DefaultStyles.Faint.Render("loading prepared content…"))
	default:
		if d.Value.Omitted != "" {
			notes = append(notes, DefaultStyles.Warning.Render("omitted: "+d.Value.Omitted))
		}
		notes = append(notes, "")
	}
	room := max(0, height-1-len(notes))
	d.visible = room
	if d.Value != nil && d.Error == "" {
		rows = d.rowsTo(max(1, width-2), d.Scroll+room)
	}
	d.Scroll = min(d.Scroll, max(0, len(rows)-room))
	if !d.complete() && d.Value != nil {
		facts = append(facts, fmt.Sprintf("loading %d/%d pages", d.loaded, d.Value.Pages))
	}
	if len(rows) > room || !d.formatted() && d.Value != nil {
		facts = append(facts, fmt.Sprintf("%d%%", d.position(d.Scroll+room)))
	}
	head := append([]string{DefaultStyles.Faint.Render(strings.Join(facts, " · "))}, notes...)

	out := make([]string, 0, height)
	for _, line := range head {
		out = append(out, "  "+line)
	}
	for _, row := range rows[d.Scroll:min(len(rows), d.Scroll+room)] {
		out = append(out, "  "+row)
	}
	for len(out) < height {
		out = append(out, "")
	}
	return out
}

type ContextDoneMsg struct{}

type contextSnapshotLoadedMsg struct {
	Snapshot *daemon.ContextSnapshot
	Err      error
	Gen      int
}

// contextPageLoadedMsg carries one page of a section; the reader appends
// pages in order and asks for the next.
type contextPageLoadedMsg struct {
	Err       error
	Data      *daemon.ContextPage
	SectionID string
	Page      int
	Gen       int
}

// contextRetryMsg reads a pending snapshot again.
type contextRetryMsg struct{ Gen int }

// pendingRetry is how often a pending snapshot is read again while the
// inspector shows it.
const pendingRetry = time.Second

// ContextInspectorModel lists the sections of the prepared request beside
// the highlighted section's facts. Enter reads a section's content.
type ContextInspectorModel struct {
	Conn      *daemon.Connection
	SessionID string
	Snapshot  *daemon.ContextSnapshot
	Detail    *ContextDetail
	pageStatus
	listView
}

func NewContextInspectorModel(conn *daemon.Connection, sessionID string) ContextInspectorModel {
	return ContextInspectorModel{
		Conn:       conn,
		SessionID:  sessionID,
		pageStatus: newPageStatus(true),
		listView:   newListView("Search sections"),
	}
}

func (m *ContextInspectorModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.listView.setSize(width, height)
}

func (m ContextInspectorModel) Init() tea.Cmd {
	return m.loadSnapshotCmd(m.Generation)
}

// compactionStatusLabel is how the inspector words a compaction status.
func compactionStatusLabel(status daemon.CompactionStatus) string {
	switch status {
	case daemon.CompactionNotConfigured:
		return "not configured"
	case daemon.CompactionNotNeeded:
		return "not needed"
	case daemon.CompactionApplied:
		return "applied"
	default:
		return "state unavailable"
	}
}

func (m ContextInspectorModel) loadSnapshotCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return contextSnapshotLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}

		snapshot, err := daemon.GetContextSnapshot(context.Background(), m.Conn, m.SessionID)
		if err != nil {
			return contextSnapshotLoadedMsg{Err: err, Gen: gen}
		}
		return contextSnapshotLoadedMsg{Snapshot: &snapshot, Gen: gen}
	}
}

// loadPageCmd reads one page of a section. A local daemon serves each in
// about a millisecond; the reader asks for the next as each arrives.
func (m ContextInspectorModel) loadPageCmd(sec daemon.ContextSection, page, gen int) tea.Cmd {
	conn, session, snapshot := m.Conn, m.SessionID, m.Snapshot.SnapshotID
	return func() tea.Msg {
		if conn == nil {
			return contextPageLoadedMsg{SectionID: sec.ID, Page: page, Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		data, err := daemon.GetContextPage(context.Background(), conn, session, snapshot, sec.ID, page)
		if err != nil {
			err = fmt.Errorf("page %d of %d: %w", page+1, max(1, sec.Pages), err)
			return contextPageLoadedMsg{SectionID: sec.ID, Page: page, Err: err, Gen: gen}
		}
		return contextPageLoadedMsg{SectionID: sec.ID, Page: page, Data: &data, Gen: gen}
	}
}

// appendPage adds the next page to the document: the content after what came
// before, and any omission not already noted.
func (d *ContextDetail) appendPage(page daemon.ContextPage) {
	if d.Value == nil {
		whole := page
		d.Value = &whole
	} else {
		d.Value.Content += page.Content
		d.Value.Pages = page.Pages
		for _, reason := range strings.Split(page.Omitted, "; ") {
			if reason != "" && !strings.Contains(d.Value.Omitted, reason) {
				d.Value.Omitted = strings.TrimPrefix(d.Value.Omitted+"; "+reason, "; ")
			}
		}
	}
	d.loaded++
}

func retryCmd(gen int) tea.Cmd {
	return tea.Tick(pendingRetry, func(time.Time) tea.Msg { return contextRetryMsg{Gen: gen} })
}

// current is the section under the cursor.
func (m ContextInspectorModel) current() (daemon.ContextSection, bool) {
	row, ok := m.highlighted()
	if !ok || m.Snapshot == nil {
		return daemon.ContextSection{}, false
	}
	i := slices.IndexFunc(m.Snapshot.Sections, func(sec daemon.ContextSection) bool { return sec.ID == row.key })
	if i < 0 {
		return daemon.ContextSection{}, false
	}
	return m.Snapshot.Sections[i], true
}

func (m *ContextInspectorModel) setSections() {
	var rows []listEntry
	if m.Snapshot != nil {
		rows = make([]listEntry, len(m.Snapshot.Sections))
		for i, sec := range m.Snapshot.Sections {
			rows[i] = sectionEntry(i, sec)
		}
	}
	m.setRows(rows)
}

func sectionEntry(i int, sec daemon.ContextSection) listEntry {
	tag := DefaultStyles.Faint.Render("no content")
	if sec.Pages > 0 {
		tag = DefaultStyles.Muted.Render(contextCount(sec.Pages, "page"))
	}
	return listEntry{
		key:    sec.ID,
		lead:   DefaultStyles.Faint.Render(fmt.Sprintf("%d.", i+1)),
		name:   sec.Label,
		desc:   sec.Source,
		tag:    tag,
		search: []string{sec.Kind, sec.Preview},
		detail: func(width int) []string { return sectionDetails(sec, width) },
	}
}

// sectionDetails is the pane: where a section comes from, how much of it
// there is, and its preview.
func sectionDetails(sec daemon.ContextSection, width int) []string {
	pages := "content unavailable"
	if sec.Pages > 0 {
		pages = contextCount(sec.Pages, "page")
	}
	lines := paneTitle(sec.Label, "", width)
	lines = append(lines, factRows("source", sec.Source, width)...)
	lines = append(lines, factRows("items", contextCount(sec.ItemCount, "item"), width)...)
	lines = append(lines, factRows("bytes", contextCount(sec.ByteCount, "measured byte"), width)...)
	lines = append(lines, factRows("pages", pages, width)...)
	if sec.Preview != "" {
		lines = append(lines, "")
		lines = append(lines, factRows("preview", sec.Preview, width)...)
	}
	lines = append(lines, "")
	return append(lines, paneNote("enter reads this section", width)...)
}

// requestFacts is the prepared request's standing, drawn above the sections
// so it reads without opening one.
func (m ContextInspectorModel) requestFacts(width int) []string {
	snap := m.Snapshot
	if snap == nil {
		return nil
	}
	if snap.State == "pending" {
		value := "no prepared request yet"
		if snap.Reason != "" {
			value += ": " + snap.Reason
		}
		return append(factRows("request", value, width), factRows("", DefaultStyles.Faint.Render("checking again every second"), width)...)
	}
	label := snap.Model
	if snap.Provider != "" {
		label = snap.Provider + " · " + snap.Model
	}
	if snap.Protocol != "" {
		label += " · " + snap.Protocol
	}
	window := "not reported"
	if snap.ContextWindowTokens != nil {
		window = contextCount(*snap.ContextWindowTokens, "token") + " (configured)"
	}
	compaction := snap.Compaction
	lines := factRows("model", label, width)
	if !slices.ContainsFunc(snap.Sections, func(sec daemon.ContextSection) bool { return sec.Kind == "history" }) {
		lines = append(lines, factRows("request", DefaultStyles.Warning.Render("preview · nothing sent yet; the first turn adds your message"), width)...)
	}
	lines = append(lines, factRows("window", window, width)...)
	strategy := cmp.Or(compaction.Strategy, "none")
	strategy += " · " + compactionStatusLabel(compaction.Status)
	lines = append(lines, factRows("compact", strategy, width)...)
	if compaction.TriggerTokens != nil {
		lines = append(lines, factRows("trigger", "compacts at "+contextCount(*compaction.TriggerTokens, "token"), width)...)
	}
	if compaction.Size != nil {
		lines = append(lines, sizeFacts(*compaction.Size, width)...)
	}
	if compaction.ProviderInputTokens != nil {
		measured := contextCount(*compaction.ProviderInputTokens, "token") + " from provider"
		if compaction.ProviderCachedInputTokens != nil {
			measured += " · " + contextCount(*compaction.ProviderCachedInputTokens, "cached token")
		}
		lines = append(lines, factRows("input", measured, width)...)
	}
	return lines
}

// sizeFacts shows a request's size by what is behind it: the part a provider
// measured, and the part albedo estimated, labelled as an estimate with the
// correction it used. One part reads on a single row; two read as their sum
// and then each.
func sizeFacts(size daemon.Size, width int) []string {
	measured, estimated := "", ""
	if m := size.Measured; m != nil {
		measured = contextCount(m.Tokens, "token") + " from the provider's reported usage"
		if m.Counted {
			measured = contextCount(m.Tokens, "token") + " counted by the provider"
		}
	}
	if e := size.Estimated; e != nil {
		estimated = contextCount(e.Tokens, "token") + " estimated"
		if e.Correction != nil {
			estimated += " · " + correctionText(*e.Correction)
		}
	}
	switch {
	case measured != "" && estimated != "":
		lines := factRows("size", contextCount(size.Tokens, "token"), width)
		lines = append(lines, factRows("measured", measured, width)...)
		return append(lines, factRows("estimated", estimated, width)...)
	case measured != "":
		return factRows("size", measured, width)
	case estimated != "":
		return factRows("size", estimated, width)
	}
	return factRows("size", contextCount(size.Tokens, "token"), width)
}

// correctionText says how an estimate was corrected towards what providers
// reported for the route.
func correctionText(c daemon.SizeCorrection) string {
	factor := fmt.Sprintf("×%d.%02d", c.PerMille/1000, c.PerMille%1000/10)
	if c.Calibrated {
		return "corrected " + factor + " from reported usage"
	}
	return "provisional correction " + factor + " after " + contextCount(c.Reports, "report")
}

// emptyText says why there are no section rows.
func (m ContextInspectorModel) emptyText() string {
	switch {
	case m.Loading && m.Snapshot == nil:
		return "loading prepared request snapshot…"
	case m.Snapshot == nil:
		return "no prepared request to inspect"
	case m.Snapshot.State == "pending":
		return "sections appear once a request is prepared"
	}
	return "the prepared request contains no inspectable sections"
}

// list draws how the request fills its window, its standing, then the
// sections, at exactly width × height.
func (m ContextInspectorModel) list(width, height int) []string {
	// The window's bar comes first and keeps at least six rows for the
	// sections; the facts and note fit in what is left. A rule like the
	// pane's separates each part (albedo-suite).
	full := height
	rule := DefaultStyles.Decor.Render(strings.Repeat("─", max(1, width-2)))
	var block []string
	if usage, ok := usageOf(m.Snapshot); ok {
		if block = usage.block(width-2, height-7); block != nil {
			block = append(block, rule)
		}
	}
	height -= len(block)
	head := m.requestFacts(width - 2)
	// The note and the facts give up their rows, in that order, to the
	// sections when the list is short, as it is with the pane stacked below.
	if height >= len(head)+8 {
		head = append(head, paneNote("read-only · transcript and request-only context are separate", width-2)...)
		head = append(head, rule)
	} else if height >= len(head)+5 {
		head = append(head, rule)
	} else {
		head = nil
	}
	head = append(block, head...)
	for i := range head {
		head[i] = svFit("  "+head[i], width)
	}
	lv := m.listView
	lv.Empty = m.emptyText()
	return append(head, lv.list(width, max(1, full-len(head)))...)
}

func (m ContextInspectorModel) footer(width int) string {
	hints := []hint{{"↑↓", "move"}, {"enter", "inspect"}, {"ctrl+r", "refresh"}, {"esc", "back"}}
	var status string
	urgent := true
	switch {
	case m.Error != "":
		status = DefaultStyles.Error.Render(m.Error)
	case m.Loading:
		status, urgent = DefaultStyles.Faint.Render("loading…"), false
	case m.Snapshot != nil:
		status, urgent = DefaultStyles.Faint.Render(counted(len(m.Snapshot.Sections), "section")), false
	}
	return footerLine(width, hints, status, urgent)
}

// readerFooter is the footer while a section's content is open.
func readerFooter(width int) string {
	return footerLine(width, []hint{{"↑↓", "scroll"}, {"pgup/pgdn", "jump"}, {"home/end", "ends"}, {"r", "raw/formatted"}, {"esc", "sections"}}, "", false)
}

func (m ContextInspectorModel) Update(msg tea.Msg) (ContextInspectorModel, tea.Cmd) {
	switch msg := msg.(type) {
	case contextSnapshotLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Snapshot, m.Error = msg.Snapshot, ""
		m.setSections()
		if m.Snapshot != nil && m.Snapshot.State == "pending" {
			return m, retryCmd(m.Generation)
		}
		return m, nil

	case contextRetryMsg:
		if msg.Gen != m.Generation || m.Detail != nil || m.Loading || m.Snapshot == nil || m.Snapshot.State != "pending" {
			return m, nil
		}
		m.Loading = true
		return m, m.loadSnapshotCmd(m.Generation)

	case contextPageLoadedMsg:
		if msg.Gen != m.Generation || m.Detail == nil || m.Detail.Section.ID != msg.SectionID {
			return m, nil
		}
		d := m.Detail
		if msg.Err != nil {
			d.Error = msg.Err.Error()
			return m, nil
		}
		if msg.Page != d.loaded || msg.Data == nil {
			return m, nil
		}
		d.appendPage(*msg.Data)
		if !d.complete() {
			return m, m.loadPageCmd(d.Section, d.loaded, m.Generation)
		}
		return m, nil

	case tea.KeyPressMsg:
		if m.Detail != nil {
			return m.readerKey(msg)
		}
		return m.sectionsKey(msg)
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

// readerKey scrolls through a section's content; esc returns to the
// sections.
func (m ContextInspectorModel) readerKey(msg tea.KeyPressMsg) (ContextInspectorModel, tea.Cmd) {
	d := m.Detail
	switch msg.String() {
	case "esc", "ctrl+c", "ctrl+d":
		m.Detail = nil
		m.Generation = nextPageGeneration()
	case "r":
		d.Raw, d.Scroll = !d.Raw, 0
	case "up":
		d.scroll(-1)
	case "down":
		d.scroll(1)
	case "pgup":
		d.scroll(-max(1, d.visible))
	case "pgdown", "space":
		d.scroll(max(1, d.visible))
	case "home", "g":
		d.Scroll = 0
	case "end", "G":
		// The end needs every row: format the rest of what has arrived.
		if d.wrappedWidth > 0 {
			d.rowsTo(d.wrappedWidth, math.MaxInt)
			d.scroll(len(d.wrapped))
		}
	}
	return m, nil
}

func (m ContextInspectorModel) sectionsKey(msg tea.KeyPressMsg) (ContextInspectorModel, tea.Cmd) {
	switch msg.String() {
	case "esc", "ctrl+c", "ctrl+d":
		return m, func() tea.Msg { return ContextDoneMsg{} }
	case "enter":
		if sec, ok := m.current(); ok && sec.Pages > 0 {
			m.Detail = &ContextDetail{Section: sec}
			m.Generation = nextPageGeneration()
			return m, m.loadPageCmd(sec, 0, m.Generation)
		}
		return m, nil
	case "ctrl+r":
		m.Loading, m.Snapshot, m.Error = true, nil, ""
		m.setSections()
		m.Generation = nextPageGeneration()
		return m, m.loadSnapshotCmd(m.Generation)
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

func wrapContextContent(content string, width int) []string {
	width = max(1, width)
	return strings.Split(ansi.Hardwrap(ansi.Wrap(content, width, " "), width, true), "\n")
}

var englishPrinter = message.NewPrinter(language.English)

func contextCount(n int, unit string) string {
	if n != 1 {
		unit += "s"
	}
	return englishPrinter.Sprintf("%d", n) + " " + unit
}

// reader is the section's content as a list with no filter and no pane.
func (m ContextInspectorModel) reader() listFrame {
	title := brand("albedo") + " " + DefaultStyles.Muted.Render("/context")
	return listFrame{
		title:  title,
		right:  DefaultStyles.Faint.Render(m.Detail.Section.Label),
		list:   m.Detail.list,
		footer: readerFooter(max(1, m.Width)),
	}
}

func (m ContextInspectorModel) View() string {
	if m.Detail != nil {
		return m.reader().view(m.Width, m.Height)
	}
	title := brand("albedo") + " " + DefaultStyles.Muted.Render("/context")
	f := m.listView.frame(title, DefaultStyles.Faint.Render("prepared request"), m.footer(max(1, m.Width)))
	f.list = m.list
	return f.view(m.Width, m.Height)
}
