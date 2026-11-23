package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"github.com/charmbracelet/x/ansi"
	"net/http"
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
	// The sign-in runs on the accounts list; the daemon joins the account to
	// the Zed profiles, so no draft profile is built here.
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

// A saved Zed profile signs in through the browser whether or not an account is
// already linked. A key it still carries from the removed manual-JWT path is
// reported as unused and never saved again.
func TestZedSavedProfileSignIn(t *testing.T) {
	keyless := config.Settings{Extension: "zed", Model: "claude-sonnet-4-6"}
	keyed := config.Settings{
		Extension: "zed", BaseURL: "https://cloud.zed.dev", Protocol: "chat_completions",
		Model: "claude-sonnet-4-6", APIKey: "stale-zed-jwt", HasKey: true,
	}
	for _, tc := range []struct {
		name     string
		settings config.Settings
		accounts []daemon.Account
		want     LoginStep
		detail   string
	}{
		{name: "keyless signed out", settings: keyless, want: StepOAuth, detail: "claude-sonnet-4-6 · zed · signed out"},
		{name: "keyless signed in", settings: keyless, want: StepSaving, detail: "claude-sonnet-4-6 · zed",
			accounts: []daemon.Account{{ID: "account-one", Provider: "zed", Kind: "oauth"}}},
		{name: "stale key", settings: keyed, want: StepOAuth, detail: "claude-sonnet-4-6 · zed · stored key unused",
			accounts: []daemon.Account{{ID: "account-one", Provider: "zed", Label: "github-user", Kind: "oauth"}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := NewLoginModel(&daemon.Connection{}, "", nil)
			t.Cleanup(func() { m.Close() })
			m.SetSize(120, 30)
			m.SignIns = []daemon.SignIn{{Provider: "zed", Label: "add Zed account", Kind: "model", Flows: []string{"browser"}}}
			m.Accounts = tc.accounts
			m.Profiles = config.Profiles{Providers: map[string]config.Settings{"zed": tc.settings}, Active: "zed"}
			showSetups(&m)
			if detail := m.profileDetail(tc.settings, "zed"); detail != tc.detail {
				t.Fatalf("profile detail %q, want %q", detail, tc.detail)
			}
			m, cmd := m.Update(PickerSelectMsg{ID: "use:zed"})
			if cmd == nil || m.Step != tc.want || (tc.want == StepOAuth && m.Provider != "zed") {
				t.Fatalf("saved Zed profile did not sign in: %v %q", m.Step, m.Provider)
			}
			if m.Draft.APIKey != "" || m.Draft.HasKey {
				t.Fatalf("Zed sign-in kept the profile's key: %+v", m.Draft)
			}
		})
	}
}

// TestZedBrowserSignInClearsAStoredKey starts from the profile the refusal names,
// a saved Zed profile that still carries an apiKey, and checks the save the
// browser sign-in issues: the daemon keeps an omitted key, so signing in has to
// send an explicit null or the profile keeps refusing every later turn.
func TestZedBrowserSignInClearsAStoredKey(t *testing.T) {
	var saved map[string]any
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch || r.URL.RequestURI() != "/settings/providers" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.RequestURI())
			return
		}
		if got := r.Header.Get("If-Match"); got != `"providers-etag"` {
			t.Errorf("save dropped the observed revision: %q", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&saved); err != nil {
			t.Error(err)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"application": map[string]any{
				"active_service_revision": nil,
				"composition_changed":     false,
				"desired_revision":        "revision",
				"validation":              "not_applicable",
				"warnings":                []any{},
			},
			"group": "providers",
			"resource": map[string]any{
				"etag": `"next-etag"`,
				"url":  "/settings/providers",
				"value": map[string]any{
					"profiles":        map[string]any{},
					"default_profile": "zed",
				},
			},
		})
	})

	keyed := config.Settings{
		Extension: "zed", BaseURL: "https://cloud.zed.dev", Protocol: "chat_completions",
		Model: "claude-sonnet-4-6", APIKey: "stale-zed-jwt", HasKey: true,
	}
	m := NewLoginModel(conn, "", nil)
	defer m.Close()
	m.SetSize(120, 30)
	m.Profiles = config.Profiles{Providers: map[string]config.Settings{"zed": keyed}, ETag: `"providers-etag"`}
	m.Name = "zed"
	m.Draft = keyed
	m.beginSignIn(daemon.SignIn{Provider: "zed", Flows: []string{"browser"}})
	m.Step = StepSaving
	cmd := m.saveProviderCmd(m.Name, m.Draft)
	if cmd == nil {
		t.Fatal("sign-in save produced no command")
	}
	if result, ok := cmd().(providerSavedMsg); !ok || result.Err != nil {
		t.Fatalf("sign-in save failed: %+v", result)
	}
	profiles, ok := saved["profiles"].(map[string]any)
	if !ok {
		t.Fatalf("save sent no profile patch: %+v", saved)
	}
	patch, ok := profiles["zed"].(map[string]any)
	if !ok {
		t.Fatalf("save sent no zed profile: %+v", profiles)
	}
	key, present := patch["api_key"]
	if !present || key != nil {
		t.Fatalf("sign-in left the stored key in place: %+v", patch)
	}
	if strings.Contains(mustJSON(t, saved), "stale-zed-jwt") {
		t.Fatalf("save re-sent the leftover key: %+v", saved)
	}
	if saved["default_profile"] != "zed" || patch["model"] != "claude-sonnet-4-6" || patch["endpoint"] != "https://cloud.zed.dev" {
		t.Fatalf("sign-in save changed more than the key: %+v", saved)
	}
}
