package app

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/testwire"
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"testing/quick"
	"time"
)

// Discovery suite: `resume` without an ID picks the session with the newest
// observed activity in the workspace (app/service.go, latestSessionIn and the
// Latest branch of PrepareOpen). The oracles below are written from the
// documented contract, not by calling the helpers under test.

// generatedSession is one list row: a workspace, whether it is archived, and
// its observed activity, if any.
type generatedSession struct {
	Workspace string
	Archived  bool
	Activity  *int64
}

// generatedWorld is a session list plus the workspace `resume` runs in.
type generatedWorld struct {
	Sessions  []generatedSession
	Workspace string
}

var generatedWorkspaces = []string{"/work", "/work/", "/other", "/work/sub", "", "host:/work"}

func (g generatedWorld) Generate(rnd *rand.Rand, size int) reflect.Value {
	world := generatedWorld{Workspace: generatedWorkspaces[rnd.Intn(len(generatedWorkspaces))]}
	for range rnd.Intn(7) {
		session := generatedSession{
			Workspace: generatedWorkspaces[rnd.Intn(len(generatedWorkspaces))],
			Archived:  rnd.Intn(4) == 0,
		}
		// A small activity domain makes ties, nil activity and equal-second
		// timestamps common instead of vanishingly rare.
		if rnd.Intn(4) != 0 {
			seconds := int64(1700000000 + rnd.Intn(3))
			session.Activity = &seconds
		}
		world.Sessions = append(world.Sessions, session)
	}
	return reflect.ValueOf(world)
}

func (g generatedWorld) String() string {
	var parts []string
	for _, session := range g.Sessions {
		activity := "nil"
		if session.Activity != nil {
			activity = fmt.Sprint(*session.Activity)
		}
		parts = append(parts, fmt.Sprintf("{%q archived=%v activity=%s}", session.Workspace, session.Archived, activity))
	}
	return fmt.Sprintf("workspace=%q sessions=[%s]", g.Workspace, strings.Join(parts, " "))
}

// worldSessions is the generated list as the daemon hands it to the app.
func worldSessions(world generatedWorld) []daemon.Session {
	sessions := make([]daemon.Session, len(world.Sessions))
	for i, generated := range world.Sessions {
		sessions[i] = daemon.Session{ID: fmt.Sprintf("session-%d", i), Workspace: generated.Workspace, Archived: generated.Archived, LastAssistantAt: generated.Activity}
	}
	return sessions
}

// candidateIndexes lists, independently of the code under test, the entries
// that are in the workspace and not archived.
func candidateIndexes(sessions []daemon.Session, workspace string) []int {
	var indexes []int
	for i := range sessions {
		if sessions[i].Workspace == workspace && !sessions[i].Archived {
			indexes = append(indexes, i)
		}
	}
	return indexes
}

// newestIndex is the earliest candidate with the greatest activity; the list
// arrives newest first, so an earlier entry wins a tie.
func newestIndex(sessions []daemon.Session, workspace string) (int, bool) {
	newest, found := -1, false
	for _, i := range candidateIndexes(sessions, workspace) {
		if !found || sessionSeconds(sessions[i]) > sessionSeconds(sessions[newest]) {
			newest, found = i, true
		}
	}
	return newest, found
}

func sessionSeconds(session daemon.Session) int64 {
	if session.LastAssistantAt == nil {
		return 0
	}
	return *session.LastAssistantAt
}

// TestPropLatestSessionInPicksNewestCandidate checks selection membership,
// existence, maximality and the earliest-wins tie-break against the reference
// model above.
func TestPropLatestSessionInPicksNewestCandidate(t *testing.T) {
	property := func(world generatedWorld) bool {
		sessions := worldSessions(world)
		got, found := latestSessionIn(sessions, world.Workspace)
		want, wantFound := newestIndex(sessions, world.Workspace)
		if found != wantFound {
			t.Errorf("%v: found=%v, want %v", world, found, wantFound)
			return false
		}
		if !wantFound {
			return true
		}
		if got.ID != sessions[want].ID {
			t.Errorf("%v: selected %q, want %q", world, got.ID, sessions[want].ID)
			return false
		}
		if got.Workspace != world.Workspace || got.Archived {
			t.Errorf("%v: selected a session outside the workspace or archived: %+v", world, got)
			return false
		}
		for i := range sessions {
			if sessionSeconds(sessions[i]) > sessionSeconds(got) && sessions[i].Workspace == world.Workspace && !sessions[i].Archived {
				t.Errorf("%v: selected %q with activity %d, but %q is newer (%d)", world, got.ID, sessionSeconds(got), sessions[i].ID, sessionSeconds(sessions[i]))
				return false
			}
		}
		return true
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 2000}); err != nil {
		t.Fatalf("latestSessionIn: %v", err)
	}
}

// wireSession renders a generated row as the daemon's list payload, so the
// property also covers decoding activity_at, workspace and archive flags.
func wireSession(index int, generated generatedSession) map[string]any {
	id := fmt.Sprintf("019c1234-5678-7000-8000-%012d", index)
	session := testwire.Session(id, testwire.GenerationA, 0)
	session["workspace"] = generated.Workspace
	session["location"] = map[string]any{"host": nil, "user": nil, "path": generated.Workspace, "label": nil}
	session["preferences"] = map[string]any{"pinned": false, "pin_order": nil, "archived": generated.Archived, "opens": 0}
	session["activity_at"] = nil
	if generated.Activity != nil {
		session["activity_at"] = time.Unix(*generated.Activity, 0).UTC().Format(time.RFC3339)
	}
	return session
}

