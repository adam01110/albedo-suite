package tui

// Property tests for the Vim composer, named TestProp* to stay out of the
// package check's filters. A line-based reference model of the
// documented semantics (docs/vim.md) replays the same operation histories as
// key presses on a real ChatModel; pure motions and text objects are also
// compared exhaustively over small buffers.

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"testing"
	"unicode"
)

// ---------- independent reference helpers ----------

// VIM_PARITY=1 switches ambiguous behaviors to Vim's, to enumerate divergences
// that docs/vim.md does not settle.
var refVimParity = os.Getenv("VIM_PARITY") == "1"

func refClass(r rune) int {
	switch {
	case unicode.IsSpace(r):
		return 0
	case unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_':
		return 1
	}
	return 2
}

// refRows splits text into rows with their flat start offsets.
func refRows(text []rune) (rows [][]rune, starts []int) {
	start := 0
	for i := 0; i <= len(text); i++ {
		if i == len(text) || text[i] == '\n' {
			rows = append(rows, text[start:i])
			starts = append(starts, start)
			start = i + 1
		}
	}
	return
}

func refRowCol(text []rune, pos int) (int, int) {
	rows, starts := refRows(text)
	for r := len(rows) - 1; r >= 0; r-- {
		if pos >= starts[r] {
			return r, pos - starts[r]
		}
	}
	return 0, 0
}

func refFlat(text []rune, row, col int) int {
	_, starts := refRows(text)
	return starts[row] + col
}

func refLastCol(row []rune) int { return max(0, len(row)-1) }

func refWordStart(text []rune, q int) bool {
	return q < len(text) && refClass(text[q]) != 0 && (q == 0 || refClass(text[q-1]) != refClass(text[q]))
}

func refWordEndAt(text []rune, q int) bool {
	return q < len(text) && refClass(text[q]) != 0 && (q+1 == len(text) || refClass(text[q+1]) != refClass(text[q]))
}

// refMotion is the documented motion target for a cursor; counts already >= 1.
func refMotion(text []rune, pos int, key string, count int, explicit bool) int {
	rows, _ := refRows(text)
	row, col := refRowCol(text, pos)
	switch key {
	case "h":
		return refFlat(text, row, max(0, col-count))
	case "l":
		return refFlat(text, row, min(refLastCol(rows[row]), col+count))
	case "0":
		return refFlat(text, row, 0)
	case "^":
		c := 0
		for c < len(rows[row]) && unicode.IsSpace(rows[row][c]) {
			c++
		}
		return refFlat(text, row, c)
	case "$":
		r := min(len(rows)-1, row+count-1)
		return refFlat(text, r, refLastCol(rows[r]))
	case "j", "k":
		step := 1
		if key == "k" {
			step = -1
		}
		if refVimParity {
			// Vim keeps the column across a counted jump.
			r := max(0, min(len(rows)-1, row+step*count))
			return refFlat(text, r, min(col, refLastCol(rows[r])))
		}
		// Without a remembered column, every line step clamps it.
		for range count {
			if r := row + step; r >= 0 && r < len(rows) {
				row, col = r, min(col, refLastCol(rows[r]))
			}
		}
		return refFlat(text, row, col)
	case "gg", "G":
		r := 0
		if key == "G" {
			r = len(rows) - 1
		}
		if explicit {
			r = min(len(rows)-1, count-1)
		}
		return refFlat(text, r, 0)
	case "w":
		for range count {
			q := pos + 1
			for q < len(text) && !refWordStart(text, q) {
				q++
			}
			pos = min(q, len(text))
		}
		return pos
	case "b":
		for range count {
			q := pos - 1
			for q > 0 && !refWordStart(text, q) {
				q--
			}
			pos = max(q, 0)
		}
		return pos
	case "e":
		for range count {
			q := pos + 1
			for q < len(text) && !refWordEndAt(text, q) {
				q++
			}
			pos = min(q, len(text))
		}
		return pos
	}
	panic("unknown motion " + key)
}

