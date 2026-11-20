package daemon

import (
	"encoding/json"
	"fmt"
	"testing"

	"albedo/cli/internal/daemon/protocol"
)

func TestSessionToolCallsDecode(t *testing.T) {
	tool := `{"type":"tool","sequence":4,"data":{"entry_id":"9","tool_call_id":"call","progress_call_id":"progress","name":"python","arguments":{},"result":"ok","trace":null,"content_complete":true,"reference":null%s}}`
	for extra, want := range map[string]int{`,"session_tool_calls":112`: 112, `,"session_tool_calls":null`: -1, ``: -1} {
		event, err := decodeChatEvent(json.RawMessage(fmt.Sprintf(tool, extra)))
		if err != nil {
			t.Fatalf("%q: %v", extra, err)
		}
		if got := event.SessionToolCalls; (want < 0) != (got == nil) || got != nil && *got != want {
			t.Fatalf("%q: %v", extra, got)
		}
	}
	count := int64(111)
	if got := sessionValue(protocol.Session{SessionToolCalls: &count}).SessionToolCalls; got == nil || *got != 111 {
		t.Fatalf("session: %v", got)
	}
	if got := sessionValue(protocol.Session{}).SessionToolCalls; got != nil {
		t.Fatalf("absent session count: %v", *got)
	}
}
