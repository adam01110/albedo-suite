package terminal

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

// The inline renderer draws a frame in the terminal's main screen, bottom
// first, and later redraws it in place. A reader sees whatever the terminal
// ends up holding, so these tests replay the renderer's output into a model
// terminal (suite_vt_model_test.go) and compare the visible screen with the
// last frame. The oracle never asks the renderer where anything is: it derives
// the frame's position from the frames themselves and from the rewrapping a
// terminal performs on a resize.

type suiteFrame struct {
	lines []string
	alt   bool
	// cursorRow is the frame row the visible cursor sits on, or -1.
	cursorRow int
	cursorCol int
	hasCursor bool
}

func (f *suiteFrame) content() string { return strings.Join(f.lines, "\n") }

type suiteSize struct{ w, h int }

type suiteDrawModel struct {
	frame *suiteFrame
	title string
}

type suiteDrawFrame struct{ frame *suiteFrame }
type suiteDrawTitle struct{ title string }

func (m suiteDrawModel) Init() tea.Cmd { return nil }
func (m suiteDrawModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case suiteDrawFrame:
		m.frame = msg.frame
	case suiteDrawTitle:
		m.title = msg.title
	}
	return m, nil
}

func (m suiteDrawModel) View() tea.View {
	v := tea.NewView("")
	if m.frame != nil {
		v.SetContent(m.frame.content())
		v.AltScreen = m.frame.alt
		if m.frame.hasCursor {
			v.Cursor = tea.NewCursor(m.frame.cursorCol, m.frame.cursorRow)
		}
	}
	v.WindowTitle = m.title
	return v
}

// suiteSession drives one program and mirrors its output in a model terminal.
type suiteSession struct {
	t      *testing.T
	out    *suiteSyncBuffer
	prog   *tea.Program
	done   chan error
	vt     *suiteVT
	read   int
	tok    int
	width  int
	height int
	// base is what the screen showed before the first frame.
	base []string
	// top is the screen row the frame's top row sits on, as the terminal
	// places it. alt marks a frame owning the whole screen.
	top int
	// drawn are the rows the last frame drew, clipped to the width, and phys
	// the rows the terminal holds for them: the same rows until a rewrap
	// splits one in two. curPhys is the cursor's row among phys.
	drawn   []string
	phys    []string
	curPhys int
	last    *suiteFrame
	// saved is the main screen's state while an alternate screen is up.
	saved *suiteExpect
}

type suiteExpect struct {
	top     int
	drawn   []string
	phys    []string
	curPhys int
	last    *suiteFrame
}

func suiteStart(t *testing.T, width, height int, env []string) *suiteSession {
	t.Helper()
	s := &suiteSession{
		t:      t,
		out:    &suiteSyncBuffer{},
		done:   make(chan error, 1),
		vt:     newSuiteVT(width, height),
		width:  width,
		height: height,
		top:    height - 1,
	}
	var seed strings.Builder
	for i := 0; i < height; i++ {
		fmt.Fprintf(&seed, "prior-%d", i)
		if i < height-1 {
			seed.WriteString("\r\n")
		}
	}
	// The trailing newline leaves the cursor on a blank last row, so the
	// program's own erase-in-display reaches nothing that was seeded.
	seed.WriteString("\r\n")
	if _, err := s.vt.Write([]byte(seed.String())); err != nil {
		t.Fatalf("seeding the model terminal: %v", err)
	}
	s.base = s.vt.visible()

	s.prog = tea.NewProgram(suiteDrawModel{},
		tea.WithOutput(s.out),
		tea.WithInput(nil),
		tea.WithWindowSize(width, height),
		tea.WithEnvironment(append([]string{"TERM=xterm-256color"}, env...)),
	)
	go func() { _, err := s.prog.Run(); s.done <- err }()
	s.sync()
	return s
}

// sync waits until everything sent so far has been rendered, then replays the
// new output into the model terminal. The window title changes on every step,
// so an unchanged frame still produces the marker that ends the wait.
func (s *suiteSession) sync() {
	s.t.Helper()
	s.tok++
	tok := fmt.Sprintf("s%d", s.tok)
	s.prog.Send(suiteDrawTitle{title: tok})
	suiteWaitFor(s.t, s.out, s.read, tok)
	s.feed()
}

func (s *suiteSession) feed() {
	s.t.Helper()
	chunk := s.out.from(s.read)
	if chunk == "" {
		return
	}
	s.read += len(chunk)
	if _, err := s.vt.Write([]byte(chunk)); err != nil {
		s.t.Fatalf("model terminal: %v", err)
	}
}

// draw renders a frame and updates the oracle.
func (s *suiteSession) draw(f *suiteFrame) {
	s.t.Helper()
	s.prog.Send(suiteDrawFrame{frame: f})
	s.sync()
	s.place(f)
}

