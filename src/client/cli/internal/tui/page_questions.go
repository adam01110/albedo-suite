package tui

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"slices"
	"strings"

	"charm.land/bubbles/v2/textarea"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type questionDraft struct {
	text             string
	selected, scroll int
}

type questionAnswerList struct {
	listView
	row      PageRow
	action   PageAction
	options  []string
	question string
	scroll   int
	editor   textarea.Model
}

func (m *PageViewModel) saveQuestionDraft() {
	if q := m.questionAnswers; q != nil {
		if m.questionDrafts == nil {
			m.questionDrafts = make(map[string]questionDraft)
		}
		m.questionDrafts[q.row.ID] = questionDraft{q.editor.Value(), q.Cursor, q.scroll}
	}
}

func (m *PageViewModel) pruneQuestionDrafts() {
	if m.Command != "/questions" || m.Doc == nil {
		return
	}
	for id := range m.questionDrafts {
		if !slices.ContainsFunc(m.Doc.Rows, func(row PageRow) bool { return row.ID == id }) {
			delete(m.questionDrafts, id)
		}
	}
}

func (m *PageViewModel) openQuestionAnswers() tea.Cmd {
	row := m.currentRow()
	if row == nil {
		return nil
	}
	return m.openQuestionRow(*row, *m.CurrentAction)
}

func (m *PageViewModel) openQuestionRow(row PageRow, action PageAction) tea.Cmd {
	prompt, err := daemon.QuestionPromptForRow(&row, m.SessionID)
	if err != nil {
		m.Error = err.Error()
		return nil
	}
	m.saveQuestionDraft()
	q := &questionAnswerList{listView: newListView(""), row: row, action: action, options: prompt.Options, question: prompt.Text}
	entries := make([]listEntry, 0, len(q.options)+1)
	for i, option := range q.options {
		entries = append(entries, listEntry{key: fmt.Sprint(i), name: fmt.Sprintf("%d. %s", i+1, oneLine(ansi.Strip(option)))})
	}
	entries = append(entries, listEntry{key: "custom", name: "Write your own answer"})
	q.setRows(entries)
	draft := m.questionDrafts[row.ID]
	q.Cursor, q.scroll = min(draft.selected, len(q.options)), draft.scroll
	q.editor = textarea.New()
	q.editor.Prompt, q.editor.Placeholder = "> ", "Write an answer. Enter adds a line."
	q.editor.ShowLineNumbers, q.editor.CharLimit = false, 8192
	q.editor.SetValue(draft.text)
	styles := q.editor.Styles()
	styles.Cursor.Blink = false
	q.editor.SetStyles(styles)
	m.questionAnswers, m.CurrentAction = q, &q.action
	m.Mode, m.Error, m.FieldIndex = modeQuestionAnswers, "", 0
	m.FormValues = nil
	m.fitQuestionEditor()
	if len(q.options) == 0 {
		return m.editQuestionAnswer(false)
	}
	return nil
}

func (m *PageViewModel) fitQuestionEditor() {
	if q := m.questionAnswers; q != nil {
		width := m.Width
		if width >= 100 {
			width -= 28 + ansi.StringWidth(svSep())
		}
		q.editor.SetWidth(max(1, width-4))
		q.editor.SetHeight(max(1, min(6, m.Height-12)))
		q.setSize(width, m.Height)
	}
}

func (m *PageViewModel) editQuestionAnswer(suggestion bool) tea.Cmd {
	q := m.questionAnswers
	if suggestion && q.Cursor < len(q.options) {
		q.editor.SetValue(q.options[q.Cursor])
	}
	m.Mode, m.Error = modeText, ""
	m.fitQuestionEditor()
	return q.editor.Focus()
}

func (m *PageViewModel) submitQuestionAnswer(answer string) tea.Cmd {
	if strings.TrimSpace(answer) == "" {
		m.Error = "Enter an answer before submitting"
		return nil
	}
	if len(answer) > 8192 {
		m.Error = "Answer exceeds 8192 bytes; shorten it before submitting"
		return nil
	}
	m.saveQuestionDraft()
	return m.runAction(m.questionAnswers.action, answer)
}

