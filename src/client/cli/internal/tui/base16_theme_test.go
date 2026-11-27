package tui

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"albedo/cli/internal/tui/chrome"

	"github.com/alecthomas/chroma/v2/lexers"
)

func base16Fixture(t *testing.T) ([]byte, [16]string) {
	t.Helper()
	var p [16]string
	values := map[string]string{}
	for i := range p {
		p[i] = fmt.Sprintf("#%02x%02x%02x", i*13+1, i*11+2, i*7+3)
		values[fmt.Sprintf("base%02X", i)] = p[i]
	}
	data, err := json.Marshal(values)
	if err != nil {
		t.Fatal(err)
	}
	return data, p
}

func saveBase16State(t *testing.T) {
	t.Helper()
	ink, styles := chrome.CurrentInk, chrome.DefaultStyles
	t.Cleanup(func() { chrome.CurrentInk, chrome.DefaultStyles = ink, styles })
}

func TestBase16HighlightKeepsTrueColor(t *testing.T) {
	saveBase16State(t)
	_, p := base16Fixture(t)
	chrome.UseBase16Theme(p)
	lines := HighlightLines([]string{"var x = 1"}, lexers.Get("go"), nil)
	if !strings.Contains(lines[0], "38;2;") || strings.Contains(lines[0], "38;5;") {
		t.Fatalf("highlight quantized: %q", lines)
	}
}