// refPairBrute enumerates every balanced pair and picks the count-th
// smallest one containing pos: an exhaustive oracle for small buffers.
func refPairBrute(text []rune, pos int, open, close rune, count int) (int, int, bool) {
	type span struct{ a, b int }
	var spans []span
	for a := range text {
		if text[a] != open {
			continue
		}
		depth := 0
		for b := a + 1; b < len(text); b++ {
			if text[b] == open {
				depth++
			} else if text[b] == close {
				if depth == 0 {
					spans = append(spans, span{a, b})
					break
				}
				depth--
			}
		}
	}
	var containing []span
	for _, s := range spans {
		if s.a <= pos && pos <= s.b {
			containing = append(containing, s)
		}
	}
	// Containing balanced spans nest, so sort by width.
	for i := range containing {
		for j := i + 1; j < len(containing); j++ {
			if containing[j].b-containing[j].a < containing[i].b-containing[i].a {
				containing[i], containing[j] = containing[j], containing[i]
			}
		}
	}
	if count > len(containing) {
		return 0, 0, false
	}
	s := containing[count-1]
	return s.a, s.b, true
}

// refTextObject models docs/vim.md text objects for count 1 words and all
// pairs: word objects stay on the cursor's logical line.
func refTextObject(text []rune, pos int, obj rune, around bool, count int) (int, int, bool, bool) {
	if pos >= len(text) {
		return 0, 0, false, true
	}
	rows, starts := refRows(text)
	row, col := refRowCol(text, pos)
	line := rows[row]
	off := starts[row]
	switch obj {
	case 'w', 'W':
		if count != 1 {
			return 0, 0, false, false
		}
		if len(line) == 0 {
			return 0, 0, false, false
		}
		cls := func(r rune) int {
			if obj == 'W' && !unicode.IsSpace(r) {
				return 1
			}
			return refClass(r)
		}
		c := cls(line[col])
		a, b := col, col+1
		for a > 0 && cls(line[a-1]) == c {
			a--
		}
		for b < len(line) && cls(line[b]) == c {
			b++
		}
		if around {
			if c == 0 {
				if b < len(line) {
					c2 := cls(line[b])
					for b < len(line) && cls(line[b]) == c2 {
						b++
					}
				}
			} else {
				old := b
				for b < len(line) && unicode.IsSpace(line[b]) {
					b++
				}
				if b == old {
					for a > 0 && unicode.IsSpace(line[a-1]) {
						a--
					}
				}
			}
		}
		return off + a, off + b, true, true
	case '"', '\'', '`':
		if count != 1 {
			return 0, 0, false, true
		}
		var quotes []int
		for i, r := range line {
			if r == obj && (i == 0 || line[i-1] != '\\') {
				quotes = append(quotes, i)
			}
		}
		for i := 0; i+1 < len(quotes); i += 2 {
			if col <= quotes[i+1] {
				a, b := quotes[i], quotes[i+1]
				if around {
					return off + a, off + b + 1, true, true
				}
				return off + a + 1, off + b, true, true
			}
		}
		return 0, 0, false, true
	}
	pairs := map[rune][2]rune{'(': {'(', ')'}, ')': {'(', ')'}, 'b': {'(', ')'}, '[': {'[', ']'}, ']': {'[', ']'}, '{': {'{', '}'}, '}': {'{', '}'}, 'B': {'{', '}'}, '<': {'<', '>'}, '>': {'<', '>'}}
	p, ok := pairs[obj]
	if !ok {
		return 0, 0, false, true
	}
	a, b, ok := refPairBrute(text, pos, p[0], p[1], count)
	if !ok {
		return 0, 0, false, true
	}
	if around {
		return a, b + 1, true, true
	}
	return a + 1, b, true, true
}

// ---------- pure exhaustive properties ----------

func refBuffers(alphabet []rune, maxLen int, visit func([]rune)) {
	var rec func(prefix []rune)
	rec = func(prefix []rune) {
		visit(prefix)
		if len(prefix) == maxLen {
			return
		}
		for _, r := range alphabet {
			rec(append(append([]rune{}, prefix...), r))
		}
	}
	rec(nil)
}

// Normal-mode cursors never sit on a newline unless the line is empty.
func refNormalPositions(text []rune) []int {
	var out []int
	rows, starts := refRows(text)
	for r, row := range rows {
		for c := 0; c <= refLastCol(row); c++ {
			out = append(out, starts[r]+c)
		}
	}
	return out
}

func TestPropVimMotionsExhaustive(t *testing.T) {
	alphabet := []rune{'a', ' ', '.', '\n', 'é'}
	cases, failures := 0, 0
	refBuffers(alphabet, 6, func(text []rune) {
		for _, pos := range refNormalPositions(text) {
			for _, key := range []string{"h", "l", "0", "^", "$", "j", "k", "w", "b", "e", "gg", "G"} {
				for _, count := range []int{0, 1, 2, 3} {
					explicit := count > 0
					spec := vimMotions[key]
					c := count
					if spec.absolute && !explicit {
						c = 0
					}
					got, ok := vimMotion(text, pos, key, c)
					want := refMotion(text, pos, key, max(1, count), explicit)
					cases++
					if !ok || got != want {
						failures++
						if failures <= 20 {
							t.Errorf("%q pos %d %d%s: got %d want %d", string(text), pos, count, key, got, want)
						}
					}
				}
			}
		}
	})
	t.Logf("motion cases: %d, failures: %d", cases, failures)
}

