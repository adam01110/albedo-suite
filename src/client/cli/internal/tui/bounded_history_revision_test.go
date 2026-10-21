package tui

import "testing"

func TestBoundedHistoryRevision(t *testing.T) {
	h := NewBoundedHistory(1, 1024*1024)
	changed := func(name string, mutate func()) {
		t.Helper()
		before := h.revision
		mutate()
		if h.revision <= before {
			t.Fatalf("%s did not advance revision", name)
		}
	}
	changed("append", func() { h.Append(HistoryEntry{ID: "a"}) })
	changed("replace", func() { h.Replace(HistoryEntry{ID: "a", Text: "new"}) })
	changed("prepend", func() { h.Prepend([]HistoryEntry{{ID: "b"}}) })
	changed("trim", h.Trim)
	changed("clear", h.Clear)
	changed("append live", func() { h.Append(HistoryEntry{MessageID: "live"}) })
	changed("retire live", func() { h.retireLive(nil, true) })
	before := h.revision
	h.Replace(HistoryEntry{ID: "missing"})
	h.Prepend(nil)
	h.Trim()
	h.retireLive(nil, true)
	if h.revision != before {
		t.Fatal("no-op invalidated selection")
	}
}
