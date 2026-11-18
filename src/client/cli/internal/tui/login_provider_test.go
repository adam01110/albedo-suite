package tui

import (
	"reflect"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
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
	if m.Draft.Extension != "opencode-go" || m.Draft.BaseURL != "https://opencode.ai/inference/go/v1" || m.Draft.Protocol != "chat_completions" {
		t.Fatalf("unexpected Go draft: %+v", m.Draft)
	}
}

func TestOpenCodeGoHint(t *testing.T) {
	m := newGoLogin(t, "opencode-go")
	m.applyHint()
	if m.Step != StepBaseURL || m.Name != "opencode-go" || m.Hint != "" {
		t.Fatalf("unexpected hint routing: %v %q", m.Step, m.Name)
	}
	assertGoDraft(t, m)
	// The hint still starts Go setup when it arrives with the sign-in list.
	m = newGoLogin(t, "opencode-go")
	m, _ = m.Update(signInsLoadedMsg{Gen: m.Generation, Listed: daemon.SignIns{}, Profiles: &config.Profiles{}})
	if m.Step != StepBaseURL || m.Name != "opencode-go" {
		t.Fatalf("first-run hint did not start Go setup: %v %q", m.Step, m.Name)
	}
	assertGoDraft(t, m)
}

// A saved profile named opencode-go wins over the Go defaults, whether it was
// selected by the hint or typed at the name step.
func TestOpenCodeGoSavedProfile(t *testing.T) {
	saved := config.Settings{Extension: "openai", BaseURL: "https://example.com/v1", Model: "custom", Protocol: "responses", HasKey: true}
	t.Run("hint", func(t *testing.T) {
		m := newGoLogin(t, "opencode-go")
		m.Profiles.Providers["opencode-go"] = saved
		m.applyHint()
		if m.Step != StepSaving || !reflect.DeepEqual(m.Draft, saved) {
			t.Fatalf("saved profile overwritten: %+v", m.Draft)
		}
	})
	t.Run("typed name", func(t *testing.T) {
		m := newGoLogin(t, "")
		m.Profiles.Providers["opencode-go"] = saved
		m.Step = StepName
		m.TextInput.SetValue("opencode-go")
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
		if !reflect.DeepEqual(m.Draft, saved) {
			t.Fatalf("saved named profile overwritten: %+v", m.Draft)
		}
	})
}
