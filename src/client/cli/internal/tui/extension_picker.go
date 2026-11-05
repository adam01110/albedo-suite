package tui

import (
	"albedo/cli/internal/daemon"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
)

type ExtensionItem = daemon.ExtensionSummary

type ExtensionPickerDoneMsg struct{}
type ExtensionPickerChangedMsg struct{}

type extensionsLoadedMsg struct {
	Err        error
	Extensions []ExtensionItem
	Gen        int
}

type extensionToggledMsg struct {
	Err        error
	Notice     string
	Extensions []ExtensionItem
	Gen        int
	Warns      bool
}

// The scopes a change can be made in, and the confirmation each asks.
const (
	scopeGlobal  = "global"
	scopeSession = "session"
	scopeInherit = "inherit"
)

// ExtensionPickerModel lists the extensions with the global default and
// this session's own choice side by side. Enter changes the global default;
// shift+enter changes this session only.
type ExtensionPickerModel struct {
	Conn       *daemon.Connection
	SessionID  string
	Extensions []ExtensionItem
	listView
	confirm
	pageStatus
	// noticeWarns says the notice is a warning rather than a save that went through.
	noticeWarns                 bool
	providersOpen, builtinsOpen bool
}

func NewExtensionPickerModel(conn *daemon.Connection, sessionID string) ExtensionPickerModel {
	return ExtensionPickerModel{
		Conn:       conn,
		SessionID:  sessionID,
		pageStatus: newPageStatus(true),
		listView:   newListView("Search extensions"),
	}
}

func (m *ExtensionPickerModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.setSize(width, height)
}

// Confirming reports a question waiting for enter or esc.
func (m ExtensionPickerModel) Confirming() bool { return m.asking() }

func (m ExtensionPickerModel) Init() tea.Cmd {
	return m.loadExtensionsCmd(m.Generation)
}

func (m ExtensionPickerModel) loadExtensionsCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return extensionsLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		items, err := daemon.ListExtensions(context.Background(), m.Conn, m.SessionID)
		return extensionsLoadedMsg{Extensions: items, Err: err, Gen: gen}
	}
}

// changeExtensionCmd sends one change: scope "global" or "session" with a
// value, or "inherit" to drop this session's choice.
func (m ExtensionPickerModel) changeExtensionCmd(name, scope string, enabled bool, gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return extensionToggledMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		etag := ""
		for _, item := range m.Extensions {
			if item.Name == name {
				etag = item.SessionETag
				if scope == "global" {
					etag = item.GlobalETag
				}
			}
		}
		body := daemon.ExtensionSelectionRequest{Name: name, Scope: scope, ETag: etag}
		if scope != "inherit" {
			body.Enabled = &enabled
		}
		updated, err := daemon.SelectExtension(context.Background(), m.Conn, m.SessionID, body)
		if err != nil {
			return extensionToggledMsg{Err: err, Gen: gen}
		}
		notice, warns := "Saved the global default. Reload sessions to apply it.", false
		if scope != "global" {
			warns = true
			reloaded, reloadErr := daemon.ReloadSession(context.Background(), m.Conn, m.SessionID, daemon.ReloadRequest{Target: "session"})
			switch {
			case reloadErr != nil:
				notice = "Selection saved; reload failed: " + reloadErr.Error()
				if _, uncertain := errors.AsType[*daemon.UncertainOutcomeError](reloadErr); uncertain {
					notice = "Selection saved; reload not confirmed: " + reloadErr.Error()
				}
			case reloaded.Session == nil:
				notice = "Selection saved; reload returned no session outcome."
			case reloaded.Session.State != "applied":
				notice = "Selection saved; session reload " + reloaded.Session.State + ". " + reloaded.Message()
			default:
				notice, warns = reloaded.Message(), false
			}
		}
		return extensionToggledMsg{Extensions: updated, Notice: notice, Warns: warns, Gen: gen}
	}
}

