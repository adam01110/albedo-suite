package tui

import (
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"fmt"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
)

func TestNavigationCountedListsAndStrictModes(t *testing.T) {
	items := make([]PickerItem, 60)
	for i := range items {
		items[i] = PickerItem{ID: fmt.Sprint(i), Label: fmt.Sprintf("row %02d", i)}
	}
	m := NewPickerModel("list", items, true, "")
	m.SetSize(80, 24)
	for _, r := range "12j" {
		m, _ = m.Update(navigationKey(r))
	}
	if m.Cursor != 12 || m.SearchInput.Value() != "" {
		t.Fatalf("counted motion: %d %q", m.Cursor, m.SearchInput.Value())
	}
	m, _ = m.Update(navigationKey('G'))
	if m.Cursor != 59 {
		t.Fatal("G", m.Cursor)
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: 'u', Mod: tea.ModCtrl})
	if m.Cursor != 47 {
		t.Fatal("half page up", m.Cursor)
	}
	for _, r := range "gg" {
		m, _ = m.Update(navigationKey(r))
	}
	if m.Cursor != 0 {
		t.Fatal("gg", m.Cursor)
	}
	m, _ = m.Update(navigationKey('z'))
	if m.navigation.editing || m.SearchInput.Value() != "" {
		t.Fatal("normal key typed into filter")
	}
	m, _ = m.Update(navigationKey('2'))
	var cmd tea.Cmd
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if cmd != nil || m.navigation.count != 0 {
		t.Fatal("Esc did not cancel count locally")
	}
	m, _ = m.Update(navigationKey('/'))
	for _, r := range "gjkG12" {
		m, _ = m.Update(navigationKey(r))
	}
	if m.SearchInput.Value() != "gjkG12" {
		t.Fatal("SEARCH not literal", m.SearchInput.Value())
	}
}

func TestNavigationNestedListCounts(t *testing.T) {
	m := pageAt(80, 24, &PageDocument{})
	rows := make([]listEntry, 20)
	for i := range rows {
		rows[i] = listEntry{key: fmt.Sprint(i), name: fmt.Sprint(i)}
	}
	m.setRows(rows)
	for _, r := range "5j" {
		m, _ = m.Update(navigationKey(r))
	}
	if m.Cursor != 5 {
		t.Fatal("containing screen lost count", m.Cursor)
	}
	for _, r := range "gg" {
		m, _ = m.Update(navigationKey(r))
	}
	if m.Cursor != 0 {
		t.Fatal("containing screen lost gg", m.Cursor)
	}
}

func TestNavigationTranscriptKeepsDraftAndUndo(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 24)
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: strings.Repeat("line of history\n", 80)})
	m.refreshViewportContent()
	vimKeys(&m, "i", "d", "r", "a", "f", "t", "esc")
	draft := m.TextArea.Value()
	undo := len(m.vim.undo)
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	before := m.reader.row
	vimKeys(&m, "j")
	if !m.reader.active || m.reader.row != before+1 || m.TextArea.Value() != draft || len(m.vim.undo) != undo {
		t.Fatal("focus/motion changed draft or undo")
	}
	m, cmd := m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
	if cmd != nil || m.reader.row <= before+1 {
		t.Fatal("ctrl+d did not page", m.reader.row)
	}
	m, _ = m.Update(tea.PasteMsg{Content: "must not reach composer"})
	if m.TextArea.Value() != draft {
		t.Fatal("reader paste corrupted draft")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	vimKeys(&m, "u")
	if m.reader.active || m.TextArea.Value() != "" {
		t.Fatal("composer undo not retained")
	}
}

