package tui

// Property tests for the activity sidebar: generated event streams are
// replayed into the real chat model, whose rows and counts are compared with an
// independent reference model of tool calls.

import (
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	"encoding/json"
	"fmt"
	"math/rand"
	"reflect"
	"strings"
	"testing"
	"testing/quick"
	"time"
	"unicode"

	"github.com/charmbracelet/x/ansi"
)

// Intents a generated history is built from. Operands are resolved against the
// reference model, so every stream is one the daemon could send.
const (
	intentStart       = iota // a new call begins
	intentUpdate             // a live call reports a new label
	intentFinish             // a live call settles
	intentFinishAgain        // the last settled tool event is redelivered
	intentTerminal           // the turn ends: completed, error, interrupt or retry
	intentReset              // a reset with and without a snapshot
)

const (
	terminalCompleted = iota
	terminalInterrupted
	terminalFailed
	terminalRetry
)

type activityIntent struct {
	Kind  int
	Label string
}

type activityStream []activityIntent

// String abbreviates a stream for a failure message.
func (s activityStream) String() string {
	names := []string{"start", "update", "finish", "again", "terminal", "reset"}
	parts := make([]string, 0, len(s))
	for i, intent := range s {
		label := intent.Label
		if runes := []rune(label); len(runes) > 12 {
			label = string(runes[:12]) + "…"
		}
		parts = append(parts, fmt.Sprintf("%d:%s(%q)", i, names[intent.Kind], label))
	}
	return strings.Join(parts, " ")
}

// gnarlyLabels stress the row text with wide runes, controls and escapes.
var gnarlyLabels = []string{
	"plain label",
	"界界界界界",
	"e\u0301e\u0301 combining",
	"\x1b[31mred\x1b[0m",
	"\x1b]52;c;secret\a",
	"tab\there",
	"line\nbreak",
	"🎉 party 🎉",
	strings.Repeat("界", 200),
	strings.Repeat("a", 4096),
	"",
}

func (s activityStream) Generate(rnd *rand.Rand, size int) reflect.Value {
	length := rnd.Intn(size + 1)
	stream := make(activityStream, 0, length)
	for range length {
		intent := activityIntent{Kind: rnd.Intn(6)}
		if rnd.Intn(2) == 0 {
			intent.Label = gnarlyLabels[rnd.Intn(len(gnarlyLabels))]
		}
		stream = append(stream, intent)
	}
	return reflect.ValueOf(stream)
}

// settledTool records one settled tool entry so a redelivery can name it.
type settledTool struct {
	call    int
	label   string
	entryID string
}

// activityState is the reference model of what the sidebar should show.
type activityState struct {
	live     []int          // call ids in flight, oldest first
	labels   map[int]string // the latest label of each live call
	entry    map[int]string // the transcript entry that settled each call
	finished int            // settled calls since the last reset
	settled  []settledTool  // settled entries still in the loaded history
	ended    bool           // the turn ended and nothing new started
	running  bool
	idle     bool
	stopped  bool
	failed   bool
	// remainder is the unfinished count a turn boundary reported.
	remainder int
	// recounts marks the known turn-boundary count gap.
	recounts bool
	nextCall int
}

func newActivityState() *activityState {
	return &activityState{labels: map[int]string{}, entry: map[int]string{}}
}

func (st *activityState) start(call int, label string) {
	st.live = append(st.live, call)
	st.labels[call] = label
	st.ended, st.running, st.idle, st.remainder = false, true, false, 0
}

func (st *activityState) finish(call int, label string) {
	st.finished++
	st.live = dropCall(st.live, call)
	st.settled = append(st.settled, settledTool{call: call, label: label, entryID: st.entry[call]})
}

func (st *activityState) terminal(kind int) {
	if len(st.live) > 0 {
		// The turn boundary leaves these calls unfinished: the documented
		// total counts each of them, the sidebar's total counts one.
		st.recounts = true
		st.remainder = len(st.live)
		st.live = nil
	}
	st.ended = true
	switch kind {
	case terminalInterrupted:
		st.running, st.idle, st.stopped = false, true, true
	case terminalFailed:
		st.running, st.idle, st.failed = false, true, true
	}
}

