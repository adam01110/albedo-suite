package daemon

import (
	"albedo/cli/internal/daemon/protocol"
	"encoding/json"
	"strconv"
	"testing"
)

func TestSessionCostUsageDecode(t *testing.T) {
	for raw, want := range map[string]string{`{"session_cost_usd":1.25}`: "1.25", `{"session_cost_usd":0}`: "0", `{"session_cost_usd":null}`: "nil", `{}`: "nil"} {
		var wire protocol.Usage
		if err := json.Unmarshal([]byte(raw), &wire); err != nil {
			t.Fatal(err)
		}
		got := "nil"
		if cost := usageValue(wire).SessionCostUSD; cost != nil {
			got = strconv.FormatFloat(*cost, 'g', -1, 64)
		}
		if got != want {
			t.Fatalf("%s decoded as %s, want %s", raw, got, want)
		}
	}
}
