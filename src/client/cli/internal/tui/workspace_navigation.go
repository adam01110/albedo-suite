package tui

import (
	"cmp"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// The launcher is separate from the composer: opening or cancelling it cannot
// modify a draft, its attachments, or its undo history.
type ChatOpenWorkspaceMsg struct{}

type workspacePickerResult struct {
	owner  *workspaceOverlay
	result tea.Msg
}

type workspaceOverlay struct {
	picker  PickerModel
	help    bool
	leader  bool
	group   string
	session bool
	chat    bool
	context string
}

func (o workspaceOverlay) view() string {
	p := o.picker
	if o.leader {
		return strings.Join(o.leaderRows(p.Width, p.Height), "\n")
	}
	f := listFrame{title: brand("albedo") + " " + DefaultStyles.Bold.Render(p.Title), filter: p.navigation.filterLine(p.SearchInput), footer: keyHints(hint{"j/k", "move"}, hint{"l/enter", "open"}, hint{"/", "search"}, hint{"esc", "back"})}
	if !o.help {
		f.right = ansi.Truncate(o.context, max(1, p.Width/3), "…")
	}
	if o.help {
		f.footer = keyHints(hint{"j/k", "browse"}, hint{"/", "find key or action"}, hint{"F1/esc", "close"})
	}
	f.list = func(width, height int) []string {
		var rows []string
		selected, group := -1, ""
		for i, item := range p.Filtered {
			if !o.help && workspaceGroup(item.ID) != group {
				group = workspaceGroup(item.ID)
				rows = append(rows, DefaultStyles.Faint.Render("  "+group))
			}
			line := "  " + pickerRow(item)
			if i == p.Cursor {
				selected = len(rows)
				line = selectBar() + " " + pickerRow(item)
				line = selectedLine(ansi.Truncate(line, width, "…"), width)
			}
			rows = append(rows, line)
		}
		if len(rows) == 0 {
			rows = []string{DefaultStyles.Faint.Render("  no matches")}
		}
		return scrollWindow(rows, selected, width, height)
	}
	if item, ok := p.Highlighted(); ok {
		f.pane = func(width, height int) []string {
			rows := paneTitle(item.Label, "", width)
			rows = append(rows, "")
			rows = append(rows, svWrap(cmp.Or(item.Note, item.Detail), width, max(1, height-len(rows)))...)
			return scrollWindow(rows, -1, width, height)
		}
	}
	return f.view(p.Width, p.Height)
}

func (m *AppModel) openWorkspaceOverlay(help bool) {
	m.closeWorkspaceOverlay()
	items := []PickerItem{
		{ID: "sessions", Label: "Sessions", Detail: "open, pin, rename and archive"},
		{ID: "folders", Label: "Folders", Detail: "browse workspaces and their sessions"},
		{ID: "new", Label: "New session", Detail: "start in the current workspace"},
		{ID: "login", Label: "Providers", Detail: "accounts and availability"},
		{ID: "config", Label: "Settings", Detail: "extension configuration"},
		{ID: "quota", Label: "Usage and quota"},
	}
	if m.ActiveSession != nil {
		items = append([]PickerItem{{ID: "chat", Label: "Conversation", Detail: "return to the current draft"},
			{ID: "model", Label: "Model", Detail: "provider, effort and context window"},
			{ID: "agents", Label: "Agents", Detail: "navigate sessions and message agents"},
			{ID: "tree", Label: "History", Detail: "branch or rewind with confirmation"},
			{ID: "context", Label: "Context", Detail: "inspect the model request"},
			{ID: "extensions", Label: "Extensions", Detail: "tools and capabilities"}}, items...)
	}
	if !help && m.ActiveSession != nil {
		known := map[string]bool{}
		for _, item := range items {
			known["/"+item.ID] = true
		}
		for _, command := range m.CommandCatalog {
			name := "/" + strings.TrimPrefix(command.Name, "/")
			if command.Page != nil && *command.Page && !known[name] {
				items = append(items, PickerItem{ID: name, Label: name, Detail: command.Description})
				known[name] = true
			}
		}
	}
	title := "Workspace"
	if help {
		title = "Keyboard reference"
		items = keyboardReference()
	}
	if !help {
		for i := range items {
			items[i].Note = workspaceDetail(items[i])
		}
	}
	p := NewPickerModel(title, items, true, "")
	p.SetSize(m.Width, m.Height)
	context := "No active session"
	if m.ActiveSession != nil {
		context = oneLine(ansi.Strip(m.ActiveSession.Title))
	}
	m.workspaceOverlay = &workspaceOverlay{picker: p, help: help, context: context}
}

func (m *AppModel) updateWorkspaceOverlay(msg tea.Msg) (tea.Cmd, bool) {
	if _, ok := msg.(ChatOpenWorkspaceMsg); ok {
		m.openWorkspaceOverlay(false)
		return nil, true
	}
	if event, ok := msg.(workspacePickerResult); ok {
		if m.workspaceOverlay != event.owner {
			return nil, true
		}
		switch result := event.result.(type) {
		case PickerCancelMsg:
			m.closeWorkspaceOverlay()
		case PickerSelectMsg:
			if !event.owner.help {
				m.closeWorkspaceOverlay()
				return m.workspaceDestination(result.ID), true
			}
		}
		return nil, true
	}
	if size, ok := msg.(tea.WindowSizeMsg); ok && m.workspaceOverlay != nil {
		m.workspaceOverlay.picker.SetSize(size.Width, size.Height)
	}
	key, isKey := msg.(tea.KeyPressMsg)
	if isKey && key.String() == "f1" {
		if m.workspaceOverlay != nil && m.workspaceOverlay.help {
			m.closeWorkspaceOverlay()
		} else {
			m.openWorkspaceOverlay(true)
		}
		return nil, true
	}
	root := m.State == AppStateChat || m.State == AppStateSessionPicker
	normal := m.State == AppStateChat && m.Chat.vim.normal && !m.Chat.reader.searching && len(m.Chat.effortOptions) == 0 && m.Chat.direnvAsk == "" && len(m.Chat.CommandMenu.Matches(m.Chat.TextArea.Value())) == 0 || m.State == AppStateSessionPicker && !m.SessionPicker.navigation.editing && !m.SessionPicker.rename.active() && !m.SessionPicker.confirm.asking()
	if m.State == AppStateChat {
		normal = normal && m.Chat.vim.pending == "" && m.Chat.vim.count == 0 && m.Chat.vim.argument == nil && m.Chat.reader.pending == "" && m.Chat.reader.count == 0
	} else if m.State == AppStateSessionPicker {
		normal = normal && !m.SessionPicker.navigation.pendingG && m.SessionPicker.navigation.count == 0
	}
	if isKey && m.workspaceOverlay == nil && root && (key.String() == "f2" || normal && key.Mod == 0 && key.Text == " ") {
		if key.String() == "f2" {
			m.openWorkspaceOverlay(false)
		} else {
			m.openLeader()
		}
		return nil, true
	}
	if m.workspaceOverlay == nil {
		return nil, false
	}
	if _, ok := msg.(tea.MouseMsg); ok {
		return nil, true
	}
	if !isKey {
		if _, ok := msg.(tea.PasteMsg); !ok {
			return nil, false
		}
	}
	o := m.workspaceOverlay
	if o.leader {
		if isKey {
			return m.updateLeader(key), true
		}
		return nil, true
	}
	if isKey && (key.String() == "f2" || key.String() == "ctrl+c") {
		m.closeWorkspaceOverlay()
		return nil, true
	}
	// Resolve the existing picker's immediate messages here, rather than letting
	// them collide with a screen that happens to use PickerSelectMsg too.
	next, cmd := o.picker.Update(msg)
	o.picker = next
	if cmd == nil {
		return nil, true
	}
	if isKey && (key.String() == "enter" || key.String() == "esc" || key.String() == "ctrl+d" || !o.picker.navigation.editing && (key.Text == "l" || key.Text == "h" || key.Text == "q")) {
		return func() tea.Msg { return workspacePickerResult{owner: o, result: cmd()} }, true
	}
	return cmd, true
}

func (m *AppModel) workspaceDestination(id string) tea.Cmd {
	switch id {
	case "chat":
		if m.ActiveSession != nil {
			return m.returnToChat()
		}
	case "sessions":
		return m.openSessions()
	case "folders":
		return m.openFolderBrowser("")
	case "new":
		return m.newSessionCmd()
	case "login":
		return m.openLogin("")
	case "config":
		return m.openConfigPage()
	case "quota":
		return m.openQuota()
	case "model":
		return m.openModelPicker()
	case "tree":
		return m.openTreePicker(false)
	case "context":
		return m.openContextInspector()
	case "extensions":
		return m.openExtensionPicker()
	case "agents":
		return func() tea.Msg { return ChatOpenAgentsMsg{} }
	default:
		if m.ActiveSession != nil {
			name := "/" + strings.TrimPrefix(id, "/")
			return func() tea.Msg { return ChatOpenPageMsg{Command: name} }
		}
	}
	return nil
}
