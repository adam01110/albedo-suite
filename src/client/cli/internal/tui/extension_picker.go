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
	Extensions []ExtensionItem
	Notice     string
	Warns      bool
	Gen        int
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
	// noticeWarns says the notice is a warning rather than a save that went through.
	noticeWarns bool
	pageStatus
	listView
	confirm
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
	m.listView.setSize(width, height)
}

// Confirming reports a question waiting for enter or esc.
func (m ExtensionPickerModel) Confirming() bool { return m.confirm.asking() }

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

func (m ExtensionPickerModel) capabilitiesList(ext ExtensionItem) []string {
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
	rows := make([]listEntry, len(items))
	for i, ext := range items {
		rows[i] = m.entry(ext)
	}
	m.setRows(rows)
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
	verb := "enable"
	if on {
		verb = "disable"
	}
	switch scope {
	case scopeInherit:
		m.confirm.ask(scope, ext.Name, "follow global", fmt.Sprintf("This session will follow the global default for %s. Remove its own choice?", ext.Name))
	case scopeSession:
		m.confirm.ask(scope, ext.Name, verb, fmt.Sprintf("This will reload this session. %s %s for this session only?", strings.ToUpper(verb[:1])+verb[1:], ext.Name))
	default:
		m.confirm.ask(scope, ext.Name, verb, fmt.Sprintf("Sessions following global defaults will use this change. %s %s globally?", strings.ToUpper(verb[:1])+verb[1:], ext.Name))
	}
}

// save sends the change the confirmation asked about.
func (m *ExtensionPickerModel) save() tea.Cmd {
	ext, ok := m.current()
	if !ok || ext.Name != m.confirm.target {
		m.confirm.dismiss()
		return nil
	}
	m.Saving, m.Error = true, ""
	m.Generation = nextPageGeneration()
	enabled := !ext.GlobalEnabled
	switch m.confirm.what {
	case scopeSession:
		enabled = !ext.Enabled
	case scopeInherit:
		enabled = false
	}
	return m.changeExtensionCmd(ext.Name, m.confirm.what, enabled, m.Generation)
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
				m.confirm.dismiss()
				m.Notice, m.noticeWarns = "The configuration changed. Review the refreshed choices before saving.", true
				m.Generation = nextPageGeneration()
				return m, m.loadExtensionsCmd(m.Generation)
			}
		}
		if !m.settle(msg.Gen, msg.Err, &m.Saving) {
			m.confirm.failed = msg.Gen == m.Generation
			return m, nil
		}
		m.confirm.dismiss()
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
		case m.confirm.asking() && !m.Saving:
			if m.confirm.key(msg) {
				cmd := m.save()
				return m, cmd
			}
			if !m.confirm.asking() {
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
			m.askToggle(scopeGlobal)
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
			cmd := m.listView.update(msg)
			return m, cmd
		}
		return m, nil
	}
	cmd := m.listView.update(msg)
	return m, cmd
}

// entry is how an extension reads in the list: its state in this session in
// front, daggered when that is the session's own choice.
func (m ExtensionPickerModel) entry(ext ExtensionItem) listEntry {
	lead, tag := daggered(stateLead(ext.Enabled), ext.Overridden), ""
	if ext.Quarantined != "" {
		lead, tag = DefaultStyles.Error.Render("bad"), DefaultStyles.Error.Render("quarantined")
	}
	return listEntry{
		key:    ext.Name,
		lead:   lead,
		name:   ext.Name,
		desc:   ext.Description,
		tag:    tag,
		search: append(slices.Clone(ext.Plugins), ext.Requires...),
		detail: func(width int) []string { return m.details(ext, "", width) },
	}
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

// details is the pane: both choices, the one a question asks about first,
// what the extension provides, and what each key would change.
func (m ExtensionPickerModel) details(ext ExtensionItem, asked string, width int) []string {
	lines := paneTitle(ext.Name, ext.Description, width)
	session := "follows global"
	if ext.Overridden {
		session = onOff(ext.Enabled) + " (its own choice)"
	}
	lines = append(lines, scopeRows(onOff(ext.GlobalEnabled)+" default", session, asked, width)...)
	lines = append(lines, factRows("plugins", joinOr(ext.Plugins, ", ", "not reported"), width)...)
	lines = append(lines, factRows("provides", joinOr(m.capabilitiesList(ext), " · ", "not reported"), width)...)
	lines = append(lines, factRows("requires", joinOr(ext.Requires, ", ", "none"), width)...)
	if ext.Quarantined != "" {
		lines = append(lines, "")
		for _, l := range svWrap("quarantined: "+ext.Quarantined, width, 6) {
			lines = append(lines, DefaultStyles.Error.Render(l))
		}
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
	if m.confirm.asking() && !m.Saving {
		return m.confirm.footer(width, m.Error)
	}
	if len(m.Extensions) == 0 && m.Error != "" {
		return footerLine(width, []hint{{"ctrl+r", "retry"}, {"esc", "back"}}, DefaultStyles.Error.Render(m.Error), true)
	}
	ext, _ := m.current()
	hints := []hint{{"↑↓", "move"}, {"enter", "global"}, {"shift+enter", "this session"}}
	if ext.Overridden {
		hints = append(hints, hint{"ctrl+x", "follow global"})
	}
	if (ext.Name == "webhooks" || ext.Name == "discord") && ext.Enabled {
		hints = append(hints, hint{"ctrl+w", ext.Name})
	}
	hints = append(hints, hint{"esc", "back"})

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
	marked := slices.ContainsFunc(m.Extensions, func(e ExtensionItem) bool { return e.Overridden && e.Quarantined == "" })
	frame := lv.frame(brand("albedo")+" "+DefaultStyles.Muted.Render("/extensions"), daggerLegend(marked), m.footer(max(1, m.Width)))
	if ext, ok := m.current(); ok && m.confirm.asking() {
		frame.pane = detailPane(func(width int) []string { return m.details(ext, m.confirm.what, width) })
	}
	return frame.view(m.Width, m.Height)
}
