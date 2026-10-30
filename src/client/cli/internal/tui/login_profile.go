package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"cmp"
	"context"
	"fmt"
	"slices"
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
)

// The rows of the profile and credential choosers that are not a profile or
// an account.
const (
	newProfileRow   = "new"
	anotherAccount  = "signin"
	accountRowStart = "bind:"
)

// signInDraft is a new profile for a sign-in provider, before it has an
// account or a model.
func signInDraft(provider string) config.Settings {
	if provider == "zed" {
		return config.Settings{Extension: provider, Protocol: "chat_completions", BaseURL: "https://cloud.zed.dev"}
	}
	return config.Settings{Extension: provider, Protocol: providerProtocol(provider)}
}

// profilesOf lists, by name, the profiles an extension runs.
func (m LoginModel) profilesOf(extension string) []string {
	var names []string
	for name, profile := range m.Profiles.Providers {
		if cmp.Or(profile.Extension, "openai") == extension {
			names = append(names, name)
		}
	}
	slices.Sort(names)
	return names
}

// freeName is the first profile name nothing has taken: the provider's own,
// then provider-2, provider-3, and so on.
func (m LoginModel) freeName(provider string) string {
	name := provider
	for n := 2; ; n++ {
		if _, taken := m.Profiles.Providers[name]; !taken {
			return name
		}
		name = provider + "-" + strconv.Itoa(n)
	}
}

// askProfileName starts a new profile for a sign-in provider by asking its
// name, offering a free one. SelectedAccount, when set, is the account it
// signs in with; otherwise the next step asks.
func (m *LoginModel) askProfileName(provider string) tea.Cmd {
	m.Provider = provider
	m.Name = ""
	m.Draft = signInDraft(provider)
	m.Editing = false
	m.Error = ""
	m.Step = StepProfileName
	m.TextInput.Placeholder = m.freeName(provider)
	return m.promptInput("", false)
}

// acceptProfileName takes the new profile's name. Blank takes the offered
// one; a profile of the same provider by that name is updated, and one of
// another provider is refused rather than turned into this one.
func (m LoginModel) acceptProfileName() (LoginModel, tea.Cmd) {
	m.TextInput.SetCursor(0)
	name, err := config.ValidateProviderName(cmp.Or(strings.TrimSpace(m.TextInput.Value()), m.TextInput.Placeholder))
	if err != nil {
		return m.fail(err.Error())
	}
	if saved, known := m.Profiles.Providers[name]; known {
		if extension := cmp.Or(saved.Extension, "openai"); extension != m.Provider {
			return m.fail(fmt.Sprintf("%s is already a profile for %s; choose another name", name, extension))
		}
		m.Draft = saved
	}
	m.Name = name
	m.Error = ""
	if m.SelectedAccount != nil {
		m.Draft.AccountID = &m.SelectedAccount.ID
		m.Draft.AccountIDs = nil
		if m.SelectedAccount.Kind == "key" {
			m.Draft.BaseURL = deref(m.SelectedAccount.Endpoint)
		}
		return m, m.credentialChosen()
	}
	return m, m.chooseCredential()
}

// keyAccounts reports extensions whose API keys are stored as accounts.
func (m LoginModel) keyAccounts() bool {
	return m.Draft.Extension == "openai" || m.Draft.Extension == "opencode-go"
}

func (m LoginModel) credentialAccounts() []daemon.Account {
	return slices.DeleteFunc(m.accountsFor(m.Provider), func(a daemon.Account) bool {
		if a.Kind == "service" {
			return true
		}
		if a.Kind == "key" {
			return a.Endpoint == nil || *a.Endpoint != m.Draft.BaseURL
		}
		return m.Provider == "openai"
	})
}

