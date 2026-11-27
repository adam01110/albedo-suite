package tui

import (
	"albedo/cli/internal/terminalui"
	"fmt"
	"math"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"albedo/cli/internal/daemon"

	"albedo/cli/internal/tui/chrome"

	"github.com/charmbracelet/x/ansi"
)

const usageBarSlots = 8

// The list's two sections: today's models, then the days themselves.
const (
	usageTodaySection = "today"
	usageDaySection   = "by day"
)

// The cells a row's counts take: wide enough for the widest count usageUnits
// writes beside its label, so neither "in" nor "out" is ever cut.
const (
	usageInW  = 9
	usageOutW = 10
)

// usageDisplayDay is one day of the list: when it began, and what it used.
type usageDisplayDay struct {
	start  time.Time
	totals daemon.UsageTotals
}

// rows are today's models, then each of the days, today first and newest
// first, a day with nothing used drawn faint.
func (m UsageModel) rows() []listEntry {
	days := m.days()
	if len(days) == 0 {
		return nil
	}
	// One scale for both sections, the week's busiest day, so a bar says the
	// same thing in the models as in the days.
	scale := int64(0)
	for _, day := range days {
		scale = max(scale, usageSize(day.totals))
	}
	var rows []listEntry
	for _, line := range m.today.Lines {
		rows = append(rows, m.lineEntry(line, scale))
	}
	for _, day := range days {
		rows = append(rows, m.dayEntry(day, scale))
	}
	return rows
}

// days are the days the list shows, newest first: today from the answer that
// also named today's models, then the days before it from the week's.
//
// The week was read first, so its last day is today or the day before it; the
// days before today are closed, and the week's answer has them either way.
func (m UsageModel) days() []usageDisplayDay {
	today, ok := m.todayDay()
	if !ok {
		return nil
	}
	days := []usageDisplayDay{today}
	for i := len(m.week.Days) - 1; i >= 0 && len(days) < usageDays; i-- {
		if day := m.week.Days[i]; day.Start.Before(today.start) {
			days = append(days, usageDisplayDay{start: day.Start, totals: day.UsageTotals})
		}
	}
	return days
}

// todayDay is the day the screen calls today: the last of the answer that asked
// for one day. A daemon that sent no day still named the week's last one, which
// is then the day to draw.
func (m UsageModel) todayDay() (usageDisplayDay, bool) {
	for _, days := range [][]daemon.UsageDay{m.today.Days, m.week.Days} {
		if n := len(days); n > 0 {
			return usageDisplayDay{start: days[n-1].Start, totals: days[n-1].UsageTotals}, true
		}
	}
	return usageDisplayDay{}, false
}

// usageSize is what a row's bar measures: what went in and came out.
func usageSize(t daemon.UsageTotals) int64 { return t.InputTokens + t.OutputTokens }

// zone is the clock the days were counted on: the offset the daemon answered
// with, so a label matches the day it summed even if this terminal's zone
// changed since.
func (m UsageModel) zone() *time.Location {
	offset := m.today.UTCOffsetMinutes
	if len(m.today.Days) == 0 {
		offset = m.week.UTCOffsetMinutes
	}
	return time.FixedZone("local", offset*60)
}

// readAt is when the answers on screen were read: the day answer's stamp, the
// later of the two, which names a day where the clock the requests left on
// would misdate a slow one.
func (m UsageModel) readAt() time.Time {
	if !m.today.GeneratedAt.IsZero() {
		return m.today.GeneratedAt
	}
	return m.week.GeneratedAt
}

// dayName is a day against the clock the totals were read on: today,
// yesterday, then its weekday and date.
func (m UsageModel) dayName(start time.Time) string {
	zone := m.zone()
	day, now := start.In(zone), m.readAt().In(zone)
	switch {
	case sameDay(day, now):
		return "today"
	case sameDay(day, now.AddDate(0, 0, -1)):
		return "yesterday"
	}
	return day.Format("Mon 2 Jan")
}

func sameDay(a, b time.Time) bool {
	ay, am, ad := a.Date()
	by, bm, bd := b.Date()
	return ay == by && am == bm && ad == bd
}

// usageDayKey names a day's row across reloads.
func usageDayKey(start time.Time) string { return "day:" + start.Format(time.RFC3339) }

// usageLineKey names a model's row across reloads.
func usageLineKey(line daemon.UsageLine) string {
	return "line:" + line.Profile + "|" + line.Provider + "|" + line.Account + "|" + line.Model
}

// usageOpaqueAccount is an account label that names nobody: the id or hash a
// provider falls back to when it has no email, which a row would otherwise show
// entire.
var usageOpaqueAccount = regexp.MustCompile(`(?i)^[0-9a-f]{8,}(-[0-9a-f]{4,})*$`)

