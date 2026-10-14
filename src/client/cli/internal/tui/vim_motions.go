package tui

import (
	"strings"
	"unicode"
)

type vimMotionSpec struct {
	step      func([]rune, int) int
	resolve   func([]rune, int, int) int
	inclusive bool
	linewise  bool
	absolute  bool
}

var vimMotions = map[string]vimMotionSpec{
	"h": {step: vimLeft}, "l": {step: vimRight},
	"0": {step: vimLineStart}, "^": {step: vimFirstNonblank},
	"j": {step: vimDown, linewise: true}, "k": {step: vimUp, linewise: true},
	"w": {step: vimWordNext}, "b": {step: vimWordPrevious}, "e": {step: vimWordEnd, inclusive: true},
	"$":  {resolve: vimCountedLineEnd, inclusive: true},
	"gg": {resolve: vimFirstLineTarget, linewise: true, absolute: true},
	"G":  {resolve: vimLastLineTarget, linewise: true, absolute: true},
}

func vimMotion(text []rune, pos int, key string, count int) (int, bool) {
	motion, ok := vimMotions[key]
	if !ok {
		return pos, false
	}
	if motion.resolve != nil {
		return motion.resolve(text, pos, count), true
	}
	for range max(1, count) {
		pos = motion.step(text, pos)
	}
	return pos, true
}

func vimCountedLineEnd(text []rune, pos, count int) int {
	return vimLineEnd(text, vimAdvanceLines(text, pos, max(1, count)-1))
}
func vimFirstLineTarget(text []rune, pos, count int) int { return vimLineTarget(text, "gg", count) }
func vimLastLineTarget(text []rune, pos, count int) int  { return vimLineTarget(text, "G", count) }

func vimAdvanceLines(text []rune, pos, count int) int {
	for range count {
		_, end := vimBounds(text, pos)
		if end == len(text) {
			break
		}
		pos = end + 1
	}
	return pos
}

func vimLineTarget(text []rune, key string, count int) int {
	if key == "G" && count == 0 {
		count = strings.Count(string(text), "\n") + 1
	}
	return vimAdvanceLines(text, 0, max(1, count)-1)
}

func vimLeft(text []rune, pos int) int {
	start, _ := vimBounds(text, pos)
	return max(start, pos-1)
}

func vimRight(text []rune, pos int) int {
	start, end := vimBounds(text, pos)
	return min(max(start, end-1), pos+1)
}

func vimLineStart(text []rune, pos int) int {
	start, _ := vimBounds(text, pos)
	return start
}

func vimFirstNonblank(text []rune, pos int) int {
	start, end := vimBounds(text, pos)
	pos = start
	for pos < end && unicode.IsSpace(text[pos]) {
		pos++
	}
	return pos
}

func vimLineEnd(text []rune, pos int) int {
	start, end := vimBounds(text, pos)
	return max(start, end-1)
}

func vimDown(text []rune, pos int) int {
	start, end := vimBounds(text, pos)
	if end < len(text) {
		_, next := vimBounds(text, end+1)
		pos = min(end+1+pos-start, max(end+1, next-1))
	}
	return pos
}

func vimUp(text []rune, pos int) int {
	start, _ := vimBounds(text, pos)
	if start > 0 {
		prev, _ := vimBounds(text, start-1)
		pos = min(prev+pos-start, max(prev, start-2))
	}
	return pos
}

func vimWordNext(text []rune, pos int) int {
	if pos < len(text) {
		class := vimClass(text[pos])
		for pos < len(text) && vimClass(text[pos]) == class {
			pos++
		}
	}
	for pos < len(text) && vimClass(text[pos]) == 0 {
		pos++
	}
	return pos
}

func vimWordPrevious(text []rune, pos int) int {
	pos = max(0, pos-1)
	for pos > 0 && vimClass(text[pos]) == 0 {
		pos--
	}
	if pos < len(text) {
		class := vimClass(text[pos])
		for pos > 0 && vimClass(text[pos-1]) == class {
			pos--
		}
	}
	return pos
}

func vimWordEnd(text []rune, pos int) int {
	pos = min(len(text), pos+1)
	for pos < len(text) && vimClass(text[pos]) == 0 {
		pos++
	}
	if pos < len(text) {
		class := vimClass(text[pos])
		for pos+1 < len(text) && vimClass(text[pos+1]) == class {
			pos++
		}
	}
	return pos
}

func vimClass(r rune) int {
	if unicode.IsSpace(r) {
		return 0
	}
	if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' {
		return 1
	}
	return 2
}

type vimRange struct {
	start, end int
	linewise   bool
	register   string
}

func vimOperatorRange(text []rune, pos int, input vimInput) (vimRange, bool) {
	key, operator, count := input.key, input.operator, input.count
	start, end := vimBounds(text, pos)
	motionSpec := vimMotions[key]
	linewise := key == operator || motionSpec.linewise
	a, b := pos, pos
	if key == operator {
		a, b = start, end
		for range count - 1 {
			if b < len(text) {
				_, b = vimBounds(text, b+1)
			}
		}
	} else {
		changeWord := operator == "c" && key == "w" && pos < len(text) && vimClass(text[pos]) != 0
		motionCount := count
		if motionSpec.absolute && !input.explicit {
			motionCount = 0
		}
		var target int
		if changeWord {
			target = vimChangeWordEnd(text, pos, count)
			motionSpec = vimMotions["e"]
		} else {
			var ok bool
			target, ok = vimMotion(text, pos, key, motionCount)
			if !ok {
				return vimRange{}, false
			}
		}
		a, b = min(pos, target), max(pos, target)
		if linewise {
			a, _ = vimBounds(text, a)
			_, b = vimBounds(text, b)
		} else if motionSpec.inclusive {
			b = min(len(text), b+1)
		}
	}
	span := vimRange{a, b, linewise, string(text[a:b])}
	if linewise && operator != "c" {
		if b < len(text) {
			span.end++
		} else if a > 0 {
			span.start--
		}
	}
	return span, true
}

func vimChangeWordEnd(text []rune, pos, count int) int {
	target := pos
	for target+1 < len(text) && vimClass(text[target+1]) == vimClass(text[pos]) {
		target++
	}
	if count > 1 {
		target, _ = vimMotion(text, target, "e", count-1)
	}
	return target
}
