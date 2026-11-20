package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"math"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// contextUsage is how a prepared request fills its context window, split by
// the sections that make it up (albedo-suite). Section shares are byte
// proportions of the request's token size, so a part's count is approximate
// even when the total was measured.
type contextUsage struct {
	Model string
	Parts []contextPart
	// Used is the request's size in tokens; Estimated marks a size read from
	// section bytes because the snapshot carried none.
	Used      int
	Estimated bool
	// Window and Trigger are 0 when unknown; compaction starts at Trigger.
	Window, Trigger int
}

type contextPart struct {
	Label  string
	Tokens int
	Style  lipgloss.Style
}

// Bar glyphs: one solid track, coloured by part where used, dim where free,
// and dotted past the compaction trigger.
const (
	usedBar    = "▆"
	freeBar    = "▆"
	reserveBar = "▆"
	// legendMark is a part's swatch in the legend.
	legendMark = "●"
)

// freeStyle is the empty track; reserveStyle the track past the trigger.
func freeStyle() lipgloss.Style    { return DefaultStyles.Decor }
func reserveStyle() lipgloss.Style { return DefaultStyles.Warning.Faint(true) }

// bytesPerToken approximates a size when a snapshot reports none.
const bytesPerToken = 4

// partStyles colour the parts in a stable order: instructions, tools,
// conversation, then anything else.
func partStyles() []lipgloss.Style {
	return []lipgloss.Style{DefaultStyles.Agent, DefaultStyles.You, DefaultStyles.Success, DefaultStyles.Warning}
}

// partLabel names a section by what it holds rather than by its wire label.
func partLabel(sec daemon.ContextSection) (string, int) {
	switch sec.Kind {
	case "instructions", "system":
		return "instructions", 0
	case "tools":
		return "tools", 1
	case "history":
		return "conversation", 2
	}
	return strings.ToLower(sec.Label), 3
}

// usageOf reads a ready snapshot's usage; false while it is pending or holds
// no sections.
func usageOf(snap *daemon.ContextSnapshot) (contextUsage, bool) {
	if snap == nil || snap.State != "ready" || len(snap.Sections) == 0 {
		return contextUsage{}, false
	}
	u := contextUsage{Model: snap.Model}
	if snap.ContextWindowTokens != nil {
		u.Window = *snap.ContextWindowTokens
	} else if snap.Compaction.InputLimitTokens != nil {
		u.Window = *snap.Compaction.InputLimitTokens
	}
	if t := snap.Compaction.TriggerTokens; t != nil && *t > 0 && (u.Window == 0 || *t < u.Window) {
		u.Trigger = *t
	}
	bytes := make([]int, 4)
	labels := make([]string, 4)
	total := 0
	for _, sec := range snap.Sections {
		label, slot := partLabel(sec)
		if slot == 3 && labels[3] != "" && labels[3] != label {
			label = "other"
		}
		labels[slot] = label
		bytes[slot] += sec.ByteCount
		total += sec.ByteCount
	}
	switch {
	case snap.Compaction.Size != nil:
		u.Used = snap.Compaction.Size.Tokens
	case snap.Compaction.ProviderInputTokens != nil:
		u.Used = *snap.Compaction.ProviderInputTokens
	default:
		u.Used, u.Estimated = (total+bytesPerToken-1)/bytesPerToken, true
	}
	styles := partStyles()
	shares := apportion(u.Used, bytes)
	for slot, label := range labels {
		if label != "" {
			u.Parts = append(u.Parts, contextPart{Label: label, Tokens: shares[slot], Style: styles[slot]})
		}
	}
	return u, true
}

// apportion splits total in proportion to weights, by largest remainder, so
// the parts add up to total exactly.
func apportion(total int, weights []int) []int {
	out := make([]int, len(weights))
	sum := 0
	for _, w := range weights {
		sum += w
	}
	if sum <= 0 || total <= 0 {
		return out
	}
	type rest struct {
		i int
		r float64
	}
	var rests []rest
	given := 0
	for i, w := range weights {
		exact := float64(total) * float64(w) / float64(sum)
		out[i] = int(exact)
		given += out[i]
		rests = append(rests, rest{i, exact - float64(out[i])})
	}
	for given < total {
		best := 0
		for j := range rests {
			if rests[j].r > rests[best].r {
				best = j
			}
		}
		out[rests[best].i]++
		rests[best].r = -1
		given++
	}
	return out
}

// capacity is what the bar measures against: the window, or the
// used size when the window is unknown.
func (u contextUsage) capacity() int {
	return max(u.Window, u.Used, 1)
}

