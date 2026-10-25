package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"maps"
	"slices"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

func (m AgentsViewModel) paneHeader() []string {
	// One column goes to the space after the divider.
	width := m.paneWidth() - 1
	if width <= 0 {
		width = max(1, m.Width-2)
	}
	rows := make([]string, 0, 12)
	n := m.nodes[m.selected]
	if n == nil || width <= 0 {
		return rows
	}
	colors := agentColors()
	styled := func(hue rgb, s string) string { return sgr(hue.hex(), "") + s + ansiReset }
	state := "idle"
	switch {
	case n.id == agentsYou:
		state = "that's you"
	case n.closed:
		state = "closed"
	case n.session.Status.Phase != nil:
		switch *n.session.Status.Phase {
		case daemon.PhasePreparing:
			state = "preparing"
		case daemon.PhaseInterrupted:
			state = "interrupting"
		case daemon.PhaseIdle, daemon.PhaseResting:
			state = "idle"
		default:
			state = "running"
		}
	case n.running:
		state = "running"
	case n.peer:
		state = "outside this tree"
	}
	rows = append(rows, styled(n.hue, "● ")+DefaultStyles.Bold.Render(n.name)+"  "+DefaultStyles.Faint.Render(state))
	var meta []string
	if n.model != "" {
		meta = append(meta, n.model)
	}
	if n.id != agentsYou {
		meta = append(meta, fmt.Sprintf("depth %d", n.depth))
	}
	if parent := m.nodes[n.parent]; parent != nil {
		meta = append(meta, "parent "+parent.name)
	}
	rows = append(rows, DefaultStyles.Faint.Render(ansi.Truncate(strings.Join(meta, " · "), width, "…")), "")
	for _, field := range []struct{ label, text string }{{"request", n.currentRequest}, {"latest", n.latestProgress}} {
		if field.text == "" {
			continue
		}
		rows = append(rows, DefaultStyles.Muted.Render(field.label))
		wrapped := strings.Split(ansi.Wrap(field.text, max(1, width), " "), "\n")
		if len(wrapped) > 3 {
			wrapped = wrapped[:3]
			wrapped[2] = ansi.Truncate(wrapped[2], max(1, width-1), "") + "…"
		}
		rows = append(rows, wrapped...)
	}
	if len(n.mail) > 0 {
		rows = append(rows, DefaultStyles.Muted.Render("mail"))
		for _, mail := range n.mail[max(0, len(n.mail)-5):] {
			var arrow string
			if mail.incoming {
				arrow = styled(colors.mail, "← ")
			} else {
				arrow = DefaultStyles.Faint.Render("→ ")
			}
			rows = append(rows, ansi.Truncate(arrow+mail.who+" "+DefaultStyles.Faint.Render(mail.kind), width, "…"))
		}
		rows = append(rows, "")
	}
	live := DefaultStyles.Muted.Render("tail")
	if n.running {
		live += " " + styled(n.hue, "●") + DefaultStyles.Faint.Render(" live")
	}
	if n.tail.omitted || n.preview.omitted {
		live += DefaultStyles.Faint.Render(" · earlier output omitted")
	}
	return append(rows, live)
}

func (m AgentsViewModel) pane(height int) []string {
	rows := m.paneHeader()
	room := max(0, height-len(rows))
	if room == 0 || len(rows) == 0 {
		return rows
	}
	wrapped := m.tailCache.rows
	if len(wrapped) == 0 {
		return append(rows, DefaultStyles.Faint.Render("nothing yet"))
	}
	return append(rows, wrapped[max(0, len(wrapped)-room):]...)
}

// drawTail wraps one tail line to width and styles it by kind.
func drawTail(line tailLine, width, limit int) []string {
	gutter, inner := "", width
	format := func(s ...string) string { return strings.Join(s, "") }
	switch line.kind {
	case tailThinking:
		format = func(s ...string) string { return DefaultStyles.Faint.Render(ansiItalic + s[0]) }
	case tailCode:
		gutter, inner, format = DefaultStyles.Decor.Render("│ "), width-2, DefaultStyles.Muted.Render
	case tailOutput:
		gutter, inner, format = DefaultStyles.Decor.Render("⎿ "), width-2, DefaultStyles.Faint.Render
	case tailMeta:
		format = DefaultStyles.Faint.Render
	}
	wrapped := ansi.Hardwrap(line.text, max(8, inner), true)
	start := len(wrapped)
	for range limit {
		index := strings.LastIndexByte(wrapped[:start], '\n')
		if index < 0 {
			start = 0
			break
		}
		start = index
	}
	if start > 0 {
		start++
	}
	var out []string
	for part := range strings.SplitSeq(wrapped[start:], "\n") {
		// A cached row must not retain the rest of a long wrapped line.
		out = append(out, gutter+format(strings.Clone(part)))
	}
	return out
}

