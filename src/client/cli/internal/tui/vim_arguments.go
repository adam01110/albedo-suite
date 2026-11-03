package tui

import (
	tea "charm.land/bubbletea/v2"
	"unicode"
)

// Capture literal arguments before parsing counts or normal-mode commands.
func (m *ChatModel) vimAwaitArgument(input vimInput) (tea.Cmd, bool) {
	key := input.key
	if input.operator != "" && input.operator != "d" && input.operator != "c" && input.operator != "y" {
		return nil, false
	}
	if key == ";" || key == "," {
		if m.vim.lastFind != "" {
			input.key = m.vim.lastFind
			if key == "," {
				input.key = map[string]string{"f": "F", "F": "f", "t": "T", "T": "t"}[input.key]
			}
			return m.vimFind(input, m.vim.lastChar, true), true
		}
		return nil, true
	}
	if key == "f" || key == "F" || key == "t" || key == "T" || (input.operator == "" && key == "r") || (input.operator != "" && (key == "i" || key == "a")) {
		m.vim.argument = &input
		return nil, true
	}
	return nil, false
}

func (m *ChatModel) vimArgument(input vimInput, key string) tea.Cmd {
	chars := []rune(key)
	if len(chars) != 1 {
		return nil
	}
	if input.key == "i" || input.key == "a" {
		before := m.vimSnapshot()
		if span, ok := vimTextObject([]rune(before.text), before.pos, chars[0], input.key == "a", input.count); ok {
			return m.vimApplyOperator(input.operator, span, before)
		}
		return nil
	}
	if input.key == "r" {
		before := m.vimSnapshot()
		_, end := vimBounds([]rune(before.text), before.pos)
		if end-before.pos < input.count {
			return nil
		}
		text := []rune(before.text)
		for i := before.pos; i < before.pos+input.count; i++ {
			text[i] = chars[0]
		}
		m.TextArea.SetValue(string(text))
		m.vimPosition(before.pos + input.count - 1)
		m.vimRemember(before)
		m.syncLayout()
		return nil
	}
	return m.vimFind(input, chars[0], false)
}

func (m *ChatModel) vimFind(input vimInput, char rune, repeat bool) tea.Cmd {
	before := m.vimSnapshot()
	text := []rune(before.text)
	start, end := vimBounds(text, before.pos)
	direction := 1
	if input.key == "F" || input.key == "T" {
		direction = -1
	}
	target := before.pos
	if repeat && (input.key == "t" || input.key == "T") {
		target += direction
	}
	for range input.count {
		target += direction
		for target >= start && target < end && text[target] != char {
			target += direction
		}
		if target < start || target >= end {
			return nil
		}
	}
	if !repeat {
		m.vim.lastFind, m.vim.lastChar = input.key, char
	}
	if input.key == "t" || input.key == "T" {
		target -= direction
	}
	if input.operator == "" {
		m.vimPosition(target)
		return nil
	}
	a, b := min(before.pos, target), max(before.pos, target)
	if direction > 0 {
		b++
	}
	// Backward find is inclusive; backward till excludes the current character.
	if input.key == "F" {
		b++
	}
	if a == b {
		return nil
	}
	return m.vimApplyOperator(input.operator, vimRange{a, b, false, string(text[a:b])}, before)
}

func vimTextObject(text []rune, pos int, object rune, around bool, count int) (vimRange, bool) {
	if pos >= len(text) {
		return vimRange{}, false
	}
	a, b := pos, pos
	if object == 'w' || object == 'W' {
		class := func(r rune) int {
			if object == 'W' && !unicode.IsSpace(r) {
				return 1
			}
			return vimClass(r)
		}
		c := class(text[pos])
		for a > 0 && class(text[a-1]) == c {
			a--
		}
		b = pos + 1
		for b < len(text) && class(text[b]) == c {
			b++
		}
		for range count - 1 {
			for b < len(text) && unicode.IsSpace(text[b]) {
				b++
			}
			if b == len(text) {
				break
			}
			c = class(text[b])
			for b < len(text) && class(text[b]) == c {
				b++
			}
		}
		if around && class(text[pos]) == 0 && b < len(text) {
			c = class(text[b])
			for b < len(text) && class(text[b]) == c {
				b++
			}
		} else if around {
			old := b
			for b < len(text) && unicode.IsSpace(text[b]) {
				b++
			}
			if b == old {
				for a > 0 && unicode.IsSpace(text[a-1]) {
					a--
				}
			}
		}
	} else {
		pairs := map[rune][2]rune{'(': {'(', ')'}, ')': {'(', ')'}, 'b': {'(', ')'}, '[': {'[', ']'}, ']': {'[', ']'}, '{': {'{', '}'}, '}': {'{', '}'}, 'B': {'{', '}'}, '<': {'<', '>'}, '>': {'<', '>'}, '\'': {'\'', '\''}, '"': {'"', '"'}, '`': {'`', '`'}}
		pair, ok := pairs[object]
		if !ok {
			return vimRange{}, false
		}
		if pair[0] == pair[1] {
			if count != 1 {
				return vimRange{}, false
			}
			start, end := vimBounds(text, pos)
			a, b = -1, -1
			for i := start; i < end; i++ {
				if text[i] != pair[0] || (i > start && text[i-1] == '\\') {
					continue
				}
				if a == -1 {
					a = i
				} else {
					b = i
					if pos <= b {
						break
					}
					a, b = -1, -1
				}
			}
			if a < 0 || b < 0 {
				return vimRange{}, false
			}
		} else {
			// A stack finds the innermost containing pair, then counted outer pairs.
			stack := []int{}
			a, b = -1, -1
			for i, r := range text {
				if r == pair[0] {
					stack = append(stack, i)
				}
				if r == pair[1] && len(stack) > 0 {
					left := stack[len(stack)-1]
					stack = stack[:len(stack)-1]
					if left <= pos && pos <= i {
						count--
						if count == 0 {
							a, b = left, i
							break
						}
					}
				}
			}
			if a < 0 {
				return vimRange{}, false
			}
		}
		if around {
			b++
		} else {
			a++
		}
	}
	return vimRange{a, b, false, string(text[a:b])}, true
}
