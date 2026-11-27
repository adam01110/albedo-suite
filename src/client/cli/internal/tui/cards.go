package tui

import (
	"encoding/json"
	"fmt"
	"maps"
	"slices"
	"strings"
	"unicode"

	"albedo/cli/internal/daemon"

	"albedo/cli/internal/tui/chrome"

	"github.com/charmbracelet/x/ansi"
)

// A tool card is one call in verbose mode, on a panel the width of the
// transcript: the call's name and how long it took, the code it ran, what it
// did, and what it printed. A long section shows its start (the newest calls,
// for what it did) and a fold row; a click on any fold row opens the card.
const (
	cardCodeRows   = 10
	cardCallRows   = 8
	cardOutputRows = 5
)

func (r TranscriptRenderer) shellCard(entry HistoryEntry, width int) []string {
	command := entry.ShellCommand
	if command == nil {
		return nil
	}
	key := entryKey(entry)
	open := r.Open[key]
	inner := max(1, width-2)
	panel := func(text string) string {
		text = ansi.Truncate(text, inner, "…")
		return chrome.DiffPanel() + " " + chrome.KeepBackground(text) + strings.Repeat(" ", max(0, inner-ansi.StringWidth(text))) + " " + chrome.AnsiReset
	}
	head := chrome.DefaultStyles.Busy.Render("! " + oneLine(command.Command))
	state := command.Status
	if command.ExitCode != nil {
		state += fmt.Sprintf(" · exit %d", *command.ExitCode)
	}
	delivery := ""
	if command.Status != "running" {
		switch command.Delivery {
		case "pending":
			delivery = "queued for agent"
		case "delivered":
			delivery = "sent to agent"
		}
	}
	status := chrome.DefaultStyles.Faint.Render(" " + state)
	if delivery != "" {
		status += chrome.DefaultStyles.Faint.Render(" · " + delivery)
	}
	rows := []string{markChrome + panel(fit(head, status, inner))}
	if command.Status == "running" {
		rows = append(rows, markChrome+rowAction{"cancel", command.ID}.mark()+panel(chrome.DefaultStyles.Faint.Render("running · click to cancel · ctrl+shift+x cancels latest")))
	}
	output := command.Output
	if open && entry.ShellOutputLoaded {
		output = entry.ShellExpandedOutput
	}
	lines := plainLines(strings.TrimRight(output, "\n"))
	if command.Output == "" {
		message := "(no output)"
		if command.Status == "running" {
			message = "(no output yet)"
		}
		lines = []string{message}
	}
	var body []string
	for _, line := range wrapped(lines, inner) {
		body = append(body, panel(chrome.DefaultStyles.Faint.Render(line)))
	}
	if open && entry.ShellOutputLoaded {
		rows = append(rows, body...)
	} else {
		shown := min(cardOutputRows, len(body))
		rows = append(rows, body[:shown]...)
		if open && !entry.ShellOutputLoaded && command.OutputBytes > int64(len(command.Output)) {
			rows = append(rows, panel(chrome.DefaultStyles.Faint.Render("loading full retained output…")))
		} else if len(body) > shown || command.OutputBytes > int64(len(command.Output)) || command.Truncated {
			label := fmt.Sprintf("%s%d more lines · click to expand", toggleClosed, max(0, len(body)-shown))
			rows = append(rows, markChrome+rowAction{verbMore, key}.mark()+panel(chrome.DefaultStyles.Faint.Render(label)))
		}
	}
	if command.Truncated {
		rows = append(rows, panel(chrome.DefaultStyles.Error.Render("capture capped at 16 MiB; later output is unavailable")))
	}
	if message := daemon.ShellCommandErrorText(*command); message != "" {
		rows = append(rows, panel(chrome.DefaultStyles.Error.Render(oneLine(message))))
	}
	if open && entry.ShellOutputLoaded {
		rows = append(rows, markChrome+rowAction{verbMore, key}.mark()+panel(chrome.DefaultStyles.Faint.Render(toggleOpen+"show less")))
	}
	return rows
}