func extensionCapabilities(ext ExtensionItem) []string {
	var caps []string
	if ext.Context {
		caps = append(caps, "context")
	}
	if len(ext.Tools) > 0 {
		caps = append(caps, fmt.Sprintf("tools (%s)", strings.Join(ext.Tools, ", ")))
	}
	if len(ext.PythonModules) > 0 {
		caps = append(caps, fmt.Sprintf("python modules (%s)", strings.Join(ext.PythonModules, ", ")))
	}
	return caps
}

// current is the extension under the cursor.
func (m ExtensionPickerModel) current() (ExtensionItem, bool) {
	row, ok := m.highlighted()
	if !ok {
		return ExtensionItem{}, false
	}
	i := slices.IndexFunc(m.Extensions, func(e ExtensionItem) bool { return e.Name == row.key })
	if i < 0 {
		return ExtensionItem{}, false
	}
	return m.Extensions[i], true
}

func (m *ExtensionPickerModel) setExtensions(items []ExtensionItem) {
	m.Extensions = items
	m.rebuildShelves()
}

// askToggle asks before changing an extension in scope, or before dropping
// this session's own choice.
func (m *ExtensionPickerModel) askToggle(scope string) {
	ext, ok := m.current()
	if !ok {
		return
	}
	if ext.Quarantined != "" {
		m.Error = ext.Quarantined
		return
	}
	m.Error = ""
	on := ext.GlobalEnabled
	if scope == scopeSession {
		on = ext.Enabled
	}
	if memoryStrategy(ext) && scope != scopeInherit {
		if on {
			return
		}
		scopeText := "globally"
		if scope == scopeSession {
			scopeText = "for this session"
		}
		prompt := fmt.Sprintf("Switch memory to %s %s?", ext.Name, scopeText)
		suffix := ""
		for _, old := range m.Extensions {
			chosen := old.GlobalEnabled
			if scope == scopeSession {
				chosen = old.Enabled
			}
			if memoryStrategy(old) && chosen && old.Name != ext.Name {
				switch old.Name {
				case "coding-lcm":
					suffix = " coding-lcm's summaries stay readable through the lcm tools."
				case "snapcompact":
					suffix = " snapcompact's images stay in the transcript."
				default:
					suffix = " Existing summaries stay in the transcript."
				}
				break
			}
		}
		prompt += suffix
		if scope == scopeSession {
			prompt += " This will reload this session."
		}
		m.ask(scope, ext.Name, "switch", prompt)
		return
	}
	verb := "enable"
	if on {
		verb = "disable"
	}
	switch scope {
	case scopeInherit:
		m.ask(scope, ext.Name, "follow global", fmt.Sprintf("This session will follow the global default for %s. Remove its own choice?", ext.Name))
	case scopeSession:
		m.ask(scope, ext.Name, verb, fmt.Sprintf("This will reload this session. %s %s for this session only?", strings.ToUpper(verb[:1])+verb[1:], ext.Name))
	default:
		m.ask(scope, ext.Name, verb, fmt.Sprintf("Sessions following global defaults will use this change. %s %s globally?", strings.ToUpper(verb[:1])+verb[1:], ext.Name))
	}
}

// save sends the change the confirmation asked about.
func (m *ExtensionPickerModel) save() tea.Cmd {
	ext, ok := m.current()
	if !ok || ext.Name != m.target {
		m.dismiss()
		return nil
	}
	m.Saving, m.Error = true, ""
	m.Generation = nextPageGeneration()
	enabled := !ext.GlobalEnabled
	switch m.what {
	case scopeSession:
		enabled = !ext.Enabled
	case scopeInherit:
		enabled = false
	}
	return m.changeExtensionCmd(ext.Name, m.what, enabled, m.Generation)
}