func TestPropVimTextObjectsExhaustive(t *testing.T) {
	alphabet := []rune{'a', ' ', '(', ')', '"', '\n', '.'}
	cases, failures, skipped := 0, 0, 0
	buckets := map[string]int{}
	refBuffers(alphabet, 6, func(text []rune) {
		for _, pos := range refNormalPositions(text) {
			for _, obj := range []rune{'w', 'W', '(', 'b', '"'} {
				for _, around := range []bool{false, true} {
					for _, count := range []int{1, 2} {
						wa, wb, wok, modeled := refTextObject(text, pos, obj, around, count)
						if !modeled {
							skipped++
							continue
						}
						span, ok := vimTextObject(text, pos, obj, around, count)
						cases++
						if ok != wok || ok && (span.start != wa || span.end != wb) {
							failures++
							cross := ok && strings.ContainsRune(string(text[span.start:span.end]), '\n') && !(wok && strings.ContainsRune(string(text[wa:wb]), '\n'))
							bucket := fmt.Sprintf("%d%c%c ok=%v/%v crossesLine=%v", count, map[bool]rune{true: 'a', false: 'i'}[around], obj, ok, wok, cross)
							if buckets[bucket] == 0 {
								t.Logf("first %s: %q pos %d got %d..%d want %d..%d", bucket, string(text), pos, span.start, span.end, wa, wb)
							}
							buckets[bucket]++
						}
					}
				}
			}
		}
	})
	t.Logf("text object cases: %d, failures: %d, unmodeled: %d", cases, failures, skipped)
	for bucket, n := range buckets {
		t.Errorf("bucket %s: %d", bucket, n)
	}
}

// ---------- operation-sequence model ----------

type refState struct {
	text     []rune
	pos      int
	normal   bool
	reg      string
	regLine  bool
	undo     []string
	redo     []string
	lastFind string
	lastChar rune
}

type vimOp struct {
	keys  []string
	apply func(*refState) // nil: only invariants are checked
	name  string
	// exactCursor: compare cursor; otherwise only bounds.
	exactCursor bool
}

func (s *refState) clampNormal() {
	rows, starts := refRows(s.text)
	row, col := refRowCol(s.text, max(0, min(s.pos, len(s.text))))
	s.pos = starts[row] + min(col, refLastCol(rows[row]))
}

func (s *refState) remember(before string) {
	if before == string(s.text) {
		return
	}
	s.undo = append(s.undo, before)
	if len(s.undo) > 100 {
		s.undo = s.undo[1:]
	}
	s.redo = nil
}

// delete removes [a,b), filling the charwise register. Attachment markers are
// not generated, so no expansion applies.
func (s *refState) delete(a, b int) {
	if a == b {
		return
	}
	s.reg, s.regLine = string(s.text[a:b]), false
	s.text = append(append([]rune{}, s.text[:a]...), s.text[b:]...)
	s.pos = a
}

func (s *refState) insertText(at int, value string) {
	s.text = append(append(append([]rune{}, s.text[:at]...), []rune(value)...), s.text[at:]...)
}