// usageAccountCut is how much of an opaque account tells two of them apart: the
// ids providers mint share their shape, not their beginning.
const usageAccountCut = 6

// usageAccountText is an account as a row says it: an email or a name as it is,
// an id or hash only when several accounts need telling apart, and then its
// first characters, and nothing when it names nobody.
func usageAccountText(account string, several bool) string {
	switch {
	case account == "":
		return ""
	case !usageOpaqueAccount.MatchString(account):
		return account
	case several:
		return account[:usageAccountCut]
	}
	return ""
}

// usageAccounts is how many accounts a profile's rows were made under, the row
// recorded with none included: two such rows are told apart by it.
func usageAccounts(profile string, lines []daemon.UsageLine) int {
	accounts := make(map[string]struct{}, len(lines))
	for _, line := range lines {
		if line.Profile == profile {
			accounts[line.Account] = struct{}{}
		}
	}
	return len(accounts)
}

// usageWho is who made a line's calls: its profile, and its account when that
// says something, or when the profile has more than one among lines and the
// rows have to be told apart. An account named after its own profile says
// nothing the row has not said already, and the row recorded with no account
// says that much. The web client says it the same way (`lineWho` in
// `web/src/lib/usage.ts`).
func usageWho(line daemon.UsageLine, lines []daemon.UsageLine) string {
	several := usageAccounts(line.Profile, lines) > 1
	account := usageAccountText(line.Account, several)
	if account != "" && account != line.Profile {
		return line.Profile + " · " + account
	}
	if several && line.Account == "" {
		return line.Profile + " · no account"
	}
	return line.Profile
}

func (m UsageModel) dayEntry(day usageDisplayDay, scale int64) listEntry {
	name := m.dayName(day.start)
	return listEntry{
		key:     usageDayKey(day.start),
		section: usageDaySection,
		name:    name,
		tag:     usageTag(day.totals, scale),
		faint:   day.totals.Calls == 0,
		search:  []string{name},
		detail:  func(width int) []string { return usageDetails(name, "", day.totals, width) },
	}
}

func (m UsageModel) lineEntry(line daemon.UsageLine, scale int64) listEntry {
	who := usageWho(line, m.today.Lines)
	provider := usageProviderName(line.Provider)
	return listEntry{
		key:     usageLineKey(line),
		section: usageTodaySection,
		name:    line.Model,
		desc:    who,
		tag:     usageTag(line.UsageTotals, scale),
		search:  []string{line.Model, line.Profile, line.Account, line.Provider, provider},
		detail: func(width int) []string {
			return usageDetails(line.Model, who+" · "+provider, line.UsageTotals, width)
		},
	}
}

// usageProvider is one endpoint a provider string can record: its host, how a
// region or a workspace joins it (nothing, a dot or a hyphen), what comes
// before that when the service writes it that way, and whether the endpoint is
// also recorded without one.
type usageProvider struct {
	host, join, prefix, name string
	bare                     bool
}

// usageProviderNames are the services behind the endpoints a provider string
// records, which is usually "<protocol>:<base URL>" and so names nothing a
// reader knows. A host no entry names, and a subdomain of one it does name, is
// shown as itself. The web client keeps the same table (`web/src/lib/usage.ts`):
// change both, and TestUsageProviderNameParityBridge says when they disagree.
var usageProviderNames = []usageProvider{
	{host: "chatgpt.com", name: "ChatGPT"},
	{host: "api.openai.com", name: "OpenAI"},
	{host: "api.anthropic.com", name: "Anthropic"},
	{host: "ollama.com", name: "Ollama"},
	{host: "generativelanguage.googleapis.com", name: "Google"},
	{host: "cloudcode-pa.googleapis.com", name: "Google"},
	{host: "aiplatform.googleapis.com", join: "-", name: "Vertex AI", bare: true},
	{host: "amazonaws.com", join: ".", prefix: "bedrock-runtime.", name: "Bedrock"},
	{host: "opencode.ai", name: "OpenCode"},
	{host: "openrouter.ai", name: "OpenRouter"},
	{host: "api.deepseek.com", name: "DeepSeek"},
	{host: "aliyuncs.com", join: ".", name: "Alibaba"},
	{host: "api.githubcopilot.com", name: "GitHub Copilot"},
}

// usageProviderName is what a screen calls the provider a call was made
// against: the service's name when the endpoint is one it knows, else the host
// it dialled, with its port when it has one. A string that is not a
// "<protocol>:<URL>" pair is already a name, and a name is never invented for
// one this does not recognise.
func usageProviderName(provider string) string {
	protocol, endpoint, ok := strings.Cut(strings.TrimSpace(provider), ":")
	if !ok || protocol == "" {
		return provider
	}
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Host == "" {
		return provider
	}
	host := strings.ToLower(parsed.Hostname())
	for _, known := range usageProviderNames {
		if usageHostIs(host, known) {
			return known.name
		}
	}
	return parsed.Host
}

