package chrome

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func saveIcons(t *testing.T) {
	t.Helper()
	icons, mark := Icon, PromptMark
	t.Cleanup(func() { Icon, PromptMark = icons, mark })
}

func TestIconsOverrideDefaults(t *testing.T) {
	got, err := parseIcons([]byte(`{"brand": "\uf135", "callFailed": "x", "agentIdle": " "}`))
	if err != nil {
		t.Fatal(err)
	}
	want := DefaultIcons
	want.Brand, want.CallFailed, want.AgentIdle = "\uf135", "x", " "
	if got != want {
		t.Fatalf("icons = %+v", got)
	}
}

func TestIconsValidation(t *testing.T) {
	// One input per rejection branch: bad JSON, a misspelt name, a non-string,
	// trailing data, an empty, wide, two-cell, control or escaped icon.
	for _, bad := range []string{
		`{`, `{"brnad": "*"}`, `{"brand": 1}`, `{"brand": "*"} {}`,
		`{"brand": ""}`, `{"brand": "🚀"}`, `{"brand": "**"}`, `{"brand": "\t"}`, `{"brand": "\u001b[31m*"}`,
	} {
		if _, err := parseIcons([]byte(bad)); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestIconsFileSelection(t *testing.T) {
	saveIcons(t)
	t.Setenv("ALBEDO_ICONS_FILE", "")
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := loadIcons(); err != nil || Icon != DefaultIcons {
		t.Fatalf("missing default: %v", err)
	}
	path := filepath.Join(dir, "albedo", "icons.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"prompt": ">", "selection": "|", "brand": "A"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := DetectInk(); err != nil {
		t.Fatal(err)
	}
	if PromptMark != "> " || !strings.Contains(SelectBar(), "|") || !strings.Contains(Brand("albedo"), "A") {
		t.Fatalf("icons not applied: %q %q %q", PromptMark, SelectBar(), Brand("albedo"))
	}
	t.Setenv("ALBEDO_ICONS_FILE", filepath.Join(dir, "missing"))
	if err := loadIcons(); err == nil {
		t.Fatal("missing explicit path accepted")
	}
	t.Setenv("ALBEDO_ICONS_FILE", path)
	before := Icon
	if err := os.WriteFile(path, []byte(`{"brand": "wide"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := loadIcons(); err == nil || Icon != before {
		t.Fatal("invalid icons changed state or succeeded")
	}
}
