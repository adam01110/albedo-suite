package daemon

import (
	"encoding/json"
	"testing"

	"albedo/cli/internal/daemon/protocol"
)

// The Zed browser sign-in publishes "confirming" while the identity waits for
// typed confirmation. The client must read that state like any other instead of
// refusing the login it is watching.
func TestZedLoginStateConfirming(t *testing.T) {
	payload := []byte(`{"id":"01a0fcea-2b00-7000-8000-000000000003",
		"provider":"zed",
		"url":"https://zed.dev/native_app_signin?native_app_port=1",
		"expires_at":"2026-10-02T14:15:00Z",
		"state":"confirming",
		"instructions":"Sign in at zed.dev, then confirm the account shown here.",
		"progress":"Zed account: github-user (user 42, organization org-42)",
		"accounts":[],
		"failure":null}`)
	var login protocol.Login
	if err := json.Unmarshal(payload, &login); err != nil {
		t.Fatalf("confirming login payload did not decode: %v", err)
	}
	status, err := loginValue(login, "identity-etag")
	if err != nil {
		t.Fatalf("confirming login state was refused: %v", err)
	}
	if status.State != "confirming" || status.ETag != "identity-etag" ||
		status.Message != "Zed account: github-user (user 42, organization org-42)" ||
		status.URL != "https://zed.dev/native_app_signin?native_app_port=1" {
		t.Fatalf("confirming status: %+v", status)
	}
	login.State = "invented"
	if _, err := loginValue(login, "identity-etag"); err == nil {
		t.Fatal("unknown login state was accepted")
	}
}