func (m PageViewModel) questionAnswerKey(msg tea.KeyPressMsg) (PageViewModel, tea.Cmd) {
	q := m.questionAnswers
	if q == nil {
		m.cancelPrompt()
		return m, nil
	}
	if m.Mode == modeConfirm {
		if m.confirm.key(msg) {
			act := *m.CurrentAction
			m.confirm.dismiss()
			cmd := m.runAction(act, "")
			return m, cmd
		}
		if !m.confirm.asking() {
			m.Mode, m.CurrentAction = modeQuestionAnswers, &q.action
		}
		return m, nil
	}
	if m.Busy {
		return m, nil
	}
	switch msg.String() {
	case "esc", "ctrl+c":
		m.saveQuestionDraft()
		if m.Mode == modeText && len(q.options) > 0 {
			m.Mode = modeQuestionAnswers
			q.editor.Blur()
		} else {
			m.cancelPrompt()
		}
		return m, nil
	case "tab", "shift+tab":
		index := slices.IndexFunc(m.Doc.Rows, func(row PageRow) bool { return row.ID == q.row.ID })
		delta := 1
		if msg.String() == "shift+tab" {
			delta = -1
		}
		if len(m.Doc.Rows) > 0 {
			index = (max(0, index) + delta + len(m.Doc.Rows)) % len(m.Doc.Rows)
			cmd := m.openQuestionRow(m.Doc.Rows[index], q.action)
			return m, cmd
		}
		return m, nil
	case "ctrl+up":
		q.scroll = max(0, q.scroll-1)
		return m, nil
	case "ctrl+down":
		q.scroll = min(q.scroll+1, max(0, len(questionWrapped(q.question, q.editor.Width()))-1))
		return m, nil
	case "ctrl+d":
		for _, action := range m.Doc.Actions {
			if action.Operation.OperationID == "dismissQuestion" {
				m.saveQuestionDraft()
				m.Mode, m.CurrentAction = modeConfirm, &action
				m.confirm.ask(action.ID, " "+rowID(q.row), action.Label, action.Confirmation)
				return m, nil
			}
		}
		return m, nil
	}
	if m.Mode == modeText {
		if msg.String() == "ctrl+enter" || msg.String() == "ctrl+s" {
			cmd := m.submitQuestionAnswer(q.editor.Value())
			return m, cmd
		}
		var cmd tea.Cmd
		q.editor, cmd = q.editor.Update(msg)
		m.saveQuestionDraft()
		return m, cmd
	}
	switch msg.String() {
	case "up", "k", "ctrl+p":
		q.move(-1)
	case "down", "j", "ctrl+n":
		q.move(1)
	case "pgup":
		q.move(-max(1, m.Height/2))
	case "pgdown":
		q.move(max(1, m.Height/2))
	case "home":
		q.Cursor = 0
	case "end":
		q.Cursor = len(q.options)
	case "e":
		cmd := m.editQuestionAnswer(true)
		return m, cmd
	case "ctrl+e":
		cmd := m.editQuestionAnswer(false)
		return m, cmd
	case "enter", "l":
		if q.Cursor == len(q.options) {
			cmd := m.editQuestionAnswer(false)
			return m, cmd
		}
		cmd := m.submitQuestionAnswer(q.options[q.Cursor])
		return m, cmd
	default:
		if len(msg.Text) == 1 && msg.Text[0] >= '1' && msg.Text[0] <= '9' {
			index := int(msg.Text[0] - '1')
			if index < len(q.options) {
				q.Cursor = index
			}
		}
	}
	m.saveQuestionDraft()
	return m, nil
}

func (m *PageViewModel) updateQuestionEditor(msg tea.Msg) tea.Cmd {
	var cmd tea.Cmd
	m.questionAnswers.editor, cmd = m.questionAnswers.editor.Update(msg)
	m.saveQuestionDraft()
	return cmd
}

func questionWrapped(text string, width int) []string {
	var rows []string
	for _, line := range strings.Split(ansi.Strip(text), "\n") {
		rows = append(rows, strings.Split(ansi.Wrap(oneLine(line), max(1, width), " -"), "\n")...)
	}
	return rows
}

