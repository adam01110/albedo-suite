package tui

import (
	"albedo/cli/internal/daemon"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func usageSnapshot() *daemon.ContextSnapshot {
	window, trigger := 1_000_000, 800_000
	return &daemon.ContextSnapshot{
		State: "ready", SnapshotID: "snap", Model: "m", ContextWindowTokens: &window,
		Compaction: daemon.CompactionState{TriggerTokens: &trigger, Size: &daemon.Size{Tokens: 100_000}},
		Sections: []daemon.ContextSection{
			{ID: "instructions", Kind: "instructions", ByteCount: 10_000, Pages: 2},
			{ID: "history", Kind: "history", ByteCount: 89_000, Pages: 3},
			{ID: "tools", Kind: "tools", ByteCount: 1_000, Pages: 1},
		},
	}
}

func TestContextUsageSplitsTheMeasuredSizeBySectionBytes(t *testing.T) {
	u, ok := usageOf(usageSnapshot())
	if !ok {
		t.Fatal("ready snapshot gave no usage")
	}
	got := map[string]int{}
	sum := 0
	for _, p := range u.Parts {
		got[p.Label] = p.Tokens
		sum += p.Tokens
	}
	if sum != 100_000 || got["instructions"] != 10_000 || got["conversation"] != 89_000 || got["tools"] != 1_000 {
		t.Fatalf("parts = %v", got)
	}
	if u.Parts[0].Label != "instructions" || u.Parts[1].Label != "tools" || u.Parts[2].Label != "conversation" {
		t.Fatalf("parts out of order: %+v", u.Parts)
	}
	if _, ok := usageOf(&daemon.ContextSnapshot{State: "pending"}); ok {
		t.Fatal("pending snapshot gave usage")
	}
	snap := usageSnapshot()
	snap.Compaction.Size = nil
	if u, _ := usageOf(snap); !u.Estimated || u.Used != 25_000 {
		t.Fatalf("bytes estimate = %+v", u)
	}
}

func TestContextUsageCellsKeepSmallPartsAndMarkTheReserve(t *testing.T) {
	u, _ := usageOf(usageSnapshot())
	cells := u.cells(100)
	counts := map[int]int{}
	reserve := 0
	for _, c := range cells {
		switch {
		case c.used:
			counts[c.part]++
		case c.reserve:
			reserve++
		}
	}
	// tools is 0.1% of the window and still shows.
	if counts[0] != 1 || counts[1] != 1 || counts[2] != 9 {
		t.Fatalf("used cells = %v", counts)
	}
	if reserve != 20 {
		t.Fatalf("reserve cells = %d, want the 20%% past the trigger", reserve)
	}
	full := contextUsage{Window: 10, Used: 10, Parts: []contextPart{{Tokens: 1}, {Tokens: 1}, {Tokens: 8}}}
	if n := len(full.cells(3)); n != 3 {
		t.Fatalf("overflowing minimums gave %d cells", n)
	}
	if got := apportion(10, []int{1, 1, 1}); got[0]+got[1]+got[2] != 10 {
		t.Fatalf("apportion lost tokens: %v", got)
	}
}

func TestContextUsageBlockFitsItsBox(t *testing.T) {
	u, _ := usageOf(usageSnapshot())
	for _, size := range [][2]int{{118, 20}, {78, 12}, {40, 4}, {40, 1}} {
		block := u.block(size[0], size[1])
		if len(block) > size[1] {
			t.Fatalf("%v: %d rows", size, len(block))
		}
		for _, row := range block {
			if w := ansi.StringWidth(row); w > size[0] {
				t.Fatalf("%v: row is %d wide: %q", size, w, ansi.Strip(row))
			}
		}
	}
	plain := ansi.Strip(strings.Join(u.block(118, 20), "\n"))
	for _, want := range []string{"100k / 1m tokens · 10%", "▆", "conversation", "free", "past compaction", "200k"} {
		if !strings.Contains(plain, want) {
			t.Fatalf("missing %q:\n%s", want, plain)
		}
	}
}

// contextServer serves a snapshot whose sections come in pages.
func contextServer(t *testing.T, pages map[string][]string) *daemon.Connection {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/server" {
			fmt.Fprint(w, usageCapabilities)
			return
		}
		parts := strings.Split(r.URL.Path, "/")
		section := parts[len(parts)-1]
		var page int
		fmt.Sscan(r.URL.Query().Get("page"), &page)
		texts := pages[section]
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"snapshot_id": "snap", "section_id": section, "page": page, "page_count": len(texts),
			"text": texts[page], "omitted": map[bool]any{true: "image base64 payload", false: nil}[page == 1],
		})
	}))
	t.Cleanup(server.Close)
	conn, err := daemon.Attach(t.Context(), daemon.ConnectionSnapshot{Port: server.Listener.Addr().(*net.TCPAddr).Port, Token: "t", Version: daemon.ProtocolVersion}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(conn.HTTPClient().CloseIdleConnections)
	return conn
}

