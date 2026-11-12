package terminal

import (
	"bytes"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// A narrowed terminal rewraps the frame it holds, so a frame row wider than the
// new width now covers two terminal rows and the redraw has further to move up
// to reach the frame's top. Moving up only by the cursor's row leaves the top of
// the old frame above the new one (charmbracelet/bubbletea#1867).
func TestSuiteInlineResizeSkipsReflowedRows(t *testing.T) {
	for _, tc := range []struct {
		name string
		rule string
		to   int
		env  []string
		want int
	}{
		// Ghostty on Hyprland narrows by one column (and one row) when the
		// window loses focus: a full-width row now covers two rows.
		{name: "unfocus narrows one column", rule: strings.Repeat("-", 100), to: 99, want: 3},
		// The rule spans 99 of 100 columns, so at 60 it covers two rows.
		{name: "rewrapping terminal", rule: strings.Repeat("-", 99), to: 60, want: 3},
		// A row wider than the screen was drawn clipped to it, so only the
		// clipped part rewraps.
		{name: "clipped row", rule: strings.Repeat("-", 150), to: 60, want: 3},
		// GNU screen truncates instead of rewrapping.
		{name: "screen", rule: strings.Repeat("-", 99), to: 60, want: 2, env: []string{"STY=12345.pts-0.host"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			frame := "\n" + tc.rule + "\n> \n" + tc.rule + "\nstatus"
			out := &suiteSyncBuffer{}
			p := tea.NewProgram(suiteFrameModel{frame: frame},
				tea.WithOutput(out), tea.WithInput(nil), tea.WithWindowSize(100, 24),
				tea.WithEnvironment(append([]string{"TERM=xterm-256color"}, tc.env...)))
			done := make(chan error, 1)
			go func() { _, err := p.Run(); done <- err }()
			defer func() {
				p.Quit()
				<-done
			}()

			suiteWaitFor(t, out, 0, "status")
			mark := out.Len()
			p.Send(tea.WindowSizeMsg{Width: tc.to, Height: 24})
			after := suiteWaitFor(t, out, mark, ansi.EraseScreenBelow)

			prefix, _, _ := strings.Cut(after, ansi.EraseScreenBelow)
			rows := 0
			for _, m := range suiteCursorUp.FindAllStringSubmatch(prefix, -1) {
				n := 1
				if m[1] != "" {
					n, _ = strconv.Atoi(m[1])
				}
				rows += n
			}
			if rows != tc.want {
				t.Fatalf("moved up %d rows before erasing, want %d: %q", rows, tc.want, after)
			}
		})
	}
}

var suiteCursorUp = regexp.MustCompile(`\x1b\[(\d*)A`)

type suiteFrameModel struct{ frame string }

func (m suiteFrameModel) Init() tea.Cmd                       { return nil }
func (m suiteFrameModel) Update(tea.Msg) (tea.Model, tea.Cmd) { return m, nil }
func (m suiteFrameModel) View() tea.View {
	v := tea.NewView(m.frame)
	v.Cursor = tea.NewCursor(2, 2)
	return v
}

type suiteSyncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *suiteSyncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *suiteSyncBuffer) Len() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Len()
}

func (b *suiteSyncBuffer) from(at int) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()[at:]
}

// suiteWaitFor returns the output written since at once it contains want.
func suiteWaitFor(t *testing.T, b *suiteSyncBuffer, at int, want string) string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if got := b.from(at); strings.Contains(got, want) {
			return got
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("output never contained %q: %q", want, b.from(at))
	return ""
}
