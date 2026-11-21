package tui

// Property tests for the login screen's provider availability toggle and the
// session viewer's cost column. Discovery only: the generators, the fake
// daemon and the models live here, and confirmed bugs get their own
// deterministic regression tests.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"sync"
	"testing"
	"testing/quick"
	"time"

	tea "charm.land/bubbletea/v2"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

// toggleRequest is one PATCH /settings/providers the client sent.
type toggleRequest struct {
	name    string
	enabled bool
	ifMatch string
}

// fakeProvidersDaemon is a fake daemon that holds the providers group and applies
// the merge patches the login screen sends, so a generated history changes the
// state the next read returns.
type fakeProvidersDaemon struct {
	mu       sync.Mutex
	etag     int
	active   string
	profiles map[string]config.Settings
	requests []toggleRequest
}

func newFakeProvidersDaemon() *fakeProvidersDaemon {
	return &fakeProvidersDaemon{etag: 1, profiles: map[string]config.Settings{}}
}

func (d *fakeProvidersDaemon) reset(profiles map[string]config.Settings, active string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.etag, d.active, d.profiles, d.requests = 1, active, profiles, nil
}

func (d *fakeProvidersDaemon) providerETag() string { return fmt.Sprintf(`"providers-%d"`, d.etag) }

// toggles returns and clears the recorded patches.
func (d *fakeProvidersDaemon) toggles() []toggleRequest {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := d.requests
	d.requests = nil
	return out
}

func (d *fakeProvidersDaemon) enabled(name string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.profiles[name].IsEnabled()
}

func (d *fakeProvidersDaemon) profilesJSON() map[string]any {
	out := map[string]any{}
	for name, s := range d.profiles {
		out[name] = map[string]any{
			"extension": s.Extension, "endpoint": s.BaseURL, "model": s.Model, "protocol": s.Protocol,
			"effort": nil, "image_edge": nil, "account_id": nil, "account_ids": nil,
			"project": nil, "location": nil, "rotation": "failover", "has_key": s.HasKey,
			"enabled": s.IsEnabled(),
		}
	}
	return out
}

func (d *fakeProvidersDaemon) settingsJSON() map[string]any {
	groups := map[string]any{}
	for _, group := range []string{"providers", "mcp", "extensions", "extension_settings", "capabilities", "models", "ui"} {
		groups[group] = map[string]any{"url": "/settings?group=" + group, "etag": `"` + group + `-1"`}
	}
	// The providers group's validator moves with every accepted patch.
	groups["providers"] = map[string]any{"url": "/settings?group=providers", "etag": d.providerETag()}
	return map[string]any{
		"providers":          map[string]any{"default_profile": d.active, "profiles": d.profilesJSON()},
		"group_resources":    groups,
		"mcp":                map[string]any{"definitions": map[string]any{}},
		"extensions":         map[string]any{"defaults": map[string]bool{}},
		"extension_settings": map[string]any{"sections": []any{}},
		"capabilities":       map[string]any{"preferences": map[string]bool{}},
		"models":             map[string]any{"raised_caps": map[string]bool{}, "compact_at": map[string]int{}, "cache_ttl_priors": []any{}},
		"ui":                 map[string]any{"thinking": false, "tools": false, "dismissed_notices": []string{}, "web_allow": []string{}},
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func (d *fakeProvidersDaemon) serveHTTP(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	defer d.mu.Unlock()
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/auth":
		writeJSON(w, http.StatusOK, map[string]any{"providers": []any{}, "accounts": []any{}})
	case r.Method == http.MethodGet && r.URL.Path == "/settings":
		writeJSON(w, http.StatusOK, d.settingsJSON())
	case r.Method == http.MethodPatch && r.URL.Path == "/settings/providers":
		data, _ := io.ReadAll(r.Body)
		if r.Header.Get("If-Match") != d.providerETag() {
			writeJSON(w, http.StatusConflict, map[string]any{"code": "stale", "message": "the providers group moved"})
			return
		}
		var body struct {
			Profiles map[string]struct {
				Enabled *bool `json:"enabled"`
			} `json:"profiles"`
		}
		if err := json.Unmarshal(data, &body); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"code": "bad_request", "message": err.Error()})
			return
		}
		for name, patch := range body.Profiles {
			if patch.Enabled == nil {
				continue
			}
			settings, ok := d.profiles[name]
			if !ok {
				continue
			}
			enabled := *patch.Enabled
			settings.Enabled = &enabled
			d.profiles[name] = settings
			d.requests = append(d.requests, toggleRequest{name: name, enabled: enabled, ifMatch: r.Header.Get("If-Match")})
		}
		d.etag++
		writeJSON(w, http.StatusOK, map[string]any{
			"application": map[string]any{"active_service_revision": nil, "composition_changed": false, "desired_revision": "revision", "validation": "not_applicable", "warnings": []any{}},
			"group":       "providers",
			"resource":    map[string]any{"etag": d.providerETag(), "url": "/settings/providers", "value": map[string]any{"default_profile": d.active, "profiles": d.profilesJSON()}},
		})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

