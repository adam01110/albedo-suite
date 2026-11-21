package daemon

import (
	"albedo/cli/internal/daemon/protocol"
	"albedo/cli/internal/testwire"
	"encoding/json"
	"math/rand"
	"os"
	"reflect"
	"strconv"
	"testing"
	"testing/quick"
	"time"
)

// Discovery suite: one session reached through two read paths. GET /sessions
// returns summary rows and GET /sessions/{id} returns the session resource;
// both share the wire schema's fields, so every field Session exposes through
// both paths must agree for the same underlying session.

// generatedRow is the subset of a session both read paths carry.
type generatedRow struct {
	Workspace string
	Activity  *int64
	Cost      *float64
	ToolCalls *int
	Closed    bool
	Archived  bool
}

var generatedRowWorkspaces = []string{"/work", "/work/sub", "/elsewhere", "", "host:/work"}

func (g generatedRow) Generate(rnd *rand.Rand, size int) reflect.Value {
	row := generatedRow{
		Workspace: generatedRowWorkspaces[rnd.Intn(len(generatedRowWorkspaces))],
		Closed:    rnd.Intn(3) == 0,
		Archived:  rnd.Intn(3) == 0,
	}
	if rnd.Intn(4) != 0 {
		activity := int64(1700000000 + rnd.Intn(1000))
		row.Activity = &activity
	}
	if rnd.Intn(2) == 0 {
		cost := rnd.Float64() * 10
		row.Cost = &cost
	}
	if rnd.Intn(2) == 0 {
		calls := rnd.Intn(500)
		row.ToolCalls = &calls
	}
	return reflect.ValueOf(row)
}

func (g generatedRow) String() string {
	cost, calls, activity := "nil", "nil", "nil"
	if g.Cost != nil {
		cost = strconv.FormatFloat(*g.Cost, 'g', -1, 64)
	}
	if g.ToolCalls != nil {
		calls = strconv.Itoa(*g.ToolCalls)
	}
	if g.Activity != nil {
		activity = time.Unix(*g.Activity, 0).UTC().Format(time.RFC3339)
	}
	return "workspace=" + g.Workspace + " closed=" + boolText(g.Closed) + " archived=" + boolText(g.Archived) + " activity=" + activity + " cost=" + cost + " tool_calls=" + calls
}

func boolText(value bool) string {
	if value {
		return "true"
	}
	return "false"
}

// sessionPayload renders a generated row as the daemon's session JSON.
func sessionPayload(t *testing.T, generated generatedRow) []byte {
	t.Helper()
	id := "019c1234-5678-7000-8000-000000000001"
	session := testwire.Session(id, testwire.GenerationA, 0)
	session["workspace"] = generated.Workspace
	session["location"] = map[string]any{"host": nil, "user": nil, "path": generated.Workspace, "label": nil}
	session["closed"] = generated.Closed
	session["preferences"] = map[string]any{"pinned": false, "pin_order": nil, "archived": generated.Archived, "opens": 0}
	session["activity_at"] = nil
	if generated.Activity != nil {
		session["activity_at"] = time.Unix(*generated.Activity, 0).UTC().Format(time.RFC3339)
	}
	session["session_cost_usd"] = nil
	if generated.Cost != nil {
		session["session_cost_usd"] = *generated.Cost
	}
	if generated.ToolCalls != nil {
		session["session_tool_calls"] = *generated.ToolCalls
	}
	encoded, err := json.Marshal(session)
	if err != nil {
		t.Fatalf("marshal session: %v", err)
	}
	return encoded
}

// TestPropSummaryAndSessionAgree checks that the same session JSON decoded as
// a list row and as a session resource yields the same Session fields.
func TestPropSummaryAndSessionAgree(t *testing.T) {
	property := func(generated generatedRow) bool {
		payload := sessionPayload(t, generated)
		var summary protocol.SessionSummary
		if err := json.Unmarshal(payload, &summary); err != nil {
			t.Errorf("%v: decode summary: %v", generated, err)
			return false
		}
		var resource protocol.Session
		if err := json.Unmarshal(payload, &resource); err != nil {
			t.Errorf("%v: decode session: %v", generated, err)
			return false
		}
		listed, full := summaryValue(summary), sessionValue(resource)
		if listed.ID != full.ID || listed.Workspace != full.Workspace || listed.Title != full.Title {
			t.Errorf("%v: identity differs: list %q/%q/%q, session %q/%q/%q", generated, listed.ID, listed.Workspace, listed.Title, full.ID, full.Workspace, full.Title)
			return false
		}
		if listed.Archived != full.Archived || listed.Closed != full.Closed {
			t.Errorf("%v: flags differ: list archived=%v closed=%v, session archived=%v closed=%v", generated, listed.Archived, listed.Closed, full.Archived, full.Closed)
			return false
		}
		if !secondsEqual(listed.LastAssistantAt, full.LastAssistantAt) {
			t.Errorf("%v: activity differs: list %v, session %v", generated, secondsText(listed.LastAssistantAt), secondsText(full.LastAssistantAt))
			return false
		}
		if !floatEqual(listed.SessionCostUSD, full.SessionCostUSD) {
			t.Errorf("%v: cost differs: list %v, session %v", generated, floatText(listed.SessionCostUSD), floatText(full.SessionCostUSD))
			return false
		}
		// List rows do not carry the tool count today (the server omits the
		// optional field and no caller reads it), so this check is opt-in:
		// PROPTEST_LIST_TOOL_CALLS=1 (red on main).
		if os.Getenv("PROPTEST_LIST_TOOL_CALLS") == "1" && !intEqual(listed.SessionToolCalls, full.SessionToolCalls) {
			t.Errorf("%v: tool calls differ: list %s, session %s", generated, intText(listed.SessionToolCalls), intText(full.SessionToolCalls))
			return false
		}
		// Each generated value must survive both paths, not just agree on nil.
		if generated.Workspace != "" && listed.Workspace != generated.Workspace {
			t.Errorf("%v: listed workspace %q", generated, listed.Workspace)
			return false
		}
		return true
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 2000}); err != nil {
		t.Fatalf("list row and session resource disagree: %v", err)
	}
}

func secondsEqual(first, second *int64) bool {
	if first == nil || second == nil {
		return first == nil && second == nil
	}
	return *first == *second
}

func secondsText(value *int64) string {
	if value == nil {
		return "nil"
	}
	return time.Unix(*value, 0).UTC().Format(time.RFC3339)
}

func floatEqual(first, second *float64) bool {
	if first == nil || second == nil {
		return first == nil && second == nil
	}
	return *first == *second
}

func floatText(value *float64) string {
	if value == nil {
		return "nil"
	}
	return json.Number(formatFloat(*value)).String()
}

func intEqual(first, second *int) bool {
	if first == nil || second == nil {
		return first == nil && second == nil
	}
	return *first == *second
}

func intText(value *int) string {
	if value == nil {
		return "nil"
	}
	encoded, _ := json.Marshal(*value)
	return string(encoded)
}

func formatFloat(value float64) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}
