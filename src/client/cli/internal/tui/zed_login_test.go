package tui

import (
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
)

func TestZedBrowserLoginAndConfirmation(t *testing.T) {
	m := NewLoginModel(&daemon.Connection{}, "zed", nil)
	t.Cleanup(func() { m.Close() })
	m.SetSize(110, 30)
	m.SignIns = []daemon.SignIn{{Provider: "zed", Label: "add Zed account", Kind: "model", Flows: []string{"browser"}}}
	if cmd := m.applyHint(); cmd == nil || m.Step != StepOAuth || m.Provider != "zed" {
		t.Fatalf("/login zed did not start browser sign-in: %+v", m)
	}
	if m.Draft.Extension != "zed" || m.Draft.Protocol != "chat_completions" || m.Draft.BaseURL != "https://cloud.zed.dev" {
		t.Fatalf("wrong Zed draft: %+v", m.Draft)
	}
	m.LoginID = "login-one"
	m.LoginETag = "waiting-etag"
	m.TextInput.SetValue("confirm")
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd != nil {
		t.Fatal("premature confirmation was submitted")
	}
	gen := m.Generation
	m, _ = m.Update(signInStatusMsg{Gen: gen, ID: m.LoginID, State: "confirming", ETag: "identity-etag", Message: "Zed account: github-user (user 42, organization org-42)"})
	if m.TextInput.Value() != "" {
		t.Fatal("queued text survived identity publication")
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "account confirmation") || !strings.Contains(view, "github-user") || strings.Contains(view, "callback URL or code") {
		t.Fatalf("identity confirmation was not distinct from callback paste: %s", view)
	}
	m.TextInput.SetValue("yes")
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd != nil || !strings.Contains(m.Error, "Type confirm") {
		t.Fatal("ambiguous confirmation accepted")
	}
	m.TextInput.SetValue("confirm")
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil || m.LoginETag != "identity-etag" || m.TextInput.Value() != "" {
		t.Fatal("current account confirmation was not submitted")
	}
}