// selectedRow returns the view line drawn on the selection surface: the one
// carrying the list's selection bar.
func selectedRow(view string) (string, bool) {
	for _, line := range strings.Split(view, "\n") {
		plain := ansi.Strip(line)
		if strings.HasPrefix(plain, ansi.Strip(selectBar())) {
			return plain, true
		}
	}
	return "", false
}

func cloneProfiles(in map[string]config.Settings) map[string]config.Settings {
	out := make(map[string]config.Settings, len(in))
	for name, s := range in {
		out[name] = s
	}
	return out
}

// generatedProfiles builds count profiles named p0..pN-1 whose enabled state
// is unset (on), explicit true, or explicit false, in that generator order.
func generatedProfiles(count uint8, states []uint8) map[string]config.Settings {
	profiles := map[string]config.Settings{}
	for i := 0; i < int(count%5); i++ {
		state := uint8(0)
		if i < len(states) {
			state = states[i] % 3
		}
		settings := config.Settings{
			ProfileName: fmt.Sprintf("p%d", i), Extension: "openai", BaseURL: "https://api.openai.com/v1",
			Model: "gpt-5", Protocol: "responses", HasKey: true,
		}
		switch state {
		case 1:
			on := true
			settings.Enabled = &on
		case 2:
			off := false
			settings.Enabled = &off
		}
		profiles[settings.ProfileName] = settings
	}
	return profiles
}

// loginKey is the key press a generated action stands for.
func loginKey(action uint8) tea.KeyPressMsg {
	switch action % 11 {
	case 0:
		return tea.KeyPressMsg{Code: tea.KeyUp}
	case 1:
		return tea.KeyPressMsg{Code: tea.KeyDown}
	case 2:
		return tea.KeyPressMsg{Code: tea.KeyEnter}
	case 3:
		return tea.KeyPressMsg{Code: tea.KeyEsc}
	case 4:
		return tea.KeyPressMsg{Code: tea.KeyPgDown}
	case 5:
		return tea.KeyPressMsg{Code: tea.KeyPgUp}
	case 6:
		return tea.KeyPressMsg{Code: tea.KeyBackspace}
	case 7, 8, 9:
		// A typed letter filters the list.
		r := []rune("p0123ae")[int(action)%7]
		return tea.KeyPressMsg{Code: r, Text: string(r)}
	default:
		return tea.KeyPressMsg{Code: 't', Mod: tea.ModCtrl}
	}
}

