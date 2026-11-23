// Property tests for the suite's additions to event decoding, whole-session
// totals and glance ordering. Discovery only; the regression tests live beside
// the fixes.
package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"slices"
	"strconv"
	"testing"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon/protocol"
	"albedo/cli/internal/testwire"
)

// toolEventExpectation is what an independently written test body computed for
// one generated tool event, before the decoder saw it.
type toolEventExpectation struct {
	entryID          string
	sessionToolCalls *int
	images           []ImageMetadata
	toolName         string
	progressCallID   string
	status           string
	title            string
	args             map[string]any
	result           string
	sequence         int64
}

func randomToken(r *rand.Rand, prefix string) string {
	return fmt.Sprintf("%s-%08x", prefix, r.Uint32())
}

func oneOf(r *rand.Rand, values ...string) string {
	return values[r.Intn(len(values))]
}

// generateToolEvent builds a tool event envelope and the expectation for it
// from the same generated values, never from the decoder's output.
func generateToolEvent(r *rand.Rand) ([]byte, toolEventExpectation) {
	sequence := int64(r.Intn(1<<20) + 1)
	name, callID, progressID := randomToken(r, "tool"), randomToken(r, "call"), randomToken(r, "progress")
	status := oneOf(r, "ok", "error", "")
	var title string
	data := map[string]any{
		"tool_call_id":     callID,
		"progress_call_id": progressID,
		"name":             name,
		"status":           status,
		"content_complete": r.Intn(2) == 0,
		"reference":        nil,
		"trace":            map[string]any{"steps": r.Intn(5)},
	}
	expectation := toolEventExpectation{toolName: name, progressCallID: progressID, status: status, sequence: sequence}

	if r.Intn(3) != 0 {
		title = randomToken(r, "title")
		data["title"] = title
	}
	expectation.title = title

	switch r.Intn(4) {
	case 0:
		expectation.entryID = ""
	case 1:
		expectation.entryID = strconv.Itoa(r.Intn(100000))
		data["entry_id"] = expectation.entryID
	}
	switch r.Intn(4) {
	case 0: // absent: the daemon could not read the ledger
	case 1: // explicit null, which a decoder must also treat as unknown
		data["session_tool_calls"] = nil
	default:
		count := r.Intn(1 << 20)
		data["session_tool_calls"] = count
		expectation.sessionToolCalls = &count
	}

	switch r.Intn(3) {
	case 1:
		text := randomToken(r, "text")
		data["result"] = text
		expectation.result = text
	case 2:
		value := map[string]any{"value": r.Intn(100)}
		data["result"] = value
		expectation.result = fmt.Sprintf(`{"value":%d}`, value["value"])
	default:
		data["result"] = nil
		expectation.result = ""
	}

	arguments := map[string]any{"path": randomToken(r, "path"), "count": r.Intn(1000)}
	data["arguments"] = arguments
	expectation.args = arguments

	var images []any
	for n := r.Intn(4); n > 0; n-- {
		mime := oneOf(r, string(ImagePNG), string(ImageJPEG), string(ImageWEBP))
		url := fmt.Sprintf("/sessions/s/history/%d/image-%d", r.Intn(1000), r.Intn(4))
		image := map[string]any{
			"mime_type":      mime,
			"width":          r.Intn(10000),
			"height":         r.Intn(10000),
			"original_bytes": r.Intn(1 << 20),
			"reference":      map[string]any{"url": url, "field": "image-0", "bytes": r.Intn(1 << 20)},
		}
		images = append(images, image)
		expectation.images = append(expectation.images, ImageMetadata{
			MimeType:  ImageMimeType(mime),
			Width:     image["width"].(int),
			Height:    image["height"].(int),
			Bytes:     image["original_bytes"].(int),
			Reference: url,
		})
	}
	data["images"] = images

	raw, err := json.Marshal(map[string]any{"type": "tool", "sequence": sequence, "data": data})
	if err != nil {
		panic(err)
	}
	return raw, expectation
}

