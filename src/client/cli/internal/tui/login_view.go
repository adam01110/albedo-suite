package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/terminalui"
	"cmp"
	"slices"
	"strings"

	"albedo/cli/internal/tui/chrome"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// linkRows is a URL broken into rows of at most width cells, one list entry
// per row: the frame clips an entry to a single row, so a newline inside one
// would cut the link off after its first line. A terminal finds a URL only
// within one row, so each row also carries the whole URL as an OSC 8
// hyperlink (the same id on every row joins them), which stays clickable
// across the breaks.
func linkRows(url string, width int) []string {
	rows := strings.Split(ansi.Hardwrap(url, max(1, width), true), "\n")
	id := "id=albedo-link"
	out := make([]string, len(rows))
	for i, row := range rows {
		out[i] = ansi.SetHyperlink(url, id) + chrome.DefaultStyles.Faint.Render(row) + ansi.ResetHyperlink()
	}
	return out
}

func (m LoginModel) openBrowserCmd(urlStr string) tea.Cmd {
	return func() tea.Msg {
		if m.openBrowser != nil {
			m.openBrowser(urlStr)
		}
		return nil
	}
}

// inputWidth leaves the frame's margin and the field's label their room.
func (m LoginModel) inputWidth() int {
	return max(8, m.Width-10-ansi.StringWidth(m.fieldLabel()))
}

func (m LoginModel) acceptsSignInInput() bool {
	login, ok := m.signInFor(m.Provider)
	return !ok || m.LoginState == "confirming" || slices.Contains(login.Flows, "manual")
}

// Device grants supply the code in their instructions and complete in the browser.
func (m LoginModel) deviceInstructions(width int) []string {
	lines := paneNote(m.LoginInstructions, width)
	if m.SignInURL != "" && !strings.Contains(m.LoginInstructions, m.SignInURL) {
		lines = append(lines, linkRows(m.SignInURL, width)...)
	}
	if m.SignInURL == "" && m.LoginInstructions == "" {
		return paneNote(cmp.Or(m.Status, "waiting for the sign-in page…"), width)
	}
	return lines
}

// signInOver reports a sign-in that failed, was cancelled or expired, so the
// step has nothing left to wait for.
func (m LoginModel) signInOver() bool {
	return m.Step == StepOAuth && m.LoginID == "" && m.Error != ""
}

// fieldLabel is what the text input is asked for.
func (m LoginModel) fieldLabel() string {
	if m.Step == StepOAuth {
		if m.LoginState == "confirming" {
			return "account confirmation (type confirm)"
		}
		return "code or callback URL"
	}
	label, _ := m.question()
	return label
}

// promptInput re-arms the text input for the next question and reports the
// blink command that shows its cursor. The placeholder is left as the
// previous step left it.
func (m *LoginModel) promptInput(value string, secret bool) tea.Cmd {
	m.TextInput.SetWidth(m.inputWidth())
	return ask(&m.TextInput, value, secret)
}

// fail shows an error on the current step and keeps waiting for input.
func (m LoginModel) fail(err string) (LoginModel, tea.Cmd) {
	m.Error = err
	return m, nil
}

func (m *LoginModel) SetSize(width, height int) {
	m.Width, m.Height = width, height
	m.TextInput.SetWidth(m.inputWidth())
	m.TextInput.SetValue(m.TextInput.Value())
	for _, p := range []*loginPick{&m.ChoosePicker, &m.ProtocolPicker, &m.ModelPicker} {
		p.setSize(width, height)
	}
}

// View is the login step in the list frame: a list for a choice, the
// question's input in the search line for a text step, and the step's text
// above it. Errors and progress sit in the footer. A terms warning sits over
// all of it.
func (m LoginModel) overlay(screen string) string {
	if m.terms != nil {
		width, height := cmp.Or(m.Width, 80), cmp.Or(m.Height, 24)
		return overlay(screen, m.terms.view(width, height), width, height)
	}
	return screen
}

