package tui

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
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
	active, palette, ink, styles, hues := base16Active, base16Palette, transcriptInk, DefaultStyles, identityHues
	t.Cleanup(func() {
		base16Active, base16Palette, transcriptInk, DefaultStyles, identityHues = active, palette, ink, styles, hues
	})
}

func TestBase16Validation(t *testing.T) {
	data, want := base16Fixture(t)
	got, err := parseBase16Theme(data)
	if err != nil || got != want {
		t.Fatalf("parse = %v, %v", got, err)
	}
	for _, bad := range []string{"null", "{}", "[]", "bad", strings.Replace(string(data), want[5], "#xyzxyz", 1), strings.Replace(string(data), want[5], want[5]+"x", 1), strings.Replace(string(data), "base0F", "extra", 1), strings.TrimSuffix(string(data), "}") + `,"extra":"#112233"}`} {
		if _, err := parseBase16Theme([]byte(bad)); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestBase16DetectBypassesTerminal(t *testing.T) {
	saveBase16State(t)
	data, p := base16Fixture(t)
	path := filepath.Join(t.TempDir(), "theme.json")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ALBEDO_THEME_FILE", path)
	// No terminal is attached under go test; success requires bypassing the query.
	if err := DetectInk(); err != nil {
		t.Fatal(err)
	}
	if !base16Active || transcriptInk.bg != p[0] || transcriptInk.code != p[5] || transcriptInk.heading != p[13] {
		t.Fatalf("wrong ink: %+v", transcriptInk)
	}
	for _, pair := range []struct {
		style lipgloss.Style
		want  string
	}{
		{DefaultStyles.You, p[12]}, {DefaultStyles.Error, p[8]}, {DefaultStyles.Warning, p[10]},
		{DefaultStyles.Success, p[11]}, {DefaultStyles.EffortHigh, p[9]}, {DefaultStyles.Agent, p[14]},
	} {
		if pair.style.GetForeground() != lipgloss.Color(pair.want) {
			t.Errorf("style != %s", pair.want)
		}
	}
	if agentColors().you.hex() != p[12] || agentColors().hi.hex() != p[5] {
		t.Fatal("orchestrator ignored palette")
	}
	if hostStyle("example").GetForeground() == nil || languageStyle("Go", "").GetForeground() != lipgloss.Color(base16Nearest(languageHues["Go"])) {
		t.Fatal("identity ignored palette")
	}
	lines := HighlightLines([]string{"var x = 1"}, lexers.Get("go"), nil)
	if !strings.Contains(lines[0], "38;2;") || strings.Contains(lines[0], "38;5;") {
		t.Fatalf("highlight quantized: %q", lines)
	}
}

func TestBase16FileSelection(t *testing.T) {
	saveBase16State(t)
	t.Setenv("ALBEDO_THEME_FILE", "")
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if loaded, err := loadBase16Theme(); loaded || err != nil {
		t.Fatalf("missing default: %v, %v", loaded, err)
	}
	path := filepath.Join(dir, "albedo", "theme.json")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	data, _ := base16Fixture(t)
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if loaded, err := loadBase16Theme(); !loaded || err != nil {
		t.Fatalf("default: %v, %v", loaded, err)
	}
	t.Setenv("ALBEDO_THEME_FILE", filepath.Join(dir, "missing"))
	if _, err := loadBase16Theme(); err == nil {
		t.Fatal("missing explicit path accepted")
	}
	t.Setenv("ALBEDO_THEME_FILE", path)
	before := transcriptInk
	if err := os.WriteFile(path, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadBase16Theme(); err == nil || transcriptInk != before {
		t.Fatal("invalid theme changed state or succeeded")
	}
}
