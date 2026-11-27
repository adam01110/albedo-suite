package daemon

// Property tests for the suite's daemon-side decode helpers: usage summary
// reads and session glance ordering.

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"reflect"
	"slices"
	"strings"
	"testing"
	"testing/quick"
	"time"

	"albedo/cli/internal/daemon/protocol"
)

func propDaemonConfig(seed int64, max int) *quick.Config {
	return &quick.Config{MaxCount: max, Rand: rand.New(rand.NewSource(seed))}
}

func propStamp(day int) string {
	return fmt.Sprintf("2026-01-%02dT00:00:00Z", day%28+1)
}

// propUsageWire builds a wire summary whose every counter differs, so a
// transposed field cannot pass unnoticed.
func propUsageWire(seed uint64, days, lines, scopes int) protocol.UsageSummary {
	next := func() int64 { seed++; return int64(seed%100000) + 1 }
	totals := func(into *protocol.UsageDay) {
		into.Calls, into.Errors = next(), next()
		into.InputTokens, into.CachedInputTokens = next(), next()
		into.CacheCreationTokens, into.OutputTokens, into.ReasoningTokens = next(), next(), next()
	}
	wire := protocol.UsageSummary{GeneratedAt: propStamp(int(seed % 28))}
	for i := 0; i < days; i++ {
		day := protocol.UsageDay{Start: propStamp(i)}
		totals(&day)
		wire.Days = append(wire.Days, day)
	}
	for i := 0; i < lines; i++ {
		line := protocol.UsageLine{Profile: fmt.Sprint("profile", i), Provider: fmt.Sprint("provider", i), Model: fmt.Sprint("model", i)}
		line.Calls, line.Errors = next(), next()
		line.InputTokens, line.CachedInputTokens = next(), next()
		line.CacheCreationTokens, line.OutputTokens, line.ReasoningTokens = next(), next(), next()
		switch i % 3 {
		case 1:
			account := fmt.Sprint("account", i)
			line.Account = &account
		case 2:
			empty := ""
			line.Account = &empty
		}
		wire.Lines = append(wire.Lines, line)
	}
	for i := 0; i < scopes; i++ {
		scope := protocol.UsageScope{Provider: fmt.Sprint("provider", i)}
		if i%2 == 1 {
			account := fmt.Sprint("account", i)
			scope.Account = &account
		}
		wire.Scopes = append(wire.Scopes, scope)
	}
	wire.LinesTruncated, wire.ScopesTruncated = seed%2 == 1, seed%3 == 0
	wire.UtcOffsetMinutes = int64(seed%29) - 14
	if seed%4 != 0 {
		profile := &protocol.UsageProfile{LifetimeTokens: next(), LifetimeCalls: next(), ActiveDays: next(), PeakDayTokens: next(),
			LongestStreakDays: next(), CurrentStreakDays: next()}
		if seed%2 == 0 {
			first, peak := propStamp(3), propStamp(9)
			profile.FirstDay, profile.PeakDay = &first, &peak
		}
		if seed%3 == 0 {
			longest := next()
			profile.LongestTurnMs = &longest
		}
		wire.Profile = profile
	}
	return wire
}