// fakeDaemon serves one generated session list plus settings, and records
// whether the client tried to create a session.
func fakeDaemon(t *testing.T, rows []map[string]any, configured bool) (func(context.Context) (*daemon.Connection, error), func() int) {
	t.Helper()
	created := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/sessions":
			created++
			w.WriteHeader(http.StatusInternalServerError)
		case r.Method == http.MethodGet && r.URL.Path == "/sessions":
			items := make([]any, len(rows))
			for i := range rows {
				items[i] = rows[i]
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"items": items, "next": nil})
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/sessions/"):
			id := strings.TrimPrefix(r.URL.Path, "/sessions/")
			for _, row := range rows {
				if row["id"] == id {
					w.Header().Set("ETag", row["configuration_resource"].(map[string]any)["etag"].(string))
					_ = json.NewEncoder(w).Encode(row)
					return
				}
			}
			http.NotFound(w, r)
		case r.Method == http.MethodGet && r.URL.Path == "/settings":
			settings := testwire.Settings()
			if configured {
				settings["providers"].(map[string]any)["default_profile"] = "work"
			}
			_ = json.NewEncoder(w).Encode(settings)
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL)
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	connection := daemon.NewConnection(daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port}, nil)
	t.Cleanup(connection.HTTPClient().CloseIdleConnections)
	return func(context.Context) (*daemon.Connection, error) { return connection, nil }, func() int { return created }
}

// TestPropPrepareOpenLatestResumesNewestWithoutCreating drives the whole
// Latest path over the wire: the selection must be the newest row in the
// resolved workspace, a missing workspace must be refused, and a resume must
// never create a session.
func TestPropPrepareOpenLatestResumesNewestWithoutCreating(t *testing.T) {
	property := func(world generatedWorld) bool {
		rows := make([]map[string]any, len(world.Sessions))
		sessions := make([]daemon.Session, len(world.Sessions))
		for i, generated := range world.Sessions {
			rows[i] = wireSession(i, generated)
			sessions[i] = daemon.Session{ID: rows[i]["id"].(string), Workspace: generated.Workspace, Archived: generated.Archived, LastAssistantAt: generated.Activity}
		}
		connect, created := fakeDaemon(t, rows, true)
		service := Service{Connect: connect}

		prepared, err := service.PrepareOpen(t.Context(), OpenOptions{Workspace: world.Workspace, Latest: true})
		if got := created(); got != 0 {
			t.Errorf("%v: resume created %d sessions", world, got)
			return false
		}
		workspace := absoluteWorkspace(world.Workspace)
		want, wantFound := newestIndex(sessions, workspace)
		if !wantFound {
			if err == nil || !strings.Contains(err.Error(), "no session has run in "+workspace) {
				t.Errorf("%v: want a refusal naming %q, got %v", world, workspace, err)
				return false
			}
			if prepared.Selected != nil {
				t.Errorf("%v: refusal still selected %+v", world, prepared.Selected)
				return false
			}
			return true
		}
		if err != nil {
			t.Errorf("%v: want %q, got error %v", world, sessions[want].ID, err)
			return false
		}
		if prepared.Selected == nil || prepared.Selected.ID != sessions[want].ID {
			t.Errorf("%v: selected %+v, want %q", world, prepared.Selected, sessions[want].ID)
			return false
		}
		if prepared.Selected.Workspace != workspace || prepared.Selected.Archived {
			t.Errorf("%v: selected workspace %q archived %v, want %q and not archived", world, prepared.Selected.Workspace, prepared.Selected.Archived, workspace)
			return false
		}
		if prepared.Workspace != workspace {
			t.Errorf("%v: prepared workspace %q, want %q", world, prepared.Workspace, workspace)
			return false
		}
		// The returned list keeps every listed session and holds the selection.
		if len(prepared.Sessions) != len(rows) {
			t.Errorf("%v: prepared %d sessions, want %d", world, len(prepared.Sessions), len(rows))
			return false
		}
		index := -1
		for i := range prepared.Sessions {
			if prepared.Sessions[i].ID == prepared.Selected.ID {
				if index >= 0 {
					t.Errorf("%v: selection %q appears twice", world, prepared.Selected.ID)
					return false
				}
				index = i
			}
		}
		if index != want {
			t.Errorf("%v: selection sits at %d, want %d", world, index, want)
			return false
		}
		return true
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 300}); err != nil {
		t.Fatalf("PrepareOpen Latest: %v", err)
	}
}

// TestPropAbsoluteWorkspaceIsStableUnderCleaning checks the workspace key used
// for matching: absolute local paths clean to themselves, and remote locations
// pass through untouched.
func TestPropAbsoluteWorkspaceIsStableUnderCleaning(t *testing.T) {
	property := func(path string) bool {
		if !strings.HasPrefix(path, "/") {
			return true
		}
		cleaned := filepath.Clean(path)
		if filepath.Clean(absoluteWorkspace(path)) != cleaned {
			t.Errorf("absoluteWorkspace(%q) = %q, want it to clean to %q", path, absoluteWorkspace(path), cleaned)
			return false
		}
		return absoluteWorkspace(absoluteWorkspace(path)) == absoluteWorkspace(path)
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 2000}); err != nil {
		t.Fatalf("absoluteWorkspace: %v", err)
	}
}
