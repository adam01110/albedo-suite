package tui

import (
	"albedo/cli/internal/config"
	"cmp"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

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
		return "callback URL or code"
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
// above it. Errors and progress sit in the footer.
func (m LoginModel) View() string {
	width := cmp.Or(m.Width, 80)
	title := brand("albedo") + " " + DefaultStyles.Muted.Render("/login")
	right := m.Name
	if m.Step == StepChoose || (m.Step == StepRemove || m.Step == StepRotationPrompt) {
		right = homePath(config.HomeDir())
	}
	if right != "" {
		right = DefaultStyles.Faint.Render(right)
	}
	footer := m.footer(width)
	// A removal question keeps the list it asks about on screen, the way every
	// other confirm does.
	if m.listing() || (m.Step == StepRemove || m.Step == StepRotationPrompt) {
		lv := m.pickerFor().listView
		lv.Empty = "nothing to choose"
		return lv.frame(title, right, footer).view(m.Width, m.Height)
	}
	f := listFrame{
		title:  title,
		right:  right,
		filter: m.filterLine(),
		list:   m.bodyList,
		footer: footer,
	}
	return f.view(m.Width, m.Height)
}

// filterLine is the question's input line; a step that is only waiting on the
// daemon takes no input and shows none.
func (m LoginModel) filterLine() string {
	if m.Step == StepSaving || m.signInOver() || (m.Step == StepOAuth && m.Provider == "zed" && m.LoginState != "confirming") {
		return ""
	}
	return promptLead() + DefaultStyles.Muted.Render(m.fieldLabel()+"  ") + m.TextInput.View()
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
		return []string{DefaultStyles.Faint.Render(state)}
	case StepOAuth:
		if m.signInOver() {
			return []string{DefaultStyles.Muted.Render("The sign-in did not finish; the reason is in the footer.")}
		}
		lines := []string{DefaultStyles.Muted.Render(cmp.Or(m.Status, "starting sign-in…"))}
		if m.LoginInstructions != "" {
			lines = append(lines, paneNote(m.LoginInstructions, width)...)
		}
		if m.SignInURL != "" {
			lines = append(lines, "", DefaultStyles.Faint.Render(ansi.Hardwrap(m.SignInURL, width, true)))
		}
		lines = append(lines, "")
		return append(lines, paneNote(m.signInHint(), width)...)
	case StepModels, StepOAuthModels:
		return []string{DefaultStyles.Faint.Render("loading models…")}
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
		return "API key", []string{"the daemon keeps a key in creds.json, not in config.json"}
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
func (m LoginModel) hints() []hint {
	switch {
	case m.Step == StepSaving:
		return nil
	case (m.Step == StepModels || m.Step == StepOAuthModels) && !m.listing():
		return []hint{{"esc", "back"}}
	case m.Step == StepCredential:
		return []hint{{"space", "tick"}, {"enter", m.enterVerb()}, {"↑↓", "move"}, {"esc", "back"}}
	case m.listing():
		hints := []hint{{"↑↓", "move"}}
		if verb := m.enterVerb(); verb != "" {
			hints = append(hints, hint{"enter", verb})
		}
		if item, ok := m.ChoosePicker.Highlighted(); ok && m.Step == StepChoose {
			if name, ok := m.highlightedProfile(); ok {
				if m.editable(name) {
					hints = append(hints, hint{"ctrl+e", "edit"})
				}
				hints = append(hints, hint{"ctrl+r", "rename"})
			}
			account, isAccount := m.accountAt(item.ID)
			external := isAccount && account.Source == "env"
			if isAccount && !external {
				hints = append(hints, hint{"ctrl+r", "rename"})
			}
			if _, removable := m.removalFor(item.ID); removable && !external {
				hints = append(hints, hint{"ctrl+d", "remove"})
			}
		}
		return append(hints, hint{"esc", "back"})
	case m.signInOver():
		return []hint{{"enter", "try again"}, {"esc", "cancel"}}
	case m.Step == StepOAuth && m.LoginState == "confirming":
		return []hint{{"enter", "confirm account"}, {"esc", "cancel without saving"}}
	case m.Step == StepOAuth && m.Provider == "zed":
		return []hint{{"esc", "cancel without saving"}}
	case m.Step == StepOAuth:
		return []hint{{"enter", "submit code"}, {"esc", "cancel"}}
	case m.Step == StepAPIKey && m.Draft.APIKey != "":
		return []hint{{"enter", "keeps the saved key"}, {"esc", "cancel"}}
	case m.Step == StepRename:
		return []hint{{"enter", "rename"}, {"esc", "back"}}
	case m.Step == StepProfileName:
		return []hint{{"enter", "continue"}, {"esc", "back"}}
	}
	return []hint{{"enter", "continue"}, {"esc", "cancel"}}
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

// footer is the keys, with an error or the catalog's note beside them.
func (m LoginModel) footer(width int) string {
	if m.Step == StepRotationPrompt {
		return footerLine(width, []hint{{"↑↓", "choose"}, {"enter", "continue"}, {"esc", "no"}}, DefaultStyles.Warning.Render(m.confirm.prompt), true)
	}
	if m.Step == StepRemove {
		return m.confirm.footer(width, m.Error)
	}
	if m.Error != "" {
		return footerLine(width, m.hints(), DefaultStyles.Error.Render(m.Error), true)
	}
	status := ""
	if m.CatalogNote != "" && (m.Step == StepModels || m.Step == StepOAuthModels) {
		status = DefaultStyles.Faint.Render(m.CatalogNote)
	} else if m.Status != "" && m.Step == StepChoose {
		status = DefaultStyles.Faint.Render(m.Status)
	}
	return footerLine(width, m.hints(), status, m.Status != "" && m.Step == StepChoose)
}