func (st *activityState) reset(withSnapshot bool) {
	st.live, st.finished, st.settled, st.remainder = nil, 0, nil, 0
	st.labels, st.entry = map[int]string{}, map[int]string{}
	st.ended = !withSnapshot
	// A reset drops the turn's outcome flags, which the next message restores.
	st.stopped, st.failed = false, false
	if withSnapshot {
		// A snapshot replaces the status with the one it carried.
		st.running, st.idle = false, false
	}
}

// liveState is what makes the sidebar show live rows instead of settled ones.
func (st *activityState) liveState() bool {
	return st.running && !st.idle && !st.stopped && !st.failed && !st.ended
}

func (st *activityState) count() int {
	pending := len(st.live)
	if pending == 0 && (st.remainder > 0 || st.liveState()) {
		pending = 1
	}
	return st.finished + pending
}

func dropCall(live []int, call int) []int {
	out := live[:0]
	for _, candidate := range live {
		if candidate != call {
			out = append(out, candidate)
		}
	}
	return out
}

// propModel is a chat model with a fixed size and no daemon session totals.
func propModel(t *testing.T) ChatModel {
	t.Helper()
	m := newTestChatModel(t, &daemon.Session{ID: "activity-prop"})
	m.SetSize(120, 32)
	return m
}

func propEvent(m *ChatModel, evt daemon.StreamEvent) {
	*m, _ = m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: evt})
}

// propToolEvent sends a tool event without the daemon's session total, the way
// a daemon that does not report one does.
func propToolEvent(m *ChatModel, evt daemon.StreamEvent) {
	evt.SessionToolCalls = nil
	propEvent(m, evt)
}

// replay applies one generated intent to the model and the reference state.
func replay(m *ChatModel, st *activityState, intent activityIntent, index int, rnd *rand.Rand) {
	label := intent.Label
	switch intent.Kind {
	case intentStart:
		call := st.nextCall
		st.nextCall++
		entryID := fmt.Sprint("entry", call)
		st.entry[call] = entryID
		propEvent(m, daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{
			CallID: fmt.Sprint("call", call), Name: "python", Phase: "running", Title: label,
		}})
		st.start(call, label)
	case intentUpdate:
		if len(st.live) == 0 {
			return
		}
		call := st.live[rnd.Intn(len(st.live))]
		propEvent(m, daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{
			CallID: fmt.Sprint("call", call), Name: "python", Phase: "running", Title: label,
		}})
		// A new label makes the call the most recent activity.
		st.live = append(dropCall(st.live, call), call)
		st.labels[call] = label
	case intentFinish:
		if len(st.live) == 0 {
			return
		}
		call := st.live[rnd.Intn(len(st.live))]
		propEvent(m, finishEvent(call, st.entry[call], label))
		st.finish(call, label)
	case intentFinishAgain:
		if len(st.settled) == 0 {
			return
		}
		last := st.settled[len(st.settled)-1]
		propToolEvent(m, finishEvent(last.call, last.entryID, last.label))
	case intentTerminal:
		evt := daemon.StreamEvent{Type: daemon.EventTurnCompleted}
		kind := index % 4
		switch kind {
		case terminalInterrupted:
			evt.Type = daemon.EventInterrupted
		case terminalFailed:
			evt.Type = daemon.EventError
		case terminalRetry:
			evt.Type = daemon.EventRetry
		}
		propEvent(m, evt)
		st.terminal(kind)
	case intentReset:
		evt := daemon.StreamEvent{Type: daemon.EventReset}
		withSnapshot := index%2 == 0
		if withSnapshot {
			evt.Snapshot = &daemon.Session{ID: "activity-prop"}
		}
		propEvent(m, evt)
		st.reset(withSnapshot)
	}
}