// opRange computes the documented operator range for a motion key.
// Returns start, end, linewise, ok.
func (s *refState) opRange(op, key string, count int, explicit bool) (int, int, bool) {
	text := s.text
	rows, starts := refRows(text)
	row, _ := refRowCol(text, s.pos)
	lineRange := func(r1, r2 int) (int, int, bool) {
		a := starts[r1]
		b := starts[r2] + len(rows[r2])
		return a, b, true
	}
	if key == op {
		return lineRange(row, min(len(rows)-1, row+count-1))
	}
	switch key {
	case "j", "k", "gg", "G":
		t := refMotion(text, s.pos, key, count, explicit)
		tr, _ := refRowCol(text, t)
		if refVimParity && (key == "j" || key == "k") && tr == row {
			// Vim: a j/k that cannot move aborts the operator.
			return s.pos, s.pos, false
		}
		return lineRange(min(row, tr), max(row, tr))
	}
	if op == "c" && key == "w" && s.pos < len(text) && refClass(text[s.pos]) != 0 {
		key = "e"
		// cw on a word changes through the end of its word, like ce from inside it.
		q := s.pos
		for q+1 < len(text) && refClass(text[q+1]) == refClass(text[s.pos]) {
			q++
		}
		if count > 1 {
			q = refMotion(text, q, "e", count-1, true)
		}
		return s.pos, min(len(text), q+1), false
	}
	if refVimParity && key == "l" {
		// Vim: an operator with l may reach past the last character.
		row, col := refRowCol(text, s.pos)
		return s.pos, starts[row] + min(len(rows[row]), col+count), false
	}
	t := refMotion(text, s.pos, key, count, explicit)
	a, b := min(s.pos, t), max(s.pos, t)
	if key == "e" || key == "$" {
		b = min(len(text), b+1)
	}
	if refVimParity && key == "w" && op != "c" {
		// Vim: a w that leaves the line ends the operated text at that line's end.
		if tr, _ := refRowCol(text, t); tr > row {
			for r := row; r < tr; r++ {
				if starts[r]+len(rows[r]) > s.pos {
					b = min(b, starts[r]+len(rows[r]))
					break
				}
			}
		}
	}
	return a, b, false
}

func (s *refState) applyLinewise(op string, a, b int) {
	before := string(s.text)
	reg := string(s.text[a:b])
	if op == "y" {
		s.reg, s.regLine = reg, true
		return
	}
	if op == "c" {
		s.text = append(append([]rune{}, s.text[:a]...), s.text[b:]...)
		s.pos = a
		s.reg, s.regLine = reg, true
		s.normal = false
		return
	}
	if b < len(s.text) {
		b++
	} else if a > 0 {
		a--
	}
	s.text = append(append([]rune{}, s.text[:a]...), s.text[b:]...)
	s.reg, s.regLine = reg, true
	s.pos = min(a, len(s.text))
	s.remember(before)
}

func (s *refState) applyCharwise(op string, a, b int) {
	before := string(s.text)
	if op == "y" {
		s.reg, s.regLine = string(s.text[a:b]), false
		return
	}
	s.delete(a, b)
	if op == "c" {
		s.normal = false
		return
	}
	s.remember(before)
}

// typeAndEscape models typed insert text followed by Esc from an insert that
// began at state "before".
func (s *refState) typeAndEscape(before, typed string) {
	s.insertText(s.pos, typed)
	s.pos += len([]rune(typed))
	s.remember(before)
	s.normal = true
	_, col := refRowCol(s.text, s.pos)
	if col > 0 {
		s.pos--
	}
	s.clampNormal()
}

func countKeys(count int) []string {
	if count == 0 {
		return nil
	}
	return strings.Split(strconv.Itoa(count), "")
}

type vimGen struct {
	r        *rand.Rand
	alphabet []rune
	weights  map[string]int
}

func (g *vimGen) char() rune { return g.alphabet[g.r.Intn(len(g.alphabet))] }

func (g *vimGen) typed() string {
	var b strings.Builder
	for range g.r.Intn(4) {
		c := g.char()
		if c == '\n' || c == ' ' {
			c = 'q'
		}
		b.WriteRune(c)
	}
	return b.String()
}

func (g *vimGen) count() int {
	switch g.r.Intn(6) {
	case 0, 1, 2:
		return 0
	case 3:
		return 1
	case 4:
		return 2
	}
	return 2 + g.r.Intn(4)
}

func keysOf(s string) []string {
	var out []string
	for _, r := range s {
		out = append(out, string(r))
	}
	return out
}

var vimOpKinds = []string{"motion", "operator", "line", "object", "find", "repeat", "replace", "x", "D", "paste", "undo", "redo", "insert", "change", "cancel", "noise", "findchain"}

func (g *vimGen) op(s *refState) vimOp {
	total := 0
	for _, k := range vimOpKinds {
		total += g.weights[k]
	}
	n := g.r.Intn(total)
	kind := ""
	for _, k := range vimOpKinds {
		n -= g.weights[k]
		if n < 0 {
			kind = k
			break
		}
	}
	if kind == "findchain" {
		// A motion find followed by repeats exercises ; and , after every find kind.
		ops := []vimOp{g.opOf("find", s, "")}
		for range 1 + g.r.Intn(2) {
			ops = append(ops, g.opOf("repeat", s, ""))
		}
		chain := vimOp{name: "findchain", exactCursor: true}
		for _, o := range ops {
			chain.keys = append(chain.keys, o.keys...)
			chain.name += " " + o.name
			chain.exactCursor = chain.exactCursor && o.exactCursor
		}
		chain.apply = func(s *refState) {
			for _, o := range ops {
				o.apply(s)
			}
		}
		return chain
	}
	return g.opOf(kind, s, "")
}

