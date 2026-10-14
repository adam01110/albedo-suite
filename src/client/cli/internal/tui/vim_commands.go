package tui

import (
	tea "charm.land/bubbletea/v2"
	"strings"
)

type vimCommand func(*ChatModel, vimInput, vimSnapshot, tea.KeyPressMsg) tea.Cmd

var vimCommands = map[string]vimCommand{
	"i": vimInsertHere, "a": vimInsertAfter, "I": vimInsertFirst, "A": vimInsertEnd,
	"o": vimOpenLine, "O": vimOpenLine,
	"d": vimStartOperator, "c": vimStartOperator, "y": vimStartOperator, "g": vimStartOperator,
	"x": vimDeleteCharacter, "X": vimDeleteCharacter,
	"D": vimDeleteToEnd, "C": vimDeleteToEnd,
	"p": vimPaste, "P": vimPaste, "u": vimUndo, "/": vimCommandMenu,
}

func vimInsertHere(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	m.vimBeginInsert(before)
	return nil
}
func vimInsertAfter(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	_, end := vimBounds([]rune(before.text), before.pos)
	m.vimPosition(min(end, before.pos+1))
	m.vimBeginInsert(before)
	return nil
}
func vimInsertFirst(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	m.vimPosition(vimFirstNonblank([]rune(before.text), before.pos))
	m.vimBeginInsert(before)
	return nil
}
func vimInsertEnd(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	_, end := vimBounds([]rune(before.text), before.pos)
	m.vimPosition(end)
	m.vimBeginInsert(before)
	return nil
}
func vimOpenLine(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	start, end := vimBounds([]rune(before.text), before.pos)
	at := end
	if input.key == "O" {
		at = start
	}
	m.vimPosition(at)
	m.TextArea.InsertString("\n")
	if input.key == "O" {
		m.vimPosition(at)
	}
	m.syncLayout()
	m.vimBeginInsert(before)
	return nil
}
func vimStartOperator(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	m.vim.pending, m.vim.operatorCount = input.key, input.rawCount
	return nil
}
func vimDeleteCharacter(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	start, end := vimBounds([]rune(before.text), before.pos)
	a, b := before.pos, min(end, before.pos+input.count)
	if input.key == "X" {
		a, b = max(start, before.pos-input.count), before.pos
	}
	m.vimDelete(a, b)
	m.vimRemember(before)
	return nil
}
func vimDeleteToEnd(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	text := []rune(before.text)
	target, _ := vimMotion(text, before.pos, "$", input.count)
	_, end := vimBounds(text, target)
	m.vimDelete(before.pos, end)
	if input.key == "C" {
		m.vimBeginInsert(before)
	} else {
		m.vimRemember(before)
	}
	return nil
}
func vimPaste(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	if m.vim.register == "" && !m.vim.linewise {
		return nil
	}
	start, end := vimBounds([]rune(before.text), before.pos)
	at := before.pos
	if input.key == "p" {
		at = min(end, before.pos+1)
	}
	value := strings.Repeat(m.vim.register, input.count)
	cursor := at + len([]rune(value)) - 1
	if m.vim.linewise {
		value = strings.TrimSuffix(strings.Repeat(m.vim.register+"\n", input.count), "\n")
		if input.key == "p" {
			at = end
			value = "\n" + value
			cursor = at + 1
		} else {
			at = start
			value += "\n"
			cursor = at
		}
	}
	m.vimPosition(at)
	m.TextArea.InsertString(value)
	m.vimPosition(cursor)
	m.vimRemember(before)
	m.syncLayout()
	return nil
}
func vimUndo(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	m.vimHistory(input.count, false)
	return nil
}
func vimCommandMenu(m *ChatModel, input vimInput, before vimSnapshot, msg tea.KeyPressMsg) tea.Cmd {
	m.vimPosition(0)
	m.vimBeginInsert(before)
	return m.updateComposer(msg, nil)
}
func (m *ChatModel) vimRemember(s vimSnapshot) {
	if s.text == m.TextArea.Value() {
		return
	}
	m.vim.undo = append(m.vim.undo, s)
	if len(m.vim.undo) > 100 {
		m.vim.undo = m.vim.undo[1:]
	}
	m.vim.redo = nil
}

func (m *ChatModel) vimRestore(s vimSnapshot) {
	m.TextArea.SetValue(s.text)
	m.vimPosition(s.pos)
	m.syncLayout()
}

func (m *ChatModel) vimHistory(count int, redo bool) {
	source, destination := &m.vim.undo, &m.vim.redo
	if redo {
		source, destination = destination, source
	}
	for range count {
		n := len(*source)
		if n == 0 {
			break
		}
		*destination = append(*destination, m.vimSnapshot())
		m.vimRestore((*source)[n-1])
		*source = (*source)[:n-1]
	}
}

// Expand edits that intersect attachment markers so their payload stays atomic.
func (m *ChatModel) vimDelete(start, end int) {
	if start == end {
		return
	}
	text := []rune(m.TextArea.Value())
	offset := 0
	for _, line := range strings.Split(string(text), "\n") {
		for _, span := range anyMarker.FindAllStringIndex(line, -1) {
			a := offset + len([]rune(line[:span[0]]))
			b := offset + len([]rune(line[:span[1]]))
			if start < b && end > a {
				start = min(start, a)
				end = max(end, b)
			}
		}
		offset += len([]rune(line)) + 1
	}
	m.vim.register = string(text[start:end])
	m.vim.linewise = false
	m.TextArea.SetValue(string(text[:start]) + string(text[end:]))
	m.vimPosition(start)
	m.syncLayout()
}

func (m *ChatModel) vimApplyOperator(operator string, span vimRange, before vimSnapshot) {
	if operator == "y" {
		m.vim.register, m.vim.linewise = span.register, span.linewise
		return
	}
	m.vimDelete(span.start, span.end)
	if span.linewise {
		m.vim.register, m.vim.linewise = span.register, true
	}
	if operator == "c" {
		m.vimBeginInsert(before)
	} else {
		m.vimRemember(before)
	}
}