func finishEvent(call int, entryID, label string) daemon.StreamEvent {
	return daemon.StreamEvent{Type: daemon.EventTool, EntryID: entryID,
		ProgressCallID: fmt.Sprint("call", call), ToolName: "python", ToolTitle: label,
		ToolResult: `{"status":"ok"}`}
}

// playStream replays a generated stream and returns the resulting model beside
// the reference state.
func playStream(t *testing.T, stream activityStream) (ChatModel, *activityState) {
	t.Helper()
	m := propModel(t)
	st := newActivityState()
	rnd := rand.New(rand.NewSource(99))
	for index, intent := range stream {
		replay(&m, st, intent, index, rnd)
	}
	return m, st
}

// propOneLine is the one-row form of a label, written out here rather than
// borrowed from the production helper the sidebar uses.
func propOneLine(text string) string {
	return strings.Join(strings.Fields(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, text)), " ")
}

// propLabel is the row text a tool name and title produce. A title with no
// visible text falls back to the tool name.
func propLabel(name, title string) string {
	for _, label := range []string{title, name} {
		if text := propOneLine(ansi.Strip(label)); text != "" {
			return ansi.Truncate(text, 160, "…")
		}
	}
	return "tool"
}

// activeLabels are the live-call rows of the sidebar, without the overflow row.
func activeLabels(rows []PageRow) []string {
	var labels []string
	for _, row := range rows {
		if row.Tone == ToneActive && !strings.HasPrefix(row.Text, "+") {
			labels = append(labels, row.Text)
		}
	}
	return labels
}

// TestPropActivityLiveRowsMatchReference checks that live rows show each
// in-flight call once, most recent first, at most three of them, that the
// overflow row counts the rest, and that a settled call never shows as running.
func TestPropActivityLiveRowsMatchReference(t *testing.T) {
	check := func(stream activityStream) bool {
		m, st := playStream(t, stream)
		rows := m.activityRows()
		if len(rows) > activityLimit {
			t.Fatalf("rows %d over the limit: %v", len(rows), stream)
		}
		active := activeLabels(rows)
		switch {
		case !st.liveState():
			if len(active) != 0 {
				t.Fatalf("settled turn shows active rows %q: %v", active, stream)
			}
		case len(st.live) == 0:
			// Nothing in flight: one row names the running phase.
			if len(active) != 1 {
				t.Fatalf("phase rows %q: %v", active, stream)
			}
		default:
			if want := min(len(st.live), 3); len(active) != want {
				t.Fatalf("%d active rows %q, model has %d live: %v", len(active), active, len(st.live), stream)
			}
			for i, text := range active {
				call := st.live[len(st.live)-1-i]
				if want := propLabel("python", st.labels[call]); text != want {
					t.Fatalf("row %d is %q, model wants %q: %v", i, text, want, stream)
				}
			}
			if extra := len(st.live) - 3; extra > 0 {
				want := fmt.Sprintf("+%d active calls", extra)
				if !slicesHas(rows, want) {
					t.Fatalf("missing overflow row %q: %v", want, stream)
				}
			}
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 300, Rand: rand.New(rand.NewSource(7))}); err != nil {
		t.Fatal(err)
	}
}

func slicesHas(rows []PageRow, text string) bool {
	for _, row := range rows {
		if row.Text == text {
			return true
		}
	}
	return false
}

// TestPropActivityCountMatchesReference checks the session total: every settled
// call counts once, a redelivery of a settled tool event counts nothing, and a
// running phase with nothing in flight adds one.
func TestPropActivityCountMatchesReference(t *testing.T) {
	excluded := 0
	check := func(stream activityStream) bool {
		m, st := playStream(t, stream)
		if st.remainder > 0 {
			// Known: at a turn boundary the total counts one unfinished call
			// instead of each of them, so only the rest is checked here.
			excluded++
			return true
		}
		if got, want := m.activityCount(), st.count(); got != want {
			t.Fatalf("count %d, model %d: %v", got, want, stream)
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 300, Rand: rand.New(rand.NewSource(11))}); err != nil {
		t.Fatal(err)
	}
	t.Logf("excluded %d streams at the known turn-boundary gap", excluded)
}