func TestNavigationTranscriptActionsAndSearch(t *testing.T) {
	m := newTestChatModel(t, &daemon.Session{ID: "s"})
	m.SetSize(100, 24)
	m.appendSettledEntry(HistoryEntry{Kind: EntryUser, Text: strings.Repeat("long message ", 100), Timestamp: 42})
	m.appendSettledEntry(HistoryEntry{Kind: EntryAssistant, Text: "unique needle", Timestamp: 43})
	m.refreshViewportContent()
	m.readerFocus(true)
	m.reader.row = 0
	m.readerAction(1)
	action, ok := actionOf(m.frameLines[m.reader.row])
	if !ok {
		t.Fatal("no keyboard action target")
	}
	m.reader.anchor = action
	m.reader.row = 0
	m.readerAnchor()
	if got, ok := actionOf(m.frameLines[m.reader.row]); !ok || got != action {
		t.Fatal("stable action anchor lost")
	}
	m.reader.query = "unique needle"
	m.readerFind(1)
	if !strings.Contains(ansi.Strip(m.frameLines[m.reader.row]), "unique needle") {
		t.Fatal("search did not reveal match")
	}
	m.reader.row = 0
	m.reader.anchor = rowAction{}
	m.readerAction(1)
	action, _ = actionOf(m.frameLines[m.reader.row])
	if action.verb != verbMore {
		t.Fatalf("expected fold target, got %+v", action)
	}
	before := m.Renderer.Open[action.key]
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Renderer.Open[action.key] == before {
		t.Fatal("Enter did not activate fold")
	}
}

func TestNavigationWorkspaceOverlayPreservesDraft(t *testing.T) {
	chat := newTestChatModel(t, &daemon.Session{ID: "s"})
	chat.SetSize(100, 24)
	vimKeys(&chat, "i", "h", "j", "k", "l", "esc")
	m := &AppModel{State: AppStateChat, Chat: chat, ActiveSession: &daemon.Session{ID: "s"}, Width: 100, Height: 24}
	m.Update(tea.KeyPressMsg{Code: tea.KeyF2})
	if m.workspaceOverlay == nil {
		t.Fatal("F2 did not open workspace")
	}
	m.Update(navigationKey('/'))
	m.Update(navigationKey('z'))
	m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if m.workspaceOverlay == nil {
		t.Fatal("search Escape closed launcher")
	}
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if cmd == nil {
		t.Fatal("missing picker cancellation")
	}
	m.Update(cmd())
	if m.workspaceOverlay != nil || m.Chat.TextArea.Value() != "hjkl" {
		t.Fatal("launcher changed draft")
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyF1})
	if m.workspaceOverlay == nil || !m.workspaceOverlay.help {
		t.Fatal("missing keyboard reference")
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyF1})
	if m.workspaceOverlay != nil {
		t.Fatal("F1 did not return")
	}
}

func TestNavigationAgentsNormalEnterDoesNotSendDraft(t *testing.T) {
	m := agentsFixture(t)
	m, _ = m.Update(navigationKey('i'))
	for _, r := range "retained draft" {
		m, _ = m.Update(navigationKey(r))
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("normal Enter did not attach")
	}
	if _, ok := cmd().(AgentsAttachMsg); !ok {
		t.Fatal("normal Enter attempted to send")
	}
	if m.input.Value() != "retained draft" {
		t.Fatal("normal Enter discarded draft")
	}
}

func TestNavigationReaderModalPriority(t *testing.T) {
	chat := newTestChatModel(t, &daemon.Session{ID: "s"})
	chat.SetSize(100, 24)
	chat.readerFocus(true)
	chat.Status.Running = true
	m := &AppModel{State: AppStateChat, Chat: chat, ActiveSession: &daemon.Session{ID: "s"}, Width: 100, Height: 24}
	m.Update(navigationKey('/'))
	for _, r := range "two words" {
		m.Update(navigationKey(r))
	}
	if m.workspaceOverlay != nil || m.Chat.reader.search.Value() != "two words" {
		t.Fatal("workspace stole FIND space")
	}
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyLeft})
	if cmd != nil || m.Chat.reader.search.Position() != 8 {
		t.Fatal("FIND Left escaped chat")
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	m.Update(navigationKey('3'))
	m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if m.Chat.Stopping || m.Chat.reader.count != 0 {
		t.Fatal("prefix Escape stopped the response")
	}
	m.Update(navigationKey('g'))
	m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if m.Chat.Stopping || m.Chat.reader.pending != "" {
		t.Fatal("g Escape stopped the response")
	}
}