// TestPropToolEventDecode checks every field a generated tool event carries
// against the value the generator put in it.
func TestPropToolEventDecode(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for i := 0; i < 500; i++ {
		raw, want := generateToolEvent(r)
		decoded, err := decodeChatEvent(raw)
		if err != nil {
			t.Fatalf("case %d: decode %s: %v", i, raw, err)
		}
		event := decoded.StreamEvent
		fail := func(field string, got, expected any) {
			t.Fatalf("case %d: %s = %v, want %v (event %s)", i, field, got, expected, raw)
		}
		if event.Type != EventTool {
			fail("type", event.Type, EventTool)
		}
		if event.ToolName != want.toolName {
			fail("tool name", event.ToolName, want.toolName)
		}
		if event.ProgressCallID != want.progressCallID {
			fail("progress call ID", event.ProgressCallID, want.progressCallID)
		}
		if event.EntryID != want.entryID {
			fail("entry ID", event.EntryID, want.entryID)
		}
		if event.ToolStatus != want.status {
			fail("status", event.ToolStatus, want.status)
		}
		if event.ToolTitle != want.title {
			fail("title", event.ToolTitle, want.title)
		}
		if event.Sequence != want.sequence {
			fail("sequence", event.Sequence, want.sequence)
		}
		switch {
		case want.sessionToolCalls == nil && event.SessionToolCalls != nil:
			fail("session tool calls", *event.SessionToolCalls, "nil")
		case want.sessionToolCalls != nil && event.SessionToolCalls == nil:
			fail("session tool calls", "nil", *want.sessionToolCalls)
		case want.sessionToolCalls != nil && *event.SessionToolCalls != *want.sessionToolCalls:
			fail("session tool calls", *event.SessionToolCalls, *want.sessionToolCalls)
		}
		if len(event.Images) != len(want.images) {
			fail("image count", len(event.Images), len(want.images))
		}
		for n, image := range want.images {
			if event.Images[n] != image {
				fail(fmt.Sprintf("image %d", n), event.Images[n], image)
			}
		}
		if event.ToolResult != want.result {
			fail("tool result", event.ToolResult, want.result)
		}
		if !slices.Equal(viewKeys(event.ToolArgs), viewKeys(want.args)) || fmt.Sprint(event.ToolArgs) != fmt.Sprint(want.args) {
			fail("tool arguments", event.ToolArgs, want.args)
		}
	}
}

func viewKeys(values map[string]any) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	return keys
}

// TestPropGlancesOrder checks the sidebar order against an independent rule:
// titles ascending, except that the mcp list follows skills.
func TestPropGlancesOrder(t *testing.T) {
	titles := []string{"mcp", "skills", "tasks", "active work", "scheduled", ""}
	r := rand.New(rand.NewSource(2))
	for i := 0; i < 500; i++ {
		var wire []protocol.Glance
		var wantTitles []string
		for n := r.Intn(7); n > 0; n-- {
			title := titles[r.Intn(len(titles))]
			wire = append(wire, protocol.Glance{Title: title})
			wantTitles = append(wantTitles, title)
		}
		var got []string
		for _, glance := range glancesValue(wire) {
			got = append(got, glance.Title)
		}
		if len(got) != len(wantTitles) {
			t.Fatalf("case %d: %v lost entries: %v", i, wantTitles, got)
		}
		sortedWant := slices.Clone(wantTitles)
		slices.Sort(sortedWant)
		sortedGot := slices.Clone(got)
		slices.Sort(sortedGot)
		if !slices.Equal(sortedWant, sortedGot) {
			t.Fatalf("case %d: multiset %v != %v", i, sortedGot, sortedWant)
		}
		for a := 0; a < len(got); a++ {
			for b := a + 1; b < len(got); b++ {
				if glanceBefore(got[b], got[a]) {
					t.Fatalf("case %d: order %v puts %q before %q", i, got, got[a], got[b])
				}
			}
		}
		skills, mcp := slices.Index(got, "skills"), slices.Index(got, "mcp")
		if skills >= 0 && mcp >= 0 && mcp < skills {
			t.Fatalf("case %d: order %v puts mcp before skills", i, got)
		}
	}
}

// glanceBefore reports whether the documented sidebar order puts a before b:
// titles ascending, except that the mcp list follows skills.
func glanceBefore(a, b string) bool {
	switch {
	case a == b:
		return false
	case a == "skills" && b == "mcp":
		return true
	case a == "mcp":
		return b > "skills"
	case b == "mcp":
		return a < "skills"
	}
	return a < b
}