func (m LoginModel) Page() terminalui.Page {
	width := cmp.Or(m.Width, 80)
	path := "/accounts"
	if m.destination != "" {
		path = "/settings › " + string(m.destination)
	}
	if m.toolOwner != "" {
		label, _ := m.serviceName(m.toolOwner)
		path = "/settings › " + label + " › account"
	}
	if m.firstRunTools {
		path = "/accounts › tool sign-ins"
	}
	title := chrome.Brand("albedo") + " " + chrome.DefaultStyles.Muted.Render(path)
	if m.advanced {
		title += chrome.DefaultStyles.Faint.Render(" › ") + chrome.DefaultStyles.Muted.Render("advanced")
	}
	right := m.Name
	onList := m.Step == StepChoose || m.Step == StepAdvanced || m.Step == StepAddKey || m.Step == StepRemove || m.Step == StepRotationPrompt || m.signingInline() || (m.Step == StepSaving && m.listBusy != "")
	if onList {
		right = chrome.HomePath(config.HomeDir())
	}
	if m.Step == StepChoose && m.accountsEmpty() {
		right = "no accounts yet"
	}
	if right != "" {
		right = chrome.DefaultStyles.Faint.Render(right)
	}
	footer := m.footer(width)
	if m.Step == StepChoose && m.accountsEmpty() {
		return terminalui.Page{Title: title, Meta: right, List: m.firstRunList, Footer: footer}
	}
	if m.signingInline() {
		f := m.accountsFrame(title, right, footer)
		if !m.signInOver() && !m.acceptsSignInInput() {
			f.Filter = ""
			// Short terminals have no detail pane. Use the whole body for the device code.
			if m.Height < 16 {
				f.List = func(w, _ int) []string { return inset(m.deviceInstructions(max(1, w-1))) }
				f.Detail = nil
			}
		} else if !m.signInOver() {
			f.Filter = chrome.PromptLead() + chrome.DefaultStyles.Muted.Render(m.fieldLabel()+"  ") + m.TextInput.View()
		} else {
			f.Filter = chrome.PromptLead() + chrome.DefaultStyles.Faint.Render("the sign-in did not finish")
		}
		return f
	}
	if m.Step == StepSaving && m.listBusy != "" {
		return m.accountsFrame(title, right, footer)
	}
	// A removal question keeps the list it asks about on screen, the way every
	// other confirm does.
	if m.listing() || (m.Step == StepRemove || m.Step == StepRotationPrompt) {
		if !m.advanced && (m.Step == StepChoose || m.Step == StepRemove) {
			return m.accountsFrame(title, right, footer)
		}
		lv := m.pickerFor().listView
		lv.Empty = cmp.Or(lv.Empty, "nothing to choose")
		return lv.frame(title, right, footer)
	}
	f := terminalui.Page{
		Title:  title,
		Meta:   right,
		Filter: m.filterLine(),
		List:   m.bodyList,
		Footer: footer,
	}
	return f
}

// accountsFrame is the accounts list in the frame, with a pane wide enough
// for an account's facts on one row each.
func (m LoginModel) accountsFrame(title, right, footer string) terminalui.Page {
	f := m.ChoosePicker.frame(title, right, footer)
	f.DetailWidth = func(width int) int { return min(max(width*38/100, 36), 48) }
	return f
}

// filterLine is the question's input line; a step that is only waiting on the
// daemon takes no input and shows none.
func (m LoginModel) filterLine() string {
	if m.Step == StepSaving || m.signInOver() || m.Step == StepOAuth && !m.acceptsSignInInput() {
		return ""
	}
	return chrome.PromptLead() + chrome.DefaultStyles.Muted.Render(m.fieldLabel()+"  ") + m.TextInput.View()
}

// bodyList is the body in the list's place, on the frame's gutter.
func (m LoginModel) bodyList(width, _ int) []string {
	return inset(m.body(max(1, width-1)))
}