// TestPropActivityRowsAreSafe checks rendering: no panic, no control
// characters and no row wider than the sidebar, for any width and label.
func TestPropActivityRowsAreSafe(t *testing.T) {
	check := func(stream activityStream, width uint16) bool {
		m := propModel(t)
		m.SetSize(int(width%260)+1, 32)
		if len(stream) > 40 {
			stream = stream[:40]
		}
		st := newActivityState()
		rnd := rand.New(rand.NewSource(17))
		for index, intent := range stream {
			replay(&m, st, intent, index, rnd)
		}
		for _, row := range m.activityRows() {
			if strings.ContainsAny(row.Text, "\x1b\a\r\n\t") {
				t.Fatalf("unsafe row %q", row.Text)
			}
			if ansi.StringWidth(row.Text) > 200 {
				t.Fatalf("row %q past the label cap", row.Text)
			}
		}
		rendered, _ := m.sidebarRows()
		sidebar := m.sidebarWidth()
		for _, line := range rendered {
			if strings.ContainsAny(ansi.Strip(line), "\x1b\a") {
				t.Fatalf("unsafe sidebar line %q", ansi.Strip(line))
			}
			if sidebar > 0 && ansi.StringWidth(line) > sidebar {
				t.Fatalf("sidebar line %q wider than %d at width %d", ansi.Strip(line), sidebar, width)
			}
		}
		_ = m.View()
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 200, Rand: rand.New(rand.NewSource(13))}); err != nil {
		t.Fatal(err)
	}
}

// resultCases are the tool results a settled call can carry.
var resultCases = []struct {
	Name, Title, Result, Status string
}{
	{"python", "ok cell", `{"status":"ok"}`, "completed"},
	{"python", "long cell", `{"status":"backgrounded"}`, "completed"},
	{"python", "stopped cell", `{"status":"interrupted"}`, "completed"},
	{"python", "cancelled cell", `{"status":"cancelled"}`, "completed"},
	{"python", "bad cell", `{"status":"error"}`, "completed"},
	{"python", "no status", ``, "completed"},
	{"python", "failed flag", `not json`, "failed"},
	{"shell", "go test ./...", "exit 1", "failed"},
	{"shell", "go build", "", "completed"},
	{"read", "", "file", "completed"},
	{"custom.lookup", "界界界界", `{"status":"error"}`, "completed"},
}

// refTone is the marker a settled call's row carries: an explicit Python status
// decides first, then the daemon's outcome.
func refTone(name, result, status string) PageTone {
	if name == "python" {
		var body struct {
			Status string `json:"status"`
		}
		if json.Unmarshal([]byte(result), &body) == nil {
			switch body.Status {
			case "ok", "backgrounded":
				return TonePlain
			case "interrupted", "cancelled", "error":
				return ToneWarning
			}
		}
	}
	if status == "failed" {
		return ToneWarning
	}
	return TonePlain
}

type settledStream []int // indexes into resultCases

func (s settledStream) Generate(rnd *rand.Rand, size int) reflect.Value {
	length := rnd.Intn(size + 1)
	out := make(settledStream, 0, length)
	for range length {
		out = append(out, rnd.Intn(len(resultCases)))
	}
	return reflect.ValueOf(out)
}

// TestPropActivitySettledRowsMatchReference checks the rows a finished turn
// leaves: the most recent calls newest first, each drawn from its title and
// outcome, at most the six rows the sidebar holds.
func TestPropActivitySettledRowsMatchReference(t *testing.T) {
	check := func(stream settledStream) bool {
		m := propModel(t)
		propEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "user", Source: "chat", Text: "work"})
		for i, index := range stream {
			c := resultCases[index]
			propToolEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: fmt.Sprint("entry", i),
				ToolName: c.Name, ToolTitle: c.Title, ToolResult: c.Result, ToolStatus: c.Status})
		}
		propEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
		rows := m.activityRows()
		want := min(len(stream), activityLimit)
		if len(rows) != want {
			t.Fatalf("%d rows, want %d: %v", len(rows), want, rows)
		}
		for i, row := range rows {
			c := resultCases[stream[len(stream)-1-i]]
			if label := propLabel(c.Name, c.Title); row.Text != label {
				t.Fatalf("row %d is %q, want %q", i, row.Text, label)
			}
			if tone := refTone(c.Name, c.Result, c.Status); row.Tone != tone {
				t.Fatalf("row %d tone %q for %#v, want %q", i, row.Tone, c, tone)
			}
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 300, Rand: rand.New(rand.NewSource(19))}); err != nil {
		t.Fatal(err)
	}
}