// graphOffset scrolls a tall swarm so the selected dot and its children's
// dots stay in view, the selected one first when both do not fit.
func (m AgentsViewModel) graphOffset(height int) int {
	n := m.nodes[m.selected]
	if n == nil {
		return 0
	}
	bottom := n.y + 3
	for _, child := range m.nodes {
		if child.parent == m.selected {
			bottom = max(bottom, child.y+2)
		}
	}
	return max(0, min(bottom-height, n.y-1))
}

func (m AgentsViewModel) View() string {
	if m.Width <= 0 || m.Height <= 0 {
		return ""
	}
	live, tokens := 0, 0
	for id, n := range m.nodes {
		if id == agentsYou {
			continue
		}
		if n.running {
			live++
		}
		tokens += n.chars / 4
	}
	right := DefaultStyles.Faint.Render(fmt.Sprintf("%d agents · %d running · ▴%s tok", len(m.nodes)-1, live, compactCount(tokens)))
	out := []string{" " + titleRule(m.Width-1, brand("albedo")+" "+DefaultStyles.Muted.Render("/agents"), right)}

	var confirmRows []string
	if m.confirm.asking() {
		confirmRows = strings.Split(m.confirm.footer(max(1, m.Width), ""), "\n")
	}
	bodyH := max(1, m.Height-3-max(1, len(confirmRows)))
	dagW := m.dagWidth()
	pw := m.paneWidth()
	var stacked []string
	if pw == 0 {
		// Under the graph no tail follows, so the header ends at its facts.
		stacked = m.paneHeader()
		stacked = stacked[:max(0, len(stacked)-1)]
		for len(stacked) > 0 && stacked[len(stacked)-1] == "" {
			stacked = stacked[:len(stacked)-1]
		}
		stacked = stacked[:min(len(stacked), max(0, bodyH/2-1))]
		if len(stacked) > 0 {
			bodyH = max(1, bodyH-len(stacked)-1)
		}
	}
	offset := m.graphOffset(bodyH)
	canvas := newCanvas(dagW, bodyH+offset)
	m.drawEdges(canvas)
	m.drawNodes(canvas)
	pane := m.pane(bodyH)
	divider := DefaultStyles.Decor.Render("│")
	for y := range bodyH {
		row := canvas.line(y + offset)
		if pw > 0 {
			side := ""
			if y < len(pane) {
				side = pane[y]
			}
			row += divider + " " + ansi.Truncate(side, pw-1, "…")
		}
		out = append(out, " "+row)
	}

	if len(stacked) > 0 {
		out = append(out, " "+DefaultStyles.Decor.Render(strings.Repeat("─", max(0, m.Width-2))))
		for _, row := range stacked {
			out = append(out, " "+ansi.Truncate(row, max(1, m.Width-1), "…"))
		}
	}

	status := ""
	switch {
	case m.rename.active():
		status = DefaultStyles.Muted.Render("rename ") + DefaultStyles.Bold.Render(m.label(m.rename.id, ""))
		if n := m.nodes[m.rename.id]; n != nil && n.address != "" {
			status += DefaultStyles.Faint.Render(" · its family can still mail it at ") + DefaultStyles.Muted.Render(n.address)
		}
	case m.err != nil:
		status = DefaultStyles.Error.Render(m.err.Error() + " · ctrl+l retries")
	case len(m.pendingOperations) > 0:
		ids := slices.Sorted(maps.Keys(m.pendingOperations))
		status = DefaultStyles.Error.Render("Unresolved request: " + strings.Join(ids, ", "))
	case m.noticeT > 0:
		status = DefaultStyles.Muted.Render(m.notice)
	}
	if len(confirmRows) > 0 {
		out = append(out, confirmRows...)
	} else {
		out = append(out, " "+status)
	}
	target := m.label(m.selected, "agent")
	input := m.input.View()
	if m.input.Value() == "" {
		input = DefaultStyles.Faint.Render("message " + target + "…  or /spawn <name> <task>")
	}
	if n := m.nodes[m.rename.id]; n != nil && m.rename.active() {
		out = append(out, " "+DefaultStyles.Prompt.Render("✎ ")+m.rename.view(m.Width-promptMarkWidth-1), " "+renameHints("restores "+renameBlank(n)))
	} else {
		out = append(out, " "+promptLead()+input, footerLine(m.Width, []hint{{"hjkl/tab", "agent"}, {"enter", "open or send"}, {"ctrl+r", "rename"}, {"ctrl+x", "delete"}, {"esc", "back"}}, "", false))
	}
	return strings.Join(out, "\n")
}
