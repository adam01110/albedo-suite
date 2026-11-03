package daemon

import (
	"encoding/json"
	"strings"
	"testing"

	"albedo/cli/internal/daemon/protocol"
)

func TestQuestionsOptionsUseDisplayedResource(t *testing.T) {
	raw := `{"id":"1","text":"preview","badge":"pending","tone":"warning","detail":"not the source of options","resource":{"url":"/extensions/questions/items/1?session_id=s","etag":"seen","value":{"id":"1","session_id":"s","question":"Where?","options":["staging","production"],"status":"pending"}}}`
	var wire protocol.PageRow
	if err := json.Unmarshal([]byte(raw), &wire); err != nil {
		t.Fatal(err)
	}
	row := pageRowValue(wire)
	prompt, err := QuestionPromptForRow(&row, "s")
	if err != nil || len(prompt.Options) != 2 || prompt.Options[1] != "production" {
		t.Fatalf("options=%v err=%v", prompt, err)
	}
	if _, err := QuestionPromptForRow(&row, "other"); err == nil {
		t.Fatal("foreign resource accepted")
	}
	if _, err := QuestionPromptForRow(nil, "s"); err == nil {
		t.Fatal("missing resource accepted")
	}
	for _, value := range []string{
		`{"id":"1","session_id":"s","question":"Where?","options":null,"status":"pending"}`,
		`{"id":"1","session_id":"s","question":"Where?","options":[],"status":"answered"}`,
		`{"id":"2","session_id":"s","question":"Where?","options":[],"status":"pending"}`,
		`{"id":"1","session_id":"s","question":"Where?","status":"pending"}`,
		`{"id":"1","session_id":"s","question":"Where?","options":["` + strings.Repeat("x", 513) + `"],"status":"pending"}`,
	} {
		wire.Resource.Value = json.RawMessage(value)
		row = pageRowValue(wire)
		if _, err := QuestionPromptForRow(&row, "s"); err == nil {
			t.Errorf("invalid question accepted: %s", value)
		}
	}
	wire.Resource.Value = json.RawMessage(`{"id":"1","session_id":"s","question":"Where?","options":[],"status":"pending"}`)
	row = pageRowValue(wire)
	if prompt, err := QuestionPromptForRow(&row, "s"); err != nil || len(prompt.Options) != 0 {
		t.Fatalf("no-options question: %v %v", prompt, err)
	}
}