// TestPropSessionTotals checks that the daemon's whole-session cost and tool
// count survive both the session and the list-row conversions.
func TestPropSessionTotals(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	for i := 0; i < 200; i++ {
		var cost *float64
		var calls *int64
		if r.Intn(2) == 0 {
			value := float64(r.Intn(1<<24)) / 10000
			cost = &value
		}
		if r.Intn(2) == 0 {
			value := int64(r.Intn(1 << 20))
			calls = &value
		}
		checkCost := func(source string, session Session) {
			if cost == nil && session.SessionCostUSD != nil || cost != nil && (session.SessionCostUSD == nil || *session.SessionCostUSD != *cost) {
				t.Fatalf("case %d: %s cost = %v, want %v", i, source, session.SessionCostUSD, cost)
			}
		}
		check := func(source string, session Session) {
			checkCost(source, session)
			switch {
			case calls == nil && session.SessionToolCalls != nil:
				t.Fatalf("case %d: %s tool calls = %d, want unknown", i, source, *session.SessionToolCalls)
			case calls != nil && session.SessionToolCalls == nil:
				t.Fatalf("case %d: %s tool calls = unknown, want %d", i, source, *calls)
			case calls != nil && int64(*session.SessionToolCalls) != *calls:
				t.Fatalf("case %d: %s tool calls = %d, want %d", i, source, *session.SessionToolCalls, *calls)
			}
		}
		check("session", sessionValue(protocol.Session{SessionCostUsd: cost, SessionToolCalls: calls}))
		// The collection endpoint reports only the cost on a list row, so a row
		// that carries no tool count must say the count is unknown.
		row := summaryValue(protocol.SessionSummary{SessionCostUsd: cost})
		if row.SessionToolCalls != nil {
			t.Fatalf("case %d: list row invented tool calls %d", i, *row.SessionToolCalls)
		}
		checkCost("list row", row)
	}
}

