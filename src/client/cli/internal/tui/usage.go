package tui

import (
	"context"
	"errors"
	"net/url"
	"time"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
)

// usageDays is how far back the screen reads: the week it lists by day.
const usageDays = 7

type UsageCancelMsg struct{}

// usageError is a failed read in the words the footer can show.
type usageError struct{ cause error }

func (e usageError) Error() string { return usageFailure(e.cause) }
func (e usageError) Unwrap() error { return e.cause }

type usageLoadedMsg struct {
	Err error
	// Today is the day alone, for its total and its lines; Week is the last
	// usageDays days, asked before it, for the days behind today.
	Today, Week daemon.UsageSummary
	Gen         int
}

// UsageModel shows what the provider calls used today by model, and each of
// the last days in total, with the highlighted row's breakdown beside it.
type UsageModel struct {
	Conn        *daemon.Connection
	today, week daemon.UsageSummary
	tab         usageTab
	profile     usageProfile
	pageStatus
	listView
}

func NewUsageModel(conn *daemon.Connection) UsageModel {
	return UsageModel{
		Conn:       conn,
		pageStatus: newPageStatus(true),
		listView:   newListView("Search models and days"),
	}
}

func (m *UsageModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.setSize(width, height)
}

func (m UsageModel) Init() tea.Cmd { return m.loadCmd(m.Generation) }

func (m UsageModel) load() (UsageModel, tea.Cmd) {
	m.Loading, m.Error = true, ""
	m.Generation = nextPageGeneration()
	return m, m.loadCmd(m.Generation)
}

func (m UsageModel) loadCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return usageLoadedMsg{Err: errors.New(usageUnreachable), Gen: gen}
		}
		_, seconds := time.Now().Zone()
		// A day is the terminal's own, so the daemon is told how far ahead of
		// UTC this clock runs and counts the days from there; both reads ask
		// under that one offset, so a day means the same in either answer.
		offset := seconds / 60
		// The week goes first and the day after it, so the day is never behind
		// the week: the later answer names today with its total and its lines,
		// which is one snapshot, while the week has the closed days behind it
		// even when midnight fell between the two reads.
		week, err := daemon.GetUsage(context.Background(), m.Conn, daemon.UsageQuery{Days: usageDays, UTCOffsetMinutes: offset})
		if err != nil {
			return usageLoadedMsg{Err: usageError{err}, Gen: gen}
		}
		today, err := daemon.GetUsage(context.Background(), m.Conn, daemon.UsageQuery{Days: 1, UTCOffsetMinutes: offset})
		if err != nil {
			return usageLoadedMsg{Err: usageError{err}, Gen: gen}
		}
		return usageLoadedMsg{Today: today, Week: week, Gen: gen}
	}
}

// usageUnreachable is a read that could not reach the daemon at all, in the
// words every screen gives a connection that is not there.
const usageUnreachable = "daemon connection unavailable"

// usageFailure is why a read failed, in the words a footer has room for. A dial
// that fails is said the way every screen says it, without the URL and socket
// the transport's sentence would name; the daemon's own message is written to be
// read, so it is shown as it comes.
func usageFailure(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, context.DeadlineExceeded):
		return "the daemon didn't answer in time"
	}
	if _, dial := errors.AsType[*url.Error](err); dial {
		return usageUnreachable
	}
	if _, garbled := errors.AsType[*daemon.ProtocolError](err); garbled {
		return "couldn't read what the daemon answered"
	}
	return err.Error()
}

func (m UsageModel) Update(msg tea.Msg) (UsageModel, tea.Cmd) {
	switch msg := msg.(type) {
	case usageLoadedMsg:
		// A failed read keeps the rows it last drew, so the screen says why and
		// how old they are rather than going blank.
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.today, m.week = msg.Today, msg.Week
		m.setRows(m.rows())
		return m, nil

	case usageYearMsg:
		m = m.settleYear(msg)
		return m, nil

	case tea.KeyPressMsg:
		switch msg.String() {
		case "esc", "ctrl+c":
			return m, func() tea.Msg { return UsageCancelMsg{} }
		case "ctrl+r":
			if !m.Loading {
				m, cmd := m.load()
				return m.withYear(cmd, true)
			}
			return m, nil
		case "tab", "shift+tab":
			m.tab = 1 - m.tab
			return m.withYear(nil, false)
		}
		if m.tab == usageProfileTab {
			m.profile = m.profile.key(msg.String(), m.Width)
			return m, nil
		}
	}
	cmd := m.update(msg)
	return m, cmd
}
