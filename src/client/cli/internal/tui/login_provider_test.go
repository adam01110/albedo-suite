package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func newGoLogin(t *testing.T, hint string) LoginModel {
	t.Helper()
	m := NewLoginModel(&daemon.Connection{}, hint, nil)
	t.Cleanup(func() { m.Close() })
	m.SetSize(120, 30)
	return m
}

func assertGoDraft(t *testing.T, m LoginModel) {
	t.Helper()
	if m.Draft.Extension != "opencode-go" || m.Draft.BaseURL != "https://opencode.ai/zen/go/v1" || m.Draft.Protocol != "chat_completions" {
		t.Fatalf("unexpected Go draft: %+v", m.Draft)
	}
}

func TestOpenCodeGoPicker(t *testing.T) {
	m := newGoLogin(t, "")
	found := false
	for _, item := range m.ChoosePicker.items {
		if item.ID == "add-opencode-go" {
			if item.Label != "add or update OpenCode Go" {
				t.Fatalf("unexpected Go action label: %q", item.Label)
			}
			found = true
		}
	}
	if !found {
		t.Fatal("Go provider absent from chooser")
	}
	m, _ = m.Update(PickerSelectMsg{ID: "add-opencode-go"})
	if m.Step != StepName || m.Name != "opencode-go" {
		t.Fatalf("unexpected wizard start: %v %q", m.Step, m.Name)
	}
	assertGoDraft(t, m)
	m.TextInput.SetValue("go-work")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Step != StepBaseURL || m.Name != "go-work" {
		t.Fatalf("unexpected endpoint step: %v %q", m.Step, m.Name)
	}
	assertGoDraft(t, m)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Step != StepAPIKey {
		t.Fatalf("unexpected key step: %v", m.Step)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Step != StepAPIKey || m.Error == "" {
		t.Fatal("empty Go key accepted")
	}
	m.TextInput.SetValue("go-secret")
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Step != StepModels || cmd == nil || m.Draft.APIKey != "go-secret" {
		t.Fatalf("key did not advance straight to models: %v", m.Step)
	}
	assertGoDraft(t, m)
	m.Draft.Model = "glm-5"
	if _, err := m.Draft.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestOpenCodeGoHint(t *testing.T) {
	m := newGoLogin(t, "opencode-go")
	m.applyHint()
	if m.Step != StepBaseURL || m.Name != "opencode-go" || m.Hint != "" {
		t.Fatalf("unexpected hint routing: %v %q", m.Step, m.Name)
	}
	assertGoDraft(t, m)
}

func TestOpenCodeGoFirstRunChooser(t *testing.T) {
	m := newGoLogin(t, "")
	m, cmd := m.Update(signInsLoadedMsg{Gen: m.Generation, Listed: daemon.SignIns{}, Profiles: &config.Profiles{}})
	if m.Step != StepChoose || cmd == nil {
		t.Fatalf("first run did not show the provider chooser: %v", m.Step)
	}
	for _, size := range [][2]int{{80, 24}, {120, 30}} {
		m.SetSize(size[0], size[1])
		if view := ansi.Strip(m.View()); !strings.Contains(view, "add or update OpenCode Go") {
			t.Fatalf("first-run screen does not show OpenCode Go at %dx%d:\n%s", size[0], size[1], view)
		}
	}
	m, _ = m.Update(PickerSelectMsg{ID: "add-opencode-go"})
	if m.Step != StepName || m.Name != "opencode-go" {
		t.Fatalf("Go selection did not ask for its profile name: %v %q", m.Step, m.Name)
	}
	assertGoDraft(t, m)
	m.TextInput.SetValue("go-work")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Step != StepBaseURL {
		t.Fatalf("Go name did not ask for endpoint: %v", m.Step)
	}
	assertGoDraft(t, m)
}

func TestOpenCodeGoFirstRunHint(t *testing.T) {
	m := newGoLogin(t, "opencode-go")
	m, _ = m.Update(signInsLoadedMsg{Gen: m.Generation, Listed: daemon.SignIns{}, Profiles: &config.Profiles{}})
	if m.Step != StepBaseURL || m.Name != "opencode-go" {
		t.Fatalf("first-run hint did not start Go setup: %v %q", m.Step, m.Name)
	}
	assertGoDraft(t, m)
}

func TestOpenCodeGoSavedHint(t *testing.T) {
	m := newGoLogin(t, "opencode-go")
	saved := config.Settings{Extension: "openai", BaseURL: "https://example.com/v1", Model: "custom", Protocol: "responses", HasKey: true}
	m.Profiles.Providers["opencode-go"] = saved
	m.applyHint()
	if m.Step != StepSaving || m.Draft != saved {
		t.Fatalf("saved profile overwritten: %+v", m.Draft)
	}
}

func TestOpenCodeGoSavedName(t *testing.T) {
	m := newGoLogin(t, "")
	saved := config.Settings{Extension: "openai", BaseURL: "https://example.com/v1", Model: "custom", Protocol: "responses", HasKey: true}
	m.Profiles.Providers["opencode-go"] = saved
	m.Step = StepName
	m.TextInput.SetValue("opencode-go")
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Draft != saved {
		t.Fatalf("saved named profile overwritten: %+v", m.Draft)
	}
}
