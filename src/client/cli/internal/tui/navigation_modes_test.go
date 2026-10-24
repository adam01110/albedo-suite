package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func checkNavigationList[T any](t *testing.T, m T, update func(T, tea.Msg) (T, tea.Cmd), cursor func(T) int, query func(T) string) {
	t.Helper()
	start := cursor(m)
	m, _ = update(m, navigationKey('j'))
	if cursor(m) != start+1 || query(m) != "" {
		t.Fatalf("j did not browse: cursor=%d query=%q", cursor(m), query(m))
	}
	m, _ = update(m, navigationKey('k'))
	if cursor(m) != start {
		t.Fatal("k did not return to the previous row")
	}
	m, _ = update(m, navigationKey('/'))
	for _, r := range "hjkl" {
		m, _ = update(m, navigationKey(r))
	}
	if query(m) != "hjkl" {
		t.Fatalf("search swallowed letters: %q", query(m))
	}
	var cmd tea.Cmd
	m, cmd = update(m, tea.KeyPressMsg{Code: tea.KeyEsc})
	if cmd != nil || query(m) != "hjkl" {
		t.Fatal("Esc closed the screen or discarded the filter")
	}
	before := cursor(m)
	m, _ = update(m, navigationKey('j'))
	if cursor(m) != before+1 || query(m) != "hjkl" {
		t.Fatal("j did not navigate the retained search results")
	}
	m, _ = update(m, navigationKey('/'))
	m, _ = update(m, navigationKey('j'))
	if query(m) != "hjklj" {
		t.Fatalf("reopening search: %q", query(m))
	}
}

func TestNavigationSearchableScreens(t *testing.T) {
	rows := []listEntry{{key: "one", name: "hjkl first"}, {key: "two", name: "hjkl second"}}
	t.Run("picker", func(t *testing.T) {
		m := NewPickerModel("choose", []PickerItem{{ID: "one", Label: "hjkl first"}, {ID: "two", Label: "hjkl second"}}, true, "")
		checkNavigationList(t, m, PickerModel.Update, func(m PickerModel) int { return m.Cursor }, func(m PickerModel) string { return m.SearchInput.Value() })
	})
	t.Run("sessions", func(t *testing.T) {
		m := NewSessionViewer("/work")
		m.SetSessions([]daemon.Session{{ID: "one", Title: "hjkl first", Workspace: "/work"}, {ID: "two", Title: "hjkl second", Workspace: "/work"}}, nil)
		m.ensure()
		m.Cursor = 0
		checkNavigationList(t, m, SessionViewer.Update, func(m SessionViewer) int { return m.Cursor }, func(m SessionViewer) string { return m.SearchInput.Value() })
	})
	t.Run("pages", func(t *testing.T) {
		m := pageAt(120, 30, &PageDocument{Rows: []PageRow{{ID: "one", Text: "hjkl first"}, {ID: "two", Text: "hjkl second"}}})
		checkNavigationList(t, m, PageViewModel.Update, func(m PageViewModel) int { return m.Cursor }, func(m PageViewModel) string { return m.input.Value() })
	})
	t.Run("context", func(t *testing.T) {
		m := contextFixture(t)
		m.setRows(rows)
		checkNavigationList(t, m, ContextInspectorModel.Update, func(m ContextInspectorModel) int { return m.Cursor }, func(m ContextInspectorModel) string { return m.input.Value() })
	})
	t.Run("tree", func(t *testing.T) {
		m := NewTreePickerModel(nil, "s")
		m.Loading = false
		m.setRows(rows)
		checkNavigationList(t, m, TreePickerModel.Update, func(m TreePickerModel) int { return m.Cursor }, func(m TreePickerModel) string { return m.input.Value() })
	})
	t.Run("extensions", func(t *testing.T) {
		m := NewExtensionPickerModel(nil, "s")
		m.Loading = false
		m.setRows(rows)
		checkNavigationList(t, m, ExtensionPickerModel.Update, func(m ExtensionPickerModel) int { return m.Cursor }, func(m ExtensionPickerModel) string { return m.input.Value() })
	})
	t.Run("capabilities", func(t *testing.T) {
		m := NewCapabilityPageModel(nil, "s", "skills")
		m.Loading = false
		m.setRows(rows)
		checkNavigationList(t, m, CapabilityPageModel.Update, func(m CapabilityPageModel) int { return m.Cursor }, func(m CapabilityPageModel) string { return m.input.Value() })
	})
	t.Run("config", func(t *testing.T) {
		m := loadedConfigPage(t, nil)
		m.setRows(rows)
		checkNavigationList(t, m, ConfigPageModel.Update, func(m ConfigPageModel) int { return m.Cursor }, func(m ConfigPageModel) string { return m.input.Value() })
	})
	t.Run("webhooks", func(t *testing.T) {
		m := NewWebhooksPageModel(nil, "s")
		m.Loaded = true
		m.Mounted = true
		m.Loading = false
		m.setRows(rows)
		checkNavigationList(t, m, WebhooksPageModel.Update, func(m WebhooksPageModel) int { return m.Cursor }, func(m WebhooksPageModel) string { return m.input.Value() })
	})
	t.Run("discord", func(t *testing.T) {
		m := NewDiscordPageModel(nil, "s")
		m.Loading = false
		m.Loaded = true
		m.Mounted = true
		m.setRows(rows)
		checkNavigationList(t, m, DiscordPageModel.Update, func(m DiscordPageModel) int { return m.Cursor }, func(m DiscordPageModel) string { return m.input.Value() })
	})
	t.Run("discord detail", func(t *testing.T) {
		m := NewDiscordPageModel(nil, "s")
		m.Loading = false
		m.Loaded = true
		m.Mounted = true
		m.Open = "bot"
		m.inner.setRows(rows)
		checkNavigationList(t, m, DiscordPageModel.Update, func(m DiscordPageModel) int { return m.inner.Cursor }, func(m DiscordPageModel) string { return m.inner.input.Value() })
	})
}