func TestContextReaderReadsTheWholeSection(t *testing.T) {
	conn := contextServer(t, map[string][]string{"history": {"[user]\nfirst half of a li", "ne\n\n[assistant]\nsecond", "\n\n[user]\nthird"}})
	m := NewContextInspectorModel(conn, "s")
	m.SetSize(100, 30)
	m, _ = m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Snapshot: usageSnapshot()})
	m.Cursor = 1
	m, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	if cmd == nil || m.Detail == nil {
		t.Fatal("enter did not open the section")
	}
	for cmd != nil {
		m, cmd = m.Update(cmd())
	}
	if m.Detail.Value == nil {
		t.Fatalf("section not loaded: %+v", m.Detail)
	}
	if got := m.Detail.Value.Content; got != "[user]\nfirst half of a line\n\n[assistant]\nsecond\n\n[user]\nthird" {
		t.Fatalf("pages were not joined in order: %q", got)
	}
	if m.Detail.Value.Omitted != "image base64 payload" {
		t.Fatalf("omitted = %q", m.Detail.Value.Omitted)
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "third") || strings.Contains(view, "page 1/") {
		t.Fatalf("reader did not show one document:\n%s", view)
	}
	before := m.Generation
	m, cmd = m.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	if cmd != nil || m.Generation != before {
		t.Fatal("arrows should no longer page")
	}
}

func TestContextInspectorReadsAPendingSnapshotAgain(t *testing.T) {
	m := NewContextInspectorModel(nil, "s")
	m.SetSize(100, 30)
	m, cmd := m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Snapshot: &daemon.ContextSnapshot{State: "pending", Reason: "preparing"}})
	if cmd == nil {
		t.Fatal("pending snapshot scheduled no retry")
	}
	m, cmd = m.Update(contextRetryMsg{Gen: m.Generation})
	if cmd == nil || !m.Loading {
		t.Fatal("retry did not read the snapshot again")
	}
	m, cmd = m.Update(contextSnapshotLoadedMsg{Gen: m.Generation, Snapshot: usageSnapshot()})
	if cmd != nil {
		t.Fatal("ready snapshot kept retrying")
	}
	if _, cmd = m.Update(contextRetryMsg{Gen: m.Generation - 1}); cmd != nil {
		t.Fatal("stale retry ran")
	}
}

func TestContextReaderShowsTheFirstPageAndFormatsOnlyWhatItShows(t *testing.T) {
	block := strings.Repeat("assistant: a line of the conversation\n", 40) + "\n"
	m := contextModel(100, 30)
	m.Cursor = 2
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnter})
	first := daemon.ContextPage{Content: strings.Repeat(block, 20), Pages: 3}
	m, cmd := m.Update(contextPageLoadedMsg{Gen: m.Generation, SectionID: "history", Data: &first})
	if cmd == nil {
		t.Fatal("the next page was not asked for")
	}
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "a line of the conversation") || !strings.Contains(view, "loading 1/3 pages") {
		t.Fatalf("first page not shown while the rest load:\n%s", view)
	}
	d := m.Detail
	if d.wrappedTo >= len(d.Value.Content) {
		t.Fatal("formatted the whole page for one screen")
	}
	for page := 1; page < 3; page++ {
		next := daemon.ContextPage{Content: strings.Repeat(block, 20), Page: page, Pages: 3}
		m, _ = m.Update(contextPageLoadedMsg{Gen: m.Generation, SectionID: "history", Page: page, Data: &next})
	}
	if !d.complete() || len(d.Value.Content) != 3*len(first.Content) {
		t.Fatal("pages were not appended in order")
	}
	m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyEnd})
	if !d.formatted() || d.Scroll == 0 || !strings.Contains(ansi.Strip(m.View()), "100%") {
		t.Fatalf("end did not reach the bottom: scroll %d of %d rows", d.Scroll, len(d.wrapped))
	}
}

func TestContextFormattingKeepsATagRunInOneBlock(t *testing.T) {
	content := "<skills>\n  <skill>\n    <name>nix</name>\n    <description>Use when a long\nline wraps.</description>\n  </skill>\n</skills>\n\nAfter the catalog."
	markdown := contextMarkdown(content)
	if n := strings.Count(markdown, "```text"); n != 1 {
		t.Fatalf("%d code blocks for one tag run:\n%s", n, markdown)
	}
	if !strings.Contains(markdown, "    <description>Use when a long\nline wraps.</description>") || !strings.Contains(markdown, "After the catalog.") {
		t.Fatalf("tag run lost its text:\n%s", markdown)
	}
}
