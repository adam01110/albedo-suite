package tui

import (
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func leaderFixture(t *testing.T, width, height int) *AppModel {
	t.Helper()
	chat := newTestChatModel(t, &daemon.Session{ID: "s"})
	chat.SetSize(width, height)
	vimKeys(&chat, "i", "d", "r", "a", "f", "t", "esc")
	return &AppModel{State: AppStateChat, Chat: chat, ActiveSession: &daemon.Session{ID: "s", Title: "Current session"}, Width: width, Height: height}
}

func TestNavigationLeaderViewAndCancellation(t *testing.T) {
	m := leaderFixture(t, 160, 40)
	before := m.Chat.vimSnapshot()
	oldWidth := m.Chat.Viewport.Width()
	oldDiffs := m.Chat.Flags.Diffs
	m.Update(navigationKey(' '))
	if m.Chat.leader == nil || m.Chat.sidebarWidth() == 0 || m.Chat.Viewport.Width() >= oldWidth {
		t.Fatal("leader did not reserve sidebar")
	}
	view := ansi.Strip(m.View().Content)
	if !strings.Contains(view, "space · actions") || !strings.Contains(view, "draft") {
		t.Fatal("leader replaced conversation")
	}
	m.Update(navigationKey('v'))
	if m.workspaceOverlay.group != "v" {
		t.Fatal("missing view prefix")
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if m.Chat.vimSnapshot() != before {
		t.Fatal("leader Enter edited draft")
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if m.workspaceOverlay == nil || m.workspaceOverlay.group != "" {
		t.Fatal("Escape did not return to root")
	}
	m.Update(navigationKey('v'))
	m.Update(navigationKey('d'))
	if m.Chat.Flags.Diffs == oldDiffs || m.workspaceOverlay != nil || m.Chat.leader != nil {
		t.Fatal("space v d did not toggle and close")
	}
	if m.Chat.Viewport.Width() != oldWidth || m.Chat.vimSnapshot() != before {
		t.Fatal("leader did not restore layout/draft")
	}
	vimKeys(&m.Chat, "u")
	if m.Chat.TextArea.Value() != "" {
		t.Fatal("leader damaged undo")
	}
}

func TestNavigationLeaderLiteralSpaceAndPrefixes(t *testing.T) {
	for _, mode := range []string{"insert", "find", "list-search", "vim-find", "count", "operator", "list-count"} {
		t.Run(mode, func(t *testing.T) {
			m := leaderFixture(t, 120, 28)
			switch mode {
			case "insert":
				m.Update(navigationKey('a'))
			case "find":
				m.Chat.readerFocus(true)
				m.Update(navigationKey('/'))
			case "list-search":
				m.State = AppStateSessionPicker
				m.SessionPicker = NewSessionViewer("/work")
				m.Update(navigationKey('/'))
			case "vim-find":
				m.Update(navigationKey('f'))
			case "count":
				m.Update(navigationKey('2'))
			case "operator":
				m.Update(navigationKey('d'))
			case "list-count":
				m.State = AppStateSessionPicker
				m.SessionPicker = NewSessionViewer("/work")
				m.Update(navigationKey('2'))
			}
			m.Update(navigationKey(' '))
			if m.workspaceOverlay != nil {
				t.Fatal("leader stole literal space or pending chord")
			}
			if mode == "insert" && !strings.Contains(m.Chat.TextArea.Value(), " ") {
				t.Fatal("insert space lost")
			}
			if mode == "find" && m.Chat.reader.search.Value() != " " {
				t.Fatal("FIND space lost")
			}
		})
	}
}

func TestNavigationLeaderRejectsModifiedKeys(t *testing.T) {
	m := leaderFixture(t, 120, 28)
	m.Update(tea.KeyPressMsg{Code: ' ', Text: " ", Mod: tea.ModAlt})
	if m.workspaceOverlay != nil {
		t.Fatal("Alt+Space opened leader")
	}
	m.Update(navigationKey(' '))
	m.Update(tea.KeyPressMsg{Code: 's', Text: "s", Mod: tea.ModAlt})
	if m.workspaceOverlay == nil {
		t.Fatal("Alt+s activated destination")
	}
	m.Update(tea.KeyPressMsg{Code: '?', Text: "?", Mod: tea.ModShift})
	if m.workspaceOverlay == nil || !m.workspaceOverlay.help {
		t.Fatal("shifted ? failed to open reference")
	}
}

func TestNavigationWorkspaceSearchMatchesDetail(t *testing.T) {
	m := leaderFixture(t, 120, 28)
	m.openWorkspaceOverlay(false)
	m.Update(navigationKey('/'))
	for _, key := range "undo history" {
		m.Update(navigationKey(key))
	}
	if len(m.workspaceOverlay.picker.Filtered) != 1 || m.workspaceOverlay.picker.Filtered[0].ID != "chat" {
		t.Fatal("workspace search omitted detail text")
	}
}

func TestNavigationLeaderLongDraftFallsBack(t *testing.T) {
	m := leaderFixture(t, 160, 18)
	m.Chat.TextArea.SetValue(strings.Repeat("draft line\n", 8))
	m.Chat.SetSize(160, 18)
	m.Update(navigationKey(' '))
	if m.Chat.sidebarWidth() != 0 {
		t.Fatal("short sidebar clips leader entries")
	}
	if !strings.Contains(ansi.Strip(m.View().Content), "Keyboard reference") {
		t.Fatal("fallback hid leader action")
	}
}

func TestNavigationLeaderSizesAndResize(t *testing.T) {
	for _, size := range [][2]int{{20, 8}, {40, 12}, {80, 24}, {104, 24}, {160, 40}} {
		m := leaderFixture(t, size[0], size[1])
		m.Update(navigationKey(' '))
		for _, group := range []string{"", "v"} {
			m.workspaceOverlay.group = group
			view := ansi.Strip(m.View().Content)
			entryWidth := size[0]
			if sidebar := m.Chat.sidebarWidth(); sidebar > 0 {
				entryWidth = sidebar
			}
			for _, entry := range m.workspaceOverlay.leaderEntries() {
				label := ansi.Truncate(ansi.Strip(keyHints(hint{entry.key, entry.label})), entryWidth, "…")
				if !strings.Contains(view, label) {
					t.Fatalf("%v hidden action %q", size, label)
				}
			}
			lines := strings.Split(view, "\n")
			if len(lines) != size[1] {
				t.Fatalf("%v rows=%d", size, len(lines))
			}
			for _, line := range lines {
				if ansi.StringWidth(line) > size[0] {
					t.Fatalf("%v overflow %q", size, line)
				}
			}
		}
		m.Update(tea.WindowSizeMsg{Width: 160, Height: 40})
		if m.Chat.sidebarWidth() == 0 {
			t.Fatal("resize did not reveal leader sidebar")
		}
		m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
		m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
		if m.Chat.leader != nil || m.workspaceOverlay != nil {
			t.Fatal("cancel left sidebar active")
		}
	}
}

func TestNavigationKeyboardReferenceIsComplete(t *testing.T) {
	items := keyboardReference()
	seen := map[string]bool{}
	for _, item := range items {
		if item.ID == "" || seen[item.ID] || item.Detail == "" {
			t.Fatal("invalid binding", item)
		}
		seen[item.ID] = true
	}
	for _, group := range []string{"", "v"} {
		menu := workspaceOverlay{leader: true, session: true, chat: true, group: group}
		prefix := "space "
		if group != "" {
			prefix += group + " "
		}
		for _, entry := range menu.leaderEntries() {
			if entry.destination == "view" {
				continue
			}
			scope := "Chat / sessions NORMAL:"
			if group == "v" {
				scope = "Chat NORMAL:"
			}
			if !seen[scope+prefix+entry.key] {
				t.Fatal("leader binding absent from reference", prefix+entry.key)
			}
		}
	}
	for _, id := range []string{"Composer NORMAL:u / ctrl+r", "Lists NORMAL:h / q / Esc", "Composer (either mode):ctrl+shift+x", "Chat NORMAL:space v d"} {
		if !seen[id] {
			t.Fatal("missing binding", id)
		}
	}
}

func TestNavigationLeaderCancelDoesNotStopAndRestoresGlances(t *testing.T) {
	m := leaderFixture(t, 160, 40)
	m.Chat.Status.Running = true
	m.Chat.Glances = []PageGlance{{Title: "Existing glance", Rows: []PageRow{{Text: "visible again"}}}}
	m.Chat.SetSize(160, 40)
	m.Update(navigationKey(' '))
	m.Update(tea.PasteMsg{Content: "never insert"})
	if strings.Contains(m.Chat.TextArea.Value(), "never insert") {
		t.Fatal("paste reached draft")
	}
	if strings.Contains(strings.Join(m.Chat.sidebarColumn(), "\n"), "Existing glance") {
		t.Fatal("glance covers leader")
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyEsc})
	if m.Chat.Stopping || !strings.Contains(strings.Join(m.Chat.sidebarColumn(), "\n"), "Existing glance") {
		t.Fatal("cancel stopped response or lost glances")
	}
	m.Update(navigationKey(' '))
	m.Chat.leader = nil // An asynchronous session replacement creates a new ChatModel.
	m.Update(tea.WindowSizeMsg{Width: 160, Height: 40})
	if m.workspaceOverlay != nil {
		t.Fatal("leader outlived its chat")
	}
}

func TestNavigationWorkspaceAndReferenceNormalPaging(t *testing.T) {
	for _, help := range []bool{false, true} {
		m := leaderFixture(t, 120, 28)
		m.openWorkspaceOverlay(help)
		_, cmd := m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
		if cmd != nil || m.workspaceOverlay == nil || m.workspaceOverlay.picker.Cursor == 0 {
			t.Fatal("NORMAL ctrl+d did not page overlay")
		}
		m.Update(tea.KeyPressMsg{Code: 'u', Mod: tea.ModCtrl})
		if m.workspaceOverlay == nil || m.workspaceOverlay.picker.Cursor != 0 {
			t.Fatal("NORMAL ctrl+u did not page back")
		}
	}
}

func TestNavigationLeaderWorkspaceAndHelp(t *testing.T) {
	m := leaderFixture(t, 120, 28)
	m.Update(navigationKey(' '))
	m.Update(navigationKey('w'))
	if m.workspaceOverlay == nil || m.workspaceOverlay.leader {
		t.Fatal("space w did not open workspace")
	}
	if !strings.Contains(m.workspaceOverlay.view(), "Current session") {
		t.Fatal("workspace context missing")
	}
	for _, item := range m.workspaceOverlay.picker.Items {
		if item.Note == "" {
			t.Fatal("destination has no detail", item.ID)
		}
	}
	m.closeWorkspaceOverlay()
	m.Update(navigationKey(' '))
	m.Update(navigationKey('?'))
	if !m.workspaceOverlay.help || m.Chat.leader != nil {
		t.Fatal("space ? did not open reference")
	}
	found := false
	for _, item := range m.workspaceOverlay.picker.Items {
		if item.Label == "space v d" && strings.Contains(item.Detail, "Toggle diffs") {
			found = true
		}
	}
	if !found {
		t.Fatal("help lacks searchable key/action binding")
	}
}

func TestNavigationSessionsLeaderCannotToggleHiddenChat(t *testing.T) {
	m := leaderFixture(t, 120, 28)
	m.State = AppStateSessionPicker
	m.SessionPicker = NewSessionViewer("/work")
	before := m.Chat.Flags
	m.Update(navigationKey(' '))
	for _, entry := range m.workspaceOverlay.leaderEntries() {
		if entry.destination == "view" {
			t.Fatal("session picker advertises hidden chat controls")
		}
	}
	m.Update(navigationKey('v'))
	m.Update(navigationKey('d'))
	if m.Chat.Flags != before || m.workspaceOverlay.group != "" {
		t.Fatal("session picker toggled hidden chat")
	}
	m.Update(tea.KeyPressMsg{Code: 'h', Mod: tea.ModCtrl})
	if m.workspaceOverlay != nil {
		t.Fatal("ctrl+h did not close menu")
	}
}

func TestNavigationLeaderAgentsAndCompaction(t *testing.T) {
	m := leaderFixture(t, 120, 28)
	m.Update(navigationKey(' '))
	_, cmd := m.Update(navigationKey('a'))
	if cmd == nil {
		t.Fatal("space a did not open agents")
	}
	if _, ok := cmd().(ChatOpenAgentsMsg); !ok {
		t.Fatal("wrong agent action")
	}
	before := m.Chat.Flags.Compaction
	m.Update(navigationKey(' '))
	m.Update(navigationKey('v'))
	m.Update(navigationKey('c'))
	if m.Chat.Flags.Compaction == before {
		t.Fatal("space v c did not toggle compaction")
	}
}