// TestPropActivityUnfinishedRowReportsLiveCalls checks the row a turn boundary
// leaves: it names the turn's outcome and counts every call left in flight.
func TestPropActivityUnfinishedRowReportsLiveCalls(t *testing.T) {
	check := func(kind uint8, count uint8, again bool) bool {
		m := propModel(t)
		live := int(count%5) + 1
		for i := range live {
			propEvent(&m, daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{
				CallID: fmt.Sprint("call", i), Name: "python", Phase: "running", Title: fmt.Sprint("work ", i),
			}})
		}
		state := "unknown"
		evt := daemon.StreamEvent{Type: daemon.EventTurnCompleted}
		switch kind % 4 {
		case terminalInterrupted:
			evt.Type = daemon.EventInterrupted
			state = "interrupted"
		case terminalFailed:
			evt.Type = daemon.EventError
		case terminalRetry:
			evt.Type = daemon.EventRetry
		}
		propEvent(&m, evt)
		rows := m.activityRows()
		want := fmt.Sprintf("%s · %d unfinished calls", state, live)
		if len(rows) == 0 || rows[0].Text != want || rows[0].Tone != ToneWarning {
			t.Fatalf("rows %v, want %q first", rows, want)
		}
		if again {
			// Resumed work replaces the uncertainty count.
			propEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "resumed", Source: "chat", Text: "again"})
			propEvent(&m, daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{
				CallID: "fresh", Name: "python", Phase: "running", Title: "resumed",
			}})
			for _, row := range m.activityRows() {
				if strings.Contains(row.Text, "unfinished calls") {
					t.Fatalf("stale unfinished row %q after resumed work", row.Text)
				}
			}
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 200, Rand: rand.New(rand.NewSource(23))}); err != nil {
		t.Fatal(err)
	}
}

// TestPropActivityOlderPageCountedOnce checks that paging older history counts
// the calls it reveals once, whatever the page repeats.
func TestPropActivityOlderPageCountedOnce(t *testing.T) {
	check := func(pageLen uint8, duplicate uint8) bool {
		m := propModel(t)
		propEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "user", Source: "chat", Text: "work"})
		propToolEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: "entry-live", ToolName: "python", ToolTitle: "live", ToolResult: `{"status":"ok"}`})
		propEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
		before := m.activityCount()
		// The loaded history already holds one entry; the page repeats it.
		events := []daemon.StreamEvent{{Type: daemon.EventTool, EntryID: "entry-live", ToolName: "python", Replayed: true}}
		fresh := int(duplicate % 4)
		inner := int(pageLen % 4)
		for i := range fresh {
			events = append(events, daemon.StreamEvent{Type: daemon.EventTool, EntryID: fmt.Sprint("older", i), ToolName: "python", Replayed: true})
		}
		for range inner {
			events = append(events, daemon.StreamEvent{Type: daemon.EventTool, EntryID: "entry-live", ToolName: "python", Replayed: true})
		}
		page := ChatOlderLoadedMsg{SessionID: m.SessionID, Generation: m.Generation,
			Page: &daemon.HistoryPage{Events: events}}
		m.loadingOlder = true
		m, _ = m.Update(page)
		if got, want := m.activityCount(), before+fresh; got != want {
			t.Fatalf("count %d after a page of %d new calls, want %d", got, fresh, want)
		}
		// The same page again must add nothing.
		m.loadingOlder = true
		m, _ = m.Update(page)
		if got, want := m.activityCount(), before+fresh; got != want {
			t.Fatalf("redelivered page counted twice: %d, want %d", got, want)
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 100, Rand: rand.New(rand.NewSource(29))}); err != nil {
		t.Fatal(err)
	}
}