// chooseCredential lists only the accounts this profile can use; with none to
// choose from it goes straight to adding one.
func (m *LoginModel) chooseCredential() tea.Cmd {
	if len(m.credentialAccounts()) == 0 {
		return m.chooseCredentialRow(anotherAccount)
	}
	if m.CredentialTicks == nil {
		m.CredentialTicks = map[string]bool{}
		for _, id := range m.Draft.AccountIDs {
			m.CredentialTicks[accountRowStart+id] = true
		}
	}
	var items []loginItem
	ids := m.tickedCredentials()
	for _, account := range m.credentialAccounts() {
		item := loginItem{ID: accountRowStart + account.ID, Label: account.Label,
			Detail: accountDetail(account), lead: accountLead(account), tag: accountTag(account), facts: m.accountFacts(account)}
		if m.CredentialTicks[item.ID] {
			item.lead = DefaultStyles.Success.Render("✓")
		}
		switch len(ids) {
		case 0:
			item.note = "enter pins " + account.Label + "; space ticks accounts for a rotation"
		case 1:
			item.note = "enter pins " + m.accountLabel(ids[0]) + "; space changes the selection"
		default:
			item.note = fmt.Sprintf("enter saves a rotation of %d; only ticked accounts join", len(ids))
		}
		items = append(items, item)
	}
	label, detail := "another account", "sign in now"
	if m.keyAccounts() {
		label, detail = "another key", "enter an API key for this endpoint"
	}
	items = append(items, loginItem{ID: anotherAccount, Label: label, Detail: detail,
		lead: DefaultStyles.Muted.Render("+"), note: "enter adds a credential; a rotation asks before adding it"})
	initial := ""
	if m.Draft.AccountID != nil {
		initial = accountRowStart + *m.Draft.AccountID
	}
	m.Step = StepCredential
	m.ChoosePicker = newLoginPick("credential for "+m.Name, items, initial, m.Width, m.Height)
	return m.ChoosePicker.Init()
}

func (m LoginModel) tickedCredentials() []string {
	var ids []string
	for _, a := range m.credentialAccounts() {
		if m.CredentialTicks[accountRowStart+a.ID] {
			ids = append(ids, a.ID)
		}
	}
	return ids
}

func (m *LoginModel) toggleCredentialTick() tea.Cmd {
	item, ok := m.ChoosePicker.Highlighted()
	if !ok || !strings.HasPrefix(item.ID, accountRowStart) {
		return nil
	}
	m.CredentialTicks[item.ID] = !m.CredentialTicks[item.ID]
	old := m.ChoosePicker
	m.chooseCredential()
	m.ChoosePicker.input = old.input
	m.ChoosePicker.refilter(item.ID)
	focusLoginCredential(m, item.ID)
	return nil
}

func focusLoginCredential(m *LoginModel, id string) {
	if i := slices.IndexFunc(m.ChoosePicker.shown, func(s listShown) bool { return m.ChoosePicker.rows[s.row].key == id }); i >= 0 {
		m.ChoosePicker.Cursor = i
	}
}

func (m *LoginModel) saveCredentialSelection() tea.Cmd {
	if item, ok := m.ChoosePicker.Highlighted(); ok && item.ID == anotherAccount {
		return m.chooseCredentialRow(item.ID)
	}
	ids := m.tickedCredentials()
	if len(ids) >= 2 {
		m.Draft.AccountID, m.Draft.AccountIDs = nil, ids
		return m.credentialChosen()
	}
	if len(ids) == 1 {
		return m.chooseCredentialRow(accountRowStart + ids[0])
	}
	if item, ok := m.ChoosePicker.Highlighted(); ok {
		return m.chooseCredentialRow(item.ID)
	}
	return nil
}

func (m *LoginModel) chooseCredentialRow(id string) tea.Cmd {
	if id == anotherAccount {
		if m.keyAccounts() {
			return m.askAPIKey()
		}
		login, _ := m.signInFor(m.Provider)
		return m.startSignIn(login)
	}
	if account, ok := strings.CutPrefix(id, accountRowStart); ok {
		m.Draft.AccountID, m.Draft.AccountIDs = &account, nil
		return m.credentialChosen()
	}
	return nil
}

// addedCredential asks before changing an existing rotation.
func (m *LoginModel) addedCredential(account daemon.Account) tea.Cmd {
	if len(m.Draft.AccountIDs) > 0 {
		m.SelectedAccount = &account
		m.Step = StepRotationPrompt
		m.confirm.ask("rotate", account.ID, "continue", "add "+account.Label+" to "+m.Name+"'s rotation?")
		m.ChoosePicker = newLoginPick("add to rotation?", []loginItem{
			{ID: "no", Label: "no", Detail: "keep the rotation unchanged"},
			{ID: "yes", Label: "yes", Detail: "add " + account.Label},
		}, "no", m.Width, m.Height)
		return m.ChoosePicker.Init()
	}
	m.Draft.AccountID, m.Draft.AccountIDs = &account.ID, nil
	return m.credentialChosen()
}

func (m *LoginModel) rotationAnswer(add bool) tea.Cmd {
	if add && m.SelectedAccount != nil && !slices.Contains(m.Draft.AccountIDs, m.SelectedAccount.ID) {
		m.Draft.AccountIDs = append(slices.Clone(m.Draft.AccountIDs), m.SelectedAccount.ID)
	}
	m.SelectedAccount = nil
	m.confirm.dismiss()
	return m.credentialChosen()
}