func TestNavigationModelEffortAndSearch(t *testing.T) {
	m := loadedPicker(t)
	m, _ = m.Update(navigationKey('h'))
	if got := chosen(t, m); got.Effort != "medium" {
		t.Fatalf("h: %+v", got)
	}
	m, _ = m.Update(navigationKey('l'))
	if got := chosen(t, m); got.Effort != "high" {
		t.Fatalf("l: %+v", got)
	}
	before := m.cursor
	m, _ = m.Update(navigationKey('j'))
	if m.cursor != before+1 || m.search.Value() != "" {
		t.Fatal("j did not browse models")
	}
	m, _ = m.Update(navigationKey('k'))
	m, _ = m.Update(navigationKey('/'))
	m, _ = m.Update(navigationKey('g'))
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	m, _ = m.Update(navigationKey('h'))
	if m.search.Value() != "g" {
		t.Fatal("h changed the retained model search")
	}
	// Models without effort levels still consume h/l rather than typing them.
	m.search.SetValue("")
	m.refilter(false)
	for i, r := range m.rows {
		if len(r.model.Efforts) == 0 {
			m.cursor = i
			break
		}
	}
	m, _ = m.Update(navigationKey('h'))
	m, _ = m.Update(navigationKey('l'))
	if m.search.Value() != "" {
		t.Fatal("effort-less model typed navigation keys")
	}
}

