// Per-account availability on the /accounts list: ctrl+t switches one
// account off or on through PATCH /auth/accounts/{id}, leaving its service's
// other accounts and every setup alone.
package tui

import (
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"strings"
	"sync"
	"testing"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	"albedo/cli/internal/tui/chrome"

	"github.com/charmbracelet/x/ansi"
)

// accountToggleDaemon answers /auth with the fixture accounts, applying
// every account patch it receives, and records those patches. It refuses
// every settings write, so a test sees one go out.
func accountToggleDaemon(t *testing.T) (LoginModel, func() []map[string]any, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var patches []map[string]any
	var settings []string
	disabled := map[string]bool{}
	wire := func(a daemon.Account) map[string]any {
		rotated := a.RotatedByProfiles
		if rotated == nil {
			rotated = []string{}
		}
		return map[string]any{"id": a.ID, "provider": a.Provider, "label": a.Label, "detail": "", "kind": a.Kind, "source": a.Source,
			"endpoint": nil, "limited_until": nil, "email": nil, "plan": nil, "needs_sign_in": false, "enabled": !disabled[a.ID],
			"selected_by_profiles": []string{}, "rotated_by_profiles": rotated}
	}
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch {
		case r.Method == http.MethodPatch && strings.HasPrefix(r.URL.Path, "/auth/accounts/"):
			id := strings.TrimPrefix(r.URL.Path, "/auth/accounts/")
			data, _ := io.ReadAll(r.Body)
			var body map[string]any
			if err := json.Unmarshal(data, &body); err != nil {
				t.Errorf("patch body is not JSON: %s", data)
			}
			patches = append(patches, map[string]any{"id": id, "body": body})
			if enabled, ok := body["enabled"].(bool); ok {
				disabled[id] = !enabled
			}
			for _, a := range accountsFixture() {
				if a.ID == id {
					_ = json.NewEncoder(w).Encode(wire(a))
					return
				}
			}
			testwire.WriteProblem(w, http.StatusNotFound, "account_unknown", "Unknown provider account.")
		case r.Method != http.MethodGet && strings.HasPrefix(r.URL.Path, "/settings"):
			settings = append(settings, r.Method+" "+r.URL.String())
			testwire.WriteProblem(w, http.StatusPreconditionFailed, "precondition_failed", "refused by the test")
		case r.URL.Path == "/auth":
			accounts := []any{}
			for _, a := range accountsFixture() {
				accounts = append(accounts, wire(a))
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"providers": []any{}, "accounts": accounts})
		case r.URL.Path == "/settings":
			_ = json.NewEncoder(w).Encode(testwire.Settings())
		default:
			t.Errorf("unexpected request %s %s", r.Method, r.URL)
			w.WriteHeader(http.StatusNotFound)
		}
	})
	m := accountsModel(140, 40)
	m.Conn = conn
	m.Profiles.ETag = `"providers-1"`
	read := func() []map[string]any { mu.Lock(); defer mu.Unlock(); return slices.Clone(patches) }
	writes := func() []string { mu.Lock(); defer mu.Unlock(); return slices.Clone(settings) }
	return m, read, writes
}

func accountByID(t *testing.T, m LoginModel, id string) daemon.Account {
	t.Helper()
	a, ok := m.accountByID(id)
	if !ok {
		t.Fatalf("account %s is not listed", id)
	}
	return a
}

