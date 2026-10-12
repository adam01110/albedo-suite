package app

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// PrepareOpen with Latest must select the newest session in the requested
// workspace, and refuse when that workspace has no session to resume.
func TestPrepareOpenLatestResumesNewestInWorkspace(t *testing.T) {
	older, newer := "2026-10-02T00:00:00Z", "2026-10-03T00:00:00Z"
	sessions := []map[string]any{
		testwire.Session("019c1234-5678-7000-8000-000000000001", testwire.GenerationA, 0),
		testwire.Session("019c1234-5678-7000-8000-000000000002", testwire.GenerationA, 0),
		testwire.Session("019c1234-5678-7000-8000-000000000003", testwire.GenerationA, 0),
	}
	sessions[0]["workspace"], sessions[0]["activity_at"] = "/work", older
	sessions[1]["workspace"], sessions[1]["activity_at"] = "/work", newer
	sessions[2]["workspace"], sessions[2]["activity_at"] = "/elsewhere", newer

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/sessions":
			items := make([]any, len(sessions))
			for i := range sessions {
				items[i] = sessions[i]
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"items": items, "next": nil})
		case strings.HasPrefix(r.URL.Path, "/sessions/"):
			id := strings.TrimPrefix(r.URL.Path, "/sessions/")
			for _, session := range sessions {
				if session["id"] == id {
					w.Header().Set("ETag", session["configuration_resource"].(map[string]any)["etag"].(string))
					_ = json.NewEncoder(w).Encode(session)
					return
				}
			}
			http.NotFound(w, r)
		case r.URL.Path == "/settings":
			settings := testwire.Settings()
			settings["providers"].(map[string]any)["default_profile"] = "work"
			_ = json.NewEncoder(w).Encode(settings)
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	connection := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	defer connection.HTTPClient().CloseIdleConnections()
	service := Service{Connect: func(context.Context) (*daemon.Connection, error) { return connection, nil }}

	prepared, err := service.PrepareOpen(t.Context(), OpenOptions{Workspace: "/work", Latest: true})
	if err != nil {
		t.Fatalf("latest resume: %v", err)
	}
	if prepared.Selected == nil || prepared.Selected.ID != sessions[1]["id"] {
		t.Fatalf("latest resume selected %+v, want the newest session in /work (%v)", prepared.Selected, sessions[1]["id"])
	}

	if _, err := service.PrepareOpen(t.Context(), OpenOptions{Workspace: "/empty", Latest: true}); err == nil || !strings.Contains(err.Error(), "no session has run in /empty") {
		t.Fatalf("latest resume without a session: %v", err)
	}
}

func TestLatestSessionInPicksNewestInWorkspace(t *testing.T) {
	old, recent := int64(100), int64(200)
	for _, scenario := range []struct {
		name      string
		sessions  []daemon.Session
		workspace string
		wantID    string
		wantFound bool
	}{
		{
			name: "newest in workspace",
			sessions: []daemon.Session{
				{ID: "a", Workspace: "/work", LastAssistantAt: &old},
				{ID: "b", Workspace: "/work", LastAssistantAt: &recent},
				{ID: "c", Workspace: "/work", LastAssistantAt: &old},
			},
			workspace: "/work", wantID: "b", wantFound: true,
		},
		{
			name: "other workspaces ignored",
			sessions: []daemon.Session{
				{ID: "other", Workspace: "/elsewhere", LastAssistantAt: &recent},
				{ID: "mine", Workspace: "/work", LastAssistantAt: &old},
			},
			workspace: "/work", wantID: "mine", wantFound: true,
		},
		{
			name: "archived ignored",
			sessions: []daemon.Session{
				{ID: "archived", Workspace: "/work", LastAssistantAt: &recent, Archived: true},
				{ID: "open", Workspace: "/work", LastAssistantAt: &old},
			},
			workspace: "/work", wantID: "open", wantFound: true,
		},
		{
			name: "no reply yet still resumes",
			sessions: []daemon.Session{
				{ID: "fresh", Workspace: "/work"},
			},
			workspace: "/work", wantID: "fresh", wantFound: true,
		},
		{
			name:      "nothing in workspace",
			sessions:  []daemon.Session{{ID: "other", Workspace: "/elsewhere", LastAssistantAt: &recent}},
			workspace: "/work", wantFound: false,
		},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			session, found := latestSessionIn(scenario.sessions, scenario.workspace)
			if found != scenario.wantFound || session.ID != scenario.wantID {
				t.Fatalf("latestSessionIn: id=%q found=%v, want id=%q found=%v", session.ID, found, scenario.wantID, scenario.wantFound)
			}
		})
	}
}
