// Discovery property test (proptest loop): the Zed sign-in confirmation state
// machine under generated interleavings of status messages, typing and enter.
// The oracles come from the screen's contract, not from the code under test:
// a new sign-in state starts with an empty input, waiting takes no answer, and
// only the word "confirm" submits the displayed account.
package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"errors"
	"reflect"
	"strings"
	"testing"
	"testing/quick"

	tea "charm.land/bubbletea/v2"
)

// zedStep is one thing that happens to the sign-in screen: a daemon status
// message, typed text, or enter.
type zedStep struct {
	Kind  uint8
	State uint8
	Text  string
}

var zedStates = []string{"waiting", "confirming", "pending"}

// zedAlphabet keeps generated typing inside the characters that matter to the
// confirmation, so a counterexample stays readable and shrinking is useful.
var zedAlphabet = []rune("confirm xqzO")

// zedTyped maps generated text onto the alphabet, at most 8 keys.
func zedTyped(text string) []rune {
	runes := []rune(text)
	if len(runes) > 8 {
		runes = runes[:8]
	}
	typed := make([]rune, len(runes))
	for i, r := range runes {
		typed[i] = zedAlphabet[int(r)%len(zedAlphabet)]
	}
	return typed
}

// zedCoverage records the interactions a generated run reached, so a passing
// run of the suite still says whether it exercised the interesting states.
type zedCoverage struct {
	queued   bool // text typed while the screen waited for the browser
	submits  int  // accepted confirmations
	refused  int  // answers that were not the confirmation word
	launched int  // runs that reached the confirmation state
}

// zedScreen is a login screen inside an inline Zed browser sign-in.
func zedScreen(t *testing.T) LoginModel {
	t.Helper()
	m := NewLoginModel(&daemon.Connection{}, "", nil)
	t.Cleanup(func() { m.Close() })
	m.SetSize(120, 30)
	m.Provider = "zed"
	m.LoginID = "login-one"
	m.LoginETag = "waiting-etag"
	m.Step = StepOAuth
	m.LoginState = "waiting"
	m.TextInput.Focus()
	return m
}

// zedRun replays one generated history and reports the first contract breach.
func zedRun(t *testing.T, steps []zedStep) (bool, string, zedCoverage) {
	t.Helper()
	var cover zedCoverage
	m := zedScreen(t)
	for i, step := range steps {
		switch step.Kind % 4 {
		case 3:
			// The word a person copies from the hint, sometimes with stray
			// space, so acceptance is reachable and trimming is exercised.
			word := []string{"confirm", " confirm ", "confirm\t", "CONFIRM"}[int(step.State)%4]
			m.TextInput.SetValue(word)
		case 0:
			state := zedStates[int(step.State)%len(zedStates)]
			before := m.LoginState
			var cmd tea.Cmd
			m, cmd = m.Update(signInStatusMsg{Gen: m.Generation, ID: m.LoginID, State: state, Message: "Zed account: github-user (user 42)", ETag: "identity-etag"})
			if m.LoginState != state {
				return false, trace(steps, i, "the state did not follow the status message"), cover
			}
			if before != state && m.TextInput.Value() != "" {
				return false, trace(steps, i, "the input kept text from the state before"), cover
			}
			if state == "confirming" && before == "waiting" {
				cover.launched++
				if m.LoginID == "" {
					return false, trace(steps, i, "the confirmation lost the sign-in it confirms"), cover
				}
			}
			if cmd == nil {
				return false, trace(steps, i, "a running sign-in stopped polling"), cover
			}
		case 1:
			for _, r := range zedTyped(step.Text) {
				m, _ = m.Update(tea.KeyPressMsg{Code: r, Text: string(r)})
			}
			if m.LoginState == "waiting" && m.TextInput.Value() != "" {
				cover.queued = true
			}
		case 2:
			typed, state := m.TextInput.Value(), m.LoginState
			var cmd tea.Cmd
			m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
			if state != "confirming" {
				if cmd != nil {
					return false, trace(steps, i, "a sign-in waiting on the browser accepted an answer"), cover
				}
				continue
			}
			if strings.TrimSpace(typed) == "confirm" {
				cover.submits++
				if cmd == nil {
					return false, trace(steps, i, "the confirmation word did not submit"), cover
				}
				if m.TextInput.Value() != "" {
					return false, trace(steps, i, "the submitted word stayed in the input"), cover
				}
				continue
			}
			cover.refused++
			if cmd != nil {
				return false, trace(steps, i, "an answer other than confirm was submitted"), cover
			}
			if m.Error == "" {
				return false, trace(steps, i, "a refused answer said nothing"), cover
			}
			if m.TextInput.Value() != typed {
				return false, trace(steps, i, "a refused answer dropped what was typed"), cover
			}
		}
	}
	return true, "", cover
}

func trace(steps []zedStep, at int, why string) string {
	var b strings.Builder
	b.WriteString(why)
	b.WriteString("\n  history:")
	for i, step := range steps {
		mark := " "
		if i == at {
			mark = ">"
		}
		switch step.Kind % 4 {
		case 3:
			b.WriteString(" " + mark + "word")
		case 0:
			b.WriteString(" " + mark + "status(" + zedStates[int(step.State)%len(zedStates)] + ")")
		case 1:
			b.WriteString(" " + mark + "type(" + string(zedTyped(step.Text)) + ")")
		case 2:
			b.WriteString(" " + mark + "enter")
		}
	}
	return b.String()
}

