package chrome

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
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
	ink, styles := CurrentInk, DefaultStyles
	t.Cleanup(func() { CurrentInk, DefaultStyles = ink, styles })
}

func TestBase16Validation(t *testing.T) {
	data, want := base16Fixture(t)
	got, err := parseBase16Theme(data)
	if err != nil || got != want {
		t.Fatalf("parse = %v, %v", got, err)
	}
	// One input per rejection branch: unparsable JSON, a bad slot value, an extra key.
	for _, bad := range []string{"bad", strings.Replace(string(data), want[5], "#xyzxyz", 1), strings.TrimSuffix(string(data), "}") + `,"extra":"#112233"}`} {
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
	if !CurrentInk.Base16() || CurrentInk.bg != p[0] || CurrentInk.Code != p[5] || CurrentInk.Heading != p[13] {
		t.Fatalf("wrong ink: %+v", CurrentInk)
	}
	for _, pair := range []struct {
		style lipgloss.Style
		want  string
	}{
		{DefaultStyles.You, p[12]}, {DefaultStyles.Error, p[8]}, {DefaultStyles.Warning, p[10]},
		{DefaultStyles.Success, p[11]}, {DefaultStyles.Agent, p[14]},
	} {
		if pair.style.GetForeground() != lipgloss.Color(pair.want) {
			t.Errorf("style != %s", pair.want)
		}
	}
	if AgentColors().You.Hex() != p[12] || AgentColors().Hi.Hex() != p[5] {
		t.Fatal("orchestrator ignored palette")
	}
	// "Go" is #6fd1c4; its nearest palette slot is base0F (#c4a76c).
	if got := LanguageStyle("Go", "").GetForeground(); got != lipgloss.Color(p[15]) {
		t.Fatalf("language label %v, want palette slot %s", got, p[15])
	}
	// Footer keys stay in the palette's text color, not the bold accent.
	if got, want := KeyHints(Hint{Key: "esc", Does: "back"}), DefaultStyles.Muted.Render("esc")+" "+DefaultStyles.Faint.Render("back"); got != want {
		t.Fatalf("key hints %q, want %q", got, want)
	}
	host := HostStyle("host").GetForeground()
	if !slices.ContainsFunc(base16Hues(p), func(hue string) bool { return lipgloss.Color(hue) == host }) {
		t.Fatalf("host label %v outside the palette", host)
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
	before := CurrentInk
	if err := os.WriteFile(path, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadBase16Theme(); err == nil || CurrentInk != before {
		t.Fatal("invalid theme changed state or succeeded")
	}
}
