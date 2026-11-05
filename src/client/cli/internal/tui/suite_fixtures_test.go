package tui

import (
	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	tea "charm.land/bubbletea/v2"
	"encoding/json"
	"github.com/charmbracelet/x/ansi"
	"strings"
	"testing"
)

func navigationKey(r rune) tea.KeyPressMsg {
	return tea.KeyPressMsg{Code: r, Text: string(r)}
}

func pageAt(width, height int, doc *PageDocument) PageViewModel {
	m := NewPageViewModel(nil, "s", "/paperclips")
	m.SetSize(width, height)
	m.setDoc(doc)
	m.Busy = false
	return m
}

func detailFixture() *PageDocument {
	return &PageDocument{
		Title:   "paperclips",
		Summary: "1 open · 1 resolved",
		Empty:   "nothing vented yet",
		Rows: []PageRow{{
			ID:     "1",
			Text:   "ruff not on PATH",
			Badge:  "open",
			Tone:   ToneWarning,
			Detail: "ruff is missing from PATH; the binary lives in pre-commit's env.\n\nsuggestion: document the canonical invocation",
		}, {
			ID:    "2",
			Text:  "stale binary",
			Badge: "resolved",
			Tone:  ToneMuted,
		}},
	}
}

func contextFixture(t *testing.T) ContextInspectorModel {
	t.Helper()
	m := NewContextInspectorModel(nil, "s")
	m.SetSize(120, 30)
	m, _ = m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Snapshot: &daemon.ContextSnapshot{
		State: "ready", Provider: "claude", Model: "claude-x", Protocol: "messages",
		Sections: []daemon.ContextSection{
			{ID: "history", Label: "History", Kind: "history", Source: "transcript", Pages: 2, ByteCount: 4096, Preview: "user: hello"},
			{ID: "system", Label: "System", Kind: "system", Source: "instructions"},
		},
	}})
	if m.Snapshot == nil || len(m.shown) != 2 {
		t.Fatal("fixture snapshot did not load")
	}
	return m
}

func agentsFixture(t *testing.T) AgentsViewModel {
	t.Helper()
	m := NewAgentsViewModel(nil, "lead")
	m.Gen = 1
	m.streamReady = true
	m.SetSize(120, 30)
	lead := "lead"
	coder := "coder"
	m, _ = m.Update(agentsSnapshotMsg{Gen: 1, Root: "lead", Nodes: []daemon.AgentNode{
		{Session: daemon.Session{ID: "lead", Title: "lead", Model: "gpt-6-luna"}, Name: "lead", Running: true},
		{Session: daemon.Session{ID: "scout", Model: "gpt-6-luna"}, Parent: &lead, Name: "scout", Depth: 1},
		{Session: daemon.Session{ID: "coder", Model: "gpt-6-luna"}, Parent: &lead, Name: "coder", Depth: 1, Running: true},
		{Session: daemon.Session{ID: "tests", Model: "gpt-6-luna"}, Parent: &coder, Name: "tests", Depth: 2},
	}})
	return m
}

func loadedPicker(t *testing.T) ModelPickerModel {
	t.Helper()
	m := NewModelPickerModel(nil, config.Profiles{Active: "work", Providers: map[string]config.Settings{"work": {Extension: "openai", BaseURL: "https://work.example/v1", Model: "gpt-5", Protocol: "responses"}, "codex": {Extension: "codex", Model: "gpt-5-codex", Protocol: "responses"}}}, "gpt-5", "work", "high")
	m.SetSize(120, 30)
	m, _ = m.Update(modelCatalogLoadedMsg{Generation: m.Generation, Profile: "work", Models: []daemon.Model{
		{ID: "gpt-4.1", Context: 1_047_576},
		{ID: "gpt-5", Efforts: []string{"low", "medium", "high"}, Context: 400_000, Output: 128_000, Input: []string{"text", "image"}},
		{ID: "o4-mini", Efforts: []string{"low", "medium"}},
	}})
	m, _ = m.Update(modelCatalogLoadedMsg{Generation: m.Generation, Profile: "codex", Models: []daemon.Model{
		{ID: "gpt-5-codex", Efforts: []string{"minimal", "low", "medium", "high"}},
	}})
	return m
}

func mcpPage(t *testing.T) CapabilityPageModel {
	t.Helper()
	m := NewCapabilityPageModel(nil, "s", "mcp")
	m.SetSize(100, 30)
	m.Loading = false
	m.ExtensionEnabled = true
	return m
}

func ctrl(m CapabilityPageModel, k rune) CapabilityPageModel {
	m, _ = m.Update(tea.KeyPressMsg{Code: k, Mod: tea.ModCtrl})
	return m
}

func key(m CapabilityPageModel, k rune) CapabilityPageModel {
	m, _ = m.Update(tea.KeyPressMsg{Code: k})
	return m
}

func loadedConfigPage(t *testing.T, conn *daemon.Connection) ConfigPageModel {
	t.Helper()
	m := NewConfigPageModel(conn)
	m.SetSize(100, 30)
	m, _ = m.Update(configLoadedMsg{Gen: m.Generation, Settings: daemon.ExtensionSettings{Sections: configSections(), ETag: `"settings-a"`}})
	return m
}

func configSections() []daemon.ExtensionSettingsSection {
	return []daemon.ExtensionSettingsSection{
		{Name: "rolling", Label: "Rolling summary compaction", Category: daemon.SettingContext, Description: "Incremental summary", Fields: []daemon.ExtensionSetting{
			{Key: "triggerPercent", Label: "Trigger", Description: "Percent of the window at which a compaction runs.", Kind: daemon.SettingInteger, Minimum: new(int64(1)), Maximum: new(int64(99)), Default: daemon.SettingValue{Number: new(int64(80))}, Saved: daemon.SettingValue{Number: new(int64(70))}},
		}},
		{Name: "exa", Label: "Exa web search", Category: daemon.SettingWebSearch, Description: "Search through exa", Fields: []daemon.ExtensionSetting{
			{Key: "endpoint", Label: "Endpoint", Description: "Base URL of the exa API.", Kind: daemon.SettingText, Default: daemon.SettingValue{Text: new("https://api.exa.ai")}},
		}},
	}
}

func mustJSON(t *testing.T, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func rowWith(t *testing.T, lines []string, text string) int {
	t.Helper()
	for i, line := range lines {
		if strings.Contains(ansi.Strip(line), text) {
			return i
		}
	}
	t.Fatalf("no row says %q", text)
	return -1
}
