package tui

import (
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	"albedo/cli/internal/tui/chrome"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// accountService is a sign-in service as /accounts names it: what it is
// called, the models it brings, and the subscriptions that sign in to it.
type accountService struct{ Extension, Label, Blurb, Plans string }

// accountServices are the sign-in services /accounts lists first, in this
// order. Keep the names and model lists here so they are easy to update;
// other sign-in services keep the daemon's own label and detail.
var accountServices = []accountService{
	{Extension: "claude", Label: "Claude", Blurb: "Opus, Sonnet, Haiku", Plans: "Pro or Max"},
	{Extension: "codex", Label: "ChatGPT", Blurb: "Astra, Sol, Terra, Luna", Plans: "Plus or Pro"},
	{Extension: "antigravity", Label: "Gemini", Blurb: "Gemini 4 Carbon, Argon, Hydrogen", Plans: "Google account"},
}

// keyBlurb is what the API key group can reach.
const keyBlurb = "OpenRouter, Mistral, Bedrock…"

// rotationModes are how a service's accounts take turns, in the order tab
// cycles them.
var rotationModes = []struct{ ID, Label, Detail string }{
	{daemon.RotationFailover, "one at a time", "Use #1; move down the list when it's limited."},
	{daemon.RotationSpread, "spread evenly", "Each new session or agent starts on the next account and stays there."},
	{daemon.RotationFirst, "only #1", "Never switch; wait when it's limited."},
}

func rotationMode(id string) (label, detail string) {
	for _, mode := range rotationModes {
		if mode.ID == id {
			return mode.Label, mode.Detail
		}
	}
	return rotationModes[0].Label, rotationModes[0].Detail
}

// nextRotation is the mode after id in the cycle.
func nextRotation(id string) string {
	i := slices.IndexFunc(rotationModes, func(mode struct{ ID, Label, Detail string }) bool { return mode.ID == id })
	return rotationModes[(i+1)%len(rotationModes)].ID
}

// The sections and rows of /accounts that are not a service's own.
const (
	sectionKeys     = "API keys"
	sectionTools    = string(toolSignIns)
	sectionMore     = "sign in to more"
	sectionAdvanced = "advanced"

	rowAccount  = "acct:"
	rowAdd      = "add:"
	rowMore     = "more:"
	rowTool     = "tool:"
	rowKeys     = "keys"
	rowAdvanced = "advanced"
	rowPending  = "pending"
)

// serviceGroup is one sign-in service with the accounts it holds, in the
// order its rotation uses them.
type serviceGroup struct {
	Extension, Label, Blurb, Mode string
	Accounts                      []daemon.Account
	HasLogin                      bool
}

// rotates reports a service whose accounts take turns, so they are numbered
// and tab and alt+↑↓ change how.
func (g serviceGroup) rotates() bool { return len(g.Accounts) > 1 }

func modelAccount(a daemon.Account) bool { return a.Kind != "key" && a.Kind != "service" }

// serviceName is a sign-in service's label and model list.
func (m LoginModel) serviceName(extension string) (label, blurb string) {
	if i := slices.IndexFunc(accountServices, func(s accountService) bool { return s.Extension == extension }); i >= 0 {
		return accountServices[i].Label, accountServices[i].Blurb
	}
	if login, ok := m.signInFor(extension); ok {
		return providerName(extension, login.Label), login.Detail
	}
	return providerName(extension, ""), ""
}

// offeredModelServices puts the familiar subscriptions first and keeps the
// daemon's label and detail for extensions that contribute other sign-ins.
func (m LoginModel) offeredModelServices() []accountService {
	var services []accountService
	seen := map[string]bool{}
	for _, service := range accountServices {
		if login, ok := m.signInFor(service.Extension); ok && login.Kind != "service" && len(login.Flows) > 0 {
			services = append(services, service)
			seen[service.Extension] = true
		}
	}
	start := len(services)
	for _, login := range m.SignIns {
		if seen[login.Provider] || login.Kind == "service" || len(login.Flows) == 0 {
			continue
		}
		services = append(services, accountService{Extension: login.Provider, Label: providerName(login.Provider, login.Label), Blurb: login.Detail})
		seen[login.Provider] = true
	}
	slices.SortStableFunc(services[start:], func(a, b accountService) int {
		return strings.Compare(strings.ToLower(a.Label), strings.ToLower(b.Label))
	})
	return services
}

// serviceGroups includes both offered sign-ins and providers that still hold
// saved accounts after their sign-in goes away.
func (m LoginModel) serviceGroups() []serviceGroup {
	var extensions []string
	for _, service := range m.offeredModelServices() {
		extensions = append(extensions, service.Extension)
	}
	offered := len(extensions)
	for _, a := range m.Accounts {
		if modelAccount(a) && !slices.Contains(extensions, a.Provider) {
			extensions = append(extensions, a.Provider)
		}
	}
	groups := make([]serviceGroup, 0, len(extensions))
	for i, extension := range extensions {
		var ids []string
		byID := map[string]daemon.Account{}
		for _, a := range m.Accounts {
			if a.Provider == extension && modelAccount(a) {
				ids = append(ids, a.ID)
				byID[a.ID] = a
			}
		}
		order, mode := daemon.ServiceRotation(extension, m.Profiles, ids)
		g := serviceGroup{Extension: extension, Mode: mode, HasLogin: i < offered}
		g.Label, g.Blurb = m.serviceName(extension)
		for _, id := range order {
			g.Accounts = append(g.Accounts, byID[id])
		}
		groups = append(groups, g)
	}
	return groups
}

// groupOf is the service an account belongs to.
func (m LoginModel) groupOf(account daemon.Account) (serviceGroup, bool) {
	for _, g := range m.serviceGroups() {
		if g.Extension == account.Provider && modelAccount(account) {
			return g, true
		}
	}
	return serviceGroup{}, false
}

// accountByID finds an account the daemon listed.
func (m LoginModel) accountByID(id string) (daemon.Account, bool) {
	i := slices.IndexFunc(m.Accounts, func(a daemon.Account) bool { return a.ID == id })
	if i < 0 {
		return daemon.Account{}, false
	}
	return m.Accounts[i], true
}

// limitedUntil is when an account's limit ends, if it is limited now.
func limitedUntil(a daemon.Account) (time.Time, bool) {
	until, err := time.Parse(time.RFC3339, a.LimitedUntil)
	if err != nil || !until.After(time.Now()) {
		return time.Time{}, false
	}
	return until, true
}

func clock(t time.Time) string { return t.Local().Format("15:04") }

// allLimited reports a service none of whose accounts can run now, at least
// one of them only until a limit ends, and when the first comes back.
func (g serviceGroup) allLimited() (time.Time, bool) {
	var first time.Time
	for _, a := range g.Accounts {
		if a.Disabled {
			continue
		}
		until, limited := limitedUntil(a)
		switch {
		case a.NeedsSignIn, !limited:
			return time.Time{}, false
		case first.IsZero() || until.Before(first):
			first = until
		}
	}
	return first, !first.IsZero()
}

// keyName is what a key account reaches: the key provider whose endpoint
// it sends to, else the endpoint's host, else its extension.
func keyName(a daemon.Account) string {
	if a.Endpoint != nil {
		for _, p := range customProviders {
			if p.DefaultURL != "" && p.DefaultURL == *a.Endpoint {
				return p.Label
			}
		}
	}
	if p, ok := customFor(a.Provider); ok && p.Extension != "openai" {
		return p.Label
	}
	return cmp.Or(a.Detail, a.Provider)
}

// sameKeyTarget reports two key accounts that reach the same models.
func sameKeyTarget(a, b daemon.Account) bool {
	return a.Provider == b.Provider && deref(a.Endpoint) == deref(b.Endpoint)
}

// signOutConsequence says what keeps working, or stops, once the account
// is signed out.
func (m LoginModel) signOutConsequence(a daemon.Account) string {
	switch a.Kind {
	case "key":
		name := keyName(a)
		var rest []string
		for _, other := range m.Accounts {
			if other.ID != a.ID && other.Kind == "key" && !other.Disabled && sameKeyTarget(a, other) {
				rest = append(rest, other.Label)
			}
		}
		if len(rest) > 0 {
			return fmt.Sprintf("%s keeps running on %s.", name, strings.Join(rest, ", "))
		}
		return fmt.Sprintf("Models from %s stop until you add another %s key.", name, name)
	case "service":
		return "Tools that use it stop until you sign in again."
	}
	label, _ := m.serviceName(a.Provider)
	var rest []string
	if g, ok := m.groupOf(a); ok {
		for _, other := range g.Accounts {
			if other.ID != a.ID && !other.Disabled {
				rest = append(rest, other.Label)
			}
		}
	}
	if len(rest) > 0 {
		return fmt.Sprintf("%s keeps running on %s.", label, strings.Join(rest, ", "))
	}
	return label + " models stop working until you sign in again. Sessions keep their history."
}

// lastOfService reports that signing out leaves its service nothing to run.
func (m LoginModel) lastOfService(a daemon.Account) bool {
	return !strings.Contains(m.signOutConsequence(a), "keeps running")
}

// pendingIn reports the inline sign-in in flight for a provider, and which
// account it signs in again, if any.
func (m LoginModel) pendingIn(provider string) (accountID string, ok bool) {
	if !m.signingInline() || m.Provider != provider {
		return "", false
	}
	return m.reSignIn, true
}

// signingInline reports a sign-in started from the accounts list, which
// stays on screen while it runs.
func (m LoginModel) signingInline() bool {
	return m.inline && (m.Step == StepOAuth)
}

// accountsEmpty reports the first run: nothing signed in, no key and no
// setup, so the screen offers the sign-ins up front instead of a list.
func (m LoginModel) accountsEmpty() bool {
	if m.destination == toolSignIns || !m.loaded || len(m.Profiles.Providers) > 0 || m.signingInline() {
		return false
	}
	return !slices.ContainsFunc(m.Accounts, func(a daemon.Account) bool { return a.Kind != "service" })
}

// accountColumns are the widths of an account row's label, plan and status
// in width cells after its lead.
func accountColumns(width int) (label, plan, status int) {
	label, plan, status = 22, 11, 15
	if spare := width - (3 + label + 1 + plan + status + 3); spare < 0 {
		label = max(8, label+spare)
	}
	return label, plan, status
}

// buildChoosePicker lists what the screen shows: the accounts, or the
// advanced setups when they are open.
func (m *LoginModel) buildChoosePicker() {
	if m.advanced {
		m.buildAdvancedPicker()
		return
	}
	m.buildAccountsPicker()
}

// buildAccountsPicker lists the accounts one section per service, each
// closed by a row that adds another, then API keys, tool sign-ins, the
// services not yet signed in to, and the advanced setups. The cursor stays
// on its row across a rebuild.
func (m *LoginModel) buildAccountsPicker() {
	keep := m.focus
	m.focus = ""
	if keep == "" {
		if row, ok := m.ChoosePicker.highlighted(); ok {
			keep = row.key
		}
	}
	var rows []listEntry
	titles := map[string]func(width int) string{}
	if m.destination == toolSignIns {
		rows = m.toolRows()
	} else {
		rows = m.modelAccountRows(titles)
	}

	if !slices.ContainsFunc(rows, func(r listEntry) bool { return r.key == keep }) {
		keep = ""
		if i := slices.IndexFunc(rows, func(r listEntry) bool { return strings.HasPrefix(r.key, rowAccount) }); i >= 0 {
			keep = rows[i].key
		}
	}
	if m.signingInline() {
		keep = rowPending
	}
	if !m.loaded {
		// Nothing is known until the daemon answers, not even what to add.
		rows = nil
	}
	p := loginPick{listView: newListView("find an account")}
	p.Empty = "loading accounts…"
	if m.destination == toolSignIns && m.loaded {
		p.Empty = "no tool sign-ins available"
	}
	if !m.loaded && m.Error != "" {
		p.Empty = "could not load accounts"
	}
	p.setSize(m.Width, m.Height)
	p.sectionTitle = func(section string, width int) string {
		if title, ok := titles[section]; ok {
			return title(width)
		}
		return chrome.SectionRule(section, 0, width)
	}
	for _, r := range rows {
		p.items = append(p.items, loginItem{ID: r.key, Label: r.name})
	}
	p.setRows(rows)
	if i := slices.IndexFunc(p.shown, func(s listShown) bool { return p.rows[s.row].key == keep }); i >= 0 {
		p.Cursor = i
	}
	m.ChoosePicker = p
}

func (m LoginModel) pendingRow(section string) listEntry {
	return listEntry{key: rowPending, section: section, name: "signing in…", draw: func(int, []int) string {
		return chrome.DefaultStyles.Agent.Render("◌") + "  " + chrome.DefaultStyles.Agent.Render("signing in… finish in your browser")
	}, detail: m.pendingPane}
}

// Older daemons sent action phrases as the names of built-in sign-ins.
func providerName(id, declared string) string {
	for _, service := range accountServices {
		if service.Extension == id {
			return service.Label
		}
	}
	for _, provider := range customProviders {
		if provider.Extension == id && provider.ID == "add-"+id {
			return provider.Label
		}
	}
	switch id {
	case "honcho":
		return "Honcho"
	case "colab":
		return "Google Colab"
	default:
		return cmp.Or(declared, id)
	}
}

func (m LoginModel) toolRows() []listEntry {
	var rows []listEntry
	connected := map[string]bool{}
	section := sectionTools
	if m.destination == toolSignIns {
		section = ""
	}
	for _, a := range m.Accounts {
		if a.Kind != "service" || (m.toolOwner != "" && a.Provider != m.toolOwner) {
			continue
		}
		connected[a.Provider] = true
		service, detail := m.serviceName(a.Provider)
		status := "connected"
		if a.NeedsSignIn {
			status = "needs sign-in"
		}
		row := listEntry{
			key: rowAccount + a.ID, section: section, name: service, desc: a.Label,
			tag: chrome.DefaultStyles.Muted.Render(status), search: []string{a.Provider, a.Email, detail},
			detail: func(width int) []string {
				lines := paneTitle(service, detail, width)
				lines = append(lines, factRows("account", a.Label, width)...)
				return append(lines, factRows("status", status, width)...)
			},
		}
		rows = append(rows, row)
	}
	for _, login := range m.SignIns {
		if login.Kind != "service" || (m.toolOwner != "" && login.Provider != m.toolOwner) {
			continue
		}
		if _, pending := m.pendingIn(login.Provider); pending {
			rows = append(rows, m.pendingRow(section))
		} else if !connected[login.Provider] {
			rows = append(rows, listEntry{
				key: rowTool + login.Provider, section: section, name: providerName(login.Provider, login.Label),
				tag: chrome.DefaultStyles.Muted.Render("signed out"), search: []string{login.Provider, login.Detail},
				detail: func(width int) []string {
					return paneTitle(providerName(login.Provider, login.Label), login.Detail, width)
				},
			})
		}
	}
	return rows
}

func (m LoginModel) modelAccountRows(titles map[string]func(int) string) []listEntry {
	var rows []listEntry
	var more []listEntry
	for _, g := range m.serviceGroups() {
		reSign, pending := m.pendingIn(g.Extension)
		if len(g.Accounts) == 0 && !pending {
			if g.HasLogin {
				more = append(more, m.moreRow(rowMore+g.Extension, g.Label, g.Blurb, m.servicePane(g)))
			}
			continue
		}
		section := g.Label
		titles[section] = m.groupTitle(g)
		for i, a := range g.Accounts {
			if pending && reSign == a.ID {
				rows = append(rows, m.pendingRow(section))
				continue
			}
			rows = append(rows, m.accountRow(a, section, g, i))
		}
		switch {
		case pending && reSign == "":
			rows = append(rows, m.pendingRow(section))
		case g.HasLogin:
			rows = append(rows, m.addRow(rowAdd+g.Extension, section, "add a "+g.Label+" account", m.servicePane(g)))
		}
	}
	var keys []daemon.Account
	for _, a := range m.Accounts {
		if a.Kind == "key" {
			keys = append(keys, a)
		}
	}
	if len(keys) > 0 {
		titles[sectionKeys] = func(width int) string { return accountsRule(sectionKeys, len(keys), "", width) }
		for _, a := range keys {
			rows = append(rows, m.accountRow(a, sectionKeys, serviceGroup{}, 0))
		}
		rows = append(rows, m.addRow(rowKeys, sectionKeys, "add a key", m.keysPane()))
	} else {
		more = append(more, m.moreRow(rowKeys, "API key or endpoint", keyBlurb, m.keysPane()))
	}
	if m.destination == "" {
		rows = append(rows, m.toolRows()...)
	}
	if len(more) > 0 {
		titles[sectionMore] = func(width int) string { return accountsRule(sectionMore, -1, "", width) }
		rows = append(rows, more...)
	}
	titles[sectionAdvanced] = func(width int) string { return accountsRule(sectionAdvanced, -1, "", width) }
	rows = append(rows, listEntry{key: rowAdvanced, section: sectionAdvanced, name: "setups", desc: "models, endpoints, protocols, pins",
		search: []string{"profiles", "advanced"},
		draw: func(width int, hits []int) string {
			lw, _, _ := accountColumns(width)
			return chrome.DefaultStyles.Muted.Render("⋯") + "  " + markedCell("setups", hits, lw, lipgloss.NewStyle()) + " " +
				chrome.DefaultStyles.Faint.Render(ansi.Truncate("models, endpoints, protocols, pins", max(1, width-lw-4), "…"))
		},
		detail: m.advancedPane})

	return rows
}

// accountsRule heads a section: " ─ Claude 2 · one at a time ───". A
// negative count shows none.
func accountsRule(label string, count int, extra string, width int) string {
	head := " " + label + " "
	tail := ""
	if count >= 0 {
		tail = fmt.Sprintf("%d ", count)
	}
	used := 2 + ansi.StringWidth(head+tail) + ansi.StringWidth(extra)
	if extra != "" {
		used++
	}
	out := chrome.DefaultStyles.Decor.Render(" ─") + chrome.DefaultStyles.Muted.Bold(true).Render(head) + chrome.DefaultStyles.Decor.Render(tail)
	if extra != "" {
		out += extra + " "
	}
	return out + chrome.DefaultStyles.Decor.Render(strings.Repeat("─", max(2, width-used)))
}

// groupTitle is a service's rule: its name, how many accounts it has, and
// how they take turns, or when the first is back if every one is limited.
func (m LoginModel) groupTitle(g serviceGroup) func(width int) string {
	extra := ""
	if back, all := g.allLimited(); all {
		extra = chrome.DefaultStyles.Faint.Render("· ") + chrome.DefaultStyles.Warning.Render("all limited · back "+clock(back))
	} else if g.rotates() {
		label, _ := rotationMode(g.Mode)
		extra = chrome.DefaultStyles.Faint.Render("· " + label)
	}
	return func(width int) string { return accountsRule(g.Label, len(g.Accounts), extra, width) }
}

// accountState is an account's dot, its short status for the row, and its
// longer one for the pane, each in its colour.
func accountState(a daemon.Account) (dot, short, long string) {
	if a.Disabled {
		return chrome.DefaultStyles.Faint.Render("○"), chrome.DefaultStyles.Faint.Render("disabled"), chrome.DefaultStyles.Faint.Render("disabled")
	}
	if a.NeedsSignIn {
		return chrome.DefaultStyles.Error.Render("✕"), chrome.DefaultStyles.Error.Render("sign in again"), chrome.DefaultStyles.Error.Render("needs sign-in")
	}
	if until, limited := limitedUntil(a); limited {
		return chrome.DefaultStyles.Warning.Render("◐"), chrome.DefaultStyles.Warning.Render("back " + clock(until)), chrome.DefaultStyles.Warning.Render("limited until " + clock(until))
	}
	if a.Source == "env" {
		return chrome.DefaultStyles.Success.Render("●"), chrome.DefaultStyles.Faint.Render("environment"), chrome.DefaultStyles.Success.Render("ready")
	}
	return chrome.DefaultStyles.Success.Render("●"), chrome.DefaultStyles.Muted.Render("ready"), chrome.DefaultStyles.Success.Render("ready")
}

// accountPlan is the small tag after an account's label: its plan, or for a
// key what it reaches.
func accountPlan(a daemon.Account) string {
	if a.Kind == "key" {
		return keyName(a)
	}
	return a.Plan
}

// accountRow is one account: its state, label, plan, status, and its place
// in the rotation when the service has several.
func (m LoginModel) accountRow(a daemon.Account, section string, g serviceGroup, index int) listEntry {
	place := ""
	if g.rotates() {
		place = fmt.Sprintf("#%d", index+1)
	}
	plan := accountPlan(a)
	return listEntry{key: rowAccount + a.ID, section: section, name: a.Label, desc: plan, search: []string{a.Email},
		draw: func(width int, hits []int) string {
			lw, pw, sw := accountColumns(width)
			dot, short, _ := accountState(a)
			status := short + strings.Repeat(" ", max(1, sw-ansi.StringWidth(short)))
			return dot + "  " + markedCell(a.Label, hits, lw, lipgloss.NewStyle()) + " " +
				chrome.DefaultStyles.Muted.Render(chrome.Cell(plan, pw-1, false)) + " " + status + chrome.DefaultStyles.Faint.Render(place)
		},
		detail: func(width int) []string { return m.accountPane(a, width) }}
}

// addRow closes a section with what adds to it.
func (m LoginModel) addRow(key, section, label string, pane func(int) []string) listEntry {
	return listEntry{key: key, section: section, name: label, draw: func(width int, hits []int) string {
		return chrome.DefaultStyles.Muted.Render("+") + "  " + markedCell(label, hits, max(1, width-3), chrome.DefaultStyles.Muted)
	}, detail: pane}
}

// moreRow is a service not signed in to yet, with what it brings.
func (m LoginModel) moreRow(key, label, blurb string, pane func(int) []string) listEntry {
	return listEntry{key: key, section: sectionMore, name: label, desc: blurb, draw: func(width int, hits []int) string {
		lw, _, _ := accountColumns(width)
		line := chrome.DefaultStyles.Muted.Render("+") + "  " + markedCell(label, hits, lw, lipgloss.NewStyle())
		if room := width - lw - 4; room > 3 && blurb != "" {
			line += " " + chrome.DefaultStyles.Muted.Render(ansi.Truncate(blurb, room, "…"))
		}
		return line
	}, detail: pane}
}

// accountPane is what an account's detail says: its status, models and
// place, then what enter or ctrl+x does with it.
func (m LoginModel) accountPane(a daemon.Account, width int) []string {
	service, blurb := m.serviceName(a.Provider)
	switch a.Kind {
	case "key":
		service, blurb = "API keys", "from "+keyName(a)
	case "service":
		service, blurb = "tool sign-in", ""
	}
	subtitle := service
	if plan := accountPlan(a); plan != "" {
		subtitle += " · " + plan
	}
	lines := paneTitle(a.Label, subtitle, width)
	_, _, long := accountState(a)
	lines = append(lines, factRows("status", long, width)...)
	if blurb != "" {
		lines = append(lines, factRows("models", blurb, width)...)
	}
	g, grouped := m.groupOf(a)
	if grouped && g.rotates() {
		place := slices.IndexFunc(g.Accounts, func(o daemon.Account) bool { return o.ID == a.ID }) + 1
		mode, _ := rotationMode(g.Mode)
		lines = append(lines, factRows("rotation", fmt.Sprintf("#%d of %d · %s", place, len(g.Accounts), mode), width)...)
	}
	if a.Email != "" && a.Email != a.Label {
		lines = append(lines, factRows("email", a.Email, width)...)
	}
	if a.Source == "env" {
		lines = append(lines, factRows("source", "the daemon's environment", width)...)
	}
	lines = append(lines, "")
	back, all := g.allLimited()
	switch {
	case a.Source == "env":
		lines = append(lines, paneNote("From the daemon's environment; change or remove it there.", width)...)
	case a.Disabled:
		lines = append(lines, paneNote("Disabled: it stays signed in, but rotation and pinned setups skip it. ctrl+t enables it again.", width)...)
	case a.NeedsSignIn:
		lines = append(lines, paneNote(service+" ended this sign-in. enter signs in again and keeps its place; rotation skips it until then.", width)...)
	case grouped && all:
		lines = append(lines, paneNote(fmt.Sprintf("Every %s account is limited. Sessions on %s wait until %s.", service, service, clock(back)), width)...)
		if other := m.readyServiceBesides(a.Provider); other != "" {
			// A sentence of its own, so the wrap never breaks after the slash.
			lines = append(lines, paneNote("/model can switch them to "+other+".", width)...)
		}
	default:
		lines = append(lines, paneNote("ctrl+x signs out this account. "+m.signOutConsequence(a), width)...)
		if toggleable(a) {
			lines = append(lines, paneNote("ctrl+t disables it without signing out; other accounts keep running.", width)...)
		}
	}
	return lines
}

// toggleable reports a saved model or key account the user can switch off
// and on; environment accounts and tool sign-ins have no switch.
func toggleable(a daemon.Account) bool {
	return a.Source != "env" && a.Kind != "service"
}

// toggleVerb is what ctrl+t does to an account.
func toggleVerb(a daemon.Account) string {
	if a.Disabled {
		return "enable"
	}
	return "disable"
}

// readyServiceBesides names another service with an account that can run
// now, for sessions to move to.
func (m LoginModel) readyServiceBesides(extension string) string {
	for _, g := range m.serviceGroups() {
		if g.Extension == extension {
			continue
		}
		for _, a := range g.Accounts {
			if _, limited := limitedUntil(a); !limited && !a.NeedsSignIn && !a.Disabled {
				return g.Label
			}
		}
	}
	return ""
}

// servicePane is what adding an account to a service says.
func (m LoginModel) servicePane(g serviceGroup) func(int) []string {
	return func(width int) []string {
		lines := paneTitle(g.Label, g.Blurb, width)
		note := "enter opens " + g.Label + "'s sign-in page in your browser. Nothing else to answer."
		if len(g.Accounts) > 0 {
			note = fmt.Sprintf("enter opens %s's sign-in page in your browser. The new account joins the rotation as #%d.", g.Label, len(g.Accounts)+1)
		}
		return append(lines, paneNote(note, width)...)
	}
}

func (m LoginModel) keysPane() func(int) []string {
	return func(width int) []string {
		lines := paneTitle("API key or endpoint", keyBlurb, width)
		return append(lines, paneNote("enter lists the key providers: OpenRouter, Mistral, Bedrock, Vertex, any OpenAI- or Anthropic-compatible endpoint.", width)...)
	}
}

func (m LoginModel) advancedPane(width int) []string {
	lines := paneTitle("Setups", "advanced", width)
	return append(lines, paneNote("enter opens the named setups behind your accounts: which model each starts on, endpoints, protocols, keys, and accounts pinned to one setup.", width)...)
}

// pendingPane is the sign-in in flight: the link to finish it on another
// machine, and where the account will go.
func (m LoginModel) pendingPane(width int) []string {
	label, _ := m.serviceName(m.Provider)
	lines := paneTitle("signing in to "+label, "", width)
	if !m.acceptsSignInInput() {
		lines = append(lines, m.deviceInstructions(width)...)
		return lines
	}
	if m.SignInURL == "" {
		lines = append(lines, chrome.DefaultStyles.Muted.Render(cmp.Or(m.Status, "starting sign-in…")))
	} else {
		lead := "Open this page to sign in, or on another machine:"
		if m.openBrowser != nil {
			lead = "Your browser opened the sign-in page. If it didn't, or you're on another machine:"
		}
		lines = append(lines, paneNote(lead, width)...)
		lines = append(lines, "")
		lines = append(lines, linkRows(m.SignInURL, width)...)
	}
	if m.LoginInstructions != "" {
		lines = append(lines, "")
		lines = append(lines, paneNote(m.LoginInstructions, width)...)
	}
	lines = append(lines, "")
	note := "then paste the code above."
	g := serviceGroup{}
	for _, group := range m.serviceGroups() {
		if group.Extension == m.Provider {
			g = group
		}
	}
	switch {
	case m.reSignIn != "":
		note += " It keeps its place in the rotation."
	case len(g.Accounts) > 0:
		note += fmt.Sprintf(" It joins the rotation as #%d.", len(g.Accounts)+1)
	}
	return append(lines, paneNote(note, width)...)
}

// accountsHints are the keys for the highlighted row of the accounts list.
func (m LoginModel) accountsHints(width int) []chrome.Hint {
	if m.signingInline() {
		if m.signInOver() {
			return []chrome.Hint{{Key: "enter", Does: "try again"}, {Key: "esc", Does: "back"}}
		}
		var hints []chrome.Hint
		if m.acceptsSignInInput() {
			hints = append(hints, chrome.Hint{Key: "enter", Does: "submit code"})
		}
		if m.openBrowser != nil && m.SignInURL != "" {
			hints = append(hints, chrome.Hint{Key: "ctrl+o", Does: "open browser"})
		}
		return append(hints, chrome.Hint{Key: "esc", Does: "cancel sign-in"})
	}
	row, ok := m.ChoosePicker.highlighted()
	if !ok {
		return []chrome.Hint{{Key: "↑↓", Does: "move"}, {Key: "esc", Does: "back"}}
	}
	id, isAccount := strings.CutPrefix(row.key, rowAccount)
	if !isAccount {
		verb := "sign in"
		switch row.key {
		case rowKeys:
			verb = "choose"
		case rowAdvanced:
			verb = "open"
		}
		return []chrome.Hint{{Key: "↑↓", Does: "move"}, {Key: "enter", Does: verb}, {Key: "esc", Does: "back"}}
	}
	a, _ := m.accountByID(id)
	if a.Source == "env" {
		return []chrome.Hint{{Key: "↑↓", Does: "move"}, {Key: "esc", Does: "back"}}
	}
	if a.NeedsSignIn && !a.Disabled {
		return []chrome.Hint{{Key: "enter", Does: "sign in again"}, {Key: "↑↓", Does: "move"}, {Key: "ctrl+t", Does: "disable"}, {Key: "ctrl+x", Does: "sign out"}, {Key: "esc", Does: "back"}}
	}
	hints := []chrome.Hint{{Key: "↑↓", Does: "move"}}
	if m.destination == toolSignIns {
		hints = append(hints, chrome.Hint{Key: "enter", Does: "sign out"})
	}
	if toggleable(a) {
		hints = append(hints, chrome.Hint{Key: "ctrl+t", Does: toggleVerb(a)})
	}
	if g, ok := m.groupOf(a); ok && g.rotates() {
		hints = append(hints, chrome.Hint{Key: "tab", Does: "rotation"}, chrome.Hint{Key: "alt+↑↓", Does: "order"})
	}
	if width >= 100 {
		hints = append(hints, chrome.Hint{Key: "ctrl+r", Does: "rename"})
	}
	if m.destination != toolSignIns {
		hints = append(hints, chrome.Hint{Key: "ctrl+x", Does: "sign out"})
	}
	return append(hints, chrome.Hint{Key: "esc", Does: "back"})
}

// accountsFooter is the list's keys with the status or error beside them,
// or the sign-out question.
func (m LoginModel) accountsFooter(width int) string {
	if m.Step == StepRemove {
		return m.signOutFooter(width)
	}
	if m.Step == StepSaving {
		return chrome.StatusRows(width, chrome.DefaultStyles.Faint.Render(cmp.Or(m.listBusy, "saving…")))
	}
	if m.accountsEmpty() {
		hints := []chrome.Hint{{Key: "↑↓", Does: "move"}, {Key: "enter", Does: "choose"}, {Key: "esc", Does: "later"}}
		if m.Error != "" {
			return chrome.FooterLine(width, hints, chrome.DefaultStyles.Error.Render(m.Error), true)
		}
		return chrome.FooterLine(width, hints, "", false)
	}
	hints := m.accountsHints(width)
	if m.Error != "" {
		return chrome.FooterLine(width, hints, chrome.DefaultStyles.Error.Render(m.Error), true)
	}
	status := m.Status
	if m.signingInline() {
		status = ""
	}
	if status != "" {
		return chrome.FooterLine(width, hints, chrome.DefaultStyles.Faint.Render(status), true)
	}
	return chrome.FooterLine(width, hints, "", false)
}

// signOutFooter asks before signing out, saying what keeps running or
// stops: the question and its consequence on one row when they fit.
func (m LoginModel) signOutFooter(width int) string {
	if m.Removing.Kind != "account" {
		return m.confirm.Footer(width, m.Error)
	}
	question := " Sign out " + m.Removing.Label + "? "
	consequence := m.confirm.Prompt
	style := chrome.DefaultStyles.Muted
	if a, ok := m.accountByID(m.Removing.ID); ok && m.lastOfService(a) {
		style = chrome.DefaultStyles.Warning
	}
	var rows []string
	if ansi.StringWidth(question+consequence) <= width-1 {
		rows = append(rows, chrome.DefaultStyles.Bold.Render(question)+style.Render(consequence))
	} else {
		rows = append(rows, chrome.DefaultStyles.Bold.Render(ansi.Truncate(question, width-1, "…")))
		for line := range strings.SplitSeq(ansi.Wrap(consequence, max(1, width-2), " "), "\n") {
			rows = append(rows, " "+style.Render(line))
		}
	}
	verb := "sign out"
	if m.Error != "" {
		rows = append(rows, " "+chrome.DefaultStyles.Error.Render(ansi.Truncate(m.Error, max(1, width-1), "…")))
		verb = "retry"
	}
	return strings.Join(append(rows, " "+chrome.KeyHints(chrome.Hint{Key: "enter", Does: verb}, chrome.Hint{Key: "esc", Does: "keep"})), "\n")
}

// accountsKey handles the accounts list's own keys and reports whether it
// took the key; the rest move and filter the list.
func (m *LoginModel) accountsKey(msg tea.KeyPressMsg) (bool, tea.Cmd) {
	key := msg.String()
	row, ok := m.ChoosePicker.highlighted()
	if !ok {
		return false, nil
	}
	id, isAccount := strings.CutPrefix(row.key, rowAccount)
	account, known := m.accountByID(id)
	switch key {
	case "tab", "alt+up", "alt+down", "ctrl+r", "ctrl+t", "ctrl+x", "ctrl+d":
	default:
		return false, nil
	}
	if !isAccount || !known {
		return true, nil
	}
	if account.Source == "env" {
		m.Error = ""
		m.Status = "environment accounts are read from the daemon's environment; change them there"
		return true, nil
	}
	switch key {
	case "ctrl+r":
		return true, m.askAccountRename(account)
	case "ctrl+t":
		if !toggleable(account) {
			m.Error = ""
			m.Status = "tool sign-ins have no switch; ctrl+x signs out"
			return true, nil
		}
		return true, m.toggleAccount(account)
	case "ctrl+x", "ctrl+d":
		return true, m.confirmRemoval(removal{Kind: "account", Provider: account.Provider, ID: account.ID, Label: account.Label})
	}
	g, grouped := m.groupOf(account)
	if !grouped || !g.rotates() {
		return true, nil
	}
	order := make([]string, len(g.Accounts))
	for i, a := range g.Accounts {
		order[i] = a.ID
	}
	mode := g.Mode
	switch key {
	case "tab":
		mode = nextRotation(g.Mode)
	case "alt+up", "alt+down":
		at := slices.Index(order, account.ID)
		to := at - 1
		if key == "alt+down" {
			to = at + 1
		}
		if to < 0 || to >= len(order) {
			return true, nil
		}
		order[at], order[to] = order[to], order[at]
	}
	return true, m.saveRotation(g, order, mode)
}

// toggleAccount switches one account off or on, leaving the rest of its
// service and every setup as they are, then re-reads what the daemon holds.
func (m *LoginModel) toggleAccount(a daemon.Account) tea.Cmd {
	enabled := a.Disabled
	m.Error, m.Status = "", ""
	verb := "disabling "
	if enabled {
		verb = "enabling "
	}
	m.listBusy = verb + a.Label + "…"
	m.focus = rowAccount + a.ID
	m.buildChoosePicker()
	m.Step = StepSaving
	// The toggle supersedes any list read still in flight, whose answer would
	// put back the account's state from before it.
	m.Generation = nextPageGeneration()
	conn, id := m.Conn, a.ID
	return m.reloadCmd(func(ctx context.Context) error {
		_, err := daemon.SetAccountEnabled(ctx, conn, id, enabled)
		return err
	})
}

// saveRotation shows a service's new order and mode at once and writes it
// to every profile of the service, then re-reads what the daemon holds.
func (m *LoginModel) saveRotation(g serviceGroup, order []string, mode string) tea.Cmd {
	before := m.Profiles
	targets := daemon.RotationTargets(g.Extension, before)
	if len(targets) == 0 {
		m.Error = ""
		m.Status = "nothing runs " + g.Label + " yet, so there is no order to keep; sign in again or add a setup under advanced"
		return nil
	}
	providers := maps.Clone(before.Providers)
	for _, name := range targets {
		s := providers[name]
		s.AccountIDs, s.Rotation, s.AccountID = slices.Clone(order), mode, nil
		providers[name] = s
	}
	m.Profiles.Providers = providers
	m.Error, m.Status = "", ""
	label, detail := rotationMode(mode)
	m.rotationNote = g.Label + ": " + label + ". " + detail
	m.listBusy = "saving " + g.Label + "'s rotation…"
	m.buildChoosePicker()
	m.Step = StepSaving
	conn, extension := m.Conn, g.Extension
	return m.reloadCmd(func(ctx context.Context) error {
		_, err := daemon.SaveServiceRotation(ctx, conn, extension, before, order, mode)
		return err
	})
}

// chooseAccountsRow runs enter on a row of the accounts list.
func (m *LoginModel) chooseAccountsRow(id string) tea.Cmd {
	m.Error = ""
	switch {
	case id == rowAdvanced:
		m.advanced = true
		m.Status = ""
		return m.backToChoose()
	case id == rowKeys:
		return m.chooseKeyProvider()
	case strings.HasPrefix(id, rowAdd), strings.HasPrefix(id, rowMore), strings.HasPrefix(id, rowTool):
		provider := id[strings.IndexByte(id, ':')+1:]
		return m.signInInline(provider, "")
	case strings.HasPrefix(id, rowAccount):
		if a, ok := m.accountByID(strings.TrimPrefix(id, rowAccount)); ok {
			if a.NeedsSignIn {
				return m.signInInline(a.Provider, a.ID)
			}
			if m.destination == toolSignIns && a.Source != "env" {
				return m.confirmRemoval(removal{Kind: "account", Provider: a.Provider, ID: a.ID, Label: a.Label})
			}
		}
	}
	return nil
}

// signInInline starts a sign-in that runs on the accounts list: the row
// waits in its section and the search line takes the code. accountID names
// the account it signs in again, or is empty for a new one.
func (m *LoginModel) signInInline(provider, accountID string) tea.Cmd {
	login, ok := m.signInFor(provider)
	if !ok {
		label, _ := m.serviceName(provider)
		m.Error = label + " sign-in isn't available right now"
		return nil
	}
	m.inline, m.reSignIn = true, accountID
	m.Status = ""
	return m.startSignIn(login)
}

// endInline leaves an inline sign-in for the list, keeping the account it
// was about highlighted.
func (m *LoginModel) endInline() tea.Cmd {
	if m.reSignIn != "" {
		m.focus = rowAccount + m.reSignIn
	} else if login, ok := m.signInFor(m.Provider); ok && login.Kind == "service" {
		m.focus = rowTool + m.Provider
	} else {
		m.focus = rowAdd + m.Provider
	}
	m.inline, m.reSignIn = false, ""
	return m.backToChoose()
}

// signedIn returns to the list after an inline sign-in brought an account
// back, highlighting it and saying where it went, and re-reads the list so
// the setups the daemon updated show.
func (m *LoginModel) signedIn(account daemon.Account) tea.Cmd {
	again := m.reSignIn != ""
	m.inline, m.reSignIn = false, ""
	m.focus = rowAccount + account.ID
	m.Error = ""
	label, _ := m.serviceName(account.Provider)
	m.Status = "Signed in to " + label + " as " + account.Label + "."
	if g, ok := m.groupOf(account); ok && g.rotates() {
		place := slices.IndexFunc(g.Accounts, func(a daemon.Account) bool { return a.ID == account.ID }) + 1
		if again {
			m.Status = fmt.Sprintf("Signed in again as %s; it keeps its place as #%d.", account.Label, place)
		} else {
			m.Status = fmt.Sprintf("Signed in as %s. It joins %s as #%d.", account.Label, label, place)
		}
	}
	back := m.backToChoose()
	gen := m.Generation
	return tea.Batch(back, func() tea.Msg { return m.listSignIns(m.readCtx, gen) })
}

// chooseKeyProvider lists the providers an API key or endpoint can be set
// up for.
func (m *LoginModel) chooseKeyProvider() tea.Cmd {
	items := make([]loginItem, 0, len(customProviders))
	for _, p := range customProviders {
		items = append(items, loginItem{ID: p.ID, Label: p.Label, Detail: p.Detail, facts: p.facts(), note: "enter names the setup, then asks for its endpoint and key"})
	}
	m.Step = StepAddKey
	m.ChoosePicker = newLoginPick("API key or endpoint", items, "", m.Width, m.Height)
	return m.ChoosePicker.Init()
}

// firstRunRows are the first run's choices: the sign-in services the daemon
// offers, then everything else.
func (m LoginModel) firstRunRows() []loginItem {
	var rows []loginItem
	for _, service := range m.offeredModelServices() {
		rows = append(rows, loginItem{ID: rowMore + service.Extension, Label: service.Label, Detail: joinDetail(service.Plans, service.Blurb)})
	}
	rows = append(rows, loginItem{ID: rowKeys, Label: "API key or endpoint", Detail: keyBlurb})
	if m.destination == "" && (slices.ContainsFunc(m.SignIns, func(s daemon.SignIn) bool { return s.Kind == "service" }) || slices.ContainsFunc(m.Accounts, func(a daemon.Account) bool { return a.Kind == "service" })) {
		rows = append(rows, loginItem{ID: sectionTools, Label: sectionTools, Detail: "accounts used by extensions"})
	}
	return rows
}

// firstRunKey moves through and picks from the first run's choices.
func (m *LoginModel) firstRunKey(msg tea.KeyPressMsg) tea.Cmd {
	rows := m.firstRunRows()
	m.firstCursor = min(m.firstCursor, len(rows)-1)
	switch msg.String() {
	case "up", "ctrl+p":
		m.firstCursor = max(0, m.firstCursor-1)
	case "down", "ctrl+n":
		m.firstCursor = min(len(rows)-1, m.firstCursor+1)
	case "enter":
		row := rows[m.firstCursor]
		if row.ID == sectionTools {
			m.firstRunTools = true
			m.destination = toolSignIns
			return m.backToChoose()
		}
		return m.chooseAccountsRow(row.ID)
	case "esc", "ctrl+c":
		return func() tea.Msg { return LoginCancelMsg{} }
	}
	return nil
}

// firstRunList keeps the active connection choice visible on short terminals.
func (m LoginModel) firstRunList(width, height int) []string {
	width = max(1, width-1)
	lines := []string{"", "  " + chrome.DefaultStyles.Bold.Render("connect a provider"), ""}
	rows := m.firstRunRows()
	cursor := min(m.firstCursor, len(rows)-1)
	selected := len(lines) + cursor
	nameWidth := 0
	for _, row := range rows {
		nameWidth = max(nameWidth, ansi.StringWidth(row.Label))
	}
	nameWidth = min(nameWidth+2, max(1, width/2))
	for i, row := range rows {
		label := chrome.Cell(row.Label, nameWidth, false)
		detail := chrome.DefaultStyles.Muted.Render(ansi.Truncate(row.Detail, max(1, width-nameWidth-4), "…"))
		if i == cursor {
			line := chrome.SelectBar() + " " + chrome.DefaultStyles.Prompt.Render("› ") + chrome.DefaultStyles.Bold.Render(label) + detail
			lines = append(lines, chrome.SelectedLine(line, width))
			continue
		}
		lines = append(lines, "    "+label+detail)
	}
	return inset(scrollWindow(lines, selected, width, height))
}