func TestNavigationAgentsKeepDraft(t *testing.T) {
	m := agentsFixture(t)
	before := m.selected
	m, _ = m.Update(navigationKey('j'))
	if m.selected == before || m.input.Value() != "" {
		t.Fatal("j did not cycle agents")
	}
	m, _ = m.Update(navigationKey('k'))
	if m.selected != before {
		t.Fatal("k did not cycle back")
	}
	m, _ = m.Update(navigationKey('i'))
	for _, r := range "hjkl" {
		m, _ = m.Update(navigationKey(r))
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	m, _ = m.Update(navigationKey('l'))
	if m.input.Value() != "hjkl" || m.selected == before {
		t.Fatal("navigation lost the agent message draft")
	}
}

func TestNavigationPickerOpenBackAndPaste(t *testing.T) {
	m := NewPickerModel("choose", []PickerItem{{ID: "one", Label: "hjkl"}}, true, "")
	_, cmd := m.Update(navigationKey('l'))
	if cmd == nil {
		t.Fatal("l did not choose")
	}
	if msg, ok := cmd().(PickerSelectMsg); !ok || msg.ID != "one" {
		t.Fatal("l chose the wrong row")
	}
	_, cmd = m.Update(navigationKey('h'))
	if cmd == nil {
		t.Fatal("h did not go back")
	}
	if _, ok := cmd().(PickerCancelMsg); !ok {
		t.Fatal("h did not cancel")
	}
	m, _ = m.Update(tea.PasteMsg{Content: "h"})
	m, _ = m.Update(navigationKey('j'))
	if m.SearchInput.Value() != "hj" {
		t.Fatal("paste did not enter search")
	}
}

func TestNavigationModeHints(t *testing.T) {
	m := pageAt(120, 30, detailFixture())
	if !strings.Contains(ansi.Strip(m.View()), "NORMAL") {
		t.Fatal("missing navigation mode")
	}
	m, _ = m.Update(navigationKey('/'))
	if !strings.Contains(ansi.Strip(m.View()), "SEARCH") {
		t.Fatal("missing search mode")
	}
}

func TestNavigationFoldersBrowseAndRetainQuery(t *testing.T) {
	m := NewFolderPicker(nil, daemon.Session{Workspace: "/work"}, nil)
	defer m.cancelReads()
	m.rows = []folderRow{{path: "/work/one"}, {path: "/work/two"}}
	m.cursor = 0
	m, _ = m.Update(navigationKey('j'))
	if m.cursor != 1 || m.input.Value() != "" {
		t.Fatal("j did not browse folders")
	}
	m, _ = m.Update(navigationKey('k'))
	if m.cursor != 0 {
		t.Fatal("k did not browse back")
	}
	m, _ = m.Update(navigationKey('l'))
	if m.input.Value() != "/work/one/" {
		t.Fatalf("l did not descend: %q", m.input.Value())
	}
	m, _ = m.Update(navigationKey('h'))
	if m.input.Value() != "/work/" {
		t.Fatalf("h did not ascend: %q", m.input.Value())
	}
	m, _ = m.Update(navigationKey('/'))
	m, _ = m.Update(navigationKey('j'))
	if m.input.Value() != "/work/j" {
		t.Fatalf("query edit: %q", m.input.Value())
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	m, _ = m.Update(navigationKey('k'))
	if m.input.Value() != "/work/j" {
		t.Fatal("navigation changed the folder query")
	}
}

func TestNavigationEmptyComposerBrowsesChat(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(80, 20)
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: strings.Repeat("history\n", 80)})
	m.refreshViewportContent()
	bottom := m.scrollOffset
	m, _ = m.Update(navigationKey('k'))
	if m.scrollOffset != bottom-1 || m.Follow {
		t.Fatal("k did not scroll the transcript")
	}
	m, _ = m.Update(navigationKey('j'))
	if m.scrollOffset != bottom || !m.Follow {
		t.Fatal("j did not return to the live tail")
	}
	var cmd tea.Cmd
	m, cmd = m.Update(navigationKey('h'))
	if cmd == nil {
		t.Fatal("h did not return to sessions")
	}
	if _, ok := cmd().(ChatBackToSessionsMsg); !ok {
		t.Fatal("h returned the wrong message")
	}
	vimKeys(&m, "i", "h", "j", "k", "l")
	if m.TextArea.Value() != "hjkl" {
		t.Fatal("insert mode swallowed letters")
	}
}