// body is the text above a question: what it asks, what it takes, and what
// a sign-in or save is doing.
func (m LoginModel) body(width int) []string {
	switch m.Step {
	case StepSaving:
		state := "saving provider…"
		switch {
		case m.Removing.Kind != "":
			state = "removing " + m.Removing.Kind + "…"
		case m.Editing:
			state = "saving " + m.Name + "…"
		}
		return []string{chrome.DefaultStyles.Faint.Render(state)}
	case StepOAuth:
		if m.signInOver() {
			return []string{chrome.DefaultStyles.Muted.Render("The sign-in did not finish.")}
		}
		if !m.acceptsSignInInput() {
			return m.deviceInstructions(width)
		}
		lines := []string{chrome.DefaultStyles.Muted.Render(cmp.Or(m.Status, "starting sign-in…"))}
		if m.LoginInstructions != "" {
			lines = append(lines, paneNote(m.LoginInstructions, width)...)
		}
		if m.SignInURL != "" {
			lines = append(lines, "")
			lines = append(lines, linkRows(m.SignInURL, width)...)
		}
		lines = append(lines, "")
		return append(lines, paneNote(m.signInHint(), width)...)
	case StepModels, StepOAuthModels:
		return []string{chrome.DefaultStyles.Faint.Render("loading models…")}
	}
	_, notes := m.question()
	var lines []string
	for _, note := range notes {
		lines = append(lines, paneNote(note, width)...)
	}
	return lines
}

// question is the label a text step asks for, and what it says beside it.
func (m LoginModel) question() (string, []string) {
	switch m.Step {
	case StepProfileName:
		notes := []string{"a name for this " + m.Provider + " profile; blank takes " + m.TextInput.Placeholder}
		if m.SelectedAccount != nil {
			notes = append(notes, "it signs in as "+m.SelectedAccount.Label)
		}
		return "profile name", append(notes, "naming a "+m.Provider+" profile you have updates it")
	case StepRename:
		if m.RenameAccountID != "" {
			return "new label", []string{"changes only the label of " + m.Name}
		}
		return "new name", []string{"renames " + m.Name + "; the default and the sessions using it follow"}
	case StepName:
		notes := []string{"a name for this provider profile"}
		if names := m.signInNames(); len(names) > 0 {
			notes = append(notes, "or name "+orList(names)+" to sign in instead of using an api key")
		}
		return "provider name", notes
	case StepBaseURL:
		if m.optionalKey() {
			return "API base URL", []string{"blank uses your daemon's environment"}
		}
		return "API base URL", nil
	case StepAPIKey:
		if m.Draft.Extension == "anthropic-api" {
			return "bearer token", nil
		}
		return "API key", nil
	case StepProject:
		return "Google Cloud project ID", nil
	case StepLocation:
		return "Vertex location", nil
	case StepModel:
		return "model ID", nil
	case StepOAuthFields:
		if m.LoginFieldIndex < len(m.LoginFields) {
			field := m.LoginFields[m.LoginFieldIndex]
			return field.Label, []string{field.Description}
		}
	}
	return "", nil
}

