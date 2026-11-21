package terminal

import (
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"testing"
	"testing/quick"
	"unicode/utf8"
)

// A frame sequence built from a script, so a failing case is reproducible from
// the bytes quick reports.
type suiteScenario struct {
	width  int
	height int
	steps  []suiteOp
}

type suiteOp struct {
	frame  *suiteFrame
	resize int // 0 for none
}

var suiteAlphabet = []rune("abcde  xyz")
var suiteWideRunes = []rune("日本語テキスト漢字")

type suiteRand struct {
	b   []byte
	pos int
}

func (r *suiteRand) next() byte {
	if len(r.b) == 0 {
		return 0
	}
	c := r.b[r.pos%len(r.b)]
	r.pos++
	return c
}

func (r *suiteRand) intn(n int) int {
	if n <= 0 {
		return 0
	}
	return int(r.next()) % n
}

// suiteScenarioFrom builds a scenario from script bytes.
func suiteScenarioFrom(script []byte, wide bool) suiteScenario {
	r := &suiteRand{b: script}
	width := 14 + r.intn(26)
	sc := suiteScenario{width: width, height: 14}
	steps := 2 + r.intn(4)
	for i := 0; i < steps; i++ {
		lines := 1 + r.intn(6)
		f := &suiteFrame{}
		for j := 0; j < lines; j++ {
			if wide {
				f.lines = append(f.lines, suiteWideLine(r, width))
			} else {
				f.lines = append(f.lines, suiteLine(r, width))
			}
		}
		if !wide && r.intn(3) == 0 {
			// A row padded past the width: the renderer paints its text and
			// leaves the padding to the terminal, which holds a blank cell
			// there already. Narrowing lands the wrap point inside the padding.
			at := r.intn(len(f.lines))
			if n := width + 1 + r.intn(4) - len(f.lines[at]); n > 0 {
				f.lines[at] += strings.Repeat(" ", n)
			}
		}
		// A distinct last row keeps the renderer's cursor on the frame's last
		// row, which is where the oracle places it.
		f.lines = append(f.lines, fmt.Sprintf("m%d", i))
		if r.intn(3) == 0 {
			f.hasCursor = true
			f.cursorRow = r.intn(len(f.lines))
			f.cursorCol = r.intn(4)
		}
		op := suiteOp{frame: f}
		if i > 0 && r.intn(2) == 0 {
			op.resize = max(8, width-(1+r.intn(6)))
			width = op.resize
		}
		sc.steps = append(sc.steps, op)
	}
	return sc
}

func suiteLine(r *suiteRand, width int) string {
	n := r.intn(width + 6)
	if r.intn(4) == 0 {
		// A row the terminal clips well short of what the frame holds: only the
		// clipped part of it can rewrap.
		n = r.intn(3*width + 1)
	}
	var sb strings.Builder
	for i := 0; i < n; i++ {
		sb.WriteRune(suiteAlphabet[r.intn(len(suiteAlphabet))])
	}
	// Trailing spaces are left out on purpose: a terminal trimming them
	// rewraps fewer rows than one keeping them, which is a separate question
	// from the one these properties ask.
	return strings.TrimRight(sb.String(), " ")
}

func suiteWideLine(r *suiteRand, width int) string {
	n := 1 + r.intn(width/2+1)
	var sb strings.Builder
	for i := 0; i < n; i++ {
		if r.intn(4) == 0 {
			sb.WriteString(string(suiteWideRunes[r.intn(len(suiteWideRunes))]))
		} else {
			sb.WriteRune(suiteAlphabet[r.intn(len(suiteAlphabet))])
		}
		// A combining mark belongs to the cell before it, so it follows a
		// letter and never a space or the row's start.
		last, _ := utf8.DecodeLastRuneInString(sb.String())
		if last != 0 && last != ' ' && r.intn(5) == 0 {
			sb.WriteString("\u0301")
		}
	}
	out := strings.TrimRight(sb.String(), " ")
	// Never draw past the width: clipping a wide rune whose second half falls
	// outside is a separate question.
	for out != "" && suiteDisplayWidth(out) > width {
		rs := []rune(out)
		out = string(rs[:len(rs)-1])
	}
	return out
}

func suiteDisplayWidth(s string) int {
	w := 0
	for _, r := range s {
		w += suiteRuneWidth(string(r))
	}
	return w
}