func (g *vimGen) opOf(kind string, s *refState, _ string) vimOp {
	motions := []string{"h", "l", "j", "k", "w", "b", "e", "0", "^", "$", "gg", "G"}
	switch kind {
	case "motion":
		key, c := motions[g.r.Intn(len(motions))], g.count()
		if key == "0" {
			c = 0
		}
		return vimOp{name: "motion", keys: append(countKeys(c), keysOf(key)...), exactCursor: true, apply: func(s *refState) {
			s.pos = refMotion(s.text, s.pos, key, max(1, c), c > 0)
			s.clampNormal()
		}}
	case "operator", "line", "change":
		op := []string{"d", "y", "c"}[g.r.Intn(3)]
		if kind == "change" {
			op = "c"
		}
		key := op
		if kind != "line" {
			key = motions[g.r.Intn(len(motions))]
		}
		c1, c2 := g.count(), g.count()
		if key == "0" {
			c2 = 0
		}
		typed := ""
		keys := append(countKeys(c1), op)
		keys = append(append(keys, countKeys(c2)...), keysOf(key)...)
		if op == "c" {
			typed = g.typed()
			keys = append(append(keys, keysOf(typed)...), "esc")
		}
		return vimOp{name: "op " + key, keys: keys, exactCursor: op != "y", apply: func(s *refState) {
			count := max(1, c1) * max(1, c2)
			before := string(s.text)
			a, b, linewise := s.opRange(op, key, count, c1 > 0 || c2 > 0)
			if linewise {
				s.applyLinewise(op, a, b)
			} else {
				s.applyCharwise(op, a, b)
			}
			if op == "c" {
				s.typeAndEscape(before, typed)
			} else {
				s.clampNormal()
			}
		}}
	case "object":
		op := []string{"d", "y", "c"}[g.r.Intn(3)]
		obj := []rune{'w', 'W', '(', ')', 'b', '[', '{', 'B', '<', '"', '\'', '`'}[g.r.Intn(12)]
		ia := []string{"i", "a"}[g.r.Intn(2)]
		c := 0
		if g.r.Intn(4) == 0 {
			c = 2
		}
		keys := append(countKeys(c), op, ia, string(obj))
		typed := ""
		if op == "c" {
			typed = g.typed()
			keys = append(append(keys, keysOf(typed)...), "esc")
		}
		return vimOp{name: "object " + ia + string(obj), keys: keys, exactCursor: op != "y", apply: func(s *refState) {
			before := string(s.text)
			a, b, ok, modeled := refTextObject(s.text, s.pos, obj, ia == "a", max(1, c))
			if !modeled {
				panic(errUnmodeled)
			}
			if !ok {
				// c with a failed object stays in Normal mode and types nothing.
				if op == "c" {
					panic(errUnmodeled)
				}
				return
			}
			s.applyCharwise(op, a, b)
			if op == "c" {
				s.typeAndEscape(before, typed)
			}
			s.clampNormal()
		}}
	case "find", "repeat":
		op := []string{"", "", "d", "y", "c"}[g.r.Intn(5)]
		key := []string{"f", "F", "t", "T"}[g.r.Intn(4)]
		if kind == "repeat" {
			key = []string{";", ","}[g.r.Intn(2)]
		}
		ch := g.char()
		// Mostly search for a character that exists on the cursor line.
		if row, _ := refRowCol(s.text, s.pos); g.r.Intn(5) > 0 {
			if rows, _ := refRows(s.text); len(rows[row]) > 0 {
				ch = rows[row][g.r.Intn(len(rows[row]))]
			}
		}
		if ch == '\n' {
			ch = 'a'
		}
		c := g.count()
		keys := append(countKeys(c), keysOf(op)...)
		keys = append(keys, key)
		if kind == "find" {
			keys = append(keys, string(ch))
		}
		typed := ""
		if op == "c" {
			typed = g.typed()
			keys = append(append(keys, keysOf(typed)...), "esc")
		}
		return vimOp{name: "find " + op + key, keys: keys, exactCursor: op != "y", apply: func(s *refState) {
			k, char, repeat := key, ch, false
			if kind == "repeat" {
				if s.lastFind == "" {
					if op == "c" {
						panic(errUnmodeled)
					}
					return
				}
				k, char, repeat = s.lastFind, s.lastChar, true
				if key == "," {
					k = map[string]string{"f": "F", "F": "f", "t": "T", "T": "t"}[k]
				}
			}
			row, col := refRowCol(s.text, s.pos)
			rows, starts := refRows(s.text)
			line := rows[row]
			// Collect matches strictly after/before the cursor on this line.
			var hits []int
			if k == "f" || k == "t" {
				for i := col + 1; i < len(line); i++ {
					if line[i] == char && !(repeat && k == "t" && i == col+1) {
						hits = append(hits, i)
					}
				}
			} else {
				for i := col - 1; i >= 0; i-- {
					if line[i] == char && !(repeat && k == "T" && i == col-1) {
						hits = append(hits, i)
					}
				}
			}
			if len(hits) < max(1, c) {
				if op == "c" {
					panic(errUnmodeled)
				}
				return
			}
			hit := hits[max(1, c)-1]
			if !repeat {
				s.lastFind, s.lastChar = k, char
			}
			target := hit
			switch k {
			case "t":
				target = hit - 1
			case "T":
				target = hit + 1
			}
			if op == "" {
				s.pos = starts[row] + target
				return
			}
			var a, b int
			switch k {
			case "f", "t":
				a, b = col, target+1
			case "F":
				// Suite contract (vim_arguments_test): dF includes the cursor.
				a, b = target, col+1
				if refVimParity {
					a, b = target, col
				}
			case "T":
				a, b = target, col
			}
			if a >= b {
				if op == "c" {
					panic(errUnmodeled)
				}
				return
			}
			before := string(s.text)
			s.applyCharwise(op, starts[row]+a, starts[row]+b)
			if op == "c" {
				s.typeAndEscape(before, typed)
			}
			s.clampNormal()
		}}
	case "replace":
		c, ch := g.count(), g.char()
		if ch == '\n' {
			ch = 'Z'
		}
		return vimOp{name: "replace", keys: append(append(countKeys(c), "r"), string(ch)), exactCursor: true, apply: func(s *refState) {
			n := max(1, c)
			row, col := refRowCol(s.text, s.pos)
			rows, _ := refRows(s.text)
			if len(rows[row])-col < n {
				return
			}
			before := string(s.text)
			for i := range n {
				s.text[s.pos+i] = ch
			}
			s.pos += n - 1
			s.remember(before)
		}}
	case "x":
		key, c := []string{"x", "X"}[g.r.Intn(2)], g.count()
		return vimOp{name: key, keys: append(countKeys(c), key), exactCursor: true, apply: func(s *refState) {
			n := max(1, c)
			row, col := refRowCol(s.text, s.pos)
			rows, starts := refRows(s.text)
			before := string(s.text)
			if key == "x" {
				s.delete(s.pos, starts[row]+min(len(rows[row]), col+n))
			} else {
				s.delete(starts[row]+max(0, col-n), s.pos)
			}
			s.remember(before)
			s.clampNormal()
		}}
	case "D":
		key, c := []string{"D", "C"}[g.r.Intn(2)], g.count()
		keys := append(countKeys(c), key)
		typed := ""
		if key == "C" {
			typed = g.typed()
			keys = append(append(keys, keysOf(typed)...), "esc")
		}
		return vimOp{name: key, keys: keys, exactCursor: true, apply: func(s *refState) {
			row, _ := refRowCol(s.text, s.pos)
			rows, starts := refRows(s.text)
			r := min(len(rows)-1, row+max(1, c)-1)
			before := string(s.text)
			s.delete(s.pos, starts[r]+len(rows[r]))
			if key == "C" {
				s.typeAndEscape(before, typed)
				return
			}
			s.remember(before)
			s.clampNormal()
		}}
	case "paste":
		key, c := []string{"p", "P"}[g.r.Intn(2)], g.count()
		return vimOp{name: key, keys: append(countKeys(c), key), exactCursor: true, apply: func(s *refState) {
			if s.reg == "" && !s.regLine {
				return
			}
			n := max(1, c)
			before := string(s.text)
			row, col := refRowCol(s.text, s.pos)
			rows, starts := refRows(s.text)
			if s.regLine {
				block := strings.TrimSuffix(strings.Repeat(s.reg+"\n", n), "\n")
				if key == "p" {
					at := starts[row] + len(rows[row])
					s.insertText(at, "\n"+block)
					s.pos = at + 1
				} else {
					s.insertText(starts[row], block+"\n")
					s.pos = starts[row]
				}
			} else {
				value := strings.Repeat(s.reg, n)
				at := s.pos
				if key == "p" && len(rows[row]) > 0 {
					at = starts[row] + col + 1
				}
				s.insertText(at, value)
				s.pos = at + len([]rune(value)) - 1
			}
			s.remember(before)
			s.clampNormal()
		}}
	case "undo", "redo":
		c := g.count()
		keys := append(countKeys(c), "u")
		if kind == "redo" {
			keys = append(countKeys(c), "ctrl+r")
		}
		return vimOp{name: kind, keys: keys, apply: func(s *refState) {
			src, dst := &s.undo, &s.redo
			if kind == "redo" {
				src, dst = dst, src
			}
			for range max(1, c) {
				if len(*src) == 0 {
					break
				}
				*dst = append(*dst, string(s.text))
				s.text = []rune((*src)[len(*src)-1])
				*src = (*src)[:len(*src)-1]
			}
			s.clampNormal()
		}}
	case "insert":
		key := []string{"i", "a", "I", "A", "o", "O"}[g.r.Intn(6)]
		typed := g.typed()
		return vimOp{name: "insert " + key, keys: append(append([]string{key}, keysOf(typed)...), "esc"), exactCursor: true, apply: func(s *refState) {
			before := string(s.text)
			row, col := refRowCol(s.text, s.pos)
			rows, starts := refRows(s.text)
			switch key {
			case "a":
				s.pos = starts[row] + min(len(rows[row]), col+1)
			case "I":
				s.pos = refMotion(s.text, s.pos, "^", 1, false)
			case "A":
				s.pos = starts[row] + len(rows[row])
			case "o":
				at := starts[row] + len(rows[row])
				s.insertText(at, "\n")
				s.pos = at + 1
			case "O":
				s.insertText(starts[row], "\n")
				s.pos = starts[row]
			}
			s.typeAndEscape(before, typed)
		}}
	case "cancel":
		prefixes := [][]string{{"3"}, {"d"}, {"2", "c"}, {"y", "2"}, {"f"}, {"d", "t"}, {"r"}, {"g"}, {"d", "g"}, {"c", "i"}, {"2", "d", "a"}}
		p := prefixes[g.r.Intn(len(prefixes))]
		return vimOp{name: "cancel", keys: append(append([]string{}, p...), "esc"), exactCursor: true, apply: func(s *refState) {}}
	case "noise":
		key := []string{"z", "q", "Q", "s", "S", "v", "J", "~", "%", "*", "n"}[g.r.Intn(11)]
		return vimOp{name: "noise " + key, keys: []string{key}, exactCursor: true, apply: func(s *refState) {}}
	}
	panic("kind " + kind)
}