// hints are the keys for the step, most important first.
func (m LoginModel) hints() []chrome.Hint {
	switch {
	case m.Step == StepSaving:
		return nil
	case (m.Step == StepModels || m.Step == StepOAuthModels) && !m.listing():
		return []chrome.Hint{{Key: "esc", Does: "back"}}
	case m.Step == StepCredential:
		return []chrome.Hint{{Key: "space", Does: "tick"}, {Key: "enter", Does: m.enterVerb()}, {Key: "↑↓", Does: "move"}, {Key: "esc", Does: "back"}}
	case m.listing():
		hints := []chrome.Hint{{Key: "↑↓", Does: "move"}}
		if verb := m.enterVerb(); verb != "" {
			hints = append(hints, chrome.Hint{Key: "enter", Does: verb})
		}
		if item, ok := m.ChoosePicker.Highlighted(); ok && m.Step == StepAdvanced {
			if name, ok := m.highlightedProfile(); ok {
				if m.editable(name) {
					hints = append(hints, chrome.Hint{Key: "ctrl+e", Does: "edit"})
				}
				verb := "disable"
				if !m.Profiles.Providers[name].IsEnabled() {
					verb = "enable"
				}
				hints = append(hints, chrome.Hint{Key: "ctrl+t", Does: verb})
				hints = append(hints, chrome.Hint{Key: "ctrl+r", Does: "rename"})
			}
			account, isAccount := m.accountAt(item.ID)
			external := isAccount && account.Source == "env"
			if isAccount && !external {
				hints = append(hints, chrome.Hint{Key: "ctrl+r", Does: "rename"})
			}
			if _, removable := m.removalFor(item.ID); removable && !external {
				verb := "remove"
				if isAccount {
					verb = "sign out"
				}
				hints = append(hints, chrome.Hint{Key: "ctrl+x", Does: verb})
			}
		}
		return append(hints, chrome.Hint{Key: "esc", Does: "back"})
	case m.signInOver():
		return []chrome.Hint{{Key: "enter", Does: "try again"}, {Key: "esc", Does: "cancel"}}
	case m.Step == StepOAuth && m.LoginState == "confirming":
		return []chrome.Hint{{Key: "enter", Does: "confirm account"}, {Key: "esc", Does: "cancel without saving"}}
	case m.Step == StepOAuth:
		if !m.acceptsSignInInput() {
			return []chrome.Hint{{Key: "esc", Does: "cancel"}}
		}
		return []chrome.Hint{{Key: "enter", Does: "submit code"}, {Key: "esc", Does: "cancel"}}
	case m.Step == StepAPIKey && m.Draft.APIKey != "":
		return []chrome.Hint{{Key: "enter", Does: "keeps the saved key"}, {Key: "esc", Does: "cancel"}}
	case m.Step == StepRename:
		return []chrome.Hint{{Key: "enter", Does: "rename"}, {Key: "esc", Does: "back"}}
	case m.Step == StepProfileName:
		return []chrome.Hint{{Key: "enter", Does: "continue"}, {Key: "esc", Does: "back"}}
	}
	return []chrome.Hint{{Key: "enter", Does: "continue"}, {Key: "esc", Does: "cancel"}}
}

// enterVerb says what enter does on the list the step shows, naming the
// highlighted row's own action where the rows differ.
func (m LoginModel) enterVerb() string {
	item, highlighted := m.pickerFor().Highlighted()
	if highlighted {
		if verb, known := m.rowVerb(item); known {
			return verb
		}
	}
	switch m.Step {
	case StepAccountProfile:
		if highlighted && item.ID == newProfileRow {
			return "create"
		}
		return "use"
	case StepCredential:
		if highlighted && item.ID == anotherAccount {
			if m.keyAccounts() {
				return "add key"
			}
			return "sign in"
		}
		if n := len(m.tickedCredentials()); n >= 2 {
			return "save rotation"
		} else if n == 1 {
			return "pin"
		}
		if highlighted && item.ID == anotherAccount {
			if m.keyAccounts() {
				return "add key"
			}
			return "sign in"
		}
		return "pin"
	case StepOAuthFlow:
		return "sign in"
	case StepModels, StepOAuthModels:
		return "use model"
	}
	return "choose"
}