func (r TranscriptRenderer) toolCard(entry HistoryEntry, flags DisplayFlags, width int) []string {
	key := entryKey(entry)
	open := r.Open[key]
	failed := toolFailed(entry)
	inner := max(1, width-2)
	panel := func(row string) string {
		row = ansi.Truncate(row, inner, "…")
		return chrome.DiffPanel() + " " + chrome.KeepBackground(row) + strings.Repeat(" ", max(0, inner-ansi.StringWidth(row))) + " " + chrome.AnsiReset
	}
	fold := func(hidden int, noun string) string {
		return markChrome + rowAction{verbMore, key}.mark() + panel(chrome.DefaultStyles.Faint.Render(fmt.Sprintf("%s%d more %s · click to expand", toggleClosed, hidden, noun)))
	}
	folded := false
	var rows []string
	// section adds a block of panel rows, after a blank one unless it
	// follows the name, keeping its first limit rows (its last, when newest)
	// while the card is closed.
	section := func(body []string, limit int, newest bool, noun string) {
		if len(body) == 0 {
			return
		}
		if len(rows) > 1 {
			rows = append(rows, markChrome+panel(""))
		}
		long := len(body) > limit+foldSlack
		folded = folded || long
		if open || !long {
			rows = append(rows, body...)
			return
		}
		hidden := len(body) - limit
		if newest {
			rows = append(append(rows, fold(hidden, noun)), body[hidden:]...)
			return
		}
		rows = append(append(rows, body[:limit]...), fold(hidden, noun))
	}

	name, glyph := cardName(entry), chrome.DefaultStyles.Busy
	if failed {
		name, glyph = chrome.Icon.CallFailed+" "+name, chrome.DefaultStyles.Error
	}
	var facts []string
	if took := cellDuration(entry); took != "" {
		facts = append(facts, took)
	}
	if failed {
		facts = append(facts, "failed")
	}
	facts = append(facts, formatClock(entry.Timestamp))
	rows = append(rows, markChrome+panel(fit(glyph.Bold(true).Render(name), chrome.DefaultStyles.Faint.Render(" "+strings.Join(facts, " · ")), inner)))

	if code, lang := cardInput(entry); strings.TrimSpace(code) != "" {
		var body []string
		for _, line := range wrapped(HighlightLines(plainLines(strings.TrimRight(code, "\n")), lexerFor(lang), r.highlights), inner) {
			body = append(body, panel(line))
		}
		section(body, cardCodeRows, false, "lines")
	}
	section(r.cardCalls(entry.ToolTrace, flags, inner, panel), cardCallRows, true, "calls")
	var body []string
	for _, part := range cardOutput(entry) {
		ink := chrome.DefaultStyles.Faint
		if part.failed {
			ink = chrome.DefaultStyles.Error
		}
		for _, line := range wrapped(plainLines(part.text), inner) {
			body = append(body, panel(ink.Render(line)))
		}
	}
	section(body, cardOutputRows, false, "lines")
	if open && folded {
		rows = append(rows, markChrome+rowAction{verbMore, key}.mark()+panel(chrome.DefaultStyles.Faint.Render(toggleOpen+"show less")))
	}
	return rows
}

// wrapped is lines wrapped to width, the rows a line wraps onto marked as
// continuing it, so a copy joins them back.
func wrapped(lines []string, width int) []string {
	var rows []string
	for _, line := range lines {
		rows = append(rows, markChunks(line, wrapOrChunkLine(line, width))...)
	}
	return rows
}

// cardCalls is what a call did, a row each: the commands, reads, searches and
// displays its trace recorded, then the files it changed, with their diffs
// when ctrl+j shows them.
func (r TranscriptRenderer) cardCalls(trace *daemon.ToolTrace, flags DisplayFlags, width int, panel func(string) string) []string {
	if trace == nil {
		return nil
	}
	var rows []string
	for _, act := range trace.Activities {
		if act.Kind == "artifact" {
			rows = append(rows, markChrome+panel(artifactRow(act, width)))
			continue
		}
		head := callGlyph(act) + " " + chrome.DefaultStyles.Busy.Render(act.Kind) + " "
		took := ""
		if act.MS != nil {
			took = " " + chrome.DefaultStyles.Decor.Render(formatMillis(*act.MS))
		}
		target := chrome.DefaultStyles.Faint.Render(r.shortTarget(act.Target, isPath(act), width-ansi.StringWidth(head)-ansi.StringWidth(took)))
		if act.Kind == "run" {
			command := HighlightLines(plainLines(r.named(act.Target)), lexerFor("command.sh"), r.highlights)
			target = ansi.Truncate(strings.Join(command, " "), max(1, width-ansi.StringWidth(head)-ansi.StringWidth(took)), "…")
		}
		rows = append(rows, markChrome+panel(head+target+took))
		if act.Kind == "display" && act.Detail != "" {
			for _, row := range r.renderDisplayRows(act.Target, act.Title, act.Description, act.Detail, width) {
				rows = append(rows, panel(row))
			}
		}
	}
	for _, change := range trace.Changes {
		counts := ""
		if change.Kind == "diff" {
			counts = "  " + r.diffCounts(change)
		}
		line := r.traceLine(chrome.DefaultStyles.Success.Render("✓")+" "+chrome.DefaultStyles.Busy.Render("edited"), change.Path, true, width-ansi.StringWidth(counts))
		rows = append(rows, markChrome+panel(fit(line, counts, width)))
		if !flags.Diffs {
			continue
		}
		if change.Kind != "diff" {
			rows = append(rows, markChrome+panel(chrome.DefaultStyles.Faint.Render(change.Reason)))
			continue
		}
		// the edited row above already names the file
		diff := strings.Split(r.renderDiffPath(change.Diff, change.Path, width), "\n")
		for _, row := range diff[1:] {
			rows = append(rows, panel(row))
		}
	}
	if trace.Truncated {
		rows = append(rows, markChrome+panel(chrome.DefaultStyles.Faint.Render("some activity was not captured; this list is incomplete")))
	}
	return rows
}