// TestPropListSessionsTotalCost checks that a generated session page's rows and
// its all-session cost survive the list conversion, and that a cost the daemon
// cannot have priced is refused rather than reported.
func TestPropListSessionsTotalCost(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	for i := 0; i < 40; i++ {
		type row struct {
			id, workspace string
			cost          *float64
		}
		var rows []row
		for n := r.Intn(5); n > 0; n-- {
			generated := row{id: fmt.Sprintf("019c1234-5678-7000-8000-%012d", r.Intn(1<<20)), workspace: oneOf(r, "/work", "/elsewhere")}
			if r.Intn(2) == 0 {
				cost := float64(r.Intn(1<<20)) / 100
				generated.cost = &cost
			}
			rows = append(rows, generated)
		}
		var total *struct {
			usd     float64
			partial bool
		}
		switch r.Intn(4) {
		case 0: // the daemon could not read the ledger
		case 1: // a cost that cannot be a price
			total = &struct {
				usd     float64
				partial bool
			}{usd: -0.01}
		default:
			total = &struct {
				usd     float64
				partial bool
			}{usd: float64(r.Intn(1<<20)) / 1000, partial: r.Intn(2) == 0}
		}

		// A negative total is outside the contract on purpose.
		connect := controlledConnection
		if total != nil && total.usd < 0 {
			connect = uncheckedConnection
		}
		conn := connect(t, func(w http.ResponseWriter, request *http.Request) {
			items := []any{}
			for _, generated := range rows {
				session := testwire.Session(generated.id, testwire.GenerationA, 0)
				session["workspace"] = generated.workspace
				if generated.cost != nil {
					session["session_cost_usd"] = *generated.cost
				}
				items = append(items, session)
			}
			page := map[string]any{"items": items, "next": nil}
			if total != nil {
				page["total_cost"] = map[string]any{"usd": total.usd, "partial": total.partial}
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(page)
		})
		sessions, cost, err := ListSessionsWithTotal(t.Context(), conn)
		if total != nil && total.usd < 0 {
			if err == nil {
				t.Fatalf("case %d: negative total cost accepted: %+v", i, cost)
			}
			continue
		}
		if err != nil {
			t.Fatalf("case %d: list sessions: %v", i, err)
		}
		if len(sessions) != len(rows) {
			t.Fatalf("case %d: %d rows, want %d", i, len(sessions), len(rows))
		}
		for n, generated := range rows {
			session := sessions[n]
			if session.ID != generated.id || session.Workspace != generated.workspace {
				t.Fatalf("case %d row %d: %+v, want %s in %s", i, n, session, generated.id, generated.workspace)
			}
			if generated.cost == nil && session.SessionCostUSD != nil || generated.cost != nil && (session.SessionCostUSD == nil || *session.SessionCostUSD != *generated.cost) {
				t.Fatalf("case %d row %d: cost %v, want %v", i, n, session.SessionCostUSD, generated.cost)
			}
		}
		switch {
		case total == nil && cost != nil:
			t.Fatalf("case %d: cost %+v reported without one", i, cost)
		case total != nil && cost == nil:
			t.Fatalf("case %d: cost missing, want %+v", i, total)
		case total != nil && (cost.USD != total.usd || cost.Partial != total.partial):
			t.Fatalf("case %d: cost %+v, want %+v", i, cost, total)
		}
	}
}

// TestPropSaveProviderPatch checks that a saved profile's every field reaches
// its own wire field: generated settings give each field a distinct value, so a
// transposed or dropped field changes the body.
func TestPropSaveProviderPatch(t *testing.T) {
	r := rand.New(rand.NewSource(8))
	for i := 0; i < 100; i++ {
		profile := config.Settings{
			Extension: oneOf(r, "openai", "anthropic-api", "bedrock", "zed"),
			BaseURL:   oneOf(r, "", "https://endpoint.example/v1"),
			Protocol:  oneOf(r, "responses", "chat_completions"),
			Model:     randomToken(r, "model"),
			Rotation:  oneOf(r, "", "failover", "spread", "first"),
			API:       oneOf(r, "", "messages", "converse"),
			APIKey:    oneOf(r, "", randomToken(r, "key")),
		}
		if r.Intn(2) == 0 {
			effort := oneOf(r, "low", "medium", "high")
			profile.Effort = &effort
		}
		if r.Intn(2) == 0 {
			edge := r.Intn(4096)
			profile.ImageEdge = &edge
		}
		if r.Intn(2) == 0 {
			account := randomToken(r, "account")
			profile.AccountID = &account
		}
		if r.Intn(3) == 0 {
			profile.AccountIDs = []string{randomToken(r, "one"), randomToken(r, "two")}
		}
		if r.Intn(2) == 0 {
			project := randomToken(r, "project")
			profile.Project = &project
		}
		if r.Intn(2) == 0 {
			location := randomToken(r, "location")
			profile.Location = &location
		}
		name := randomToken(r, "profile")
		clearKey := r.Intn(2) == 0
		var body map[string]any
		conn := controlledConnection(t, func(w http.ResponseWriter, request *http.Request) {
			data, _ := io.ReadAll(request.Body)
			if err := json.Unmarshal(data, &body); err != nil {
				t.Errorf("body %s: %v", data, err)
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(testwire.SettingsChange("providers", map[string]any{"default_profile": nil, "profiles": map[string]any{}}))
		})
		save := SaveProvider
		if clearKey {
			save = func(ctx context.Context, conn *Connection, name string, profile config.Settings, etag string) error {
				return SaveSignedInProvider(ctx, conn, name, profile, etag, false)
			}
		}
		// The body is the record; the fixture's change document is generic.
		_ = save(t.Context(), conn, name, profile, `"providers-1"`)
		profiles, ok := body["profiles"].(map[string]any)
		if !ok {
			t.Fatalf("case %d: body %v has no profiles", i, body)
		}
		patch, ok := profiles[name].(map[string]any)
		if !ok {
			t.Fatalf("case %d: body %v has no profile %q", i, body, name)
		}
		want := map[string]any{
			"extension": profile.Extension, "protocol": profile.Protocol, "model": profile.Model,
			"endpoint": nullableText(profile.BaseURL), "effort": nullableText(valueOf(profile.Effort)),
			"image_edge": nullableNumber(profile.ImageEdge), "account_id": nullableText(valueOf(profile.AccountID)),
			"project": nullableText(valueOf(profile.Project)), "location": nullableText(valueOf(profile.Location)),
			"account_ids": nullableList(profile.AccountIDs),
		}
		if profile.API != "" {
			want["api"] = profile.API
		}
		if profile.Rotation != "" {
			want["rotation"] = profile.Rotation
		}
		switch {
		case profile.APIKey != "":
			want["api_key"] = profile.APIKey
		case clearKey:
			want["api_key"] = nil
		}
		for field, expected := range want {
			got, present := patch[field]
			if !present {
				t.Fatalf("case %d: %s missing from %v", i, field, patch)
			}
			if jsonOf(got) != jsonOf(expected) {
				t.Fatalf("case %d: %s = %s, want %s (%v)", i, field, jsonOf(got), jsonOf(expected), patch)
			}
		}
		for field := range patch {
			if _, wanted := want[field]; !wanted {
				t.Fatalf("case %d: unexpected field %q in %v", i, field, patch)
			}
		}
	}
}

func valueOf(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func nullableText(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func nullableNumber(value *int) any {
	if value == nil {
		return nil
	}
	return float64(*value)
}

func nullableList(values []string) any {
	if values == nil {
		return nil
	}
	result := make([]any, len(values))
	for n, value := range values {
		result[n] = value
	}
	return result
}

func jsonOf(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		return "unmarshalable"
	}
	return string(data)
}

// TestPropProviderProfileDecode checks that a saved profile's every wire field
// reaches its own settings field, with a distinct value in each.
func TestPropProviderProfileDecode(t *testing.T) {
	r := rand.New(rand.NewSource(9))
	for i := 0; i < 100; i++ {
		name := randomToken(r, "profile")
		profile := map[string]any{
			"extension":   randomToken(r, "extension"),
			"api":         oneOf(r, "messages", "converse"),
			"endpoint":    randomToken(r, "endpoint"),
			"model":       randomToken(r, "model"),
			"protocol":    oneOf(r, "responses", "chat_completions"),
			"effort":      randomToken(r, "effort"),
			"image_edge":  r.Intn(4095) + 1,
			"account_id":  randomToken(r, "account"),
			"account_ids": []any{randomToken(r, "one"), randomToken(r, "two")},
			"rotation":    oneOf(r, "failover", "spread", "first"),
			"project":     randomToken(r, "project"),
			"location":    randomToken(r, "location"),
			"has_key":     r.Intn(2) == 0,
		}
		enabled := r.Intn(2) == 0
		profile["enabled"] = enabled
		conn := controlledConnection(t, func(w http.ResponseWriter, _ *http.Request) {
			groups := map[string]any{}
			for _, group := range []string{"providers", "mcp", "extensions", "extension_settings", "capabilities", "models", "ui"} {
				groups[group] = map[string]any{"url": "/settings?group=" + group, "etag": `"` + group + `-1"`}
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"providers":          map[string]any{"default_profile": name, "profiles": map[string]any{name: profile}},
				"group_resources":    groups,
				"mcp":                map[string]any{"definitions": map[string]any{}},
				"extensions":         map[string]any{"defaults": map[string]bool{}},
				"extension_settings": map[string]any{"sections": []any{}},
				"capabilities":       map[string]any{"preferences": map[string]bool{}},
				"models":             map[string]any{"raised_caps": map[string]bool{}, "compact_at": map[string]int{}, "cache_ttl_priors": []any{}},
				"ui":                 map[string]any{"thinking": false, "tools": false, "dismissed_notices": []string{}, "web_allow": []string{}},
			})
		})
		saved, err := ProviderProfiles(t.Context(), conn)
		if err != nil {
			t.Fatalf("case %d: %v", i, err)
		}
		got := saved.Providers[name]
		fail := func(field string, actual, expected any) {
			t.Fatalf("case %d: %s = %v, want %v", i, field, actual, expected)
		}
		if saved.Active != name {
			fail("active profile", saved.Active, name)
		}
		if got.ProfileName != name || got.Extension != profile["extension"] || got.API != profile["api"] ||
			got.BaseURL != profile["endpoint"] || got.Model != profile["model"] || got.Protocol != profile["protocol"] ||
			got.Rotation != profile["rotation"] {
			fail("profile", got, profile)
		}
		if got.Effort == nil || *got.Effort != profile["effort"] {
			fail("effort", got.Effort, profile["effort"])
		}
		if got.ImageEdge == nil || *got.ImageEdge != profile["image_edge"] {
			fail("image edge", got.ImageEdge, profile["image_edge"])
		}
		if got.AccountID == nil || *got.AccountID != profile["account_id"] {
			fail("account id", got.AccountID, profile["account_id"])
		}
		if len(got.AccountIDs) != 2 || got.AccountIDs[0] != profile["account_ids"].([]any)[0] || got.AccountIDs[1] != profile["account_ids"].([]any)[1] {
			fail("account ids", got.AccountIDs, profile["account_ids"])
		}
		if got.Project == nil || *got.Project != profile["project"] {
			fail("project", got.Project, profile["project"])
		}
		if got.Location == nil || *got.Location != profile["location"] {
			fail("location", got.Location, profile["location"])
		}
		if got.HasKey != profile["has_key"] || got.IsEnabled() != enabled {
			fail("presence", got, profile)
		}

	}
}
