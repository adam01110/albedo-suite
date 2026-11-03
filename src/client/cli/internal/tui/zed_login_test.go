package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"github.com/charmbracelet/x/ansi"
	"net"
	"net/http"
	"net/http/httptest"
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

// The Zed extension signs in through the browser, so the chooser must not offer
// a second Zed row that asks for an API key instead.
func TestZedChooserOffersOnlyBrowserSignIn(t *testing.T) {
	m := NewLoginModel(&daemon.Connection{}, "", nil)
	t.Cleanup(func() { m.Close() })
	m.SetSize(120, 30)
	m.SignIns = []daemon.SignIn{{Provider: "zed", Label: "add Zed account", Kind: "model", Flows: []string{"browser"}}}
	m.buildChoosePicker()
	var zed []loginItem
	for _, item := range m.ChoosePicker.items {
		if strings.Contains(item.Label, "Zed") {
			zed = append(zed, item)
		}
	}
	if len(zed) != 1 || zed[0].ID != "signin:zed" {
		t.Fatalf("Zed chooser rows: %+v", zed)
	}
	m, _ = m.Update(PickerSelectMsg{ID: "signin:zed"})
	if m.Step != StepProfileName {
		t.Fatalf("Zed sign-in did not ask for a profile name: %v", m.Step)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Step != StepOAuth || m.Provider != "zed" || m.Draft.Extension != "zed" ||
		m.Draft.BaseURL != "https://cloud.zed.dev" || m.Draft.Protocol != "chat_completions" {
		t.Fatalf("Zed sign-in did not start: %v %q %+v", m.Step, m.Provider, m.Draft)
	}
}

func TestZedSavedProfileUsesExistingAccount(t *testing.T) {
	for _, signedIn := range []bool{false, true} {
		m := NewLoginModel(&daemon.Connection{}, "", nil)
		t.Cleanup(func() { m.Close() })
		m.SignIns = []daemon.SignIn{{Provider: "zed", Flows: []string{"browser"}}}
		if signedIn {
			m.Accounts = []daemon.Account{{ID: "account-one", Provider: "zed", Kind: "oauth"}}
		}
		settings := config.Settings{Extension: "zed", Model: "claude-sonnet-4-6"}
		cmd := m.useProfile("saved-zed", settings)
		want := StepOAuth
		if signedIn {
			want = StepSaving
		}
		if cmd == nil || m.Step != want {
			t.Fatalf("signedIn=%v: got step %v, want %v", signedIn, m.Step, want)
		}
	}
}

// A saved Zed profile can still carry a key from the removed manual-JWT path.
// /login must start browser sign-in anyway, describe the key as unused, and not
// save it again.
func TestZedSavedProfileSignsInWithAKey(t *testing.T) {
	keyed := config.Settings{
		Extension: "zed", BaseURL: "https://cloud.zed.dev", Protocol: "chat_completions",
		Model: "claude-sonnet-4-6", APIKey: "stale-zed-jwt", HasKey: true,
	}
	saved := func() LoginModel {
		m := NewLoginModel(&daemon.Connection{}, "", nil)
		m.SetSize(120, 30)
		m.SignIns = []daemon.SignIn{{Provider: "zed", Label: "add Zed account", Kind: "model", Flows: []string{"browser"}}}
		m.Accounts = []daemon.Account{{ID: "account-one", Provider: "zed", Label: "github-user", Kind: "oauth"}}
		m.Profiles = config.Profiles{Providers: map[string]config.Settings{"zed": keyed}, Active: "zed"}
		m.buildChoosePicker()
		return m
	}

	m := saved()
	t.Cleanup(func() { m.Close() })
	if detail := m.profileDetail(keyed, "zed"); strings.Contains(detail, "API key") {
		t.Fatalf("Zed profile described as api key authenticated: %q", detail)
	}
	m, cmd := m.Update(PickerSelectMsg{ID: "use:zed"})
	if cmd == nil || m.Step != StepOAuth || m.Provider != "zed" {
		t.Fatalf("saved Zed profile did not start sign-in: %v %q", m.Step, m.Provider)
	}
	if m.Draft.APIKey != "" || m.Draft.HasKey {
		t.Fatalf("Zed sign-in kept the profile's key: %+v", m.Draft)
	}

	hinted := saved()
	t.Cleanup(func() { hinted.Close() })
	hinted.Hint = "zed"
	if cmd := hinted.applyHint(); cmd == nil || hinted.Step != StepOAuth || hinted.Provider != "zed" {
		t.Fatalf("/login zed on a keyed profile did not start sign-in: %v %q", hinted.Step, hinted.Provider)
	}
	if hinted.Draft.APIKey != "" || hinted.Draft.HasKey {
		t.Fatalf("/login zed kept the profile's key: %+v", hinted.Draft)
	}
}

// TestZedBrowserSignInClearsAStoredKey starts from the profile the refusal names,
// a saved Zed profile that still carries an apiKey, and checks the save the
// browser sign-in issues: the daemon keeps an omitted key, so signing in has to
// send an explicit null or the profile keeps refusing every later turn.
func TestZedBrowserSignInClearsAStoredKey(t *testing.T) {
	var saved map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch || r.URL.RequestURI() != "/settings?group=providers" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.RequestURI())
			return
		}
		if got := r.Header.Get("If-Match"); got != "providers-etag" {
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
				"etag": "next-etag",
				"url":  "/settings?group=providers",
				"value": map[string]any{
					"profiles":        map[string]any{},
					"default_profile": "zed",
				},
			},
		})
	}))
	defer server.Close()

	keyed := config.Settings{
		Extension: "zed", BaseURL: "https://cloud.zed.dev", Protocol: "chat_completions",
		Model: "claude-sonnet-4-6", APIKey: "stale-zed-jwt", HasKey: true,
	}
	conn := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	defer conn.HTTPClient().CloseIdleConnections()
	m := NewLoginModel(conn, "", nil)
	defer m.Close()
	m.SetSize(120, 30)
	m.Profiles = config.Profiles{Providers: map[string]config.Settings{"zed": keyed}, ETag: "providers-etag"}
	m.Name = "zed"
	m.Draft = signedInDraft(keyed, "zed")
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