func TestPropLoginProviderToggle(t *testing.T) {
	d := newFakeProvidersDaemon()
	conn := commandTestConnection(t, d.serveHTTP)
	coverage := map[string]int{}

	f := func(count uint8, states []uint8, actions []uint8) bool {
		profiles := generatedProfiles(count, states)
		names := make([]string, 0, len(profiles))
		for name := range profiles {
			names = append(names, name)
		}
		active := ""
		if len(names) > 0 {
			active = names[0]
		}
		d.reset(profiles, active)
		d.toggles()

		m := NewLoginModel(conn, "", nil)
		defer m.Close()
		m.SetSize(120, 30)
		m.Profiles = config.Profiles{Active: active, Providers: cloneProfiles(profiles), ETag: d.providerETag()}
		m.advanced = true
		m.backToChoose()
		if m.Step != StepAdvanced {
			t.Fatalf("setups list not shown: %v", m.Step)
		}

		for _, action := range actions {
			key := loginKey(action)
			before := m.ChoosePicker.input.Value()
			if m.Step == StepAdvanced && key.String() == "ctrl+t" {
				// The row the screen draws as selected is the row a toggle
				// acts on: the oracle reads it from the rendered view.
				line, selected := selectedRow(m.View())
				var target string
				if selected {
					for name := range profiles {
						if strings.Contains(line, " "+name+" ") || strings.HasSuffix(line, " "+name) {
							if target != "" {
								t.Fatalf("two profile names on the selected row %q", line)
							}
							target = name
						}
					}
				}
				wantCmd := selected && target != ""
				switch {
				case !selected:
					coverage["toggle with no row visible"]++
				case target == "":
					coverage["toggle on a non-profile row"]++
				case !d.enabled(target):
					coverage["toggle enabling a disabled profile"]++
				default:
					coverage["toggle disabling an enabled profile"]++
				}
				next, cmd := pressCtrl(m, 't')
				if wantCmd != (cmd != nil) {
					t.Fatalf("ctrl+t on %q selected=%v sent cmd=%v", line, selected, cmd != nil)
				}
				if cmd == nil {
					m = next
					continue
				}
				if next.Step != StepSaving {
					t.Fatalf("toggle left step %v, want saving", next.Step)
				}
				want := !d.enabled(target)
				msg := cmd()
				applied, _ := next.Update(msg)
				requests := d.toggles()
				if len(requests) != 1 {
					t.Fatalf("one toggle sent %d requests: %+v", len(requests), requests)
				}
				if requests[0].name != target || requests[0].enabled != want {
					t.Fatalf("toggle patched %+v, want %s enabled=%v", requests[0], target, want)
				}
				if d.enabled(target) != want {
					t.Fatalf("daemon did not apply %+v", requests[0])
				}
				if applied.Error != "" {
					var apiErr *daemon.APIError
					cause := ""
					if errors.As(msg.(providerAvailabilityMsg).Result.Err, &apiErr) {
						cause = fmt.Sprintf(" status=%d code=%s detail=%s", apiErr.StatusCode, apiErr.Code, apiErr.Message)
					}
					chain := []string{}
					for err := error(msg.(providerAvailabilityMsg).Result.Err); err != nil; err = errors.Unwrap(err) {
						chain = append(chain, fmt.Sprintf("%T: %v", err, err))
					}
					t.Fatalf("accepted toggle reported %q (daemon etag %s, client etag %s, saw %+v%s, count=%d states=%v action=%d chain=%v)", applied.Error, d.providerETag(), m.Profiles.ETag, requests, cause, count, states, action, chain)
				}
				if applied.Step != StepAdvanced {
					t.Fatalf("toggle left step %v, want the setups list", applied.Step)
				}
				if got := applied.ChoosePicker.input.Value(); got != before {
					t.Fatalf("toggle changed the filter from %q to %q", before, got)
				}
				if name, ok := applied.highlightedProfile(); !ok || name != target {
					t.Fatalf("toggle moved the cursor to %q, want %q", name, target)
				}
				if applied.Profiles.Providers[target].IsEnabled() != want {
					t.Fatalf("model kept enabled=%v after patching %v", applied.Profiles.Providers[target].IsEnabled(), want)
				}
				if line, ok := selectedRow(applied.View()); !ok || !strings.Contains(line, target) {
					t.Fatalf("toggled row is not drawn as selected: %q", line)
				}
				m = applied
				continue
			}

			next, cmd := m.Update(key)
			m = next
			if m.Step == StepAdvanced {
				if len(m.ChoosePicker.shown) > 0 {
					if m.ChoosePicker.Cursor < 0 || m.ChoosePicker.Cursor >= len(m.ChoosePicker.shown) {
						t.Fatalf("cursor %d outside %d rows", m.ChoosePicker.Cursor, len(m.ChoosePicker.shown))
					}
					if _, ok := selectedRow(m.View()); !ok {
						t.Fatalf("no row drawn as selected:\n%s", ansi.Strip(m.View()))
					}
				}
				if key.String() == "enter" && cmd != nil {
					// Selecting a row leaves the list unless the row is a
					// disabled profile, which refuses in place.
					line, _ := selectedRow(m.View())
					disabled := false
					for name, settings := range profiles {
						if strings.Contains(line, " "+name+" ") && !settings.IsEnabled() {
							disabled = true
						}
					}
					selected, _ := m.Update(cmd())
					if requests := d.toggles(); len(requests) != 0 {
						t.Fatalf("choosing %q patched providers: %+v", line, requests)
					}
					if disabled {
						coverage["enter on a disabled profile"]++
						if selected.Step != StepAdvanced || !strings.Contains(selected.Status, "disabled") {
							t.Fatalf("disabled row %q was chosen: step %v status %q", line, selected.Step, selected.Status)
						}
					} else if selected.Step == StepAdvanced {
						t.Fatalf("choosing %q stayed on the list", line)
					} else {
						coverage["enter on an enabled or other row"]++
					}
					m.advanced = true
					m.backToChoose()
					continue
				}
			}
			if m.Step == StepChoose {
				m.advanced = true
				m.backToChoose()
			}
		}
		return true
	}

	if err := quick.Check(f, &quick.Config{MaxCount: 400}); err != nil {
		t.Fatal(err)
	}
	t.Logf("coverage: %v", coverage)
}