type unmodeled struct{}

var errUnmodeled = unmodeled{}

func vimRandomBuffer(r *rand.Rand, alphabet []rune) string {
	var b strings.Builder
	n := r.Intn(14)
	if r.Intn(3) == 0 {
		n = r.Intn(60)
	}
	for range n {
		c := alphabet[r.Intn(len(alphabet))]
		// Long buffers keep long lines so wrapping happens.
		if n > 14 && c == '\n' && r.Intn(3) > 0 {
			c = 'a'
		}
		b.WriteRune(c)
	}
	return b.String()
}

type vimMismatch struct {
	op, field, detail string
}

// runVimHistory replays one generated history; returns the first mismatch.
func runVimHistory(t *testing.T, seed int64, steps int, swarm bool) (trace []string, mismatch *vimMismatch, modeledOps int) {
	r := rand.New(rand.NewSource(seed))
	alphabet := []rune{'a', 'b', ' ', '.', '\n', 'é', '日', '(', ')', '"', '_'}
	weights := map[string]int{}
	for _, k := range vimOpKinds {
		weights[k] = 3
		if swarm {
			weights[k] = []int{0, 1, 3, 6}[r.Intn(4)]
		}
	}
	weights["motion"]++
	g := &vimGen{r: r, alphabet: alphabet, weights: weights}
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	// Narrow composers soft-wrap long logical lines.
	m.SetSize(12+r.Intn(40), 24)
	initial := vimRandomBuffer(r, alphabet)
	m.TextArea.SetValue(initial)
	m.vim.normal = true
	ref := &refState{text: []rune(initial), normal: true}
	start := r.Intn(len(ref.text) + 1)
	ref.pos = start
	ref.clampNormal()
	m.vimPosition(ref.pos)
	trace = append(trace, fmt.Sprintf("initial %q pos %d", initial, ref.pos))
	for range steps {
		op := g.op(ref)
		snapshot := *ref
		snapshot.text = append([]rune{}, ref.text...)
		snapshot.undo = append([]string{}, ref.undo...)
		snapshot.redo = append([]string{}, ref.redo...)
		skipped := false
		func() {
			defer func() {
				if v := recover(); v != nil {
					if _, ok := v.(unmodeled); !ok {
						panic(v)
					}
					skipped = true
				}
			}()
			op.apply(ref)
		}()
		var panicked any
		func() {
			defer func() { panicked = recover() }()
			vimKeys(&m, op.keys...)
		}()
		trace = append(trace, fmt.Sprintf("%s %q", op.name, strings.Join(op.keys, " ")))
		if panicked != nil {
			return trace, &vimMismatch{op.name, "panic", fmt.Sprint(panicked)}, modeledOps
		}
		got := m.vimSnapshot()
		text := []rune(got.text)
		// Invariants that hold regardless of the model.
		if !m.vim.normal {
			return trace, &vimMismatch{op.name, "mode", "left in INSERT"}, modeledOps
		}
		rows, starts := refRows(text)
		row, col := refRowCol(text, got.pos)
		if got.pos < 0 || got.pos > len(text) || col > refLastCol(rows[row]) || starts[row]+col != got.pos {
			return trace, &vimMismatch{op.name, "cursor-bounds", fmt.Sprintf("pos %d in %q", got.pos, got.text)}, modeledOps
		}
		if skipped {
			// Resynchronise the model with production and continue.
			*ref = snapshot
			ref.text, ref.pos = text, got.pos
			ref.reg, ref.regLine = m.vim.register, m.vim.linewise
			ref.lastFind, ref.lastChar = m.vim.lastFind, m.vim.lastChar
			ref.undo = nil
			ref.redo = nil
			for _, u := range m.vim.undo {
				ref.undo = append(ref.undo, u.text)
			}
			for _, u := range m.vim.redo {
				ref.redo = append(ref.redo, u.text)
			}
			continue
		}
		modeledOps++
		if string(ref.text) != got.text {
			return trace, &vimMismatch{op.name, "text", fmt.Sprintf("got %q want %q", got.text, string(ref.text))}, modeledOps
		}
		if op.exactCursor && ref.pos != got.pos {
			return trace, &vimMismatch{op.name, "cursor", fmt.Sprintf("got %d want %d in %q", got.pos, ref.pos, got.text)}, modeledOps
		}
		if ref.reg != m.vim.register || ref.regLine != m.vim.linewise {
			return trace, &vimMismatch{op.name, "register", fmt.Sprintf("got %q/%v want %q/%v", m.vim.register, m.vim.linewise, ref.reg, ref.regLine)}, modeledOps
		}
		if len(ref.undo) != len(m.vim.undo) || len(ref.redo) != len(m.vim.redo) {
			return trace, &vimMismatch{op.name, "history", fmt.Sprintf("undo %d/%d redo %d/%d", len(m.vim.undo), len(ref.undo), len(m.vim.redo), len(ref.redo))}, modeledOps
		}
		// Keep cursor in sync when cursor is not compared exactly.
		ref.pos = got.pos
	}
	return trace, nil, modeledOps
}

func TestPropVimHistories(t *testing.T) {
	n := 300
	if v, err := strconv.Atoi(os.Getenv("VIM_PROP_CASES")); err == nil {
		n = v
	}
	base := int64(1)
	if v, err := strconv.ParseInt(os.Getenv("VIM_PROP_SEED"), 10, 64); err == nil {
		base = v
	}
	byKind := map[string]int{}
	examples := map[string]string{}
	total := 0
	for i := range n {
		seed := base + int64(i)
		trace, mm, ops := runVimHistory(t, seed, 25, i%2 == 1)
		total += ops
		if mm != nil {
			key := mm.field + " @ " + mm.op
			byKind[key]++
			if _, ok := examples[key]; !ok {
				examples[key] = fmt.Sprintf("seed %d: %s\n  %s", seed, mm.detail, strings.Join(trace, "\n  "))
			}
		}
	}
	t.Logf("histories: %d, modeled ops checked: %d", n, total)
	for key, count := range byKind {
		t.Errorf("%d× %s\n%s", count, key, examples[key])
	}
}
