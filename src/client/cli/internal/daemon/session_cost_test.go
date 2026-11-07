package daemon

import (
	"albedo/cli/internal/daemon/protocol"
	"encoding/json"
	"testing"
)

func TestSessionCostUsageDecode(t *testing.T) {
	for _, raw := range []string{`{"session_cost_usd":1.25}`, `{"session_cost_usd":0}`, `{"session_cost_usd":null}`, `{}`} {
		var wire protocol.Usage
		if err := json.Unmarshal([]byte(raw), &wire); err != nil {
			t.Fatal(err)
		}
		got := usageValue(wire)
		if got.SessionCostUSD != wire.SessionCostUsd {
			t.Fatal(raw)
		}
	}
}
