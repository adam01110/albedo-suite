package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
)

func navigationKey(r rune) tea.KeyPressMsg { return tea.KeyPressMsg{Code: r, Text: string(r)} }

func TestNavigationPickerWithoutSearch(t *testing.T) {
	items := []PickerItem{{ID: "first"}, {ID: "second"}}
	m := NewPickerModel("choose", items, false, "")
	for _, step := range []struct {
		key  rune
		want int
	}{{'k', 0}, {'j', 1}, {'j', 1}, {'k', 0}} {
		m, _ = m.Update(navigationKey(step.key))
		if m.Cursor != step.want {
			t.Fatalf("%c: cursor %d, want %d", step.key, m.Cursor, step.want)
		}
	}
}

func TestNavigationSearchKeepsLetters(t *testing.T) {
	for _, r := range "hjkl" {
		t.Run(string(r), func(t *testing.T) {
			m := NewPickerModel("search", []PickerItem{{ID: "hjkl"}}, true, "")
			m, _ = m.Update(navigationKey(r))
			if m.SearchInput.Value() != string(r) {
				t.Fatalf("picker swallowed %c", r)
			}
			page := pageAt(120, 30, detailFixture())
			page, _ = page.Update(navigationKey(r))
			if page.input.Value() != string(r) {
				t.Fatalf("page filter swallowed %c", r)
			}
			context := contextFixture(t)
			context, _ = context.Update(navigationKey(r))
			if context.input.Value() != string(r) {
				t.Fatalf("context filter swallowed %c", r)
			}
			sessions := NewSessionViewer("/work")
			sessions, _ = sessions.Update(navigationKey(r))
			if sessions.SearchInput.Value() != string(r) {
				t.Fatalf("session search swallowed %c", r)
			}
			agents := agentsFixture(t)
			agents, _ = agents.Update(navigationKey(r))
			if agents.input.Value() != string(r) {
				t.Fatalf("agent composer swallowed %c", r)
			}
			folder := NewFolderPicker(nil, daemon.Session{Workspace: "/work"}, nil)
			defer folder.cancelReads()
			folder, _ = folder.Update(navigationKey(r))
			if folder.input.Value() != string(r) {
				t.Fatalf("folder query swallowed %c", r)
			}
			model := loadedPicker(t)
			model, _ = model.Update(navigationKey(r))
			if model.search.Value() != string(r) {
				t.Fatalf("model filter swallowed %c", r)
			}
		})
	}
}

func TestNavigationPageMenus(t *testing.T) {
	doc := detailFixture()
	doc.Actions = []PageAction{{ID: "first"}, {ID: "second"}}
	m := pageAt(120, 30, doc)
	m, _ = m.Update(tea.KeyPressMsg{Code: 'a', Mod: tea.ModCtrl})
	for _, step := range []struct {
		key  rune
		want int
	}{{'j', 1}, {'j', 1}, {'k', 0}, {'k', 0}} {
		m, _ = m.Update(navigationKey(step.key))
		if m.ActionIndex != step.want {
			t.Fatalf("%c: action index %d", step.key, m.ActionIndex)
		}
	}
	m.Mode = modeChoice
	m.CurrentAction = &PageAction{Fields: []daemon.FormField{{Type: "boolean"}}}
	for _, step := range []struct {
		key  rune
		want int
	}{{'l', 1}, {'h', 0}, {'k', 1}, {'j', 0}} {
		m, _ = m.Update(navigationKey(step.key))
		if m.ChoiceIndex != step.want {
			t.Fatalf("%c: choice index %d", step.key, m.ChoiceIndex)
		}
	}
	m.Mode = modeText
	m.TextInput.Focus()
	for _, r := range "hjkl" {
		m, _ = m.Update(navigationKey(r))
	}
	if m.TextInput.Value() != "hjkl" {
		t.Fatalf("text prompt: %q", m.TextInput.Value())
	}
}

func TestNavigationContextReader(t *testing.T) {
	m := contextFixture(t)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	m, _ = m.Update(contextPageLoadedMsg{Gen: m.Generation, SectionID: "history", Data: &daemon.ContextPage{Content: strings.Repeat("line\n", 80)}})
	m.View()
	m, _ = m.Update(navigationKey('j'))
	if m.Detail.Scroll != 1 {
		t.Fatalf("j: scroll %d", m.Detail.Scroll)
	}
	m, _ = m.Update(navigationKey('k'))
	if m.Detail.Scroll != 0 {
		t.Fatalf("k: scroll %d", m.Detail.Scroll)
	}
	for _, step := range []struct {
		key  rune
		want int
	}{{'h', 0}, {'l', 1}, {'l', 1}, {'h', 0}} {
		before := m.Detail.Page
		var cmd tea.Cmd
		m, cmd = m.Update(navigationKey(step.key))
		if m.Detail.Page != step.want {
			t.Fatalf("%c: page %d", step.key, m.Detail.Page)
		}
		if (cmd != nil) != (before != step.want) {
			t.Fatalf("%c: page fetch command did not match page change", step.key)
		}
	}
}

func TestNavigationFolderSessions(t *testing.T) {
	m := NewFolderPicker(nil, daemon.Session{Workspace: "/work"}, nil)
	defer m.cancelReads()
	m.rows = []folderRow{{path: "/work"}}
	m.sessions = []daemon.Session{{ID: "first", Workspace: "/work"}, {ID: "second", Workspace: "/work"}}
	m.inSessions = true
	for _, step := range []struct {
		key  rune
		want int
	}{{'k', 0}, {'j', 1}, {'j', 1}, {'k', 0}} {
		m, _ = m.Update(navigationKey(step.key))
		if !m.inSessions || m.sessionCursor != step.want {
			t.Fatalf("%c: pane %v, cursor %d", step.key, m.inSessions, m.sessionCursor)
		}
	}
	var cmd tea.Cmd
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if msg, ok := cmd().(FolderOpenSessionMsg); !ok || msg.Session.ID != "first" {
		t.Fatalf("enter: %v", msg)
	}
	m, _ = m.Update(navigationKey('h'))
	if m.inSessions {
		t.Fatal("h did not leave session pane")
	}
}

func TestNavigationMCPTransport(t *testing.T) {
	m := mcpPage(t)
	m = ctrl(m, 'o')
	m = key(m, tea.KeyUp)
	for _, step := range []struct {
		key  rune
		want string
	}{{'l', "stdio"}, {'h', "http"}} {
		m, _ = m.Update(navigationKey(step.key))
		if m.Form.Transport != step.want {
			t.Fatalf("%c: transport %q", step.key, m.Form.Transport)
		}
	}
	m, _ = m.Update(navigationKey('j'))
	if m.Form.current() != fieldURL {
		t.Fatalf("j: field %q", m.Form.current())
	}
	for _, r := range "hjkl" {
		m, _ = m.Update(navigationKey(r))
	}
	if m.Form.Inputs[fieldURL].Value() != "hjkl" {
		t.Fatal("transport form swallowed URL text")
	}
}
