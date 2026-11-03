package tui

import (
	"context"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

type zoxideTickMsg struct {
	Gen   int64
	Query string
}

type zoxideFoldersMsg struct {
	Gen   int64
	Query string
	Paths []string
}

// Only a colocated daemon can use this client's directory database.
func (m *FolderPicker) zoxideCmd() tea.Cmd {
	query := m.input.Value()
	if m.src == nil || !m.src.Local() || parseQuery(query).kind != queryRecent {
		return nil
	}
	if _, ok := m.zoxide[query]; ok {
		return nil
	}
	key := "zoxide:" + query
	if m.asked[key] {
		return nil
	}
	m.asked[key] = true
	gen := m.sessionsGeneration
	return useTick(m.Tick, 150*time.Millisecond, func(time.Time) tea.Msg {
		return zoxideTickMsg{Gen: gen, Query: query}
	})
}

func queryZoxide(ctx context.Context, query string) []string {
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	args := append([]string{"query", "--list", "--"}, strings.Fields(query)...)
	out, err := exec.CommandContext(ctx, "zoxide", args...).Output()
	if err != nil {
		return nil // Optional: missing binary, empty database or no matches.
	}
	var paths []string
	for _, p := range strings.Split(string(out), "\n") {
		if filepath.IsAbs(p) {
			paths = append(paths, p)
			if len(paths) == 200 {
				break
			}
		}
	}
	return paths
}

// Keep zoxide's ranking and avoid repeating session workspaces.
func (m *FolderPicker) appendZoxide(paths []string) {
	seen := make(map[string]bool, len(m.rows))
	for _, row := range m.rows {
		seen[row.path] = true
	}
	for _, p := range paths {
		if !seen[p] {
			m.rows = append(m.rows, folderRow{path: p, name: path.Base(p), recent: true, repo: true})
			seen[p] = true
		}
	}
}

// Existing relative directories win over database shortcuts.
func zoxideTarget(workspace, input string) string {
	if !filepath.IsAbs(workspace) || input == "" || input == "." || input == ".." || parseQuery(input).kind != queryRecent {
		return input
	}
	if info, err := os.Stat(filepath.Join(workspace, input)); err == nil && info.IsDir() {
		return input
	}
	if paths := queryZoxide(context.Background(), input); len(paths) > 0 {
		return paths[0]
	}
	return input
}

func recordZoxide(workspace string) {
	if !filepath.IsAbs(workspace) {
		return // Never write remote locations to the local database.
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = exec.CommandContext(ctx, "zoxide", "add", "--", workspace).Run()
}
