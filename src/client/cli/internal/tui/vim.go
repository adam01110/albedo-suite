package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
)

type vimSnapshot struct {
	text string
	pos  int
}
type vimState struct {
	normal        bool
	count         int
	operatorCount int
	pending       string
	undo, redo    []vimSnapshot
	insert        *vimSnapshot
	register      string
	linewise      bool
}

func (m ChatModel) vimMode() string {
	if m.vim.normal {
		return "NORMAL"
	}
	return "INSERT"
}

func (m ChatModel) vimSnapshot() vimSnapshot {
	lines := strings.Split(m.TextArea.Value(), "\n")
	pos := m.TextArea.Column()
	for _, line := range lines[:m.TextArea.Line()] {
		pos += len([]rune(line)) + 1
	}
	return vimSnapshot{m.TextArea.Value(), pos}
}

func (m *ChatModel) vimPosition(pos int) {
	text := []rune(m.TextArea.Value())
	pos = max(0, min(pos, len(text)))
	row, col := 0, 0
	for _, r := range text[:pos] {
		if r == '\n' {
			row++
			col = 0
		} else {
			col++
		}
	}
	m.TextArea, _ = m.TextArea.Update(tea.KeyPressMsg{Code: tea.KeyHome, Mod: tea.ModCtrl})
	for m.TextArea.Line() < row {
		m.TextArea.CursorDown()
	}
	m.TextArea.SetCursorColumn(col)
}

func (m *ChatModel) vimClamp() {
	s := m.vimSnapshot()
	start, end := vimBounds([]rune(s.text), s.pos)
	m.vimPosition(min(s.pos, max(start, end-1)))
}

func vimBounds(text []rune, pos int) (int, int) {
	start, end := pos, pos
	for start > 0 && text[start-1] != '\n' {
		start--
	}
	for end < len(text) && text[end] != '\n' {
		end++
	}
	return start, end
}

func (m *ChatModel) vimBeginInsert(before vimSnapshot) {
	m.vim.normal = false
	m.vim.insert = &before
}

func (m *ChatModel) vimEndInsert() {
	if m.vim.insert != nil {
		m.vimRemember(*m.vim.insert)
		m.vim.insert = nil
	}
	m.vim.normal = true
	m.TextArea.SetCursorColumn(max(0, m.TextArea.Column()-1))
	m.vimClamp()
}

type vimInput struct {
	key      string
	count    int
	rawCount int
	explicit bool
	operator string
}

func (v *vimState) resetInput() {
	v.pending, v.count, v.operatorCount = "", 0, 0
}

func (v *vimState) accumulateCount(key string) bool {
	if len(key) != 1 || key[0] < '0' || key[0] > '9' || (key == "0" && v.count == 0) {
		return false
	}
	v.count = min(999, v.count*10+int(key[0]-'0'))
	return true
}

func (v *vimState) takeInput(key string) vimInput {
	input := vimInput{key: key, count: max(1, v.count), rawCount: v.count, explicit: v.count > 0 || v.operatorCount > 0, operator: v.pending}
	if input.operator != "" {
		input.count = min(999, input.count*max(1, v.operatorCount))
	}
	v.resetInput()
	return input
}

var vimPassthroughKeys = map[string]bool{
	"enter": true, "shift+enter": true, "left": true, "right": true,
	"up": true, "down": true, "pgup": true, "pgdown": true,
}

func (m *ChatModel) handleVim(msg tea.KeyPressMsg) (tea.Cmd, bool) {
	key := msg.String()
	if !m.vim.normal {
		if key != "esc" || len(m.CommandMenu.Matches(m.TextArea.Value())) > 0 || m.isSending || m.Status.Running || len(m.pendingUsers) > 0 {
			return nil, false
		}
		m.vimEndInsert()
		return nil, true
	}
	if len(m.CommandMenu.Matches(m.TextArea.Value())) > 0 {
		return nil, false
	}
	m.vimClamp()
	defer func() {
		if m.vim.normal {
			m.vimClamp()
		}
	}()
	if key == "ctrl+r" {
		count := max(1, m.vim.count)
		m.vim.resetInput()
		m.vimHistory(count, true)
		return nil, true
	}
	if key == "esc" || msg.Mod & ^tea.ModShift != 0 || vimPassthroughKeys[key] {
		m.vim.resetInput()
		return nil, false
	}
	if m.vim.accumulateCount(key) {
		return nil, true
	}
	input := m.vim.takeInput(key)
	if m.vimPending(input) {
		return nil, true
	}
	before := m.vimSnapshot()
	if command, ok := vimCommands[key]; ok {
		return command(m, input, before, msg), true
	}
	count := input.count
	if motion := vimMotions[key]; motion.absolute && !input.explicit {
		count = 0
	}
	if target, ok := vimMotion([]rune(before.text), before.pos, key, count); ok {
		m.vimPosition(target)
	}
	return nil, true
}

func (m *ChatModel) vimPending(input vimInput) bool {
	pending := input.operator
	if pending == "" {
		return false
	}
	if pending == "g" {
		if input.key == "g" {
			m.vimPosition(vimLineTarget([]rune(m.TextArea.Value()), "gg", input.count))
		}
		return true
	}
	if len(pending) == 2 {
		if input.key != "g" {
			return true
		}
		input.operator, input.key = pending[:1], "gg"
	}
	if input.key == "g" {
		m.vim.pending = input.operator + "g"
		if input.explicit {
			m.vim.operatorCount = input.count
		}
		return true
	}
	before := m.vimSnapshot()
	if span, ok := vimOperatorRange([]rune(before.text), before.pos, input); ok {
		m.vimApplyOperator(input.operator, span, before)
	}
	return true
}