// usageHostIs reports whether host is the entry's own endpoint or one label in
// front of it, joined the way that service writes it: the region in
// "us-central1-aiplatform.googleapis.com", the workspace in
// "dashscope.aliyuncs.com", the region after Bedrock's own prefix in
// "bedrock-runtime.eu-west-1.amazonaws.com". An entry that is recorded both
// ways also answers for its host with no label at all, as Vertex AI does.
func usageHostIs(host string, known usageProvider) bool {
	if known.join == "" {
		return known.prefix == "" && host == known.host
	}
	if known.bare && host == known.host {
		return true
	}
	label, ok := strings.CutSuffix(host, known.join+known.host)
	if !ok {
		return false
	}
	label, ok = strings.CutPrefix(label, known.prefix)
	return ok && label != "" && !strings.Contains(label, ".")
}

// usageBar fills slots in proportion to value over scale. A row with any use
// shows at least one.
func usageBar(value, scale int64) string {
	filled := 0
	if scale > 0 {
		filled = int(math.Round(float64(value) / float64(scale) * usageBarSlots))
		if value > 0 {
			filled = max(filled, 1)
		}
	}
	var b strings.Builder
	for i := range usageBarSlots {
		if i < filled {
			b.WriteString(chrome.BrandInk(float64(i) / (usageBarSlots - 1)).Render("▰"))
		} else {
			b.WriteString(chrome.DefaultStyles.Decor.Render("▱"))
		}
	}
	return b.String()
}

// usageTag is the right edge of a row: the bar, then what went in and out.
func usageTag(t daemon.UsageTotals, scale int64) string {
	if t.Calls == 0 {
		return chrome.DefaultStyles.Faint.Render("no use")
	}
	return usageBar(usageSize(t), scale) + " " + usageCount(t.InputTokens, "in", usageInW) + "  " + usageCount(t.OutputTokens, "out", usageOutW)
}