func TestPropUsageSummaryDecoding(t *testing.T) {
	f := func(seed uint64) bool {
		wire := propUsageWire(seed, int(seed%4), int((seed>>3)%4), int((seed>>6)%4))
		got, err := usageSummary(wire)
		if err != nil {
			t.Logf("seed=%d err=%v", seed, err)
			return false
		}
		generated, _ := time.Parse(time.RFC3339, wire.GeneratedAt)
		want := UsageSummary{GeneratedAt: generated, UTCOffsetMinutes: int(wire.UtcOffsetMinutes),
			LinesTruncated: wire.LinesTruncated, ScopesTruncated: wire.ScopesTruncated,
			Days: make([]UsageDay, 0, len(wire.Days)), Lines: make([]UsageLine, 0, len(wire.Lines)), Scopes: make([]UsageScope, 0, len(wire.Scopes))}
		for _, day := range wire.Days {
			start, _ := time.Parse(time.RFC3339, day.Start)
			want.Days = append(want.Days, UsageDay{Start: start, UsageTotals: UsageTotals{Calls: day.Calls, Errors: day.Errors,
				InputTokens: day.InputTokens, CachedInputTokens: day.CachedInputTokens, CacheCreationTokens: day.CacheCreationTokens,
				OutputTokens: day.OutputTokens, ReasoningTokens: day.ReasoningTokens}})
		}
		for _, line := range wire.Lines {
			account := ""
			if line.Account != nil {
				account = *line.Account
			}
			want.Lines = append(want.Lines, UsageLine{Profile: line.Profile, Provider: line.Provider, Account: account, Model: line.Model,
				UsageTotals: UsageTotals{Calls: line.Calls, Errors: line.Errors, InputTokens: line.InputTokens, CachedInputTokens: line.CachedInputTokens,
					CacheCreationTokens: line.CacheCreationTokens, OutputTokens: line.OutputTokens, ReasoningTokens: line.ReasoningTokens}})
		}
		for _, scope := range wire.Scopes {
			account := ""
			if scope.Account != nil {
				account = *scope.Account
			}
			want.Scopes = append(want.Scopes, UsageScope{Provider: scope.Provider, Account: account})
		}
		if wire.Profile != nil {
			p := wire.Profile
			profile := UsageProfile{LifetimeTokens: p.LifetimeTokens, LifetimeCalls: p.LifetimeCalls, ActiveDays: p.ActiveDays,
				PeakDayTokens: p.PeakDayTokens, LongestStreakDays: p.LongestStreakDays, CurrentStreakDays: p.CurrentStreakDays}
			if p.FirstDay != nil {
				profile.FirstDay, _ = time.Parse(time.RFC3339, *p.FirstDay)
			}
			if p.PeakDay != nil {
				profile.PeakDay, _ = time.Parse(time.RFC3339, *p.PeakDay)
			}
			if p.LongestTurnMs != nil {
				profile.LongestTurn = time.Duration(*p.LongestTurnMs) * time.Millisecond
			}
			want.Profile = &profile
		}
		if !reflect.DeepEqual(got, want) {
			t.Logf("seed=%d got=%+v want=%+v", seed, got, want)
			return false
		}
		return true
	}
	if err := quick.Check(f, propDaemonConfig(11, 500)); err != nil {
		t.Fatal(err)
	}
}