// TestPropZedConfirmationStateMachine generates interleavings of the daemon's
// sign-in status, typing, and enter, and checks them against the contract the
// screen promises: nothing typed before the verification is shown can be
// submitted, and only "confirm" saves the displayed account.

// loginSnapshot is what a stale message must leave alone: the screen's step,
// what it shows, and the data it lists.
type loginSnapshot struct {
	Step     LoginStep
	Error    string
	Status   string
	Name     string
	LoginID  string
	Login    string
	Text     string
	Profiles config.Profiles
	Accounts []daemon.Account
	SignIns  []daemon.SignIn
	Draft    config.Settings
	Gen      int
}

func snapshotOf(m LoginModel) loginSnapshot {
	return loginSnapshot{
		Step: m.Step, Error: m.Error, Status: m.Status, Name: m.Name,
		LoginID: m.LoginID, Login: m.LoginState, Text: m.TextInput.Value(),
		Profiles: m.Profiles, Accounts: m.Accounts, SignIns: m.SignIns,
		Draft: m.Draft, Gen: m.Generation,
	}
}

// loginStaleMsg is a message that carries the generation of the read that
// produced it, for a screen at the given step.
func loginStaleMsg(kind, step uint8, gen int) tea.Msg {
	profiles := config.Profiles{Active: "stale", ETag: `"stale"`, Providers: map[string]config.Settings{"stale": {Extension: "openai"}}}
	listing := daemon.SignIns{
		Logins:   []daemon.SignIn{{Provider: "claude", Label: "Claude", Flows: []string{"browser"}}},
		Accounts: []daemon.Account{{Provider: "claude", ID: "stale-account", Label: "stale"}},
	}
	_ = step
	switch kind % 6 {
	case 0:
		return signInsLoadedMsg{Gen: gen, Loaded: true, Listed: listing, Profiles: &profiles}
	case 1:
		return signInStartedMsg{Gen: gen, ID: "stale-login", URL: "https://example/authorize", ETag: "stale-etag"}
	case 2:
		return signInStatusMsg{Gen: gen, ID: "stale-login", State: "confirming", Message: "Zed account: stale", ETag: "stale-etag"}
	case 3:
		return keyAccountSavedMsg{Gen: gen, Account: daemon.Account{Provider: "openai", ID: "stale-key", Label: "stale"}}
	case 4:
		return loginModelsLoadedMsg{Gen: gen, Models: []string{"stale-model"}}
	case 5:
		return providerSavedMsg{Gen: gen, Name: "stale", Settings: config.Settings{Extension: "openai"}, Err: errors.New("stale failure")}
	}
	return nil
}

// loginScreenAt is the login screen at one of the steps a list read can
// arrive in.
func loginScreenAt(t *testing.T, step uint8) LoginModel {
	t.Helper()
	m := loginModel(120, 30)
	switch step % 5 {
	case 0:
		showSetups(&m)
	case 1:
		m.Editing = true
		m.Name, m.Draft = "work", m.Profiles.Providers["work"]
		m.Step = StepSaving
		m.TextInput.Focus()
	case 2:
		m.Provider, m.LoginID, m.Step = "zed", "login-one", StepOAuth
		m.LoginState = "confirming"
		m.TextInput.Focus()
		m.TextInput.SetValue("confirm")
	case 3:
		m.Accounts = append(m.Accounts, daemon.Account{Provider: "claude", ID: "acc-2", Label: "ana@example.com"})
		m.editCredential("claude-team")
	case 4:
		m.Name = "work"
		m.askRename("work")
		m.TextInput.SetValue("renamed")
	}
	return m
}

// A message from a read that a newer read or a change superseded must not
// touch the screen: everything it carries describes a state that is already
// gone, whether or not it is still the right shape for the step it lands in.
func TestPropLoginStaleMessageLeavesState(t *testing.T) {
	f := func(kind uint8, step uint8) bool {
		m := loginScreenAt(t, step)
		before := snapshotOf(m)
		got, _ := m.Update(loginStaleMsg(kind, step, m.Generation-1))
		after := snapshotOf(got)
		if !reflect.DeepEqual(before, after) {
			t.Logf("stale message kind %d at step %d changed the screen:\n before %+v\n after  %+v", kind%6, step%5, before, after)
			return false
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 60}); err != nil {
		t.Fatal(err)
	}
}

func TestPropZedConfirmationStateMachine(t *testing.T) {
	const cases = 400
	var total zedCoverage
	f := func(steps []zedStep) bool {
		ok, why, cover := zedRun(t, steps)
		if !ok {
			t.Log(why)
			return false
		}
		total.queued = total.queued || cover.queued
		total.submits += cover.submits
		total.refused += cover.refused
		total.launched += cover.launched
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: cases}); err != nil {
		t.Fatal(err)
	}
	t.Logf("cases %d: confirmation states reached %d, accepted confirmations %d, refused answers %d, runs typing while waiting %v",
		cases, total.launched, total.submits, total.refused, total.queued)
	if total.launched == 0 || total.submits == 0 || total.refused == 0 || !total.queued {
		t.Fatalf("the generator did not reach the confirmation states: %+v", total)
	}
}
