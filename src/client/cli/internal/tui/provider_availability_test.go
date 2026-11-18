package tui

import (
	"encoding/json"
	"io"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestProviderAvailabilityTogglePatchesOnlyEnabledWithValidator(t *testing.T) {
	for _, enabled := range []bool{true, false} {
		t.Run(map[bool]string{true: "disable", false: "enable"}[enabled], func(t *testing.T) {
			m, patches := providersDaemon(t)
			profile := m.Profiles.Providers["claude"]
			profile.Enabled = &enabled
			m.Profiles.Providers["claude"] = profile
			showSetups(&m)
			focusLoginRow(&m, "use:claude")
			verb := "enable"
			if enabled {
				verb = "disable"
			}
			if !slices.Contains(m.hints(), hint{"ctrl+t", verb}) {
				t.Fatalf("missing toggle hint: %v", m.hints())
			}
			next, cmd := pressCtrl(m, 't')
			if cmd == nil || next.Step != StepSaving {
				t.Fatalf("toggle did not save: %v", next.Step)
			}
			msg := cmd()
			var patch providerPatch
			select {
			case patch = <-patches:
			default:
				t.Fatal("toggle sent no providers patch")
			}
			profiles := patch.body["profiles"].(map[string]any)
			if len(profiles) != 1 || profiles["claude"].(map[string]any)["enabled"] != !enabled {
				t.Fatalf("toggle sent %s", mustJSON(t, patch.body))
			}
			next, _ = next.Update(msg)
			if next.Step != StepAdvanced || next.Error == "" {
				t.Fatalf("refusal not shown: %+v", next)
			}
			if next.Profiles.Providers["claude"].IsEnabled() != enabled {
				t.Fatal("failed toggle changed state")
			}
			if name, _ := next.highlightedProfile(); name != "claude" {
				t.Fatalf("cursor moved to %s", name)
			}
		})
	}
}

func TestProviderAvailabilityDisabledRowStaysVisibleAndCannotBeSelected(t *testing.T) {
	m := loginModel(100, 24)
	profile := m.Profiles.Providers["work"]
	enabled := false
	profile.Enabled = &enabled
	m.Profiles.Providers["work"] = profile
	showSetups(&m)
	focusLoginRow(&m, "use:work")
	if view := ansi.Strip(m.View()); !strings.Contains(view, "disabled") || !strings.Contains(view, "ctrl+t") {
		t.Fatalf("missing disabled state or hint:\n%s", view)
	}
	next, cmd := m.Update(PickerSelectMsg{ID: "use:work"})
	if cmd != nil || next.Step != StepAdvanced || !strings.Contains(next.Status, "disabled") {
		t.Fatal("disabled row selected or silently re-enabled")
	}
	m.backToChoose()
	m.advanced = false
	m.backToChoose()
	if _, cmd := pressCtrl(m, 't'); cmd != nil {
		t.Fatal("accounts list toggled a provider")
	}
}

func TestProviderAvailabilityReloadKeepsFilterAndSelection(t *testing.T) {
	m := loginModel(100, 24)
	showSetups(&m)
	m.ChoosePicker.input.SetValue("work")
	m.ChoosePicker.refilter("use:work")
	m.Step = StepSaving
	profile := m.Profiles.Providers["work"]
	enabled := false
	profile.Enabled = &enabled
	m.Profiles.Providers["work"] = profile
	profiles := m.Profiles
	next, _ := m.Update(providerAvailabilityMsg{Name: "work", Result: signInsLoadedMsg{Gen: m.Generation, Profiles: &profiles}})
	if next.Step != StepAdvanced || next.ChoosePicker.input.Value() != "work" {
		t.Fatal("toggle lost search")
	}
	if name, _ := next.highlightedProfile(); name != "work" {
		t.Fatalf("toggle lost cursor: %s", name)
	}
	if next.Profiles.Providers["work"].IsEnabled() {
		t.Fatal("reload lost disabled flag")
	}
}

// showSetups opens the advanced list of named setups, where profiles live.
func showSetups(m *LoginModel) {
	m.advanced = true
	m.backToChoose()
}

// providersDaemon is loginWithDaemon for the per-group settings resource the
// client patches: it records each PATCH /settings/providers and refuses it.
func providersDaemon(t *testing.T) (LoginModel, <-chan providerPatch) {
	t.Helper()
	patches := make(chan providerPatch, 4)
	conn := commandTestConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPatch || r.URL.Path != "/settings/providers" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		data, _ := io.ReadAll(r.Body)
		var body map[string]any
		if err := json.Unmarshal(data, &body); err != nil {
			t.Errorf("patch body is not JSON: %s", data)
		}
		patches <- providerPatch{query: r.URL.RawQuery, body: body}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusConflict)
		_, _ = w.Write([]byte(`{"code":"profile_exists","message":"refused by the test"}`))
	})
	m := loginModel(120, 30)
	m.Conn = conn
	m.Profiles.ETag = `"providers-1"`
	return m, patches
}
