package tui

import (
	"slices"
	"testing"

	tea "charm.land/bubbletea/v2"
)

func TestUpstreamMergeAgentFindOwnsModalKeys(t *testing.T) {
	for _, editing := range []bool{false, true} {
		name := "normal"
		if editing {
			name = "insert"
		}
		t.Run(name, func(t *testing.T) {
			m := orderModel(t, orderFamily...)
			m.navigation.editing = editing
			m.input.SetValue("retained message")
			before := m.selected
			m, _ = m.Update(tea.KeyPressMsg{Code: 'f', Mod: tea.ModCtrl})
			if !m.find.active() {
				t.Fatal("ctrl+f did not open agent Find")
			}
			for _, r := range "hjkl/i9g" {
				m, _ = m.Update(navigationKey(r))
			}
			if got := m.find.input.Value(); got != "hjkl/i9g" {
				t.Fatalf("Find lost literal navigation keys: %q", got)
			}
			if m.input.Value() != "retained message" || m.navigation.editing != editing {
				t.Fatal("Find changed the composer draft or its mode")
			}
			m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
			if m.find.active() || m.selected != before || m.navigation.editing != editing {
				t.Fatal("Escape did not cancel Find independently of composer navigation")
			}
		})
	}
}

func TestUpstreamMergeAgentFoldKeepsNormalDraft(t *testing.T) {
	m := orderModel(t,
		orderAgent{id: "done-a", parent: "root", created: 1, closed: true},
		orderAgent{id: "done-b", parent: "root", created: 2, closed: true},
		orderAgent{id: "done-c", parent: "root", created: 3, closed: true},
	)
	fold := agentsFoldPrefix + "root"
	if f := m.folds[fold]; f == nil || f.open {
		t.Fatal("fixture did not create a closed fold")
	}
	m.selected = fold
	m.input.SetValue("do not send this draft")
	m.navigation.editing = false
	var cmd tea.Cmd
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if f := m.folds[fold]; f == nil || !f.open || !m.expanded["root"] || !slices.Contains(m.order, "done-a") {
		t.Fatal("NORMAL Enter with a retained draft did not expand the fold")
	}
	if m.selected != fold || m.navigation.editing || m.input.Value() != "do not send this draft" {
		t.Fatal("expanding a fold changed selection, mode, or the unsent draft")
	}
	if len(m.pendingOperations) != 0 || m.notice != "" {
		t.Fatal("fold activation tried to message an agent instead of expanding")
	}
	if cmd == nil || m.holdUntil.IsZero() {
		t.Fatal("fold activation did not hold the native agent order")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.folds[fold].open || m.input.Value() != "do not send this draft" {
		t.Fatal("NORMAL Enter did not fold the agents again while retaining the draft")
	}
}

func TestUpstreamMergeSessionsHostShortcutPrecedesNavigation(t *testing.T) {
	m := NewSessionViewer("/work")
	m.ensure()
	if m.navigation.editing {
		t.Fatal("fixture is not in NORMAL")
	}
	m, cmd := m.Update(navigationKey('@'))
	if cmd == nil {
		t.Fatal("NORMAL @ was consumed instead of opening the host picker")
	}
	if msg, ok := cmd().(SessionFoldersMsg); !ok || msg.Query != "@" {
		t.Fatalf("@ returned %T (%+v), want SessionFoldersMsg with @ query", msg, msg)
	}
	if m.SearchInput.Value() != "" || m.navigation.editing {
		t.Fatal("@ changed the retained session filter or navigation mode")
	}
	m, cmd = m.Update(navigationKey('/'))
	if cmd != nil || !m.navigation.editing || m.SearchInput.Value() != "" {
		t.Fatal("/ must still enter session SEARCH, not open the folder picker")
	}
}
