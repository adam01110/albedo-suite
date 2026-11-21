package tui

import (
	"os"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// A turn that ends while the terminal is unfocused raises a desktop
// notification through the terminal itself (OSC 777), followed by a bell so
// the window manager can mark the window urgent. The sequence travels over the
// TTY, so it reaches the local desktop over SSH too; a terminal without
// support ignores it. A terminal that never reports focus never blurs and
// never notifies.

// notifyMode is what a turn notification says, read once from ALBEDO_NOTIFY:
// on (the default) includes the reply preview, brief leaves it out, off sends
// nothing.
type notifyMode int

const (
	notifyOn notifyMode = iota
	notifyBrief
	notifyOff
)

func turnNotifyMode() notifyMode {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("ALBEDO_NOTIFY"))) {
	case "off", "0", "false", "no":
		return notifyOff
	case "brief":
		return notifyBrief
	}
	return notifyOn
}

const (
	// notifyMinElapsedMs skips turns short enough that you were still watching.
	notifyMinElapsedMs = 10_000
	notifyTitleLimit   = 80
	notifyPreviewLimit = 100
)

// queueTurnNotification remembers the notification for the first live turn
// signoff among entries, which the caller has already appended to History.
func (m *ChatModel) queueTurnNotification(entries []HistoryEntry) {
	if !m.blurred || m.notifyMode == notifyOff {
		return
	}
	for _, entry := range entries {
		if entry.Kind == EntryTurnEnd && entry.ElapsedMs >= notifyMinElapsedMs {
			m.notifyPending = m.turnNotification(entry)
			return
		}
	}
}

// takeTurnNotification hands the queued notification to the terminal once.
func (m *ChatModel) takeTurnNotification() tea.Cmd {
	seq := m.notifyPending
	m.notifyPending = ""
	if seq == "" {
		return nil
	}
	return tea.Raw(seq)
}

func (m *ChatModel) turnNotification(end HistoryEntry) string {
	title := "albedo"
	if m.notifyTitle != nil {
		if name := notifyText(m.notifyTitle(), notifyTitleLimit); name != "" {
			title += " · " + name
		}
	}
	elapsed := formatElapsed(end.ElapsedMs)
	var status string
	switch end.Mood {
	case moodFailed:
		status = "Failed after " + elapsed
	case moodStopped:
		status = "Interrupted after " + elapsed
	default:
		status = "Done in " + elapsed
	}
	if end.Tools == 1 {
		status += " · 1 tool"
	} else if end.Tools > 1 {
		status += " · " + formatCount(end.Tools) + " tools"
	}
	body := status
	if detail := m.turnDetail(end.Mood); detail != "" {
		body += " — " + detail
	}
	return notificationSequence(title, body, os.Getenv("TMUX") != "")
}

// turnDetail is the error that failed the turn, or the first line of its
// final reply unless the mode is brief. It reads back from the signoff to the
// message that opened the turn.
func (m *ChatModel) turnDetail(end mood) string {
	if end == moodStopped || m.History == nil {
		return ""
	}
	entries := m.History.Entries()
	// The signoff is the entry being described. An older signoff ends the turn
	// before it, whose reply or error is not this turn's.
	signoff := true
	for i := len(entries) - 1; i >= 0; i-- {
		e := entries[i]
		switch e.Kind {
		case EntryUser:
			return ""
		case EntryTurnEnd:
			if !signoff {
				return ""
			}
			signoff = false
		case EntryError:
			if end == moodFailed {
				return notifyText(e.Text, notifyPreviewLimit)
			}
		case EntryAssistant:
			if end != moodFailed && m.notifyMode == notifyOn {
				return notifyText(replyPreview(e.Text), notifyPreviewLimit)
			}
		}
	}
	return ""
}

// replyPreview is the first line of a reply without its leading Markdown
// block marks or inline emphasis.
func replyPreview(text string) string {
	line := strings.TrimLeft(firstLine(text), "#>*-+ ")
	return strings.NewReplacer("**", "", "__", "", "`", "").Replace(line)
}

// notifyText makes untrusted text one safe OSC 777 field: escape sequences and
// control runes go, ";" (the field separator) becomes ",", and the markup
// characters become lookalikes. It is cut to limit cells.
//
// Entities cannot be used: each ends in ";", the field separator, and servers
// parse a bare "&lt" differently (Pango rejects it, others show it literally).
// The lookalikes are mapped before truncation so the limit counts their width.
var notifyReplacer = strings.NewReplacer(";", ",", "&", "＆", "<", "‹", ">", "›")

func notifyText(text string, limit int) string {
	text = titleText(oneLine(ansi.Strip(text)), 0)
	return ansi.Truncate(notifyReplacer.Replace(text), limit, "…")
}

// notificationSequence is the OSC 777 notification and a bell. Inside tmux
// the OSC is wrapped for passthrough (allow-passthrough must be on); the bell
// stays outside, where tmux applies its own bell handling.
func notificationSequence(title, body string, tmux bool) string {
	osc := "\x1b]777;notify;" + title + ";" + body + "\x1b\\"
	if tmux {
		osc = "\x1bPtmux;" + strings.ReplaceAll(osc, "\x1b", "\x1b\x1b") + "\x1b\\"
	}
	return osc + "\a"
}