// TestPropGlanceOrdering keeps every pushed glance and its rows, sorts them by
// title, and keeps the mcp list next to skills.
func TestPropGlanceOrdering(t *testing.T) {
	titles := []string{"skills", "mcp", "agents", "memory", "tools"}
	f := func(seed uint64) bool {
		n := int(seed % 6)
		var wire []protocol.Glance
		for i := 0; i < n; i++ {
			title := titles[(seed>>uint(i*3))%uint64(len(titles))]
			wire = append(wire, protocol.Glance{Title: title, URL: protocol.ResourceURL(fmt.Sprint("/pages/", title, i)),
				Rows: []protocol.PageRow{{ID: protocol.ID(fmt.Sprint("row", i)), Text: fmt.Sprint("row ", i)}}})
		}
		got := glancesValue(wire)
		if len(got) != len(wire) {
			return false
		}
		want := make([]string, len(wire))
		for i, glance := range wire {
			want[i] = glance.Title
		}
		count := func(values []string) map[string]int {
			out := map[string]int{}
			for _, value := range values {
				out[value]++
			}
			return out
		}
		gotTitles := make([]string, len(got))
		for i := range got {
			gotTitles[i] = got[i].Title
			if len(got[i].Rows) != 1 || got[i].Rows[0].Text != fmt.Sprint("row ", strings.TrimPrefix(string(got[i].Rows[0].ID), "row")) {
				t.Logf("glance %+v lost its row", got[i])
				return false
			}
		}
		if !reflect.DeepEqual(count(gotTitles), count(want)) {
			t.Logf("titles %v became %v", want, gotTitles)
			return false
		}
		for i := 0; i+1 < len(got); i++ {
			if strings.Compare(glanceOrder(got[i].Title), glanceOrder(got[i+1].Title)) > 0 {
				t.Logf("titles %v out of order", gotTitles)
				return false
			}
		}
		if slices.Contains(gotTitles, "skills") && slices.Contains(gotTitles, "mcp") {
			lastSkills := -1
			for i, title := range gotTitles {
				if title == "skills" {
					lastSkills = i
				}
			}
			firstMcp := -1
			for i, title := range gotTitles {
				if title == "mcp" {
					firstMcp = i
					break
				}
			}
			if firstMcp != lastSkills+1 {
				t.Logf("titles %v: mcp at %d, last skills at %d", gotTitles, firstMcp, lastSkills)
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, propDaemonConfig(12, 500)); err != nil {
		t.Fatal(err)
	}
}

// propHistoryJSON builds the wire JSON of one entry, so the anonymous tool
// struct and the raw content parts stay out of the test's own types.
func propHistoryJSON(seed uint64) ([]byte, struct {
	Text     string
	Result   string
	Images   []ImageMetadata
	ToolName string
	Status   string
	Title    string
	CallID   string
	EntryID  string
	Position int
	ToolArgs map[string]any
}) {
	type want struct {
		Text     string
		Result   string
		Images   []ImageMetadata
		ToolName string
		Status   string
		Title    string
		CallID   string
		EntryID  string
		Position int
		ToolArgs map[string]any
	}
	var expected want
	n := func(k uint) int64 { return int64((seed>>k)%900) + 1 }
	expected.EntryID = fmt.Sprint("entry-", seed%7)
	expected.Position = int(seed%9) + 1
	expected.ToolName, expected.Status = fmt.Sprint("tool", seed%5), fmt.Sprint("status", seed%3)
	expected.Title = fmt.Sprint("title ", seed%11)
	callID := fmt.Sprint("call", seed%4)
	expected.CallID = callID
	var content []any
	expected.Text = fmt.Sprint("text ", seed%13)
	content = append(content, map[string]any{"kind": "text", "text": expected.Text})
	arguments := map[string]any{"alpha": fmt.Sprint("a", seed%3), "beta": float64(seed % 5)}
	expected.ToolArgs = arguments
	content = append(content, map[string]any{"kind": "json", "field": "arguments", "value": arguments})
	if seed%2 == 0 {
		expected.Result = fmt.Sprint("result ", seed%17)
		content = append(content, map[string]any{"kind": "json", "field": "result", "value": expected.Result})
	} else {
		expected.Result = fmt.Sprintf(`{"ok":%d}`, seed%10)
		content = append(content, map[string]any{"kind": "json", "field": "result", "value": map[string]any{"ok": float64(seed % 10)}})
	}
	for i := 0; i < int(seed%3); i++ {
		image := ImageMetadata{MimeType: ImageMimeType(fmt.Sprint("image/", seed%2)), Width: int(n(3 + uint(i)*4)), Height: int(n(4 + uint(i)*4)), Bytes: int(n(5 + uint(i)*4)),
			Reference: fmt.Sprint("/sessions/agent/history/entry/image-", i+1)}
		expected.Images = append(expected.Images, image)
		content = append(content, map[string]any{"kind": "image", "image": map[string]any{
			"mime_type": string(image.MimeType), "width": image.Width, "height": image.Height,
			"original_bytes": image.Bytes, "reference": map[string]any{"url": image.Reference}}})
	}
	tool := map[string]any{"name": expected.ToolName, "status": expected.Status, "title": expected.Title, "tool_call_id": fmt.Sprint("callid-", seed%3)}
	if seed%2 == 0 {
		tool["progress_call_id"] = callID
	} else {
		// Without progress, the call ID stands in for it.
		tool["tool_call_id"] = callID
	}
	raw, _ := json.Marshal(map[string]any{"id": expected.EntryID, "kind": "tool_result", "position": expected.Position, "content": content, "tool": tool})
	return raw, expected
}

func TestPropHistoryEntryDecoding(t *testing.T) {
	f := func(seed uint64) bool {
		raw, want := propHistoryJSON(seed)
		var wire protocol.HistoryEntry
		if err := json.Unmarshal(raw, &wire); err != nil {
			t.Logf("seed=%d unmarshal: %v", seed, err)
			return false
		}
		entries, err := decodeHistoryEntries([]protocol.HistoryEntry{wire})
		if err != nil {
			t.Logf("seed=%d parts: %v", seed, err)
			return false
		}
		events, err := historyEvents(entries)
		if err != nil {
			t.Logf("seed=%d events: %v", seed, err)
			return false
		}
		if len(events) != 1 {
			t.Logf("seed=%d events=%+v", seed, events)
			return false
		}
		event := events[0]
		if event.Type != EventTool || event.EntryID != want.EntryID || event.Position != int64(want.Position) || !event.Replayed {
			t.Logf("seed=%d event identity=%+v", seed, event)
			return false
		}
		if event.ToolName != want.ToolName || event.ToolStatus != want.Status || event.ToolTitle != want.Title || event.ProgressCallID != want.CallID {
			t.Logf("seed=%d tool=%+v want=%+v", seed, event, want)
			return false
		}
		if event.ToolResult != want.Result || event.Text != "" {
			t.Logf("seed=%d result=%q text=%q want=%q", seed, event.ToolResult, event.Text, want.Result)
			return false
		}
		if len(event.ToolArgs) != len(want.ToolArgs) || fmt.Sprint(event.ToolArgs["alpha"]) != fmt.Sprint(want.ToolArgs["alpha"]) {
			t.Logf("seed=%d args=%v want=%v", seed, event.ToolArgs, want.ToolArgs)
			return false
		}
		if !reflect.DeepEqual(event.Images, want.Images) {
			t.Logf("seed=%d images=%v want=%v", seed, event.Images, want.Images)
			return false
		}
		return true
	}
	if err := quick.Check(f, propDaemonConfig(13, 400)); err != nil {
		t.Fatal(err)
	}
}

// validSessionWire is the smallest wire session validateSession has to accept:
// an identity, a generation and cursor, an empty history page it can resume
// from, no active output yet, and a resting status.
func validSessionWire() protocol.Session {
	generation := protocol.Generation("abcdefghijklmnopqrstuv")
	text := "streaming"
	wire := protocol.Session{ID: "session", RootID: "session", Name: "session", Revision: "rev", FamilyRevision: "rev"}
	wire.Cursor = &protocol.Cursor{Generation: generation, Sequence: 0}
	wire.ConfigurationResource.ETag = "etag"
	wire.History.Items = []protocol.HistoryEntry{}
	wire.ActiveOutput = []protocol.ActiveOutput{{MessageID: "message", RunID: "run", Kind: "text", Text: &text, Bytes: int64(len(text))}}
	wire.Status.Phase = "idle"
	fillRequiredWire(reflect.ValueOf(&wire).Elem())
	return wire
}

// fillRequiredWire gives every non-nullable, non-optional wire field a value,
// so the fixture is about the semantic constraints rather than presence.
func fillRequiredWire(value reflect.Value) {
	if !value.IsValid() {
		return
	}
	switch value.Kind() {
	case reflect.Pointer:
		if value.IsNil() {
			value.Set(reflect.New(value.Type().Elem()))
		}
		fillRequiredWire(value.Elem())
	case reflect.Slice:
		if value.IsNil() {
			value.Set(reflect.MakeSlice(value.Type(), 0, 0))
		}
		for i := 0; i < value.Len(); i++ {
			fillRequiredWire(value.Index(i))
		}
	case reflect.Map:
		if value.IsNil() {
			value.Set(reflect.MakeMap(value.Type()))
		}
	case reflect.Struct:
		for i := 0; i < value.NumField(); i++ {
			field := value.Type().Field(i)
			if !field.IsExported() {
				continue
			}
			jsonTag, options, _ := strings.Cut(field.Tag.Get("json"), ",")
			if jsonTag == "-" {
				continue
			}
			target := value.Field(i)
			if target.Kind() == reflect.Pointer && target.IsNil() &&
				(strings.Contains(field.Tag.Get("nullable"), "true") || strings.Contains(options, "omitempty")) {
				continue
			}
			fillRequiredWire(target)
		}
	}
}

func propDecodeSession(wire protocol.Session) (Session, error) {
	data, err := json.Marshal(wire)
	if err != nil {
		return Session{}, err
	}
	return decodeSession(data)
}

// TestPropSessionValidationAcceptsValid keeps the fixture valid, so a rejection
// below is the mutation's doing.
func TestPropSessionValidationAcceptsValid(t *testing.T) {
	if _, err := propDecodeSession(validSessionWire()); err != nil {
		t.Fatalf("valid wire session rejected: %v", err)
	}
}

// TestPropSessionValidationRejectsNearValid breaks one documented constraint
// at a time and requires the decoder to notice.
func TestPropSessionValidationRejectsNearValid(t *testing.T) {
	text := "streaming"
	both := "kept"
	reference := protocol.ContentReference{URL: "/sessions/session/history/message/image-1"}
	cases := map[string]func(*protocol.Session){
		"no id":              func(w *protocol.Session) { w.ID = "" },
		"no root":            func(w *protocol.Session) { w.RootID = "" },
		"no cursor":          func(w *protocol.Session) { w.Cursor = nil },
		"short generation":   func(w *protocol.Session) { w.Cursor.Generation = "short" },
		"bad generation":     func(w *protocol.Session) { w.Cursor.Generation = "abcdefghijklmnopqrstu!" },
		"negative sequence":  func(w *protocol.Session) { w.Cursor.Sequence = -1 },
		"no etag":            func(w *protocol.Session) { w.ConfigurationResource.ETag = "" },
		"no history items":   func(w *protocol.Session) { w.History.Items = nil },
		"no active output":   func(w *protocol.Session) { w.ActiveOutput = nil },
		"bad status phase":   func(w *protocol.Session) { w.Status.Phase = "resting" },
		"output without run": func(w *protocol.Session) { w.ActiveOutput[0].RunID = "" },
		"output without msg": func(w *protocol.Session) { w.ActiveOutput[0].MessageID = "" },
		"output with neither": func(w *protocol.Session) {
			w.ActiveOutput[0].Text, w.ActiveOutput[0].Reference = nil, nil
		},
		"output with both": func(w *protocol.Session) {
			w.ActiveOutput[0].Text, w.ActiveOutput[0].Reference = &both, &reference
		},
		"output kind":  func(w *protocol.Session) { w.ActiveOutput[0].Kind = "tool" },
		"output bytes": func(w *protocol.Session) { w.ActiveOutput[0].Bytes = -1 },
		"duplicate output": func(w *protocol.Session) {
			w.ActiveOutput = append(w.ActiveOutput, protocol.ActiveOutput{MessageID: w.ActiveOutput[0].MessageID, RunID: "other", Kind: "text", Text: &text})
		},
		"negative elapsed": func(w *protocol.Session) {
			elapsed := int64(-1)
			w.ActiveOutput[0].ElapsedMs = &elapsed
		},
		"empty side question": func(w *protocol.Session) {
			w.SideQuestion = &protocol.SideQuestion{ID: "", Question: "why"}
		},
	}
	for name, mutate := range cases {
		wire := validSessionWire()
		mutate(&wire)
		if _, err := propDecodeSession(wire); err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
}