// credentialChosen moves on once the profile's account is settled: an edit
// saves it, a new profile asks for its model.
func (m *LoginModel) credentialChosen() tea.Cmd {
	if m.Editing {
		m.Step = StepSaving
		return m.saveProviderCmd(m.Name, m.Draft)
	}
	if m.keyAccounts() {
		if m.isFixedProtocol() {
			return m.advanceToModels()
		}
		m.Step = StepProtocol
		m.buildProtocolPicker()
		return m.ProtocolPicker.Init()
	}
	return m.askSignInModel()
}

// askSignInModel lists the models the sign-in provider offers.
func (m *LoginModel) askSignInModel() tea.Cmd {
	m.Catalog = nil
	m.CatalogNote = ""
	m.Step = StepOAuthModels
	m.Generation = nextPageGeneration()
	endpoint := ""
	if m.Draft.Extension == "zed" && m.Draft.AccountID != nil {
		endpoint = "albedo:zed:account:" + *m.Draft.AccountID
	}
	return m.fetchCatalogCmd(m.Draft.Extension, endpoint, m.Generation)
}

// highlightedProfile is the saved profile under the list's cursor.
func (m LoginModel) highlightedProfile() (string, bool) {
	item, ok := m.ChoosePicker.Highlighted()
	if !ok {
		return "", false
	}
	name, ok := strings.CutPrefix(item.ID, "use:")
	if _, saved := m.Profiles.Providers[name]; !ok || !saved {
		return "", false
	}
	return name, true
}

// editable reports a profile whose credential /login can change: a sign-in
// profile's account, or the endpoint and key of one set up by hand.
func (m LoginModel) editable(name string) bool {
	settings := m.Profiles.Providers[name]
	extension := cmp.Or(settings.Extension, "openai")
	if _, signIn := m.signInFor(extension); signIn && !hasKey(settings) {
		return true
	}
	return slices.ContainsFunc(customProviders, func(p customProvider) bool { return p.Extension == extension })
}

// editCredential changes how a saved profile signs in, keeping its model and
// leaving the default alone: a sign-in profile picks its account again, one
// with a key answers its provider's questions again.
func (m *LoginModel) editCredential(name string) tea.Cmd {
	settings := m.Profiles.Providers[name]
	settings.Extension = cmp.Or(settings.Extension, "openai")
	m.Name, m.Draft, m.Provider = name, settings, settings.Extension
	m.Editing = true
	m.SelectedAccount = nil
	m.Error = ""
	m.CredentialTicks = nil
	if _, signIn := m.signInFor(settings.Extension); m.keyAccounts() || (signIn && !hasKey(settings)) {
		return m.chooseCredential()
	}
	return m.askEndpoint()
}

func (m *LoginModel) askAccountRename(account daemon.Account) tea.Cmd {
	m.RenameAccountID = account.ID
	m.Name = account.Label
	m.Step = StepRename
	m.Error = ""
	m.TextInput.Placeholder = ""
	return m.promptInput(account.Label, false)
}

// askRename asks for a profile's new name, starting from the one it has.
func (m *LoginModel) askRename(name string) tea.Cmd {
	m.Name = name
	m.RenameAccountID = ""
	m.Error = ""
	m.Step = StepRename
	m.TextInput.Placeholder = ""
	return m.promptInput(name, false)
}

// acceptRename renames the profile, or goes back to the list when the name
// did not change.
func (m LoginModel) acceptRename() (LoginModel, tea.Cmd) {
	m.TextInput.SetCursor(0)
	to := strings.TrimSpace(m.TextInput.Value())
	var err error
	if m.RenameAccountID == "" {
		to, err = config.ValidateProviderName(to)
	} else if to == "" || strings.ContainsFunc(to, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
		err = fmt.Errorf("enter an account label without control characters")
	}
	if err != nil {
		return m.fail(err.Error())
	}
	if to == m.Name {
		m.Error = ""
		return m, m.backToChoose()
	}
	if m.RenameAccountID != "" {
		id, label := m.RenameAccountID, to
		m.Step = StepSaving
		m.RenameAccountID = ""
		return m, m.reloadCmd(func(ctx context.Context) error { _, err := daemon.RenameAccount(ctx, m.Conn, id, label); return err })
	}
	if _, taken := m.Profiles.Providers[to]; taken {
		return m.fail(to + " is already a profile; choose another name")
	}
	m.Error = ""
	m.Step = StepSaving
	from, etag := m.Name, m.Profiles.ETag
	return m, m.reloadCmd(func(ctx context.Context) error {
		return daemon.RenameProvider(ctx, m.Conn, from, to, etag)
	})
}