type outputPart struct {
	text   string
	failed bool
}

// cardOutput is what a call printed, then its error: a cell's traceback is
// red, what it printed before failing is not.
func cardOutput(entry HistoryEntry) []outputPart {
	var cell struct{ Output, Value, Error string }
	if entry.ToolName != "python" || json.Unmarshal([]byte(entry.ToolResult), &cell) != nil {
		if output := toolOutput(entry); output != "" {
			return []outputPart{{output, toolFailed(entry)}}
		}
		return nil
	}
	var parts []outputPart
	for _, part := range []outputPart{{cell.Output, false}, {cell.Value, false}, {cell.Error, true}} {
		if part.text = strings.TrimSpace(part.text); part.text != "" {
			parts = append(parts, part)
		}
	}
	return parts
}

// cardInput is what a call was given, and a file name whose language tints
// it: a cell's code, a command, or the arguments of any other call.
func cardInput(entry HistoryEntry) (text, file string) {
	arg := func(key string) string { s, _ := entry.ToolArgs[key].(string); return s }
	switch entry.ToolName {
	case "python":
		return arg("code"), "cell.py"
	case "shell", "bash":
		return arg("command"), "command.sh"
	}
	keys := slices.Sorted(maps.Keys(entry.ToolArgs))
	lines := make([]string, len(keys))
	for i, key := range keys {
		value, ok := entry.ToolArgs[key].(string)
		if !ok {
			encoded, _ := json.Marshal(entry.ToolArgs[key])
			value = string(encoded)
		}
		lines[i] = key + ": " + value
	}
	return strings.Join(lines, "\n"), ""
}

func cardName(entry HistoryEntry) string {
	if entry.ToolName == "shell" || entry.ToolName == "bash" {
		return "shell"
	}
	return entry.ToolName
}

// cellDuration is how long a python cell ran, from its result.
func cellDuration(entry HistoryEntry) string {
	var cell struct {
		Duration float64 `json:"duration"`
	}
	if entry.ToolName != "python" || json.Unmarshal([]byte(entry.ToolResult), &cell) != nil || cell.Duration <= 0 {
		return ""
	}
	return formatMillis(int64(cell.Duration * 1000))
}

// formatMillis is a call's duration as pi shows it: 40ms, 1.5s, or past a
// minute 2m 3s.
func formatMillis(ms int64) string {
	switch {
	case ms < 1000:
		return fmt.Sprintf("%dms", ms)
	case ms < 60_000:
		return fmt.Sprintf("%.1fs", float64(ms)/1000)
	default:
		return formatElapsed(ms)
	}
}

// callGlyph is how a call inside a cell ended: ✓ or ✗, or · for a call
// still running when its cell finished, or one that records no outcome.
func callGlyph(act daemon.ToolActivity) string {
	switch {
	case act.OK == nil:
		return chrome.DefaultStyles.Faint.Render(chrome.Icon.CallPending)
	case *act.OK:
		return chrome.DefaultStyles.Success.Render(chrome.Icon.CallSucceeded)
	default:
		return chrome.DefaultStyles.Error.Render(chrome.Icon.CallFailed)
	}
}

// plainLines is text as rows of printable cells: tool output may carry
// colors, tabs, and carriage returns that would wreck the panel around it.
func plainLines(text string) []string {
	text = strings.NewReplacer("\r\n", "\n", "\r", "\n", "\t", "    ").Replace(ansi.Strip(text))
	return strings.Split(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' {
			return ' '
		}
		return r
	}, text), "\n")
}
