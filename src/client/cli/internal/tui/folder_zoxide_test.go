package tui

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"

	"albedo/cli/internal/daemon"
)

func isolatedZoxide(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("zoxide"); err != nil {
		t.Fatal("zoxide is required for these integration tests")
	}
	root := t.TempDir()
	t.Setenv("_ZO_DATA_DIR", filepath.Join(root, "db"))
	t.Setenv("_ZO_EXCLUDE_DIRS", "")
	return root
}

func TestZoxideQueryAndMove(t *testing.T) {
	root := isolatedZoxide(t)
	dir := filepath.Join(root, "parent words", "project")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	moved := moveCmd(&fakeFolders{}, "id", root, dir, nil)().(FolderMovedMsg)
	if moved.Err != nil {
		t.Fatal(moved.Err)
	}
	if got := queryZoxide(t.Context(), "parent project"); !slices.Equal(got, []string{dir}) {
		t.Fatalf("query after successful move = %v", got)
	}
	if got := queryZoxide(t.Context(), "no-match"); len(got) != 0 {
		t.Fatal(got)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if got := queryZoxide(ctx, ""); len(got) != 0 {
		t.Fatal(got)
	}
}

type zoxideSource struct {
	fakeFolders
	remote bool
	fail   bool
}

func (f *zoxideSource) Local() bool { return !f.remote }
func (f *zoxideSource) Move(_ context.Context, id, workspace string) (daemon.Session, error) {
	if f.fail {
		return daemon.Session{}, errors.New("refused")
	}
	return daemon.Session{ID: id, Workspace: workspace}, nil
}

func TestZoxideMoveIsolation(t *testing.T) {
	root := isolatedZoxide(t)
	for _, src := range []*zoxideSource{{remote: true}, {fail: true}} {
		moveCmd(src, "id", root, root, nil)()
	}
	recordZoxide("host:/remote/path")
	if got := queryZoxide(t.Context(), ""); len(got) != 0 {
		t.Fatal(got)
	}
	m := NewFolderPicker(&zoxideSource{remote: true}, daemon.Session{Workspace: root}, nil)
	defer m.Close()
	if m.zoxideCmd() != nil {
		t.Fatal("remote daemon queried client database")
	}
}

func TestZoxidePicker(t *testing.T) {
	m := NewFolderPicker(&fakeFolders{}, daemon.Session{Workspace: "/current"}, nil)
	defer m.Close()
	m.sessionsLoading = false
	m, _ = m.Update(zoxideFoldersMsg{Gen: m.sessionsGeneration, Paths: []string{"/second", "/third", "/second", "/current"}})
	var paths []string
	for _, row := range m.rows {
		paths = append(paths, row.path)
	}
	if !slices.Equal(paths, []string{"/current", "/second", "/third"}) {
		t.Fatal(paths)
	}
	m, _ = m.Update(zoxideFoldersMsg{Gen: m.sessionsGeneration - 1, Paths: []string{"/stale"}})
	if slices.Contains(m.zoxide[""], "/stale") {
		t.Fatal("accepted stale result")
	}
	m.setQuery("./")
	if m.zoxideCmd() != nil {
		t.Fatal("path listing queried zoxide")
	}
	for _, row := range m.rows {
		if row.path == "/second" {
			t.Fatal("zoxide leaked into listing")
		}
	}
	m.asked["zoxide:old"] = true
	m, _ = m.Update(zoxideTickMsg{Gen: m.sessionsGeneration, Query: "old"})
	if m.asked["zoxide:old"] {
		t.Fatal("abandoned debounce blocked later lookup")
	}
}

func TestZoxideDirectShortcut(t *testing.T) {
	root := isolatedZoxide(t)
	destination := filepath.Join(root, "elsewhere", "shortcut")
	if err := os.MkdirAll(destination, 0700); err != nil {
		t.Fatal(err)
	}
	recordZoxide(destination)
	msg := moveCmd(&fakeFolders{}, "id", root, "shortcut", nil)().(FolderMovedMsg)
	if msg.Err != nil || msg.Workspace != destination {
		t.Fatalf("shortcut = %+v", msg)
	}
	local := filepath.Join(root, "shortcut")
	if err := os.Mkdir(local, 0700); err != nil {
		t.Fatal(err)
	}
	if got := zoxideTarget(root, "shortcut"); got != "shortcut" {
		t.Fatal(got)
	}
	for _, input := range []string{".", "..", "./shortcut", "/shortcut", "host:shortcut", "missing"} {
		if got := zoxideTarget(root, input); got != input {
			t.Fatalf("%q became %q", input, got)
		}
	}
	if got := zoxideTarget("host:/root", "shortcut"); got != "shortcut" {
		t.Fatal(got)
	}
}

func TestZoxideUnavailable(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	if got := queryZoxide(t.Context(), ""); len(got) != 0 {
		t.Fatal(got)
	}
	recordZoxide(t.TempDir())
}