// resize narrows the terminal, rewrapping the model terminal's buffer the way
// a reflowing terminal does before the renderer redraws.
func (s *suiteSession) resize(w int) {
	s.t.Helper()
	if w != s.width {
		s.rewrap(w)
		s.vt.resize(w, s.height)
		s.width = w
	}
	s.prog.Send(tea.WindowSizeMsg{Width: w, Height: s.height})
	s.sync()
	if s.last != nil {
		// The redraw paints the frame clipped to the new width, one screen row
		// per line, so the frame keeps the top the rewrap gave it.
		s.setFrame(s.last)
	}
}

// place records where the terminal will put a freshly drawn frame.
func (s *suiteSession) place(f *suiteFrame) {
	s.t.Helper()
	if f.alt {
		s.top = 0
	} else if n := min(len(f.lines), s.height); n < s.height {
		s.top = max(0, min(s.top, s.height-n))
	} else {
		s.top = 0
	}
	s.setFrame(f)
	s.last = f
}

func (s *suiteSession) setFrame(f *suiteFrame) {
	s.drawn = suiteFrameRows(f, s.width, s.height)
	s.phys = s.drawn
	s.curPhys = len(s.drawn) - 1
	if f.hasCursor {
		s.curPhys = min(max(f.cursorRow, 0), max(len(s.drawn)-1, 0))
	}
}

// rewrap models the terminal narrowing its width: each row is re-split, and the
// frame's top moves up by as many rows as the rows above the cursor gained.
func (s *suiteSession) rewrap(w int) {
	s.t.Helper()
	aboveNew := 0
	for i := 0; i < len(s.drawn) && i < s.curPhys; i++ {
		aboveNew += suiteWrapCount(s.drawn[i], w)
	}
	if s.last != nil && s.last.hasCursor {
		aboveNew += s.last.cursorCol / w
	}
	var phys []string
	for _, row := range s.drawn {
		phys = append(phys, suiteWrapRow(row, w)...)
	}
	s.phys = phys
	s.top = max(0, s.top-(aboveNew-s.curPhys))
	s.curPhys = aboveNew
}

// suiteFailure marks a property failure, so a generated case reports it rather
// than aborting the run.
type suiteFailure struct{ msg string }

// check compares the model terminal's screen with the frame it should show.
func (s *suiteSession) check(f *suiteFrame) {
	s.t.Helper()
	want := s.expected(f)
	visible := s.vt.visible()
	for i := range want {
		if got, exp := strings.TrimRight(visible[i], " "), strings.TrimRight(want[i], " "); got != exp {
			panic(suiteFailure{fmt.Sprintf("row %d: got %q, want %q\nscreen:\n%s\nwant:\n%s\nframe:\n%s",
				i, got, exp, strings.Join(visible, "\n"), strings.Join(want, "\n"),
				strings.Join(f.lines, "\n"))})
		}
	}
}

func (s *suiteSession) expected(f *suiteFrame) []string {
	rows := suiteFrameRows(f, s.width, s.height)
	want := make([]string, 0, s.height)
	if !f.alt {
		// The rows above the frame keep the screen position they had when the
		// frame reached its tallest, so the frame's top row is s.top.
		head := max(0, s.height-1-s.top)
		for i := head; i < s.height-1 && len(want) < s.top; i++ {
			want = append(want, s.base[i])
		}
	}
	want = append(want, rows...)
	for len(want) < s.height {
		want = append(want, "")
	}
	return want
}

func (s *suiteSession) stop() {
	s.prog.Quit()
	<-s.done
}

// suiteFrameRows is what a frame draws: its lines clipped to the width, and
// only the last rows when it is taller than the screen.
func suiteFrameRows(f *suiteFrame, width, height int) []string {
	rows := make([]string, 0, len(f.lines))
	for _, line := range f.lines {
		var sb strings.Builder
		used := 0
		for _, r := range line {
			w := suiteRuneWidth(string(r))
			if used+w > width {
				break
			}
			sb.WriteRune(r)
			used += w
		}
		// The renderer leaves a trailing blank cell to the terminal, which is
		// blank there already, so the row reaches it this wide and no further.
		rows = append(rows, strings.TrimRight(sb.String(), " "))
	}
	if len(rows) > height {
		rows = rows[len(rows)-height:]
	}
	return rows
}

// suiteWrapCount is how many screen rows a frame row covers once the terminal
// is width wide.
func suiteWrapCount(row string, width int) int {
	return len(suiteWrapRow(row, width))
}

func suiteWrapRow(row string, width int) []string {
	var out []string
	var sb strings.Builder
	used := 0
	for _, r := range row {
		w := suiteRuneWidth(string(r))
		if used+w > width && used > 0 {
			out = append(out, sb.String())
			sb.Reset()
			used = 0
		}
		sb.WriteRune(r)
		used += w
	}
	return append(out, sb.String())
}

// suiteEnvCount lets a longer run be asked for without editing the test.
func suiteEnvCount(def int) int {
	if v := os.Getenv("SUITE_PROP_COUNT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return def
}