// runScenario plays a scenario against a fresh program and checks the screen
// after every step, returning the first failure.
func runScenario(t *testing.T, sc suiteScenario, env []string) (err error) {
	t.Helper()
	s := suiteStart(t, sc.width, sc.height, env)
	defer s.stop()
	defer func() {
		if r := recover(); r != nil {
			failure, ok := r.(suiteFailure)
			if !ok {
				panic(r)
			}
			err = fmt.Errorf("width %d: %s", s.width, failure.msg)
		}
	}()
	for _, op := range sc.steps {
		s.draw(op.frame)
		s.check(op.frame)
		if op.resize > 0 {
			s.resize(op.resize)
			s.check(op.frame)
		}
	}
	return nil
}

// suiteQuickConfig pins the seed so a failure is reproducible from the run
// itself; SUITE_PROP_SEED explores other cases.
func suiteQuickConfig(def int) *quick.Config {
	seed := int64(1)
	if v := os.Getenv("SUITE_PROP_SEED"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			seed = n
		}
	}
	return &quick.Config{MaxCount: suiteEnvCount(def), MaxCountScale: 0, Rand: rand.New(rand.NewSource(seed))}
}

// TestPropInlineNarrowReflow draws frames, narrows the terminal between them
// and requires the screen to show the last frame with the content above it
// intact: no stale rows above or below, no rows lost.
func TestPropInlineNarrowReflow(t *testing.T) {
	err := quick.Check(func(script []byte) bool {
		if e := runScenario(t, suiteScenarioFrom(script, false), nil); e != nil {
			t.Logf("script %x: %v", script, e)
			return false
		}
		return true
	}, suiteQuickConfig(40))
	if err != nil {
		t.Fatalf("%v", err)
	}
}

// TestPropInlineWideRunes draws frames holding wide runes and combining marks at
// a fixed width and requires an exact screen.
func TestPropInlineWideRunes(t *testing.T) {
	err := quick.Check(func(script []byte) bool {
		sc := suiteScenarioFrom(script, true)
		for i := range sc.steps {
			sc.steps[i].resize = 0
		}
		if e := runScenario(t, sc, nil); e != nil {
			t.Logf("script %x: %v", script, e)
			return false
		}
		return true
	}, suiteQuickConfig(20))
	if err != nil {
		t.Fatalf("%v", err)
	}
}

// TestPropInlineIdempotent requires an unchanged frame to write nothing but
// sequences a reader cannot see: no content, no cursor moves, no erases.
func TestPropInlineIdempotent(t *testing.T) {
	err := quick.Check(func(script []byte) bool {
		sc := suiteScenarioFrom(script, false)
		s := suiteStart(t, sc.width, sc.height, nil)
		defer s.stop()
		for _, op := range sc.steps {
			s.draw(op.frame)
			mark := s.out.Len()
			s.prog.Send(suiteDrawFrame{frame: op.frame})
			s.sync()
			if quiet := s.out.from(mark); !suiteOnlyInvisible(quiet) {
				t.Logf("script %x: unchanged frame wrote %q", script, quiet)
				return false
			}
			if e := func() (err error) {
				defer func() {
					if r := recover(); r != nil {
						failure, ok := r.(suiteFailure)
						if !ok {
							panic(r)
						}
						err = fmt.Errorf("%s", failure.msg)
					}
				}()
				s.check(op.frame)
				return nil
			}(); e != nil {
				t.Logf("script %x: %v", script, e)
				return false
			}
			if op.resize > 0 {
				s.resize(op.resize)
				if e := func() (err error) {
					defer func() {
						if r := recover(); r != nil {
							failure, ok := r.(suiteFailure)
							if !ok {
								panic(r)
							}
							err = fmt.Errorf("%s", failure.msg)
						}
					}()
					s.check(op.frame)
					return nil
				}(); e != nil {
					t.Logf("script %x: %v", script, e)
					return false
				}
			}
		}
		return true
	}, suiteQuickConfig(12))
	if err != nil {
		t.Fatalf("%v", err)
	}
}

// suiteOnlyInvisible reports whether s holds only sequences that put no cell on
// the screen: title markers, cursor visibility and mode changes.
func suiteOnlyInvisible(s string) bool {
	for len(s) > 0 {
		switch {
		case strings.HasPrefix(s, "\x1b]2;"):
			j := strings.IndexByte(s, '\a')
			if j < 0 {
				return false
			}
			s = s[j+1:]
		case strings.HasPrefix(s, "\x1b[?"):
			// Skip the introducer and find the final byte of the CSI.
			j := 3
			for j < len(s) && (s[j] < 0x40 || s[j] > 0x7e) {
				j++
			}
			if j >= len(s) {
				return false
			}
			s = s[j+1:]
		default:
			return false
		}
	}
	return true
}