func (m ExtensionPickerModel) Update(msg tea.Msg) (ExtensionPickerModel, tea.Cmd) {
	switch msg := msg.(type) {
	case extensionsLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.Error = ""
		m.setExtensions(msg.Extensions)
		return m, nil

	case extensionToggledMsg:
		if msg.Gen == m.Generation {
			if apiErr, ok := errors.AsType[*daemon.APIError](msg.Err); ok && apiErr.StatusCode == 412 {
				m.Saving, m.Loading, m.Error = false, true, ""
				m.dismiss()
				m.Notice, m.noticeWarns = "The configuration changed. Review the refreshed choices before saving.", true
				m.Generation = nextPageGeneration()
				return m, m.loadExtensionsCmd(m.Generation)
			}
		}
		if !m.settle(msg.Gen, msg.Err, &m.Saving) {
			m.failed = msg.Gen == m.Generation
			return m, nil
		}
		m.dismiss()
		m.setExtensions(msg.Extensions)
		m.Error = ""
		m.Notice, m.noticeWarns = msg.Notice, msg.Warns
		return m, func() tea.Msg { return ExtensionPickerChangedMsg{} }

	case tea.KeyPressMsg:
		if !m.confirm.asking() {
			var done bool
			msg, done = m.navigation.key(msg, &m.input, false)
			if done {
				return m, nil
			}
		}
		key := msg.String()
		switch {
		case m.asking() && !m.Saving:
			if m.key(msg) {
				cmd := m.save()
				return m, cmd
			}
			if !m.asking() {
				m.Error = ""
			}
			return m, nil
		case key == "esc" || key == "ctrl+c" || key == "ctrl+d":
			return m, func() tea.Msg { return ExtensionPickerDoneMsg{} }
		case m.Loading || m.Saving:
			return m, nil
		}
		ext, _ := m.current()
		switch key {
		case "enter":
			if row, ok := m.highlighted(); ok && row.heading {
				switch row.group {
				case "providers":
					m.providersOpen = !m.providersOpen
				case "builtins":
					m.builtinsOpen = !m.builtinsOpen
				}
				m.rebuildShelves()
			} else {
				m.askToggle(scopeGlobal)
			}
		case "shift+enter", "alt+enter":
			m.askToggle(scopeSession)
		case "ctrl+x":
			if ext.Overridden {
				m.askToggle(scopeInherit)
			}
		case "ctrl+w":
			if ext.Name == "webhooks" && ext.Enabled {
				return m, func() tea.Msg { return ChatOpenWebhooksPageMsg{} }
			}
			if ext.Name == "discord" && ext.Enabled {
				return m, func() tea.Msg { return ChatOpenDiscordPageMsg{} }
			}
		case "ctrl+r":
			m.Loading, m.Error, m.Notice = true, "", ""
			m.Generation = nextPageGeneration()
			return m, m.loadExtensionsCmd(m.Generation)
		default:
			before := m.input.Value()
			cmd := m.update(msg)
			if before != m.input.Value() {
				m.rebuildShelves()
			}
			return m, cmd
		}
		return m, nil
	}
	before := m.input.Value()
	cmd := m.update(msg)
	if before != m.input.Value() {
		m.rebuildShelves()
	}
	return m, cmd
}

func stateLead(on bool) string {
	if on {
		return DefaultStyles.Success.Render("on")
	}
	return DefaultStyles.Faint.Render("off")
}

// daggered marks a row's state as this session's own choice.
func daggered(lead string, overridden bool) string {
	if overridden {
		return lead + DefaultStyles.Muted.Render("†")
	}
	return lead
}

// daggerLegend is the title's right end while some row carries a dagger.
func daggerLegend(marked bool) string {
	if !marked {
		return ""
	}
	return DefaultStyles.Muted.Render("†") + DefaultStyles.Faint.Render(" session override")
}

func onOff(on bool) string {
	if on {
		return "on"
	}
	return "off"
}