// TestPropActivityDaemonTotalWins checks the daemon's session total: a live
// tool event sets it, a failed ledger read adds one, and a snapshot replaces it.
func TestPropActivityDaemonTotalWins(t *testing.T) {
	check := func(totals []uint8, unread uint8) bool {
		m := propModel(t)
		rnd := rand.New(rand.NewSource(31))
		_ = rnd
		total := 0
		for i, want := range totals {
			total = int(want % 40)
			propEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: fmt.Sprint("entry", i),
				ToolName: "python", ToolResult: `{"status":"ok"}`, SessionToolCalls: new(total)})
		}
		for i := range int(unread % 4) {
			total++
			propEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: fmt.Sprint("unread", i), ToolName: "python"})
		}
		propEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
		if got := m.activityCount(); got != total {
			t.Fatalf("count %d, daemon total %d", got, total)
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 100, Rand: rand.New(rand.NewSource(37))}); err != nil {
		t.Fatal(err)
	}
}

// TestPropActivitySidebarCacheMatchesBuild checks that the cached glance column
// the frame draws is what a fresh build would produce, for any event stream,
// width and height.
func TestPropActivitySidebarCacheMatchesBuild(t *testing.T) {
	check := func(stream activityStream, size uint16) bool {
		m := propModel(t)
		width, height := int(size%180)+30, int(size/180%40)+4
		m.SetSize(width, height)
		st := newActivityState()
		rnd := rand.New(rand.NewSource(41))
		if len(stream) > 40 {
			stream = stream[:40]
		}
		for index, intent := range stream {
			replay(&m, st, intent, index, rnd)
			_ = m.View()
			cached, cachedOmitted := m.sidebarRows()
			fresh, freshOmitted := m.buildSidebar()
			if !sameStrings(cached, fresh) {
				t.Fatalf("cached rows %q, fresh %q at %dx%d: %v", cached, fresh, width, height, stream)
			}
			if len(cachedOmitted) != len(freshOmitted) {
				t.Fatalf("cached omitted %d, fresh %d at %dx%d: %v", len(cachedOmitted), len(freshOmitted), width, height, stream)
			}
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 120, Rand: rand.New(rand.NewSource(43))}); err != nil {
		t.Fatal(err)
	}
}

// TestPropActivityLiveRowsPrecedeHistory checks the row order while work is
// running: the active calls, then their overflow count, then the most recent
// settled calls, within the six rows the sidebar holds.
func TestPropActivityLiveRowsPrecedeHistory(t *testing.T) {
	check := func(liveCount, settledCount uint8) bool {
		m := propModel(t)
		settled := int(settledCount % 8)
		for i := range settled {
			propToolEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: fmt.Sprint("old", i),
				ToolName: "python", ToolTitle: fmt.Sprint("old ", i), ToolResult: `{"status":"ok"}`})
		}
		live := int(liveCount % 6)
		for i := range live {
			propEvent(&m, daemon.StreamEvent{Type: daemon.EventToolProgress, Progress: &daemon.ToolProgress{
				CallID: fmt.Sprint("call", i), Name: "python", Phase: "running", Title: fmt.Sprint("new ", i),
			}})
		}
		rows := m.activityRows()
		shown := min(live, 3)
		head := shown
		if live > 3 {
			head++
		}
		if live == 0 && settled > 0 {
			// Nothing in flight: one row names the running phase.
			if len(rows) == 0 {
				t.Fatalf("no rows for a running turn with %d settled calls", settled)
			}
			head++
		}
		if len(rows) > activityLimit {
			t.Fatalf("rows %d over the limit", len(rows))
		}
		for i := range shown {
			if want, got := fmt.Sprint("new ", live-1-i), rows[i].Text; got != want {
				t.Fatalf("row %d is %q, want %q", i, got, want)
			}
		}
		if live > 3 {
			if want, got := fmt.Sprintf("+%d active calls", live-3), rows[shown].Text; got != want {
				t.Fatalf("overflow row %q, want %q", got, want)
			}
		}
		history := min(settled, activityLimit-head)
		for i := range history {
			if got, want := rows[head+i].Text, fmt.Sprint("old ", settled-1-i); got != want {
				t.Fatalf("history row %d is %q, want %q in %v", i, got, want, rows)
			}
			if rows[head+i].Tone == ToneActive {
				t.Fatalf("settled row %d is active: %v", i, rows)
			}
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 200, Rand: rand.New(rand.NewSource(47))}); err != nil {
		t.Fatal(err)
	}
}