// usageUnits is a count in the client's own units: "34k", "1.2m", "2.3b",
// "2.3t". A row has room for five characters of number, so the ladder keeps a
// unit for each thousandfold above a million, the units the web client writes
// too (robot-docs/tui.md).
func usageUnits(n int64) string {
	switch {
	case n >= 999_500_000_000:
		return fmt.Sprintf("%.1ft", float64(n)/1_000_000_000_000)
	case n >= 999_500_000:
		return fmt.Sprintf("%.1fb", float64(n)/1_000_000_000)
	case n >= 999_500:
		return fmt.Sprintf("%.1fm", float64(n)/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%dk", (n+500)/1_000)
	}
	return strconv.FormatInt(n, 10)
}

// usageCount is a count in a cell of w columns with its label whole. A count
// too wide for what the label leaves keeps its leading digits and loses the
// rest, so the row still says which count it is.
func usageCount(n int64, label string, w int) string {
	room := max(1, w-len(label)-1)
	return chrome.Cell(ansi.Truncate(usageUnits(n), room, "")+" "+label, w, true)
}

// usageDetails is the pane: how many calls, then the counts as reported, and
// only then who made them. The pane is cut from the bottom in a short terminal
// and the numbers are what a row is for; the account is in the row beside it,
// and the line about cache is a footnote to the numbers above.
func usageDetails(name, who string, t daemon.UsageTotals, width int) []string {
	lines := paneTitle(name, "", width)
	if t.Calls == 0 {
		return append(lines, chrome.DefaultStyles.Faint.Render("nothing used"))
	}
	calls := countedText(t.Calls, "call")
	if t.Errors > 0 {
		calls += " · " + fmt.Sprintf("%d failed", t.Errors)
	}
	lines = append(lines, factRows("calls", calls, width)...)
	input := usageUnits(t.InputTokens) + usageShare(t.CachedInputTokens, t.InputTokens, "cached")
	if t.CacheCreationTokens > 0 {
		input += " · " + usageUnits(t.CacheCreationTokens) + " written"
	}
	lines = append(lines, factRows("input", input, width)...)
	lines = append(lines, factRows("output", usageUnits(t.OutputTokens)+usageShare(t.ReasoningTokens, t.OutputTokens, "reasoning"), width)...)
	lines = append(lines, "")
	if who != "" {
		for _, line := range svWrap(who, width, 3) {
			lines = append(lines, chrome.DefaultStyles.Muted.Render(line))
		}
	}
	return append(lines, paneNote("Cached input is part of input, not added to it.", width)...)
}

// usageShare is "  36k cached", with the percent of the whole when it has one.
func usageShare(part, whole int64, what string) string {
	if part == 0 {
		return ""
	}
	text := " · " + usageUnits(part) + " " + what
	if whole > 0 && part <= whole {
		text += fmt.Sprintf(" (%.0f%%)", float64(part)/float64(whole)*100)
	}
	return text
}

func countedText(n int64, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}

// summary is the highlighted row's counts on one line, for a terminal with no
// room for the pane. A day nothing was used on has none: its row already says
// so, and the frame must not draw the empty line.
func (m UsageModel) summary() string {
	row, ok := m.highlighted()
	if !ok {
		return ""
	}
	text := usageTotalsText(m.rowTotals(row.key))
	if text == "" {
		return ""
	}
	return chrome.DefaultStyles.Faint.Render(text)
}

// rowTotals is what the row a key names used, from whichever section it is in.
func (m UsageModel) rowTotals(key string) daemon.UsageTotals {
	for _, line := range m.today.Lines {
		if usageLineKey(line) == key {
			return line.UsageTotals
		}
	}
	for _, day := range m.days() {
		if usageDayKey(day.start) == key {
			return day.totals
		}
	}
	return daemon.UsageTotals{}
}

// usageTotalsText is a row's counts on one line: "12 calls · 48k in · 2.1k out".
func usageTotalsText(t daemon.UsageTotals) string {
	if t.Calls == 0 {
		return ""
	}
	return countedText(t.Calls, "call") + " · " + usageUnits(t.InputTokens) + " in · " + usageUnits(t.OutputTokens) + " out"
}

// period is the header's right end: what the days it lists come to, and when a
// read failed, how old the rows still on screen are. The footer says why, and
// its row belongs to the keys.
func (m UsageModel) period() string {
	days := m.days()
	if len(days) == 0 {
		return ""
	}
	var in, out int64
	for _, day := range days {
		in += day.totals.InputTokens
		out += day.totals.OutputTokens
	}
	name := "last " + fmt.Sprint(len(days)) + " days"
	if len(days) == 1 {
		name = "today"
	}
	total := name + " · " + usageUnits(in) + " in · " + usageUnits(out) + " out"
	if age := m.stale(); age != "" {
		total += " · as of " + age
	}
	return total
}

// standing is the quiet line beside the hints: a list the daemon cut is only
// the busiest models, which matters more than where the limits are, and it has
// to fit beside the hints at 70 columns.
func (m UsageModel) standing() string {
	if m.today.LinesTruncated {
		return "busiest models only"
	}
	return "limits are in /quota"
}

// stale is when the rows still on screen were read, when the last refresh
// failed over them: a failed read keeps the last good one up rather than a
// blank screen.
func (m UsageModel) stale() string {
	if m.Error == "" {
		return ""
	}
	return m.asOf()
}

// asOf is when the rows on screen were read, in the clock the daemon counted
// them on: the hour when that was on the screen's own day, the day too once the
// read is older.
func (m UsageModel) asOf() string {
	at := m.readAt()
	if at.IsZero() {
		return ""
	}
	at = at.In(m.zone())
	// The hour alone is enough while the read is on the day it names; a screen
	// left open through midnight needs the date to say how old it is.
	if day, ok := m.todayDay(); ok && sameDay(at, day.start.In(m.zone())) {
		return at.Format("15:04")
	}
	return at.Format("Mon 2 Jan 15:04")
}

func (m UsageModel) footer(width int) string {
	hints := []chrome.Hint{{Key: "↑↓", Does: "move"}, {Key: "tab", Does: "profile"}, {Key: "ctrl+r", Does: "refresh"}, {Key: "esc", Does: "back"}}
	if m.Error != "" {
		// A failed read offers the retry every list screen offers.
		hints = []chrome.Hint{{Key: "ctrl+r", Does: "retry"}, {Key: "esc", Does: "back"}}
	}
	var status string
	urgent := true
	switch {
	case m.Loading:
		status, urgent = chrome.DefaultStyles.Faint.Render("loading…"), false
	case m.Error != "":
		status = chrome.DefaultStyles.Error.Render(m.Error)
	case len(m.week.Days) > 0 || len(m.today.Days) > 0:
		status, urgent = chrome.DefaultStyles.Faint.Render(m.standing()), false
	}
	return chrome.FooterLine(width, hints, status, urgent)
}

func (m UsageModel) Page() terminalui.Page {
	lv := m.listView
	switch {
	case m.Loading:
		lv.Empty = "loading usage…"
	case m.Error != "":
		lv.Empty = "Could not read usage from the daemon."
	default:
		lv.Empty = "Nothing used yet."
	}
	title := chrome.Brand("albedo") + " " + chrome.DefaultStyles.Muted.Render("/usage") + "  " + m.tabsText()
	if m.tab == usageProfileTab {
		return m.profileView(title)
	}
	f := lv.frame(title, chrome.DefaultStyles.Faint.Render(m.period()), m.footer(max(1, m.Width)))
	f.Summary = m.summary()
	return f
}