// rowVerb is what enter does with one row of the accounts picker, and whether
// the row's kind decides it. A service account is ready as it stands, so its
// row has no action to name.
func (m LoginModel) rowVerb(item loginItem) (string, bool) {
	switch {
	case strings.HasPrefix(item.ID, "use:"):
		if !m.Profiles.Providers[strings.TrimPrefix(item.ID, "use:")].IsEnabled() {
			// The row's kind decides: a disabled profile has no enter action.
			return "", true
		}
		return "use", true
	case strings.HasPrefix(item.ID, "signin:"):
		if login, ok := m.signInFor(strings.TrimPrefix(item.ID, "signin:")); ok && login.Kind == "service" {
			return "sign in", true
		}
		return "set up", true
	case strings.HasPrefix(item.ID, "account:"):
		if account, ok := m.accountAt(item.ID); ok && account.Kind == "service" {
			return "", true
		}
		return "use", true
	}
	if _, ok := customProviderByID(item.ID); ok {
		return "set up", true
	}
	return "", false
}

// signInNames lists the providers a name at the first step can sign in with.
func (m LoginModel) signInNames() []string {
	names := make([]string, 0, len(m.SignIns))
	for _, login := range m.SignIns {
		names = append(names, login.Provider)
	}
	return names
}

// orList joins names the way a sentence does: "a", "a or b", "a, b or c".
func orList(names []string) string {
	if len(names) < 2 {
		return strings.Join(names, "")
	}
	return strings.Join(names[:len(names)-1], ", ") + " or " + names[len(names)-1]
}

// signInHint says how the sign-in in flight finishes.
func (m LoginModel) signInHint() string {
	if m.Provider == "zed" {
		if m.LoginState == "confirming" {
			return "Save only if the verified account above is yours. Esc cancels without saving."
		}
		return "Complete sign-in in the browser; account confirmation follows here."
	}
	if m.LoginFlow == "manual" {
		return "paste the callback URL or code from the provider's page"
	}
	return "browser sign-in finishes on its own; paste the callback URL or code if it stalls"
}

// zedSignInFooter is an inline Zed sign-in's keys: the browser finishes it,
// and the identity the daemon verified is shown beside the confirmation keys.
func (m LoginModel) zedSignInFooter(width int) string {
	if m.Error != "" {
		return chrome.FooterLine(width, m.hints(), chrome.DefaultStyles.Error.Render(m.Error), true)
	}
	if m.LoginState == "confirming" {
		return chrome.FooterLine(width, m.hints(), chrome.DefaultStyles.Warning.Render(m.Status), m.Status != "")
	}
	return chrome.FooterLine(width, m.hints(), chrome.DefaultStyles.Faint.Render(m.signInHint()), true)
}

// footer is the keys, with an error or the catalog's note beside them.
func (m LoginModel) footer(width int) string {
	if m.signingInline() && m.Provider == "zed" && !m.signInOver() {
		return m.zedSignInFooter(width)
	}
	if !m.advanced && (m.Step == StepChoose || m.signingInline() || (m.Step == StepSaving && m.listBusy != "") || (m.Step == StepRemove && m.Removing.Kind == "account")) {
		return m.accountsFooter(width)
	}
	if m.Step == StepRemove && m.Removing.Kind == "account" {
		return m.signOutFooter(width)
	}
	if m.Step == StepRotationPrompt {
		return chrome.FooterLine(width, []chrome.Hint{{Key: "↑↓", Does: "choose"}, {Key: "enter", Does: "continue"}, {Key: "esc", Does: "no"}}, chrome.DefaultStyles.Warning.Render(m.confirm.Prompt), true)
	}
	if m.Step == StepRemove {
		return m.confirm.Footer(width, m.Error)
	}
	if m.Error != "" {
		return chrome.FooterLine(width, m.hints(), chrome.DefaultStyles.Error.Render(m.Error), true)
	}
	status := ""
	if m.CatalogNote != "" && (m.Step == StepModels || m.Step == StepOAuthModels) {
		status = chrome.DefaultStyles.Faint.Render(m.CatalogNote)
	} else if m.Status != "" && (m.Step == StepChoose || m.Step == StepAdvanced) {
		status = chrome.DefaultStyles.Faint.Render(m.Status)
	}
	return chrome.FooterLine(width, m.hints(), status, m.Status != "" && (m.Step == StepChoose || m.Step == StepAdvanced))
}