// TestPropActivityFooterCountCarriesOmittedActivity checks the narrow-screen
// contract: a sidebar without room for the activity glance leaves the footer
// carrying the session total instead, once.
func TestPropActivityFooterCountCarriesOmittedActivity(t *testing.T) {
	check := func(stream activityStream, size uint16) bool {
		m := propModel(t)
		m.SetSize(int(size%160)+20, int(size/160%24)+4)
		st := newActivityState()
		rnd := rand.New(rand.NewSource(53))
		if len(stream) > 30 {
			stream = stream[:30]
		}
		for index, intent := range stream {
			replay(&m, st, intent, index, rnd)
		}
		counts := m.glanceCounts()
		shown := false
		if m.sidebarWidth() > 0 {
			rows, omitted := m.sidebarRows()
			shown = len(rows) > 0
			for _, g := range omitted {
				if g.Title == "activity" {
					shown = false
				}
			}
		}
		hasActivity := false
		want := fmt.Sprintf("activity %d", m.activityCount())
		for _, text := range counts {
			if strings.HasPrefix(text, "activity ") {
				hasActivity = true
				if text != want {
					t.Fatalf("footer %q, want %q", text, want)
				}
			}
		}
		if m.activityCount() > 0 && !shown && !hasActivity {
			t.Fatalf("activity %d missing from the footer %q", m.activityCount(), counts)
		}
		if shown && hasActivity {
			t.Fatalf("activity counted twice: rows and footer %q", counts)
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 150, Rand: rand.New(rand.NewSource(59))}); err != nil {
		t.Fatal(err)
	}
}

// eventStream is a stream of arbitrary stream events, for panics and for rows
// that must stay safe whatever the daemon sends.
type eventStream []daemon.StreamEvent

func (s eventStream) Generate(rnd *rand.Rand, size int) reflect.Value {
	kinds := []daemon.EventType{
		daemon.EventReset, daemon.EventRetry, daemon.EventText, daemon.EventError,
		daemon.EventInterrupted, daemon.EventMessage, daemon.EventUser, daemon.EventThinking,
		daemon.EventNote, daemon.EventToolProgress, daemon.EventTool, daemon.EventUsage,
		daemon.EventKernel, daemon.EventGlances, daemon.EventCommitted,
	}
	length := rnd.Intn(size + 1)
	stream := make(eventStream, 0, length)
	for i := range length {
		evt := daemon.StreamEvent{Type: kinds[rnd.Intn(len(kinds))]}
		if rnd.Intn(2) == 0 {
			evt.EntryID = fmt.Sprint("entry", rnd.Intn(4))
		}
		if rnd.Intn(3) == 0 {
			evt.Progress = &daemon.ToolProgress{CallID: fmt.Sprint("call", rnd.Intn(4)), Name: "python", Title: gnarlyLabels[rnd.Intn(len(gnarlyLabels))]}
		}
		if rnd.Intn(3) == 0 {
			evt.ProgressCallID = fmt.Sprint("call", rnd.Intn(4))
		}
		if rnd.Intn(3) == 0 {
			evt.ToolName = "python"
			evt.ToolTitle = gnarlyLabels[rnd.Intn(len(gnarlyLabels))]
			evt.ToolResult = `{"status":"ok"}`
		}
		if evt.Type == daemon.EventReset && rnd.Intn(2) == 0 {
			evt.Snapshot = &daemon.Session{ID: "activity-prop"}
		}
		if evt.Type == daemon.EventTool && rnd.Intn(4) == 0 {
			evt.SessionToolCalls = new(int)
		}
		evt.Replayed = i%7 == 0 && rnd.Intn(2) == 0
		stream = append(stream, evt)
	}
	return reflect.ValueOf(stream)
}

