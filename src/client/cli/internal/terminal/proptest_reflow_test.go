package terminal

// Property test for the suite's bubbletea#1868 port: when a resize narrows the
// frame, cursed_renderer moves the cursor up past the rows the terminal
// rewrapped. The independent model below counts the physical rows each frame
// row occupies after reflow (ceil of cells over the new width) instead of
// asking ansi.Hardwrap, so the two arriving at the same count is evidence, not
// a tautology.

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"
	"testing/quick"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// propFrame is a frame the harness can draw: one line per terminal row, with
// the cursor on cursorY so exactly the rows above it are counted.
type propFrame struct {
	rows    []string
	cursorY int
}

func (m propFrame) Init() tea.Cmd                       { return nil }
func (m propFrame) Update(tea.Msg) (tea.Model, tea.Cmd) { return m, nil }
func (m propFrame) View() tea.View {
	v := tea.NewView(strings.Join(m.rows, "\n"))
	v.Cursor = tea.NewCursor(0, m.cursorY)
	return v
}

// propReflow is the model: each row above the cursor is clipped to the old
// width as it was drawn, then reflowed cell by cell into lines of newWidth
// cells. A rune that does not fit the current line starts the next one, which
// is how a terminal keeps a double-width rune whole.
func propReflow(frame propFrame, oldWidth, newWidth int) int {
	if newWidth <= 0 || newWidth >= oldWidth {
		return 0
	}
	extra := 0
	for i := 0; i < frame.cursorY && i < len(frame.rows); i++ {
		// The renderer never writes trailing blank cells and the terminal drops
		// them before rewrapping, so only the drawn cells can wrap. Exact for
		// these plain-text frames; a styled trailing space would be drawn.
		row := strings.TrimRight(ansi.Truncate(frame.rows[i], oldWidth, ""), " ")
		lines, col := 1, 0
		for _, r := range row {
			cells := ansi.StringWidth(string(r))
			if cells > 0 && col+cells > newWidth {
				lines++
				col = 0
			}
			col += cells
		}
		extra += lines - 1
	}
	return extra
}

// propResizeRows drives one program through the given widths and returns the
// cursor-up rows it emitted before each forced redraw, in order.
func propResizeRows(t *testing.T, frame propFrame, height int, widths []int) []int {
	t.Helper()
	out := &suiteSyncBuffer{}
	p := tea.NewProgram(frame, tea.WithOutput(out), tea.WithInput(nil),
		tea.WithWindowSize(widths[0], height), tea.WithEnvironment([]string{"TERM=xterm-256color"}))
	done := make(chan error, 1)
	go func() { _, err := p.Run(); done <- err }()
	defer func() {
		p.Quit()
		<-done
	}()
	suiteWaitFor(t, out, 0, "zzz")
	var counts []int
	for _, width := range widths[1:] {
		mark := out.Len()
		p.Send(tea.WindowSizeMsg{Width: width, Height: height})
		after := suiteWaitFor(t, out, mark, ansi.EraseScreenBelow)
		prefix, _, _ := strings.Cut(after, ansi.EraseScreenBelow)
		if strings.Contains(prefix, "\x1b[2J") {
			t.Fatalf("full clear before erase: %q", prefix)
		}
		rows := 0
		for _, match := range suiteCursorUp.FindAllStringSubmatch(prefix, -1) {
			n := 1
			if match[1] != "" {
				fmt.Sscanf(match[1], "%d", &n)
			}
			rows += n
		}
		counts = append(counts, rows)
	}
	return counts
}

var propPieces = []string{"-", "a", " ", "世", "é", "→", "ab", "世界", "|x|"}

// propRow builds a row of roughly the requested cells from single- and
// double-width pieces.
func propRow(rng *rand.Rand, cells int) string {
	var b strings.Builder
	for ansi.StringWidth(b.String()) < cells {
		b.WriteString(propPieces[rng.Intn(len(propPieces))])
	}
	return ansi.Truncate(b.String(), cells, "")
}

// TestPropReflowModelSingleResize checks one narrowing resize per frame.
func TestPropReflowModelSingleResize(t *testing.T) {
	f := func(seed uint64) bool {
		rng := rand.New(rand.NewSource(int64(seed)))
		height := 6 + int(seed%4)
		oldWidth := 8 + int((seed>>3)%30)
		newWidth := 2 + int((seed>>9)%uint64(oldWidth-2))
		frame := propFrame{cursorY: 2 + int((seed>>15)%uint64(height-2))}
		for i := 0; i < height-1; i++ {
			frame.rows = append(frame.rows, propRow(rng, rng.Intn(oldWidth+8)))
		}
		frame.rows = append(frame.rows, "zzz")
		switch seed % 4 {
		case 0:
			newWidth = oldWidth // unchanged: nothing reflowed
		case 1:
			newWidth = oldWidth + 1 + int((seed>>20)%10) // wider: nothing reflowed
		}
		got := propResizeRows(t, frame, height, []int{oldWidth, newWidth})
		want := frame.cursorY + propReflow(frame, oldWidth, newWidth)
		if len(got) != 1 || got[0] != want {
			t.Logf("frame=%q cursorY=%d %d->%d: moved %v, model says %d", frame.rows, frame.cursorY, oldWidth, newWidth, got, want)
			return false
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 40, Rand: rand.New(rand.NewSource(21))}); err != nil {
		t.Fatal(err)
	}
}

// TestPropReflowModelResizeSequence checks successive narrowings, where each
// step's old width is the width the previous step drew at.
func TestPropReflowModelResizeSequence(t *testing.T) {
	f := func(seed uint64) bool {
		rng := rand.New(rand.NewSource(int64(seed)))
		height := 6 + int(seed%4)
		widths := []int{24 + int((seed>>3)%24)}
		for i := 0; i < 3 && widths[len(widths)-1] > 2; i++ {
			widths = append(widths, 2+int(rng.Intn(widths[len(widths)-1]-1)))
		}
		frame := propFrame{cursorY: 2 + int((seed>>15)%uint64(height-2))}
		for i := 0; i < height-1; i++ {
			frame.rows = append(frame.rows, propRow(rng, rng.Intn(widths[0]+8)))
		}
		frame.rows = append(frame.rows, "zzz")
		got := propResizeRows(t, frame, height, widths)
		if len(got) != len(widths)-1 {
			return false
		}
		for i := range got {
			if want := frame.cursorY + propReflow(frame, widths[i], widths[i+1]); got[i] != want {
				t.Logf("frame=%q cursorY=%d widths=%v step %d: moved %d, model says %d", frame.rows, frame.cursorY, widths, i, got[i], want)
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 15, Rand: rand.New(rand.NewSource(22))}); err != nil {
		t.Fatal(err)
	}
}
