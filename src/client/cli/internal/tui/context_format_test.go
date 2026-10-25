package tui

import (
	"albedo/cli/internal/daemon"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestContextFormattingCatalog(t *testing.T) {
	content := "<extension-context name=\"mcp\">\nConfigured servers.\n" +
		`[{"name":"canvas","count":9007199254740993,"description":"Read <assignments>"}]` +
		"\n</extension-context>"
	markdown := contextMarkdown(content)
	for _, want := range []string{"```json", `  {`, `    "name": "canvas"`, "9007199254740993"} {
		if !strings.Contains(markdown, want) {
			t.Fatalf("missing %q in formatted catalog:\n%s", want, markdown)
		}
	}
	plain := ansi.Strip(strings.Join(formattedContextRows(content, 80), "\n"))
	for _, want := range []string{`<extension-context name="mcp">`, "</extension-context>", "canvas", "Read <assignments>"} {
		if !strings.Contains(plain, want) {
			t.Fatalf("renderer hid %q:\n%s", want, plain)
		}
	}
}

func TestContextFormattingPreservesFencesAndPartialPages(t *testing.T) {
	code := "```text\n<example>\n{\"value\":1}\n```\n"
	if got := contextMarkdown(code); got != code {
		t.Fatalf("code changed: %q", got)
	}
	for _, partial := range []string{`[{"name":"can`, `vas"}]`, `{"incomplete":`, "    indented code"} {
		if got := contextMarkdown(partial); !strings.Contains(got, partial) || strings.Contains(got, "```json") {
			t.Fatalf("partial page was rewritten: %q", got)
		}
	}
	content := `<tag value="` + "```" + `">`
	if !strings.HasPrefix(contextMarkdown(content), "\n````text\n") {
		t.Fatal("wrapper fence can be closed by its content")
	}
}

func TestContextFormattingSpacingAndMarkdown(t *testing.T) {
	line := strings.Repeat("Independent rule. ", 20)
	markdown := contextMarkdown(line + "\nNext rule.\n\n# Heading\n\n- first\n- second\n")
	if !strings.Contains(markdown, line+"  \n\nNext rule.") {
		t.Fatal("long instruction rules should have paragraph spacing")
	}
	plain := ansi.Strip(strings.Join(formattedContextRows(markdown, 80), "\n"))
	if strings.Contains(plain, "# Heading") || !strings.Contains(plain, "Heading") || !strings.Contains(plain, "first") {
		t.Fatalf("Markdown was not rendered:\n%s", plain)
	}
}

func TestContextFormattingRawToggleAndCache(t *testing.T) {
	content := "# Heading\n\n[{\"name\":\"canvas\"}]"
	page := &daemon.ContextPage{Content: content}
	d := &ContextDetail{Value: page, Section: daemon.ContextSection{Pages: 2}, Scroll: 10}
	m := ContextInspectorModel{Detail: d}
	formatted := strings.Join(d.rows(100), "\n")
	if strings.Contains(ansi.Strip(formatted), "# Heading") {
		t.Fatal("default view is not formatted")
	}
	m, cmd := m.readerKey(tea.KeyPressMsg{Code: 'r', Text: "r"})
	if cmd != nil || !d.Raw || d.Scroll != 0 || m.Detail != d {
		t.Fatal("toggle should be local and reset scroll")
	}
	if got := strings.Join(d.rows(100), "\n"); got != content {
		t.Fatalf("raw view changed the source: %q", got)
	}
	m, _ = m.readerKey(tea.KeyPressMsg{Code: 'r', Text: "r"})
	if got := strings.Join(d.rows(100), "\n"); got != formatted || d.Raw {
		t.Fatal("toggle reused the wrong cached rows")
	}
	if page.Content != content {
		t.Fatal("formatting mutated the request snapshot")
	}
	for _, width := range []int{1, 2, 20, 80} {
		for _, raw := range []bool{true, false} {
			d.Raw = raw
			for _, row := range d.rows(width) {
				if ansi.StringWidth(row) > width {
					t.Fatalf("row exceeds width %d (raw=%v): %q", width, raw, row)
				}
			}
		}
	}
	page2 := &daemon.ContextPage{Content: "Replacement page"}
	d.Value = page2
	if got := ansi.Strip(strings.Join(d.rows(80), "\n")); !strings.Contains(got, "Replacement page") {
		t.Fatal("page change reused old rows")
	}
}
