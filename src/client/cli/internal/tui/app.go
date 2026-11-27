// Package tui implements the interactive CLI and its terminal views.
package tui

import (
	"albedo/cli/internal/attach"
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/terminalclient"
	"context"
	"errors"
	"maps"
	"slices"
	"strings"

	"albedo/cli/internal/tui/agents"
	"albedo/cli/internal/tui/chrome"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

type AppState = terminalclient.Route

const (
	AppStateSettings         = terminalclient.Settings
	AppStateChat             = terminalclient.Chat
	AppStateSessionPicker    = terminalclient.Sessions
	AppStateModelPicker      = terminalclient.Models
	AppStateExtensionPicker  = terminalclient.Extensions
	AppStateTreePicker       = terminalclient.Tree
	AppStateContextInspector = terminalclient.Context
	AppStatePageView         = terminalclient.Page
	AppStateLogin            = terminalclient.Accounts
	AppStateCapabilityPage   = terminalclient.Capabilities
	AppStateWebhooksPage     = terminalclient.Webhooks
	AppStateDiscordPage      = terminalclient.Discord
	AppStateConfigPage       = terminalclient.Config
	AppStateAgents           = terminalclient.Agents
	AppStateFolderPicker     = terminalclient.Folders
	AppStateQuota            = terminalclient.Quota
	AppStateUsage            = terminalclient.Usage
)

type pendingSessionIntents struct {
	continuations map[string]pendingOperation
	users         []PendingUserTurn
}

type Workspace struct {
	UI               daemon.UIPreferences
	Client           *terminalclient.Client
	Conn             *daemon.Connection
	ActiveSession    *daemon.Session
	SettingsETags    map[string]string
	pendingBySession map[string]pendingSessionIntents
	pendingCreations map[string]pendingOperation
	Tick             TickFunc
	openBrowser      func(url string)
	// cd is the /cd question while it is open or its move goes on.
	cd *cdQuestion
	// attachedTo is a moved session's new daemon while its view is open; it
	// takes every message until it quits.
	attachedTo *attachedApp
	// openAttachment reaches a daemon on another host; nil uses ssh.
	openAttachment func(ctx context.Context, host, home string) (*attach.Attachment, error)
	Profiles       config.Profiles
	Workspace      string
	// afterReset is a note for the chat to show once its stream's first reset has
	// hydrated it, which clears any notice added sooner.
	afterReset     string
	Sessions       []daemon.Session
	Notices        Notices
	CommandCatalog []daemon.SessionCommand
	// signIns are the daemon's sign-ins, read once for their terms warnings.
	signIns          []daemon.SignIn
	Usage            UsageModel
	Quota            QuotaModel
	ContextInspector ContextInspectorModel
	ConfigPage       ConfigPageModel
	Settings         settingsIndex
	settingsPath     []AppState
	CapabilityPage   CapabilityPageModel
	WebhooksPage     WebhooksPageModel
	ExtensionPicker  ExtensionPickerModel
	TreePicker       TreePickerModel
	DiscordPage      DiscordPageModel
	ModelPicker      ModelPickerModel
	FolderPicker     FolderPicker
	PageView         PageViewModel
	Login            LoginModel
	Agents           agents.Model
	SessionPicker    SessionViewer
	// listedFilter is the filter the last listing was asked under.
	listedFilter   daemon.SessionFilter
	Chat           ChatModel
	Width          int
	Height         int
	State          AppState
	settingsReturn AppState
	// folderReturn is the screen the folder picker goes back to.
	folderReturn AppState
	titleMode    titleMode
	SettingsGen  int
	// SessionGen invalidates earlier session-list and session-creation replies.
	SessionGen      int
	SessionFactsGen int
	CatalogGen      int
	ModelGen        int
	CommandGen      int
	ProfileGen      int
	UISaving        bool
	StandaloneLogin bool
	// Graphemes says the terminal measures grapheme clusters; see ChatModel.
	Graphemes bool
	// nested marks the model of an attached view, whose quitting returns to
	// the view it is attached under.
	nested bool
	// listingSessions says a session listing is in flight.
	listingSessions bool
	// refreshingSession says a session read is in flight, and SessionFactsGen
	// dates the reply. A read asked for meanwhile is read once more when the
	// answer arrives.
	refreshingSession     bool
	sessionRefreshPending bool
}

func (m *Workspace) newChatModel(session *daemon.Session) ChatModel {
	chat := NewChatModel(session, daemon.NewChatClient(m.Conn, session.ID))
	chat.artifactConn = m.Conn
	chat.openBrowser = m.openBrowser
	chat.termsFor = m.termsFor
	chat.notifyTitle = func() string {
		if m.ActiveSession != nil && m.ActiveSession.ID == session.ID {
			return m.ActiveSession.Title
		}
		return session.Title
	}
	if pending, ok := m.pendingBySession[session.ID]; ok {
		chat.pendingUsers = slices.Clone(pending.users)
		chat.pendingContinuations = maps.Clone(pending.continuations)
		delete(m.pendingBySession, session.ID)
	}
	chat.Flags.AssistantName = m.UI.AssistantName
	chat.Flags.Thinking = m.UI.Thinking
	chat.Flags.Tools = m.UI.Tools
	chat.Notices = slices.Clone(m.Notices)
	chat.graphemes = m.Graphemes
	m.Notices = nil
	return chat
}

// NewWorkspace requires an established daemon connection and panics if conn is nil.
func NewWorkspace(conn *daemon.Connection, bootstrap Bootstrap, initialSession *daemon.Session, workspace string, needsLogin bool, openBrowser func(string)) *Workspace {
	if conn == nil {
		panic("tui.NewWorkspace requires a daemon connection")
	}
	m := &Workspace{
		titleMode:     windowTitleMode(),
		Conn:          conn,
		Profiles:      bootstrap.Settings.Profiles,
		ActiveSession: initialSession,
		Workspace:     workspace,
		openBrowser:   openBrowser,
		Tick:          tea.Tick,
	}

	// Seed the shared owner before constructing a screen that reads preferences.
	m.SessionPicker = NewSessionViewer(workspace)
	m.SessionPicker.Fetch = func(id string) tea.Cmd {
		current, _ := m.session(id)
		return sessionPreviewCmd(conn, id, current.ETag)
	}
	baseFilter := prefs.sessionFilter()
	m.SessionPicker.Filter = baseFilter.Chips(daemon.SessionFilter{})
	m.listedFilter = baseFilter
	m.SettingsETags = maps.Clone(bootstrap.Settings.ETags)
	m.applySessionList(bootstrap.Sessions)
	m.ApplyUI(bootstrap.Settings.UI)
	if needsLogin {
		m.State = AppStateLogin
		m.Login = NewLoginModel(conn, "", openBrowser)
	} else if initialSession != nil {
		m.State = AppStateChat
		m.Chat = m.newChatModel(m.ActiveSession)
	} else {
		m.State = AppStateSessionPicker
	}

	m.mount()
	return m
}

// NewLoginWorkspace starts the standalone login flow, which exits when finished.
func NewLoginWorkspace(conn *daemon.Connection, bootstrap Bootstrap, workspace, nameHint string, openBrowser func(string)) *Workspace {
	m := NewWorkspace(conn, bootstrap, nil, workspace, false, openBrowser)
	m.State = AppStateLogin
	m.StandaloneLogin = true
	m.Login = NewLoginModel(conn, nameHint, openBrowser)
	return m
}

func (m *Workspace) Start() tea.Cmd {
	return tea.Batch(m.initScreen(), m.loadTermsCmd())
}

func (m *Workspace) AddNotice(message string) {
	if m.ActiveSession != nil && m.Chat.History != nil {
		m.Chat.AddNotice(message)
		return
	}
	m.Notices.AddNotice(message)
}

func (m *Workspace) AddError(message string) {
	if m.ActiveSession != nil && m.Chat.History != nil {
		m.Chat.AddError(message)
		return
	}
	m.Notices.AddError(message)
}

func (m *Workspace) ClearNotices() {
	m.Notices.Clear()
	if m.ActiveSession != nil && m.Chat.History != nil {
		m.Chat.ClearNotices()
	}
}

func (m *Workspace) Receive(msg tea.Msg) (handled bool, resultCmd tea.Cmd) {
	previous := m.Chat
	defer func() {
		if previous.Generation != m.Chat.Generation || previous.streamCtx != nil && previous.streamCtx.Err() != nil {
			var cleanup strings.Builder
			for _, preview := range previous.Renderer.ToolImages {
				cleanup.WriteString(deleteToolPreview(preview, terminalGraphics()))
			}
			if previous.Generation == m.Chat.Generation {
				m.Chat.Renderer.ToolImages = nil
			}
			if cleanup.Len() > 0 {
				resultCmd = tea.Sequence(tea.Raw(cleanup.String()), resultCmd)
			}
		}
	}()
	if cmd, handled := m.updateAttached(msg); handled {
		return true, cmd
	}
	if cmd, handled := m.handleCD(msg); handled {
		return true, cmd
	}
	if cmd, handled := m.handleCommandInvocation(msg); handled {
		return true, cmd
	}
	if handled, cmd := m.handleLoginOutcome(msg); handled {
		return true, cmd
	}
	if cmd, handled := m.handleChatLifecycle(msg); handled {
		return true, cmd
	}

	if cmd, handled := m.handlePreferences(msg); handled {
		return true, cmd
	}
	if cmd, handled := m.handleTerms(msg); handled {
		return true, cmd
	}
	if cmd, handled := m.handleSessionResults(msg); handled {
		return true, cmd
	}
	if cmd, handled := m.handleCommandResults(msg); handled {
		return true, cmd
	}

	switch msg := msg.(type) {

	case tea.FocusMsg:
		// the chat is the one screen that wakes up for input
		return true, m.Chat.focus(true)

	case tea.BlurMsg:
		return true, m.Chat.focus(false)

	case tea.ModeReportMsg:
		// the reply Bubble Tea switches to grapheme widths on
		if msg.Mode == ansi.ModeUnicodeCore {
			switch msg.Value {
			case ansi.ModeReset, ansi.ModeSet, ansi.ModePermanentlySet:
				m.Graphemes = true
				m.Chat.graphemes = true
			}
		}
		return true, nil

	case SessionDeleteMsg:
		if m.State != AppStateSessionPicker || !m.SessionPicker.ArchiveView || m.ActiveSession != nil && m.ActiveSession.ID == msg.ID {
			return true, nil
		}
		return true, m.deleteSessionCmd(msg.ID, msg.Condition)

	case commandCatalogLoadedMsg:
		if msg.Gen != m.CatalogGen {
			return true, nil
		}
		if msg.Err != nil {
			if _, ok := errors.AsType[*daemon.UpgradeRequiredError](msg.Err); ok {
				m.AddError("Could not load commands: " + msg.Err.Error())
			}
			return true, nil
		}
		m.CommandCatalog = msg.Commands
		m.Chat.CommandMenu.Catalog = msg.Commands
		if m.ActiveSession != nil {
			m.Chat.syncLayout()
		}
		return true, nil

	case ChatQuitMsg:
		m.Chat.Close()
		return true, m.quit()

	case ChatBackToSessionsMsg:
		return true, m.openSessions()

	case ChatNewSessionMsg:
		return true, m.newSessionCmd()

	case ChatOpenModelPickerMsg:
		return true, m.openModelPicker()

	case ModelPickerSelectMsg:
		m.ModelPicker.Close()
		m.ModelPicker.Saving = true
		m.ModelPicker.Error = ""
		m.ModelGen++
		return true, m.changeModelAccessCmd(msg.Model, msg.Provider, msg.Effort, new(msg.CyberAccess), msg.MakeDefault, m.ModelGen)

	case ModelPickerCapsMsg:
		return true, m.saveCapsCmd(msg)

	case modelCapsSavedMsg:
		if msg.Err == nil {
			if m.SettingsETags == nil {
				m.SettingsETags = map[string]string{}
			}
			m.SettingsETags["models"] = msg.ETag
		}
		var cmd tea.Cmd
		m.ModelPicker, cmd = m.ModelPicker.Update(msg)
		return true, cmd

	case ChatOpenExtensionPickerMsg:
		return true, m.openExtensionPicker()

	case ChatOpenWebhooksPageMsg:
		if m.ActiveSession != nil {
			m.WebhooksPage = NewWebhooksPageModel(m.Conn, m.ActiveSession.ID)
			return true, m.openScreen(AppStateWebhooksPage, &m.WebhooksPage)
		}

	case ChatOpenDiscordPageMsg:
		if m.ActiveSession != nil {
			m.DiscordPage = NewDiscordPageModel(m.Conn, m.ActiveSession.ID)
			return true, m.openScreen(AppStateDiscordPage, &m.DiscordPage)
		}
	case refreshSettingsPanesMsg:
		return true, m.loadSettingsPanes()
	case settingsPanesMsg:
		if msg.gen == m.Settings.generation {
			if msg.err == nil || msg.panes != nil {
				m.Settings.panes = msg.panes
				m.Settings.setDestinations(m.ActiveSession != nil)
			}
			if msg.err != nil {
				m.Settings.problem = "couldn’t load extension panes: " + msg.err.Error()
			} else {
				m.Settings.problem = ""
			}
		}
		return true, nil
	case openToolAccountMsg:
		if m.State == AppStateConfigPage && msg.owner == m.ConfigPage.paneOwner && m.ConfigPage.hasAccount {
			return true, m.openToolAccount(msg.owner)
		}
		return true, nil
	case openSettingsMsg:
		return true, m.openSettings()
	case closeSettingsMsg:
		if m.State == AppStateSettings {
			m.State = m.settingsReturn
			m.settingsPath = nil
		}
		return true, nil
	case settingsDestination:
		return true, m.openSettingsDestination(msg)
	case ChatOpenConfigPageMsg:
		return true, m.openConfigPage()

	case ChatOpenAgentsMsg:
		if m.ActiveSession != nil {
			m.Agents.Reopen(m.Conn, m.ActiveSession.ID)
			return true, m.openScreen(AppStateAgents, &m.Agents)
		}
	case agents.OperationResultMsg:
		if m.State != AppStateAgents && msg.Handle != nil {
			var cmd tea.Cmd
			m.Agents, cmd = m.Agents.Update(msg)
			return true, cmd
		}

	case ChatOpenFolderPickerMsg:
		return true, m.openFolderPicker(msg.Retry)

	case FolderMovedMsg:
		return true, m.moved(msg)

	case FolderPickerCancelMsg:
		m.FolderPicker.Close()
		m.State = m.folderReturn
		return true, nil

	case SessionFoldersMsg:
		return true, m.openFolderBrowser(msg.Query)

	case FolderOpenSessionMsg:
		m.FolderPicker.Close()
		return true, m.openSession(msg.Session)

	case FolderNewSessionMsg:
		m.FolderPicker.Close()
		m.SessionGen++
		return true, m.createSessionCmd(m.SessionGen, msg.Workspace)

	case agents.DoneMsg:
		m.Agents.Close()
		m.State = AppStateChat
		return true, nil

	case agents.AttachMsg:
		m.Agents.Close()
		session := msg.Session
		if i := slices.IndexFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == session.ID }); i >= 0 {
			session = m.Sessions[i]
		}
		return true, m.openSession(session)

	case ModelPickerCancelMsg:
		m.ModelPicker.Close()
		m.State = AppStateChat
		return true, nil

	case WebhooksPageDoneMsg, DiscordPageDoneMsg, ExtensionPickerDoneMsg,
		TreeCancelMsg, ContextDoneMsg, CapabilityPageDoneMsg, PageCancelMsg,
		QuotaCancelMsg, UsageCancelMsg:
		if !m.restoreSettings() {
			m.State = AppStateChat
		}
		return true, nil
	case ConfigPageDoneMsg:
		if !m.restoreSettings() {
			m.State = AppStateChat
		}
		return true, m.refreshSettingsCmd()

	case ExtensionPickerChangedMsg:
		m.CatalogGen++
		cmd := m.loadCommandCatalogCmd(m.CatalogGen)
		if len(m.settingsPath) > 0 {
			cmd = tea.Batch(cmd, m.loadSettingsPanes())
		}
		return true, cmd

	case CapabilityPageChangedMsg:
		m.CatalogGen++
		return true, m.loadCommandCatalogCmd(m.CatalogGen)

	case ChatOpenTreePickerMsg:
		return true, m.openTreePicker(false)

	case ChatOpenForkPickerMsg:
		return true, m.openTreePicker(true)

	case ChatOpenQuotaMsg:
		return true, m.openQuota()

	case ChatOpenUsageMsg:
		return true, m.openUsage()

	case TreeRewindSuccessMsg:
		if m.State != AppStateTreePicker || msg.Generation != m.TreePicker.Generation || m.ActiveSession == nil {
			return true, nil
		}
		conn, id, outcome, gen := m.Conn, m.ActiveSession.ID, msg.Outcome, msg.Generation
		return true, func() tea.Msg {
			s, err := daemon.GetSession(context.Background(), conn, id)
			return TreeRewindReloadMsg{Session: s, Outcome: outcome, Generation: gen, Err: err}
		}

	case TreeRewindReloadMsg:
		if msg.Err != nil {
			m.AddError(chrome.OperationError(msg.Err, "Could not reload rewound session: ", "Reconnect to refresh this session."))
			m.State = AppStateChat
			return true, nil
		}
		note := "Rewound. The earlier conversation is archived as " + msg.Outcome.ArchiveSessionID[:min(8, len(msg.Outcome.ArchiveSessionID))] + "."
		if msg.Outcome.Summary != "" {
			note += " Summary added."
		}
		draft := m.Chat.TextArea.Value()
		cmd := m.setChatSession(msg.Session, false)
		m.afterReset = note
		// A draft the person was writing outranks the message taken back.
		switch {
		case draft != "":
			m.Chat.TextArea.SetValue(draft)
		case msg.Outcome.HasInput:
			m.Chat.TextArea.SetValue(msg.Outcome.Input)
		}
		return true, cmd

	case TreeForkSuccessMsg:
		if m.State != AppStateTreePicker || msg.Generation != m.TreePicker.Generation {
			return true, nil
		}
		return true, m.setChatSession(msg.Session, true)

	case ChatSideQuestionOpenMsg:
		if m.ActiveSession == nil || msg.SessionID != m.ActiveSession.ID || msg.Generation != m.Chat.Generation {
			return true, nil
		}
		return true, m.openSession(msg.Session)

	case ChatOpenContextInspectorMsg:
		return true, m.openContextInspector()

	case ChatOpenCapabilityPageMsg:
		if m.ActiveSession != nil {
			m.CapabilityPage = NewCapabilityPageModel(m.Conn, m.ActiveSession.ID, msg.Kind)
			m.CapabilityPage.openBrowser = m.openBrowser
			return true, m.openScreen(AppStateCapabilityPage, &m.CapabilityPage)
		}

	case ChatOpenPageMsg:
		if m.ActiveSession != nil {
			m.PageView = NewPageViewModel(m.Conn, m.ActiveSession.ID, msg.Command)
			return true, m.openScreen(AppStatePageView, &m.PageView)
		}

	case PageViewChangedMsg:
		m.Chat.statusRevision++
		return true, m.Chat.statusCmd()

	case ChatOpenLoginMsg:
		return true, m.openLogin(msg.Name)

	case LoginCancelMsg:
		cleanup := m.Login.Close()
		m.ProfileGen++
		if m.restoreSettings() {
			return true, tea.Batch(cleanup, m.refreshSettingsCmd(), m.loadSettingsPanes())
		}
		// /login may have removed providers even when it ends without a choice.

		if m.StandaloneLogin {
			return true, tea.Batch(cleanup, tea.Quit)
		}
		if m.ActiveSession != nil {
			return true, tea.Batch(cleanup, m.returnToChat(), m.loadProfilesCmd("", m.ProfileGen))
		}
		m.State = AppStateSessionPicker
		m.updateSessionPickerItems()
		m.SessionGen++
		return true, tea.Batch(cleanup, m.SessionPicker.Init(), m.loadSessionsCmd(m.SessionGen))

	case LoginDoneMsg:
		if m.State != AppStateLogin || msg.Gen != m.Login.Generation {
			return true, nil
		}
		cleanup := m.Login.Close()
		if len(m.Login.SignIns) > 0 {
			m.signIns = m.Login.SignIns
		}
		m.ProfileGen++
		if m.restoreSettings() {
			return true, tea.Batch(cleanup, m.refreshSettingsCmd(), m.loadSettingsPanes())
		}
		return true, tea.Batch(cleanup, m.loadProfilesCmd(msg.Name, m.ProfileGen))

	case PickerSelectMsg:
		if m.State == AppStateSessionPicker {
			switch msg.ID {
			case "new":
				return true, m.newSessionCmd()
			case "archive":
				m.SessionPicker.OpenArchive()
				return true, nil
			case "settings":
				return true, m.openSettings()
			case "login":
				return true, m.openLogin("")
			default:
				// The active session may not yet appear in the daemon's recent list.
				listed := m.Sessions
				if m.ActiveSession != nil && !slices.ContainsFunc(m.Sessions, func(s daemon.Session) bool { return s.ID == m.ActiveSession.ID }) {
					listed = append([]daemon.Session{*m.ActiveSession}, listed...)
				}
				if i := slices.IndexFunc(listed, func(s daemon.Session) bool { return s.ID == msg.ID }); i >= 0 {
					return true, m.openSession(listed[i])
				}
			}
		}

	case PickerCancelMsg:
		if m.State == AppStateSessionPicker {
			if m.SessionPicker.ArchiveView {
				m.SessionPicker.CloseArchive()
				return true, nil
			}
			if m.ActiveSession != nil {
				m.State = AppStateChat
				return true, nil
			}
			return true, m.quit()
		}
	}

	return false, nil
}