func TestNavigationWorkspaceCancellationIsOwned(t *testing.T) {
	m := &AppModel{State: AppStateSessionPicker, SessionPicker: NewSessionViewer("/work"), Width: 80, Height: 24}
	m.openWorkspaceOverlay(false)
	m.Update(navigationKey('/'))
	_, cmd := m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
	if cmd == nil {
		t.Fatal("missing cancellation")
	}
	if _, ok := cmd().(workspacePickerResult); !ok {
		t.Fatal("picker result leaked to underlying screen")
	}
	m.Update(cmd())
	if m.workspaceOverlay != nil || m.State != AppStateSessionPicker {
		t.Fatal("cancellation changed underlying screen")
	}
}

func TestNavigationNormalSlashKeepsDraft(t *testing.T) {
	chat := newTestChatModel(t, &daemon.Session{ID: "s"})
	chat.SetSize(80, 24)
	vimKeys(&chat, "i", "d", "r", "a", "f", "t", "esc")
	before := chat.vimSnapshot()
	chat, cmd := chat.Update(navigationKey('/'))
	if cmd == nil || chat.vimSnapshot() != before {
		t.Fatal("slash changed draft")
	}
	if _, ok := cmd().(ChatOpenWorkspaceMsg); !ok {
		t.Fatal("slash did not open independent launcher")
	}
}

func TestNavigationArchiveDeleteAndPaging(t *testing.T) {
	m := NewSessionViewer("/work")
	m.SetSessions([]daemon.Session{{ID: "one", Title: "one", Archived: true}}, nil)
	m.OpenArchive()
	m, _ = m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
	if m.confirm.asking() {
		t.Fatal("page-down opened destructive confirmation")
	}
	m, _ = m.Update(navigationKey('x'))
	if !m.confirm.asking() {
		t.Fatal("explicit delete did not require confirmation")
	}
}

func TestNavigationWorkspacePagesNeverSubmitInput(t *testing.T) {
	m := &AppModel{State: AppStateSessionPicker, ActiveSession: &daemon.Session{ID: "s"}, Width: 80, Height: 24}
	page := true
	m.CommandCatalog = []daemon.SessionCommand{{Name: "/requests", Delivery: "input"}, {Name: "/requests", Delivery: "read", Page: &page}}
	m.openWorkspaceOverlay(false)
	found := false
	for _, item := range m.workspaceOverlay.picker.Items {
		if item.ID == "/requests" {
			found = true
		}
	}
	if !found {
		t.Fatal("catalog page absent from launcher")
	}
	for _, id := range []string{"/requests", "questions"} {
		cmd := m.workspaceDestination(id)
		if cmd == nil {
			t.Fatal("missing page command", id)
		}
		message, ok := cmd().(ChatOpenPageMsg)
		if !ok || message.Command != "/"+strings.TrimPrefix(id, "/") {
			t.Fatalf("%s was not a page read: %#v", id, cmd())
		}
		if m.State != AppStateSessionPicker {
			t.Fatal("destination mutated state before page routing")
		}
	}
}

func TestNavigationWorkspaceTerminalSizes(t *testing.T) {
	for _, size := range [][2]int{{20, 8}, {40, 12}, {80, 24}, {160, 40}} {
		for _, help := range []bool{true, false} {
			m := &AppModel{State: AppStateSessionPicker, Width: size[0], Height: size[1]}
			m.openWorkspaceOverlay(help)
			lines := strings.Split(ansi.Strip(m.workspaceOverlay.view()), "\n")
			if len(lines) != size[1] {
				t.Fatalf("%v help=%v rows=%d", size, help, len(lines))
			}
			for _, line := range lines {
				if ansi.StringWidth(line) > size[0] {
					t.Fatalf("%v overflow: %q", size, line)
				}
			}
		}
	}
}

func TestNavigationShellFooterAlwaysShowsMode(t *testing.T) {
	for _, width := range []int{8, 40, 80, 160} {
		m := newTestChatModel(t, &daemon.Session{ID: "s"})
		m.SetSize(width, 24)
		m.appendSettledEntry(HistoryEntry{Kind: EntryShell, Text: "output"})
		for _, normal := range []bool{true, false} {
			m.vim.normal = normal
			footer := ansi.Strip(m.renderFooter())
			if !strings.Contains(footer, m.vimMode()) || ansi.StringWidth(footer) > m.chatWidth() {
				t.Fatalf("width %d: %q", width, footer)
			}
		}
	}
}
