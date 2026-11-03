package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type questionAnswerList struct {
	listView
	row     PageRow
	options []string
}

func (m *PageViewModel) openQuestionAnswers() tea.Cmd {
	row := m.currentRow()
	prompt, err := daemon.QuestionPromptForRow(row, m.SessionID)
	if err != nil {
		m.Error, m.Mode = err.Error(), modeBrowse
		return nil
	}
	options := prompt.Options
	if len(options) == 0 {
		m.Mode = modeText
		m.fitInput()
		return ask(&m.TextInput, "", false)
	}
	answers := &questionAnswerList{listView: newListView(""), row: *row, options: options}
	detailRow := *row
	detailRow.Text, detailRow.Detail = "Question "+rowID(*row), ansi.Strip(prompt.Text)
	rows := make([]listEntry, 0, len(options)+1)
	for i, option := range options {
		rows = append(rows, listEntry{
			key: fmt.Sprint(i), name: fmt.Sprintf("%d. %s", i+1, oneLine(ansi.Strip(option))),
			detail: func(width int) []string {
				lines := paneTitle("Selected answer", "", width)
				for _, paragraph := range strings.Split(ansi.Strip(option), "\n") {
					lines = append(lines, strings.Split(ansi.Wrap(oneLine(paragraph), width, " -"), "\n")...)
				}
				return append(append(lines, ""), pageDetail(detailRow, width)...)
			},
		})
	}
	rows = append(rows, listEntry{
		key: "custom", name: "Type your own answer", desc: "free text",
		detail: func(width int) []string { return pageDetail(detailRow, width) },
	})
	answers.setRows(rows)
	answers.setSize(m.Width, m.Height)
	m.questionAnswers, m.Mode = answers, modeQuestionAnswers
	return nil
}

func (m PageViewModel) questionAnswerKey(msg tea.KeyPressMsg) (PageViewModel, tea.Cmd) {
	answers := m.questionAnswers
	if answers == nil {
		m.cancelPrompt()
		return m, nil
	}
	switch msg.String() {
	case "up", "k", "ctrl+p":
		answers.move(-1)
	case "down", "j", "ctrl+n":
		answers.move(1)
	case "pgup":
		answers.move(-max(1, m.Height/2))
	case "pgdown":
		answers.move(max(1, m.Height/2))
	case "home":
		answers.Cursor = 0
	case "end":
		answers.Cursor = len(answers.options)
	case "ctrl+e":
		m.Mode = modeText
		m.fitInput()
		return m, ask(&m.TextInput, m.TextInput.Value(), false)
	case "enter", "l":
		if answers.Cursor == len(answers.options) {
			m.Mode = modeText
			m.fitInput()
			return m, ask(&m.TextInput, m.TextInput.Value(), false)
		}
		cmd := m.runAction(*m.CurrentAction, answers.options[answers.Cursor])
		return m, cmd
	default:
		if len(msg.Text) == 1 && msg.Text[0] >= '1' && msg.Text[0] <= '9' {
			index := int(msg.Text[0] - '1')
			if index < len(answers.options) {
				answers.Cursor = index
			}
		}
	}
	return m, nil
}

func (m PageViewModel) questionAnswerView() string {
	answers := m.questionAnswers
	status, urgent := m.status()
	footer := footerLine(m.Width, []hint{{"↑↓", "choose"}, {"enter", "submit"}, {"ctrl+e", "custom"}, {"esc", "back"}}, status, urgent)
	frame := answers.frame(brand("albedo")+" "+DefaultStyles.Muted.Render("/questions · answer "+rowID(answers.row)), "", footer)
	frame.filter = ""
	frame.summary = oneLine(ansi.Strip(answers.row.Text))
	return frame.view(m.Width, m.Height)
}