// expectedCost is the list column's text for a session cost, written from the
// documented format rather than from the production formatter.
func expectedCost(cost *float64) string {
	if cost == nil || *cost < 0 || math.IsNaN(*cost) || math.IsInf(*cost, 0) {
		return "—"
	}
	if *cost > 0 && *cost < 0.01 {
		return "$<0.01"
	}
	if *cost >= 1000 {
		return fmt.Sprintf("$%.0f", *cost)
	}
	return fmt.Sprintf("$%.2f", *cost)
}

func TestPropSessionViewerCostColumn(t *testing.T) {
	now := time.Date(2026, 9, 23, 12, 0, 0, 0, time.Local)
	recent := now.Add(-5 * time.Minute).Unix()

	f := func(rawWidth uint16, costs []int32) bool {
		width := 1 + int(rawWidth%200)
		costSets := []float64{0, 0.001, 1.234, 999.99, 12345, 999999}
		sessions := make([]daemon.Session, 0, 6)
		for i := 0; i < 6; i++ {
			value := costSets[i]
			if i < len(costs) && costs[i]%4 == 0 {
				// Keep the formatted cost inside the column's eight cells.
				value = float64(int64(costs[i])%100000) / 100
			}
			session := daemon.Session{
				ID: fmt.Sprintf("s%d", i), Title: fmt.Sprintf("session %d", i),
				Model: "gpt-5", Workspace: "/work/current", LastAssistantAt: &recent,
			}
			if i < len(costs) && costs[i]%3 == 0 {
				session.SessionCostUSD = nil
			} else {
				cost := value
				session.SessionCostUSD = &cost
			}
			sessions = append(sessions, session)
		}
		m := viewerAt(now)
		m.SetSize(width, 24)
		m.SetSessions(sessions, nil)
		m.Init()
		lines := m.column(width, 20, now)
		if len(lines) == 0 {
			return true
		}
		right := -1
		for i, session := range sessions {
			if width < 40 {
				// Narrower rows carry no cost column; the age column is all
				// that stays on the right.
				break
			}
			want := expectedCost(session.SessionCostUSD)
			row := ""
			for _, line := range lines {
				plain := ansi.Strip(line)
				if strings.Contains(plain, "session "+fmt.Sprint(i)) {
					row = plain
					break
				}
			}
			if row == "" {
				// The column may be narrow enough for the title to be cut.
				continue
			}
			at := strings.Index(row, want)
			if at < 0 {
				t.Fatalf("width %d row %q lacks cost %q", width, row, want)
			}
			end := ansi.StringWidth(row[:at]) + ansi.StringWidth(want)
			if right < 0 {
				right = end
			} else if end != right {
				t.Fatalf("width %d cost column ends at %d and %d:\n%s", width, right, end, strings.Join(lines, "\n"))
			}
			if end > width {
				t.Fatalf("width %d cost overflows: %q", width, row)
			}
			// The age column keeps its four cells at the row's right end, with
			// the two-space gap between them: the cost column ends before it.
			if end > width-6 {
				t.Fatalf("width %d cost ends at %d, over the age column: %q", width, end, row)
			}
			if at := strings.Index(row, "5m"); at < 0 || at < end {
				t.Fatalf("width %d row %q lost its age after the cost", width, row)
			}
		}
		for _, line := range lines {
			if w := ansi.StringWidth(line); w != width {
				t.Fatalf("width %d drew a %d-cell row: %q", width, w, ansi.Strip(line))
			}
		}
		return true
	}

	if err := quick.Check(f, &quick.Config{MaxCount: 400}); err != nil {
		t.Fatal(err)
	}
}
