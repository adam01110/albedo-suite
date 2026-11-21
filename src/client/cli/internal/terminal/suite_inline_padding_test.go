package terminal

import (
	"strconv"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// A frame row padded with spaces to the terminal's width reaches the terminal
// as the cells before the padding: the renderer leaves a trailing blank cell
// alone, because the terminal's cell there is blank already. Narrowing must
// count the rows the terminal will rewrap, so padding changes nothing about how
// far up the redraw starts. Counting it made the redraw begin one row above the
// frame, erasing the last row of whatever the terminal showed before it.
func TestSuiteInlineResizeIgnoresUnwrittenPadding(t *testing.T) {
	const width, narrowed = 21, 20
	for _, tc := range []struct {
		name  string
		first string
		want  int
	}{
		{name: "no padding", first: "row one", want: 1},
		{name: "padded to the width", first: "row one" + strings.Repeat(" ", 14), want: 1},
		{name: "padded past the width", first: "row one" + strings.Repeat(" ", 20), want: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			frame := tc.first + "\nstatus"
			out := &suiteSyncBuffer{}
			p := tea.NewProgram(suiteFrameModel{frame: frame},
				tea.WithOutput(out), tea.WithInput(nil), tea.WithWindowSize(width, 12),
				tea.WithEnvironment([]string{"TERM=xterm-256color"}))
			done := make(chan error, 1)
			go func() { _, err := p.Run(); done <- err }()
			defer func() {
				p.Quit()
				<-done
			}()

			suiteWaitFor(t, out, 0, "status")
			mark := out.Len()
			p.Send(tea.WindowSizeMsg{Width: narrowed, Height: 12})
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