// TestPropActivityArbitraryEvents checks that any stream of events, including
// replayed ones and missing fields, leaves safe rows and never panics.
func TestPropActivityArbitraryEvents(t *testing.T) {
	check := func(stream eventStream, size uint16) bool {
		m := propModel(t)
		m.SetSize(int(size%200)+1, int(size/200%40)+2)
		for _, evt := range stream {
			m, _ = m.Update(ChatStreamEventMsg{SessionID: m.SessionID, Generation: m.Generation, Event: evt})
			for _, row := range m.activityRows() {
				if strings.ContainsAny(row.Text, "\x1b\a\r\n\t") {
					t.Fatalf("unsafe row %q from %#v", row.Text, evt)
				}
				if ansi.StringWidth(row.Text) > 200 {
					t.Fatalf("row %q past the label cap from %#v", row.Text, evt)
				}
			}
			rows, _ := m.sidebarRows()
			for _, line := range rows {
				if strings.ContainsAny(ansi.Strip(line), "\x1b\a") {
					t.Fatalf("unsafe sidebar line %q", ansi.Strip(line))
				}
			}
			_ = m.View()
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 120, Rand: rand.New(rand.NewSource(61))}); err != nil {
		t.Fatal(err)
	}
}

// TestPropActivitySectionOrder checks the sidebar's documented order: the
// extensions' glances, background jobs, the agents glance, then activity.
func TestPropActivitySectionOrder(t *testing.T) {
	check := func(extensions uint8, jobs uint8, activity uint8) bool {
		m := propModel(t)
		var want []string
		names := []string{"pulls", "queue", "tests", "agents"}
		for i := range int(extensions % 5) {
			title := names[i%len(names)]
			m.Glances = append(m.Glances, PageGlance{Title: title, Rows: []PageRow{{Text: fmt.Sprint(title, " row")}}})
			if title != agentsGlance {
				want = append(want, title)
			} else if len(want) == 0 || !slicesHasText(want, agentsGlance) {
				want = append(want, agentsGlance)
			}
		}
		if jobs%3 > 0 {
			m.Status.RunningJobs = []protocol.KernelJob{{ID: "j", Command: "go test ./...", StartedAt: time.Now().Add(-time.Minute).UnixMilli()}}
			// A job section comes before the agents glance.
			if slicesHasText(want, agentsGlance) {
				want = slicesDeleteText(want, agentsGlance)
				want = append(want, "background jobs", agentsGlance)
			} else {
				want = append(want, "background jobs")
			}
		}
		for i := range int(activity % 4) {
			propToolEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: fmt.Sprint("entry", i),
				ToolName: "python", ToolTitle: fmt.Sprint("work ", i), ToolResult: `{"status":"ok"}`})
		}
		if activity%4 > 0 {
			want = append(want, "activity")
		}
		var got []string
		for _, g := range m.activeGlances() {
			got = append(got, g.Title)
		}
		if !sameStrings(got, want) {
			t.Fatalf("sections %q, want %q", got, want)
		}
		if len(got) > 0 && got[len(got)-1] != "activity" && activity%4 > 0 {
			t.Fatalf("activity is not last: %q", got)
		}
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 200, Rand: rand.New(rand.NewSource(67))}); err != nil {
		t.Fatal(err)
	}
}

func slicesHasText(list []string, text string) bool {
	for _, item := range list {
		if item == text {
			return true
		}
	}
	return false
}

func slicesDeleteText(list []string, text string) []string {
	out := list[:0]
	for _, item := range list {
		if item != text {
			out = append(out, item)
		}
	}
	return out
}