func (m *Workspace) chatInput(msg tea.Msg) tea.Cmd {
	var cmd tea.Cmd
	beforePending := len(m.Chat.pendingUsers)
	before := m.Chat.Flags
	m.Chat, cmd = m.Chat.Update(msg)
	if len(m.Chat.pendingUsers) > beforePending {
		m.ClearNotices()
	}
	if m.Chat.Flags.Thinking != before.Thinking || m.Chat.Flags.Tools != before.Tools {
		draft := m.Chat.Flags
		m.Chat.Flags = before
		if !m.UISaving {
			m.UISaving = true
			m.SettingsGen++
			patch := daemon.UIPreferencesPatch{}
			if draft.Thinking != before.Thinking {
				patch.Thinking = &draft.Thinking
			}
			if draft.Tools != before.Tools {
				patch.Tools = &draft.Tools
			}
			cmd = tea.Batch(cmd, m.patchUICmd("", patch, m.SettingsGen))
		}
	}
	return cmd
}
func (m *Workspace) mount() {
	chat := terminalclient.Screen{Input: m.chatInput, Draw: m.Chat.View, Resize: func(w, h int) {
		if m.ActiveSession != nil && m.Chat.History != nil {
			m.Chat.SetSize(w, h)
		}
	}}
	sessions := terminalclient.BindPage(&m.SessionPicker)
	input := sessions.Input
	sessions.Input = func(msg tea.Msg) tea.Cmd {
		cmd := input(msg)
		switch msg.(type) {
		case tea.KeyPressMsg, tea.PasteMsg:
			cmd = tea.Batch(cmd, m.relistForFilter())
		}
		return cmd
	}
	sessions.Page = nil
	sessions.Draw = func() string {
		base := m.sessionsPage().Render(m.Width, m.Height, pageTheme())
		return m.SessionPicker.filterOverlay(base)
	}
	m.Client = terminalclient.New(m, [terminalclient.RouteCount]terminalclient.Screen{
		terminalclient.Chat:         chat,
		terminalclient.Sessions:     sessions,
		terminalclient.Models:       terminalclient.BindPage(&m.ModelPicker),
		terminalclient.Extensions:   terminalclient.BindPage(&m.ExtensionPicker),
		terminalclient.Tree:         terminalclient.BindPage(&m.TreePicker),
		terminalclient.Context:      terminalclient.BindPage(&m.ContextInspector),
		terminalclient.Page:         terminalclient.BindPage(&m.PageView),
		terminalclient.Accounts:     terminalclient.BindPage(&m.Login),
		terminalclient.Capabilities: terminalclient.BindPage(&m.CapabilityPage),
		terminalclient.Webhooks:     terminalclient.BindPage(&m.WebhooksPage),
		terminalclient.Discord:      terminalclient.BindPage(&m.DiscordPage),
		terminalclient.Config:       terminalclient.BindPage(&m.ConfigPage),
		terminalclient.Settings:     terminalclient.BindPage(&m.Settings),
		terminalclient.Agents: {
			Draw:   func() string { return m.Agents.View() },
			Resize: m.Agents.SetSize,
			Input: func(msg tea.Msg) tea.Cmd {
				next, cmd := m.Agents.Update(msg)
				m.Agents = next
				return cmd
			},
		},
		terminalclient.Folders: terminalclient.BindPage(&m.FolderPicker),
		terminalclient.Quota:   terminalclient.BindPage(&m.Quota),
		terminalclient.Usage:   terminalclient.BindPage(&m.Usage),
	}, pageTheme)
}