// extensionDetails returns pane facts, with the scope being confirmed first.
func extensionDetails(ext ExtensionItem, asked string, width int) []string {
	lines := paneTitle(ext.Name, ext.Description, width)
	if ext.Quarantined != "" {
		for _, line := range svWrap("quarantined: "+ext.Quarantined, width, 6) {
			lines = append(lines, DefaultStyles.Error.Render(line))
		}
		lines = append(lines, "")
	}
	session := "follows everywhere"
	if ext.Overridden {
		session = onOff(ext.Enabled) + " (its own choice)"
	}
	facts := [][]string{factRows("everywhere", onOff(ext.GlobalEnabled), width), factRows("here", session, width)}
	if asked == scopeSession || asked == scopeInherit {
		slices.Reverse(facts)
	}
	lines = append(lines, slices.Concat(facts...)...)
	lines = append(lines, factRows("needs", joinOr(ext.Requires, ", ", "none"), width)...)
	lines = append(lines, factRows("provides", joinOr(extensionCapabilities(ext), " · ", "not reported"), width)...)
	if ext.Quarantined != "" {
		return lines
	}
	switch asked {
	case "":
		return lines
	case scopeGlobal:
		return append(append(lines, ""), paneNote("A global change applies as sessions reload.", width)...)
	}
	return append(append(lines, ""), paneNote("A session change reloads this session and may lose Python variables that cannot be saved.", width)...)
}

// scopeRows are the global and session facts, the session's first when a
// question asks about it.
func scopeRows(global, session, asked string, width int) []string {
	rows := [][]string{factRows("global", global, width), factRows("session", session, width)}
	if asked == scopeSession || asked == scopeInherit {
		slices.Reverse(rows)
	}
	return slices.Concat(rows...)
}

func joinOr(items []string, sep, empty string) string {
	if len(items) == 0 {
		return empty
	}
	return strings.Join(items, sep)
}

func (m ExtensionPickerModel) footer(width int) string {
	if m.asking() && !m.Saving {
		return m.confirm.footer(width, m.Error)
	}
	if len(m.Extensions) == 0 && m.Error != "" {
		return footerLine(width, []hint{{"ctrl+r", "retry"}, {"esc", "back"}}, DefaultStyles.Error.Render(m.Error), true)
	}
	ext, _ := m.current()
	hints := []hint{{"↑↓", "move"}, {"enter", "everywhere"}, {"shift+enter", "here"}}
	if row, ok := m.highlighted(); ok && row.heading {
		hints = []hint{{"↑↓", "move"}, {"enter", "open/close"}}
	}
	if ext.Overridden {
		hints = append(hints, hint{"ctrl+x", "follow global"})
	}
	if (ext.Name == "webhooks" || ext.Name == "discord") && ext.Enabled {
		hints = append(hints, hint{"ctrl+w", ext.Name})
	}
	hints = append(hints, hint{"ctrl+r", "refresh"}, hint{"esc", "back"})

	var status string
	urgent := true
	switch {
	case m.Saving:
		status = DefaultStyles.Busy.Render("saving…")
	case m.Loading:
		status, urgent = DefaultStyles.Faint.Render("loading…"), false
	case m.Error != "":
		status = DefaultStyles.Error.Render(m.Error)
	case m.Notice != "":
		status = notice(m.Notice, m.noticeWarns)
	default:
		on := 0
		for _, e := range m.Extensions {
			if e.Enabled {
				on++
			}
		}
		status, urgent = DefaultStyles.Faint.Render(fmt.Sprintf("%s · %d on here", counted(len(m.Extensions), "extension"), on)), false
	}
	return footerLine(width, hints, status, urgent)
}

func (m ExtensionPickerModel) View() string {
	lv := m.listView
	lv.Empty = "No extensions are available for this session."
	switch {
	case m.Loading:
		lv.Empty = "loading extensions…"
	case m.Error != "" && len(m.Extensions) == 0:
		lv.Empty = "Could not load extensions; the reason is in the footer."
	}
	own := 0
	for _, ext := range m.Extensions {
		if ext.Overridden {
			own++
		}
	}
	right := ""
	if own > 0 {
		right = DefaultStyles.Muted.Render(fmt.Sprintf("%d own choices here", own))
	}
	frame := lv.frame(brand("albedo")+" "+DefaultStyles.Muted.Render("/extensions"), right, m.footer(max(1, m.Width)))
	if ext, ok := m.current(); ok && m.asking() {
		frame.pane = detailPane(func(width int) []string { return extensionDetails(ext, m.what, width) })
	}
	return frame.view(m.Width, m.Height)
}