func TestAccountAvailabilityTogglesOneAccountOnly(t *testing.T) {
	m, patches, settings := accountToggleDaemon(t)
	focusLoginRow(&m, "acct:me")
	if !slices.Contains(m.accountsHints(140), chrome.Hint{Key: "ctrl+t", Does: "disable"}) {
		t.Fatalf("an enabled account offers no disable: %v", m.accountsHints(140))
	}
	m, cmd := pressCtrl(m, 't')
	if m.Step != StepSaving || cmd == nil {
		t.Fatalf("ctrl+t did not start a change: step %v", m.Step)
	}
	m = settleLogin(m, cmd)
	got := patches()
	if len(got) != 1 || got[0]["id"] != "me" || len(got[0]["body"].(map[string]any)) != 1 || got[0]["body"].(map[string]any)["enabled"] != false {
		t.Fatalf("ctrl+t sent %v", got)
	}
	if writes := settings(); len(writes) != 0 {
		t.Fatalf("ctrl+t changed setups: %v", writes)
	}
	if m.Step != StepChoose || m.Error != "" {
		t.Fatalf("list did not come back: step %v error %q", m.Step, m.Error)
	}
	if !accountByID(t, m, "me").Disabled || accountByID(t, m, "work").Disabled || accountByID(t, m, "gpt").Disabled {
		t.Fatalf("only the highlighted account should be disabled: %+v", m.Accounts)
	}
	for name, settings := range m.Profiles.Providers {
		if !settings.IsEnabled() {
			t.Fatalf("setup %s was disabled", name)
		}
	}
	if row, ok := m.ChoosePicker.highlighted(); !ok || row.key != "acct:me" {
		t.Fatalf("cursor left the toggled account: %v", row.key)
	}
	view := plainView(m)
	if !strings.Contains(view, "disabled") {
		t.Fatalf("the disabled account is not marked:\n%s", view)
	}
	// Its service keeps running on the other account.
	if c := m.signOutConsequence(accountByID(t, m, "work")); !strings.Contains(c, "Claude models stop") {
		t.Fatalf("a disabled sibling still counts as running: %q", c)
	}

	// ctrl+t again enables it.
	if !slices.Contains(m.accountsHints(140), chrome.Hint{Key: "ctrl+t", Does: "enable"}) {
		t.Fatalf("a disabled account offers no enable: %v", m.accountsHints(140))
	}
	m, cmd = pressCtrl(m, 't')
	m = settleLogin(m, cmd)
	got = patches()
	if len(got) != 2 || got[1]["body"].(map[string]any)["enabled"] != true || accountByID(t, m, "me").Disabled {
		t.Fatalf("second ctrl+t sent %v; disabled %v", got, accountByID(t, m, "me").Disabled)
	}
}

func TestAccountAvailabilityRefusesEnvironmentAndToolAccounts(t *testing.T) {
	m := accountsModel(140, 40)
	m.Accounts = append(m.Accounts,
		daemon.Account{Provider: "openai", ID: "env", Label: "$OPENAI_API_KEY", Kind: "key", Source: "env"},
		daemon.Account{Provider: "colab", ID: "colab-1", Label: "ana@valefar", Kind: "service", Source: "saved"},
	)
	m.buildChoosePicker()
	for _, id := range []string{"env", "colab-1"} {
		focusLoginRow(&m, "acct:"+id)
		if slices.ContainsFunc(m.accountsHints(140), func(h chrome.Hint) bool { return h.Key == "ctrl+t" }) {
			t.Fatalf("%s offers ctrl+t", id)
		}
		next, cmd := pressCtrl(m, 't')
		if cmd != nil || next.Step != StepChoose || next.Status == "" {
			t.Fatalf("%s: ctrl+t sent a change or said nothing: step %v status %q", id, next.Step, next.Status)
		}
	}
}

func TestAccountAvailabilityRowAndPaneSayDisabled(t *testing.T) {
	m := accountsModel(140, 40)
	m.Accounts[0].Disabled = true
	m.buildChoosePicker()
	focusLoginRow(&m, "acct:me")
	_, short, _ := accountState(m.Accounts[0])
	if !strings.Contains(short, "disabled") {
		t.Fatalf("row status %q", short)
	}
	pane := ansi.Strip(strings.Join(m.accountPane(m.Accounts[0], 200), " "))
	if !strings.Contains(pane, "ctrl+t enables it again") {
		t.Fatalf("pane does not say how to enable:\n%s", pane)
	}
}