// cells lays the usage over n cells: each part's style for the cells it
// fills, then free cells, with the reserve past the trigger marked. A part
// with any tokens keeps at least one cell while the used cells fit.
func (u contextUsage) cells(n int) []cellKind {
	out := make([]cellKind, n)
	per := float64(u.capacity()) / float64(n)
	counts := make([]int, len(u.Parts))
	used := 0
	for i, p := range u.Parts {
		if p.Tokens > 0 {
			counts[i] = max(1, int(math.Round(float64(p.Tokens)/per)))
		}
		used += counts[i]
	}
	// Minimum cells can overflow a full window; take them from the largest.
	for used > n {
		largest := 0
		for i := range counts {
			if counts[i] > counts[largest] {
				largest = i
			}
		}
		counts[largest]--
		used--
	}
	at := 0
	for i, c := range counts {
		for range c {
			out[at] = cellKind{part: i, used: true}
			at++
		}
	}
	reserveFrom := n
	if u.Trigger > 0 {
		reserveFrom = int(math.Round(float64(u.Trigger) / per))
	}
	for ; at < n; at++ {
		out[at] = cellKind{part: -1, reserve: at >= reserveFrom}
	}
	return out
}

type cellKind struct {
	part          int
	used, reserve bool
}

// bar is the usage as one rule of width cells.
func (u contextUsage) bar(width int) string {
	var b strings.Builder
	for _, c := range u.cells(max(1, width)) {
		switch {
		case c.used:
			b.WriteString(u.Parts[c.part].Style.Render(usedBar))
		case c.reserve:
			b.WriteString(reserveStyle().Render(reserveBar))
		default:
			b.WriteString(freeStyle().Render(freeBar))
		}
	}
	return b.String()
}

// percent is share of the window as a whole-number percentage, or "" when
// the window is unknown.
func (u contextUsage) percent(tokens int) string {
	if u.Window <= 0 {
		return ""
	}
	pct := 100 * float64(tokens) / float64(u.Window)
	if pct > 0 && pct < 1 {
		return fmt.Sprintf("%.1f%%", pct)
	}
	return fmt.Sprintf("%d%%", int(math.Round(pct)))
}

// headline is the size against the window: "104k / 1m tokens · 10%".
func (u contextUsage) headline() string {
	used := shortCount(u.Used)
	if u.Estimated {
		used = "~" + used
	}
	if u.Window <= 0 {
		return used + " tokens"
	}
	return used + " / " + shortCount(u.Window) + " tokens · " + u.percent(u.Used)
}

// legend is one row per part, then free space and the compaction reserve,
// each with its tokens and share, fitted to width.
func (u contextUsage) legend(width int) []string {
	type row struct {
		mark, label string
		tokens      int
		approximate bool
	}
	var rows []row
	for _, p := range u.Parts {
		rows = append(rows, row{p.Style.Render(legendMark), p.Label, p.Tokens, true})
	}
	if u.Window > 0 {
		reserve := 0
		if u.Trigger > 0 {
			reserve = u.Window - max(u.Trigger, u.Used)
		}
		free := max(0, u.Window-u.Used-max(0, reserve))
		rows = append(rows, row{freeStyle().Render(legendMark), "free", free, u.Estimated})
		if reserve > 0 {
			rows = append(rows, row{reserveStyle().Render(legendMark), "past compaction", reserve, false})
		}
	}
	labelW := 0
	for _, r := range rows {
		labelW = max(labelW, ansi.StringWidth(r.label))
	}
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		amount := shortCount(r.tokens)
		if r.approximate {
			amount = "~" + amount
		}
		if pct := u.percent(r.tokens); pct != "" {
			amount += " " + DefaultStyles.Faint.Render(pct)
		}
		line := r.mark + " " + r.label + strings.Repeat(" ", labelW-ansi.StringWidth(r.label)+2) + DefaultStyles.Muted.Render(amount)
		out = append(out, ansi.Truncate(line, max(1, width), "…"))
	}
	return out
}

// block is the inspector's picture of the request: the size against the
// window, a bar, then the legend, in at most height rows. The legend goes
// first when rows are short; nil when not even the bar fits.
func (u contextUsage) block(width, height int) []string {
	if height < 2 {
		return nil
	}
	head := []string{DefaultStyles.Bold.Render(ansi.Truncate(u.headline(), width, "…")), u.bar(width)}
	legend := u.legend(width)
	if height < len(head)+1+len(legend) {
		return head
	}
	return append(append(head, ""), legend...)
}
