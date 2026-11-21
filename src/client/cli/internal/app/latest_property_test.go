// Property test for `albedo resume` without an ID: the session it reopens must
// be the documented newest-activity one in the current workspace.
package app

import (
	"fmt"
	"math/rand"
	"slices"
	"strings"
	"testing"

	"albedo/cli/internal/daemon"
)

// referenceLatest is the documented rule written as a filter plus a stable sort
// by activity, so it shares no loop structure with latestSessionIn.
func referenceLatest(sessions []daemon.Session, workspace string) (string, bool) {
	var candidates []daemon.Session
	for _, session := range sessions {
		if session.Archived || session.Workspace != workspace {
			continue
		}
		candidates = append(candidates, session)
	}
	if len(candidates) == 0 {
		return "", false
	}
	slices.SortStableFunc(candidates, func(first, second daemon.Session) int {
		return activity(second) - activity(first)
	})
	return candidates[0].ID, true
}

func activity(session daemon.Session) int {
	if session.LastAssistantAt == nil {
		return 0
	}
	return int(*session.LastAssistantAt)
}

// TestPropLatestSessionInWorkspace checks selection over generated session
// lists: archived and foreign sessions never win, and the newest activity wins
// with the list's own order breaking ties.
func TestPropLatestSessionInWorkspace(t *testing.T) {
	workspaces := []string{"/work", "/elsewhere"}
	r := rand.New(rand.NewSource(4))
	for i := 0; i < 500; i++ {
		var sessions []daemon.Session
		for n := r.Intn(9); n > 0; n-- {
			session := daemon.Session{
				ID:        fmt.Sprintf("session-%d-%d", i, n),
				Workspace: workspaces[r.Intn(len(workspaces))],
				Archived:  r.Intn(4) == 0,
			}
			if r.Intn(3) != 0 {
				moment := int64(r.Intn(4))
				session.LastAssistantAt = &moment
			}
			sessions = append(sessions, session)
		}
		workspace := workspaces[r.Intn(len(workspaces))]
		wantID, wantFound := referenceLatest(sessions, workspace)
		got, found := latestSessionIn(sessions, workspace)
		if found != wantFound {
			t.Fatalf("case %d: found = %v, want %v for %v in %s", i, found, wantFound, sessions, workspace)
		}
		if found && got.ID != wantID {
			t.Fatalf("case %d: selected %q, want %q for %v in %s", i, got.ID, wantID, sessions, workspace)
		}
	}
}

// TestPropResolveSessionID checks that a full ID or a unique prefix resolves to
// exactly that session, and that an ambiguous or missing prefix is refused.
func TestPropResolveSessionID(t *testing.T) {
	r := rand.New(rand.NewSource(10))
	for i := 0; i < 500; i++ {
		var sessions []daemon.Session
		var ids []string
		for n := r.Intn(5); n > 0; n-- {
			id := fmt.Sprintf("019c%s", randomHex(r, 3+r.Intn(4)))
			if slices.Contains(ids, id) {
				continue
			}
			ids = append(ids, id)
			sessions = append(sessions, daemon.Session{ID: id})
		}
		query := "019c" + randomHex(r, 1+r.Intn(6))
		if len(ids) > 0 && r.Intn(2) == 0 {
			source := ids[r.Intn(len(ids))]
			query = source[:1+r.Intn(len(source))]
		}
		var matches []string
		for _, id := range ids {
			if strings.HasPrefix(id, query) {
				matches = append(matches, id)
			}
		}
		resolved, err := resolveSessionID(query, sessions)
		switch {
		case len(matches) == 1 && (err != nil || resolved != matches[0]):
			t.Fatalf("case %d: %q over %v resolved %q, %v; want %q", i, query, ids, resolved, err, matches[0])
		case len(matches) != 1 && err == nil:
			t.Fatalf("case %d: %q over %v resolved %q with %d matches", i, query, ids, resolved, len(matches))
		}
	}
}

func randomHex(r *rand.Rand, length int) string {
	const digits = "0123456789abcdef"
	var text strings.Builder
	for range length {
		text.WriteByte(digits[r.Intn(len(digits))])
	}
	return text.String()
}
