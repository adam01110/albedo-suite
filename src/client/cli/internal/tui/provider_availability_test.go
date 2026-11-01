package tui

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestProviderAvailabilityTogglePatchesOnlyEnabledWithValidator(t *testing.T) {
	for _, enabled := range []bool{true, false} {
		t.Run(map[bool]string{true: "disable", false: "enable"}[enabled], func(t *testing.T) {
			m, patches := loginWithDaemon(t)
			profile := m.Profiles.Providers["claude"]
			profile.Enabled = &enabled
			m.Profiles.Providers["claude"] = profile
			m.buildChoosePicker()
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
			patch := <-patches
			if patch.query != "group=providers" || patch.ifMatch != `"providers-1"` {
				t.Fatalf("wrong conditional target: %+v", patch)
			}
			want := map[string]any{"profiles": map[string]any{"claude": map[string]any{"enabled": !enabled}}}
			got, _ := json.Marshal(patch.body)
			if string(got) != mustJSON(t, want) {
				t.Fatalf("toggle sent %s", got)
			}
			next, _ = next.Update(msg)
			if next.Step != StepChoose || next.Error == "" {
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
	m.buildChoosePicker()
	focusLoginRow(&m, "use:work")
	if view := ansi.Strip(m.View()); !strings.Contains(view, "disabled") || !strings.Contains(view, "ctrl+t") {
		t.Fatalf("missing disabled state or hint:\n%s", view)
	}
	next, cmd := m.Update(PickerSelectMsg{ID: "use:work"})
	if cmd != nil || next.Step != StepChoose || !strings.Contains(next.Status, "disabled") {
		t.Fatal("disabled row selected or silently re-enabled")
	}
	focusLoginRow(&m, "add-openrouter")
	if _, cmd := pressCtrl(m, 't'); cmd != nil {
		t.Fatal("new-provider row toggled")
	}
}

func TestProviderAvailabilityReloadKeepsFilterAndSelection(t *testing.T) {
	m := loginModel(100, 24)
	m.ChoosePicker.input.SetValue("work")
	m.ChoosePicker.refilter("use:work")
	m.Step = StepSaving
	profile := m.Profiles.Providers["work"]
	enabled := false
	profile.Enabled = &enabled
	m.Profiles.Providers["work"] = profile
	profiles := m.Profiles
	next, _ := m.Update(providerAvailabilityMsg{Name: "work", Result: signInsLoadedMsg{Gen: m.Generation, Profiles: &profiles}})
	if next.Step != StepChoose || next.ChoosePicker.input.Value() != "work" {
		t.Fatal("toggle lost search")
	}
	if name, _ := next.highlightedProfile(); name != "work" {
		t.Fatalf("toggle lost cursor: %s", name)
	}
	if next.Profiles.Providers["work"].IsEnabled() {
		t.Fatal("reload lost disabled flag")
	}
}