func (m PageViewModel) questionAnswerView() string {
	q := m.questionAnswers
	index := slices.IndexFunc(m.Doc.Rows, func(row PageRow) bool { return row.ID == q.row.ID })
	status, urgent := m.status()
	hints := []hint{{"↑↓", "choose"}, {"enter", "submit"}, {"tab", "next question"}, {"e", "edit"}, {"ctrl+d", "dismiss"}, {"esc", "back"}}
	if m.Mode == modeText {
		hints = []hint{{"ctrl+enter", "submit"}, {"enter", "new line"}, {"tab", "next question"}, {"esc", "back"}}
	}
	footer := footerLine(m.Width, hints, status, urgent)
	if m.Mode == modeConfirm {
		footer = m.confirm.footer(m.Width, m.Error)
	}
	frame := listFrame{
		title: brand("albedo") + " " + DefaultStyles.Muted.Render("/questions"),
		right: DefaultStyles.Faint.Render(fmt.Sprintf("%d/%d · %d pending", max(0, index)+1, len(m.Doc.Rows), len(m.Doc.Rows))),
		list:  m.questionWorkspaceRows, footer: footer,
	}
	return frame.view(m.Width, m.Height)
}

func (m PageViewModel) questionWorkspaceRows(width, height int) []string {
	if width < 100 {
		return m.questionContentRows(width, height)
	}
	const railWidth = 28
	queue := newListView("")
	entries := make([]listEntry, 0, len(m.Doc.Rows))
	for _, row := range m.Doc.Rows {
		text := m.questionDrafts[row.ID].text
		if row.ID == m.questionAnswers.row.ID {
			text = m.questionAnswers.editor.Value()
		}
		tag := ""
		if strings.TrimSpace(text) != "" {
			tag = "draft"
		}
		entries = append(entries, listEntry{key: row.ID, name: oneLine(ansi.Strip(row.Text)), tag: DefaultStyles.Faint.Render(tag)})
	}
	queue.setRows(entries)
	queue.Cursor = max(0, slices.IndexFunc(m.Doc.Rows, func(row PageRow) bool { return row.ID == m.questionAnswers.row.ID }))
	rail := append([]string{DefaultStyles.Bold.Render(" Pending questions")}, queue.list(railWidth, max(1, height-1))...)
	body := m.questionContentRows(width-railWidth-ansi.StringWidth(svSep()), height)
	rows := make([]string, height)
	for i := range height {
		left := ansi.Truncate(rail[i], railWidth, "…")
		left += strings.Repeat(" ", max(0, railWidth-ansi.StringWidth(left)))
		rows[i] = left + svSep() + body[i]
	}
	return rows
}

func (m PageViewModel) questionContentRows(width, height int) []string {
	q := m.questionAnswers
	inner := max(1, width-4)
	question := questionWrapped(q.question, inner)
	shown := max(1, min(6, height/4))
	offset := min(q.scroll, max(0, len(question)-shown))
	label := "Question " + rowID(q.row)
	if len(question) > shown {
		label += fmt.Sprintf(" · %d–%d/%d · ctrl+↑↓ scroll", offset+1, min(len(question), offset+shown), len(question))
	}
	rows := []string{" " + DefaultStyles.Bold.Render(ansi.Truncate(label, inner, "…"))}
	for _, line := range question[offset:min(len(question), offset+shown)] {
		rows = append(rows, " "+line)
	}
	if height >= 9 {
		rows = append(rows, "")
	}
	if m.Mode == modeText {
		rows = append(rows, " "+DefaultStyles.Muted.Render(fmt.Sprintf("Your answer · %d/8192 bytes", len(q.editor.Value()))))
		editor := q.editor
		editor.SetWidth(inner)
		editor.SetHeight(max(1, min(6, height-len(rows))))
		for _, line := range strings.Split(editor.View(), "\n") {
			rows = append(rows, " "+line)
		}
	} else {
		rows = append(rows, " "+DefaultStyles.Muted.Render("Suggested answers"))
		preview := 0
		if height >= 14 {
			preview = 4
		}
		optionsHeight := max(1, min(len(q.rows), height-len(rows)-preview))
		rows = append(rows, q.listView.list(width, optionsHeight)...)
		if preview > 0 {
			text := q.editor.Value()
			title := "Custom draft"
			if q.Cursor < len(q.options) {
				text, title = q.options[q.Cursor], "Answer preview · e to edit"
			}
			if text == "" {
				text = "Write a different answer with ctrl+e."
			}
			rows = append(rows, " "+DefaultStyles.Faint.Render(title))
			for _, line := range svWrap(ansi.Strip(text), inner, preview-1) {
				rows = append(rows, " "+DefaultStyles.Muted.Render(line))
			}
		}
	}
	rows = rows[:min(len(rows), height)]
	rows = append(rows, make([]string, max(0, height-len(rows)))...)
	for i, line := range rows {
		rows[i] = ansi.Truncate(line, max(1, width), "…")
	}
	return rows
}
