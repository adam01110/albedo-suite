package tui

// Property tests for the small suite-owned helpers: activity counting and
// labels, cancelled-draft attachment recovery, zoxide row merging, tool image
// cell fitting, cost formatting and notification text.

import (
	"albedo/cli/internal/pickersearch"
	"fmt"
	"math"
	"math/rand"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"testing/quick"
	"unicode"
	"unicode/utf8"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/ansi/kitty"
	"github.com/sahilm/fuzzy"
)

func propConfig(seed int64, max int) *quick.Config {
	return &quick.Config{MaxCount: max, Rand: rand.New(rand.NewSource(seed))}
}

// --- activityLabel -------------------------------------------------------

// propLabelText composes a label from pieces a stream can carry: prose,
// escape sequences, whitespace and control runes.
func propLabelText(seed uint64, parts int) string {
	var b strings.Builder
	for i := 0; i < parts; i++ {
		switch int(seed>>uint(4*i)) % 8 {
		case 0:
			b.WriteString("cell title")
		case 1:
			b.WriteString(" ")
		case 2:
			b.WriteString("\t")
		case 3:
			b.WriteString("\x1b[31m")
		case 4:
			b.WriteString("\x1b]0;title\x07")
		case 5:
			b.WriteString("\n")
		case 6:
			b.WriteString("\u00e9")
		case 7:
			b.WriteString("\u0000")
		}
	}
	return b.String()
}

func TestPropActivityLabel(t *testing.T) {
	f := func(seed uint64, parts int) bool {
		parts = int(seed%5 + 1)
		name, title := propLabelText(seed, parts), propLabelText(seed>>8, parts)
		// A blank title currently yields a blank label; the deterministic
		// regression test for that finding lives with the fix.
		label := activityLabel(name, title)
		if w := ansi.StringWidth(label); w > 160 {
			return false
		}
		for _, r := range label {
			if r == '\n' || r == '\r' || unicode.IsControl(r) {
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, propConfig(1, 800)); err != nil {
		t.Fatal(err)
	}
}

// --- importDraftAttachments ---------------------------------------------

// propText builds text that interleaves filler with markers for numbers.
func propMarkers(filler string, nums []int, kind string) string {
	var b strings.Builder
	b.WriteString(filler)
	for i, n := range nums {
		fmt.Fprintf(&b, "[%s #%d]", kind, n)
		if i%2 == 0 {
			b.WriteString(filler)
		}
	}
	return b.String()
}

var propImageMarker = regexp.MustCompile(`\[Image #(\d+)\]`)

// modelImportImages independently expresses importDraftAttachments for the
// image kind: every referenced number gets the next destination number, in
// first-appearance order, and other markers stay as typed.
func modelImportImages(text string, items int, dst int) (string, int) {
	assigned := make(map[int]int)
	next := dst
	matches := propImageMarker.FindAllStringSubmatch(text, -1)
	for _, m := range matches {
		n, _ := strconv.Atoi(m[1])
		if n < 1 || n > items {
			continue
		}
		if _, ok := assigned[n]; !ok {
			next++
			assigned[n] = next
		}
	}
	out := propImageMarker.ReplaceAllStringFunc(text, func(marker string) string {
		n, _ := strconv.Atoi(propImageMarker.FindStringSubmatch(marker)[1])
		if to, ok := assigned[n]; ok {
			return "[Image #" + strconv.Itoa(to) + "]"
		}
		return marker
	})
	return out, next
}

func TestPropImportDraftImages(t *testing.T) {
	f := func(filler string, nums []int, items, dst int) bool {
		items, dst = abs(items)%5, abs(dst)%4
		images := make([]pastedImage, items)
		for i := range images {
			images[i] = pastedImage{ImageAttachment: daemon.ImageAttachment{Data: fmt.Sprintf("ref-%d", i+1)}}
		}
		var draft promptImages
		for i := 0; i < dst; i++ {
			draft.add(pastedImage{ImageAttachment: daemon.ImageAttachment{Data: fmt.Sprintf("held-%d", i+1)}})
		}
		text := propMarkers(filler, nums, "Image")
		wantText, wantNext := modelImportImages(text, len(images), dst)
		got := importDraftAttachments(&draft, text, images)
		if got != wantText || draft.next != wantNext {
			return false
		}
		// Each referenced item is held exactly once, in first-appearance order.
		var wantRefs []string
		seen := make(map[int]bool)
		for _, m := range propImageMarker.FindAllStringSubmatch(text, -1) {
			n, _ := strconv.Atoi(m[1])
			if n >= 1 && n <= len(images) && !seen[n] {
				seen[n] = true
				wantRefs = append(wantRefs, images[n-1].Data)
			}
		}
		var gotRefs []string
		for i := dst + 1; i <= draft.next; i++ {
			gotRefs = append(gotRefs, draft.byNumber[i].Data)
		}
		return equalStrings(gotRefs, wantRefs)
	}
	if err := quick.Check(f, propConfig(2, 300)); err != nil {
		t.Fatal(err)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

var propPasteMarker = regexp.MustCompile(`\[Paste #(\d+)(?:, [^\]\n]*)?\]`)

// modelPasteMarker independently formats one collapsed paste marker.
func modelPasteMarker(n int, text string) string {
	if lines := strings.Count(text, "\n") + 1; lines > 10 {
		return "[Paste #" + strconv.Itoa(n) + ", +" + strconv.Itoa(lines) + " lines]"
	}
	return "[Paste #" + strconv.Itoa(n) + ", " + strconv.Itoa(len([]rune(text))) + " chars]"
}

func modelImportPastes(text string, items []string, dst int) (string, int) {
	assigned := make(map[int]int)
	next := dst
	for _, m := range propPasteMarker.FindAllStringSubmatch(text, -1) {
		n, _ := strconv.Atoi(m[1])
		if n < 1 || n > len(items) {
			continue
		}
		if _, ok := assigned[n]; !ok {
			next++
			assigned[n] = next
		}
	}
	out := propPasteMarker.ReplaceAllStringFunc(text, func(marker string) string {
		n, _ := strconv.Atoi(propPasteMarker.FindStringSubmatch(marker)[1])
		if to, ok := assigned[n]; ok {
			return modelPasteMarker(to, items[n-1])
		}
		return marker
	})
	return out, next
}

func TestPropImportDraftPastes(t *testing.T) {
	f := func(filler string, nums []int, shapes []int, dst int) bool {
		shapes = shapes[:min(len(shapes), 4)]
		pastes := make([]string, len(shapes))
		for i, shape := range shapes {
			shape = abs(shape)
			switch shape % 3 {
			case 0:
				pastes[i] = strings.Repeat("line\n", shape%14)
			case 1:
				pastes[i] = strings.Repeat("z", shape%1200)
			default:
				pastes[i] = ""
			}
		}
		var draft promptPastes
		for i := 0; i < abs(dst)%3; i++ {
			draft.add(fmt.Sprintf("held-%d", i))
		}
		start := draft.next
		text := propMarkers(filler, nums, "Paste")
		wantText, wantNext := modelImportPastes(text, pastes, start)
		got := importDraftAttachments(&draft, text, pastes)
		return got == wantText && draft.next == wantNext
	}
	if err := quick.Check(f, propConfig(3, 300)); err != nil {
		t.Fatal(err)
	}
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

// --- activityCount -------------------------------------------------------

// TestPropActivityCountMatchesSessionTotal compares the counter with an
// independent daemon model: the reported session total plus the calls the
// daemon has not reported yet.
func TestPropActivityCountMatchesSessionTotal(t *testing.T) {
	f := func(ops []int) bool {
		m := activityChat(t)
		calls := map[string]bool{}
		inflight := map[string]bool{}
		for _, op := range ops {
			call := fmt.Sprintf("call-%d", abs(op)%6)
			switch abs(op) % 3 {
			case 0, 1:
				activityStart(&m, call, "work")
				calls[call], inflight[call] = true, true
			case 2:
				activityFinish(&m, call, "work", `{"status":"ok"}`)
				calls[call] = true
				delete(inflight, call)
			}
		}
		// Finish what is still running so the turn ends with no unfinished call.
		for call := range inflight {
			activityFinish(&m, call, "work", `{"status":"ok"}`)
		}
		// A live turn counts as one more activity than its calls.
		live := len(calls)
		if len(calls) > 0 {
			live++
		}
		if got := m.activityCount(); got != live {
			t.Logf("ops=%v live want=%d got=%d", ops, live, got)
			return false
		}
		activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTurnCompleted})
		if got := m.activityCount(); got != len(calls) {
			t.Logf("ops=%v settled want=%d got=%d", ops, len(calls), got)
			return false
		}
		// An older page of already-loaded calls must not be counted twice.
		m.loadingOlder = true
		m.countOlderActivity(ChatOlderLoadedMsg{SessionID: m.SessionID, Generation: m.Generation})
		if got := m.activityCount(); got != len(calls) {
			t.Logf("ops=%v after older page want=%d got=%d", ops, len(calls), got)
			return false
		}
		return true
	}
	if err := quick.Check(f, propConfig(4, 150)); err != nil {
		t.Fatal(err)
	}
}

// TestPropActivityRowsBounded keeps the display at most six nonempty rows
// however many calls a session produced.
func TestPropActivityRowsBounded(t *testing.T) {
	f := func(calls int) bool {
		m := activityChat(t)
		calls = abs(calls) % 40
		for i := 0; i < calls; i++ {
			activityFinish(&m, fmt.Sprint(i), "", `{"status":"ok"}`)
		}
		rows := m.activityRows()
		if len(rows) > activityLimit {
			return false
		}
		for _, row := range rows {
			if row.Text == "" || ansi.StringWidth(row.Text) > 160 {
				return false
			}
		}
		if m.activityCount() < len(rows) {
			return false
		}
		return true
	}
	if err := quick.Check(f, propConfig(5, 60)); err != nil {
		t.Fatal(err)
	}
}

// TestPropActivityRowsStayBoundedWhileLive keeps the six-row display while
// concurrent calls run beside a long history, newest call first.
func TestPropActivityRowsStayBoundedWhileLive(t *testing.T) {
	f := func(finished, live int) bool {
		m := activityChat(t)
		finished, live = abs(finished)%40, abs(live)%8
		for i := 0; i < finished; i++ {
			activityFinish(&m, fmt.Sprint("old", i), "done work", `{"status":"ok"}`)
		}
		var started []string
		for i := 0; i < live; i++ {
			call := fmt.Sprint("live", i)
			activityStart(&m, call, "live work")
			started = append(started, "live work")
		}
		rows := m.activityRows()
		if len(rows) > activityLimit {
			return false
		}
		// The live calls own the top rows, and the counter never undercounts them.
		shown := min(live, 3)
		for i := 0; i < shown; i++ {
			if rows[i].Text != "live work" || rows[i].Tone != ToneActive {
				t.Logf("finished=%d live=%d rows=%#v", finished, live, rows)
				return false
			}
		}
		if live > 0 && m.activityCount() < live {
			return false
		}
		return true
	}
	if err := quick.Check(f, propConfig(10, 120)); err != nil {
		t.Fatal(err)
	}
}

// --- toolImageCells ------------------------------------------------------

func TestPropToolImageCells(t *testing.T) {
	f := func(width, height, cols, rows int) bool {
		width, height = abs(width)%4000+1, abs(height)%4000+1
		cols, rows = abs(cols)%200+1, abs(rows)%40+1
		c, r := toolImageCells(width, height, cols, rows)
		if c < 1 || r < 1 || c > cols || r > rows {
			return false
		}
		// A cell is about twice as tall as wide, so c cells show c*h/(2w) rows.
		fitRows := func(c int) int {
			return max(1, (c*height+width)/(2*width))
		}
		if fitRows(cols) <= rows {
			// The whole width fits: the image keeps every column.
			return c == cols && r == fitRows(cols)
		}
		// Otherwise the image fills the box height, and the column count is
		// the pixel aspect rounded to the nearest cell.
		if r != rows {
			return false
		}
		exact := 2 * float64(r) * float64(width) / float64(height)
		return c == 1 || math.Abs(float64(c)-exact) <= 0.5+1e-9
	}
	if err := quick.Check(f, propConfig(6, 2000)); err != nil {
		t.Fatal(err)
	}
}

// --- estimatedCost -------------------------------------------------------

func TestPropEstimatedCost(t *testing.T) {
	f := func(bits uint64, compact bool) bool {
		cost := math.Float64frombits(bits)
		if math.IsNaN(cost) || math.IsInf(cost, 0) {
			cost = float64(bits % 100000)
		}
		text, ok := estimatedCost(&cost, compact)
		unknown := cost < 0
		if ok == unknown {
			return false
		}
		if !ok {
			return text == ""
		}
		if !strings.HasPrefix(text, "$") {
			return false
		}
		if cost > 0 && cost < 0.01 {
			return text == "$<0.01"
		}
		value, err := strconv.ParseFloat(strings.TrimPrefix(text, "$"), 64)
		if err != nil {
			return false
		}
		tolerance := 0.005 + 1e-9
		if compact && cost >= 1000 {
			tolerance = 0.5 + 1e-9
		}
		return math.Abs(value-cost) <= tolerance
	}
	if err := quick.Check(f, propConfig(7, 2000)); err != nil {
		t.Fatal(err)
	}
}

// --- notifyText ----------------------------------------------------------

// propNotifyText composes untrusted text from the pieces a notification
// carries: prose, OSC field separators, markup, escapes and long runs.
func propNotifyText(seed uint64, parts int) string {
	var b strings.Builder
	for i := 0; i < parts; i++ {
		switch int(seed>>uint(3*i)) % 9 {
		case 0:
			b.WriteString("reply done")
		case 1:
			b.WriteString(";")
		case 2:
			b.WriteString("&<>")
		case 3:
			b.WriteString("&amp;")
		case 4:
			b.WriteString("\x1b[31mred\x1b[0m")
		case 5:
			b.WriteString("\n")
		case 6:
			b.WriteString("\u00e9\u4e16")
		case 7:
			b.WriteString(strings.Repeat("wide ", 40))
		case 8:
			b.WriteString("\x00\x07")
		}
	}
	return b.String()
}

// modelNotifyText independently expresses one safe OSC 777 field: printable
// single-line text, no separator or markup characters, cut to limit cells.
func modelNotifyText(text string, limit int) string {
	text = ansi.Strip(text)
	text = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, text)
	text = strings.Join(strings.Fields(text), " ")
	// Separator and markup characters become lookalikes before the cut.
	var b strings.Builder
	for _, r := range text {
		switch r {
		case ';':
			r = ','
		case '&':
			r = '\uff06'
		case '<':
			r = '\u2039'
		case '>':
			r = '\u203a'
		}
		b.WriteRune(r)
	}
	return ansi.Truncate(b.String(), limit, "…")
}

func TestPropNotifyTextIsOneSafeField(t *testing.T) {
	f := func(seed uint64, parts, limit int) bool {
		text := propNotifyText(seed, int(seed%6+1))
		limit = abs(limit)%120 + 1
		out := notifyText(text, limit)
		if out != modelNotifyText(text, limit) {
			t.Logf("text=%q limit=%d out=%q want=%q", text, limit, out, modelNotifyText(text, limit))
			return false
		}
		for _, r := range out {
			if unicode.IsControl(r) {
				return false
			}
		}
		if strings.Contains(out, "\x1b") {
			return false
		}
		if strings.ContainsAny(out, ";&<>") {
			return false
		}
		return ansi.StringWidth(out) <= limit
	}
	if err := quick.Check(f, propConfig(8, 800)); err != nil {
		t.Fatal(err)
	}
}

// --- appendZoxide --------------------------------------------------------

func TestPropAppendZoxideMergesWithoutDuplicates(t *testing.T) {
	paths := func(values []int) []string {
		out := make([]string, len(values))
		for i, v := range values {
			out[i] = "/d" + strconv.Itoa(abs(v)%6)
		}
		return out
	}
	f := func(existingIdx, suggestionIdx []int, chunk int) bool {
		existing, suggestions := paths(existingIdx), paths(suggestionIdx)
		picker := &FolderPicker{}
		seen := map[string]bool{}
		for _, p := range existing {
			if seen[p] {
				continue
			}
			seen[p] = true
			picker.rows = append(picker.rows, folderRow{path: p, name: p})
		}
		want := len(picker.rows)
		var wantOrder []string
		for _, p := range suggestions {
			if !seen[p] {
				seen[p] = true
				want++
				wantOrder = append(wantOrder, p)
			}
		}
		// Merge in the batches the picker asks for.
		step := abs(chunk)%5 + 1
		for i := 0; i < len(suggestions); i += step {
			picker.appendZoxide(suggestions[i:min(len(suggestions), i+step)])
		}
		if len(picker.rows) != want {
			t.Logf("existing=%v suggestions=%v rows=%d want=%d", existing, suggestions, len(picker.rows), want)
			return false
		}
		got := map[string]bool{}
		var added []string
		for i, row := range picker.rows {
			if got[row.path] {
				return false
			}
			got[row.path] = true
			if i >= len(picker.rows)-len(wantOrder) {
				added = append(added, row.path)
			}
		}
		return slices.Equal(added, wantOrder)
	}
	if err := quick.Check(f, propConfig(9, 400)); err != nil {
		t.Fatal(err)
	}
}

// --- fuzzyNames ----------------------------------------------------------

var propTokens = []string{"alpha", "Beta", "gamma", "delta", "report", "x", "file", "notes"}
var propSeps = []string{"-", "_", ".", "/", " ", ":", ""}

// propFold is the documented search normalisation: lower case, spaces and the
// separators -_.:/ dropped.
func propFold(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) || strings.ContainsRune("-_.:/", r) {
			return -1
		}
		return unicode.ToLower(r)
	}, s)
}

func propName(seed uint64) string {
	var b strings.Builder
	n := int(seed%3) + 1
	for i := 0; i < n; i++ {
		b.WriteString(propSeps[(seed>>uint(i*3+1))%uint64(len(propSeps))])
		b.WriteString(propTokens[(seed>>uint(i*3+6))%uint64(len(propTokens))])
	}
	return b.String()
}

// propToken is one alphanumeric token of a generated name, lower cased.
func propToken(seed uint64) string {
	return strings.ToLower(propTokens[seed%uint64(len(propTokens))])
}

// TestPropFuzzyNamesCompleteness asserts the documented rule: a word that is
// somewhere inside a token, or the start of the folded name, is matched.
func TestPropFuzzyNamesCompleteness(t *testing.T) {
	f := func(seed uint64) bool {
		name := propName(seed)
		fold := propFold(name)
		tokens := strings.FieldsFunc(strings.ToLower(name), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) })
		if fold == "" || len(tokens) == 0 {
			return true
		}
		var queries []string
		// A nonempty prefix of the folded name, the whole name included.
		keep := int(seed%uint64(len(fold))) + 1
		queries = append(queries, fold[:keep])
		token := tokens[(seed>>4)%uint64(len(tokens))]
		var runes []rune
		for _, r := range token {
			if unicode.IsLetter(r) || unicode.IsNumber(r) {
				runes = append(runes, r)
			}
		}
		if len(runes) == 0 {
			return true
		}
		// A contiguous stretch of one token of the name.
		at := int((seed >> 8) % uint64(len(runes)))
		length := int((seed>>12)%uint64(len(runes)-at)) + 1
		queries = append(queries, string(runes[at:at+length]))
		// A subsequence of one token, starting at its first rune.
		if len(runes) > 2 {
			sub := []rune{runes[0]}
			for i := 1; i < len(runes) && len(sub) < 3; i += 2 {
				sub = append(sub, runes[i])
			}
			queries = append(queries, string(sub))
		}
		for _, query := range queries {
			if query == "" {
				continue
			}
			names := []string{name}
			matches := fuzzyNames(query, names)
			if len(matches) != 1 || matches[0].Index != 0 || matches[0].Str != name {
				t.Logf("name=%q query=%q matches=%+v", name, query, matches)
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, propConfig(14, 800)); err != nil {
		t.Fatal(err)
	}
}

// TestPropFuzzyNamesInvariants keeps the result a subset of the input with
// usable underline offsets, ordered by the documented rank.
func TestPropFuzzyNamesInvariants(t *testing.T) {
	f := func(seed uint64, querySeed uint64) bool {
		n := int(seed % 5)
		names := make([]string, n)
		for i := range names {
			names[i] = propName(seed>>uint(i*3) + querySeed)
		}
		query := ""
		if n > 0 && querySeed%3 != 0 {
			query = propToken(querySeed)
		}
		matches := fuzzyNames(query, names)
		words := pickersearch.Words(query)
		seen := map[int]bool{}
		previous := pickersearch.Rank{}
		for i, match := range matches {
			if match.Index < 0 || match.Index >= len(names) || seen[match.Index] || match.Str != names[match.Index] {
				t.Logf("query=%q names=%v match=%+v", query, names, match)
				return false
			}
			seen[match.Index] = true
			rank, _, ok := pickersearch.Match(words, match.Str)
			if !ok {
				t.Logf("query=%q matched %q that matchFields rejects", query, match.Str)
				return false
			}
			if i > 0 && previous.Compare(rank) < 0 {
				t.Logf("query=%q ranks out of order at %d", query, i)
				return false
			}
			previous = rank
			last := -1
			for _, hit := range match.MatchedIndexes {
				if hit <= last || hit >= len(match.Str) || !utf8.RuneStart(match.Str[hit]) {
					t.Logf("query=%q name=%q hits=%v", query, match.Str, match.MatchedIndexes)
					return false
				}
				last = hit
			}
		}
		// An empty search keeps every name in order.
		if query == "" && len(matches) != len(names) {
			return false
		}
		for i := range matches {
			if query == "" && (matches[i].Index != i || matches[i].Str != names[i]) {
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, propConfig(15, 600)); err != nil {
		t.Fatal(err)
	}
}

// TestPropFuzzyNamesPermutationInvariance keeps matching and rank order
// independent of the order names arrive in.
func TestPropFuzzyNamesPermutationInvariance(t *testing.T) {
	f := func(seed, querySeed uint64, shift int) bool {
		n := int(seed%5) + 1
		names := make([]string, n)
		for i := range names {
			names[i] = propName(seed>>uint(i*3+1) + querySeed)
		}
		query := propToken(querySeed)
		rotated := make([]string, n)
		at := abs(shift) % n
		for i := range names {
			rotated[i] = names[(i+at)%n]
		}
		ranks := func(matches []fuzzy.Match) []pickersearch.Rank {
			out := make([]pickersearch.Rank, len(matches))
			for i, match := range matches {
				out[i], _, _ = pickersearch.Match(pickersearch.Words(query), match.Str)
			}
			return out
		}
		want, got := fuzzyNames(query, names), fuzzyNames(query, rotated)
		wantRanks, gotRanks := ranks(want), ranks(got)
		if len(wantRanks) != len(gotRanks) || !reflect.DeepEqual(wantRanks, gotRanks) {
			t.Logf("query=%q names=%v ranks %v vs %v", query, names, wantRanks, gotRanks)
			return false
		}
		wantSet, gotSet := map[string]bool{}, map[string]bool{}
		for _, match := range want {
			wantSet[match.Str] = true
		}
		for _, match := range got {
			gotSet[match.Str] = true
		}
		return reflect.DeepEqual(wantSet, gotSet)
	}
	if err := quick.Check(f, propConfig(16, 500)); err != nil {
		t.Fatal(err)
	}
}

// --- thumbnails ----------------------------------------------------------

var propSGR = regexp.MustCompile(`^\x1b\[([0-9;]*)m`)

// propDiacriticIndex inverts kitty's row/column diacritics, so a placeholder
// grid can be read back without the writer's own ordering.
var propDiacriticIndex = func() map[rune]int {
	out := map[rune]int{}
	for i := 0; i < 512; i++ {
		if _, ok := out[kitty.Diacritic(i)]; !ok {
			out[kitty.Diacritic(i)] = i
		}
	}
	return out
}()

// propDecodeThumbnail reads the image id and the placeholder grid back out of
// one row of placeholders.
func propDecodeThumbnail(t *testing.T, row string) (id int, cells []int, ok bool) {
	t.Helper()
	match := propSGR.FindStringSubmatch(row)
	if match == nil {
		t.Logf("no colour in %q", row)
		return 0, nil, false
	}
	var params []int
	for _, field := range strings.Split(match[1], ";") {
		n, err := strconv.Atoi(field)
		if err != nil {
			return 0, nil, false
		}
		params = append(params, n)
	}
	switch {
	case len(params) == 3 && params[0] == 38 && params[1] == 5:
		id = params[2]
	case len(params) == 5 && params[0] == 38 && params[1] == 2:
		id = params[2]<<16 | params[3]<<8 | params[4]
	default:
		t.Logf("unexpected colour params %v", params)
		return 0, nil, false
	}
	runes := []rune(row[len(match[0]):])
	runes = runes[:len(runes)-len([]rune(ansi.Style{}.DefaultForegroundColor().String()))]
	for i := 0; i+2 < len(runes); i += 3 {
		if runes[i] != kitty.Placeholder {
			return 0, nil, false
		}
		r, okr := propDiacriticIndex[runes[i+1]]
		c, okc := propDiacriticIndex[runes[i+2]]
		if !okr || !okc {
			return 0, nil, false
		}
		cells = append(cells, r<<8|c)
	}
	return id, cells, true
}

// TestPropPlaceholderRowsEncodeImage keeps every placeholder row pointing at
// the thumbnail's own id, with one placeholder per cell.
func TestPropPlaceholderRowsEncodeImage(t *testing.T) {
	f := func(id, cols, rows int) bool {
		cols, rows = abs(cols)%6+1, abs(rows)%5+1
		id = abs(id)%0xffffff + 1
		thumb := thumbnail{id: id, cols: cols, rows: rows}
		out := placeholderRows(thumb)
		if len(out) != rows {
			return false
		}
		for r, row := range out {
			gotID, cells, ok := propDecodeThumbnail(t, row)
			if !ok || gotID != id {
				t.Logf("id=%d cols=%d rows=%d row=%q decoded=%d ok=%v", id, cols, rows, row, gotID, ok)
				return false
			}
			if len(cells) != cols {
				t.Logf("id=%d cols=%d row %d has %d cells", id, cols, r, len(cells))
				return false
			}
			for c, cell := range cells {
				if cell != r<<8|c {
					t.Logf("id=%d row %d cell %d decodes as %#x", id, r, c, cell)
					return false
				}
			}
		}
		return true
	}
	if err := quick.Check(f, propConfig(17, 400)); err != nil {
		t.Fatal(err)
	}
}

// --- Compact -------------------------------------------------------------

// TestPropCompactKeepsImageTools keeps a tool call that carried images in the
// transcript, whatever the display flags say.
func TestPropCompactKeepsImageTools(t *testing.T) {
	kinds := []EntryKind{EntryTool, EntryUser, EntryAssistant, EntryNote, EntryShell, EntryThinking}
	f := func(kindIndex, images int, tools, other bool) bool {
		entry := HistoryEntry{Kind: kinds[abs(kindIndex)%len(kinds)]}
		for i := 0; i < abs(images)%4; i++ {
			entry.Images = append(entry.Images, daemon.ImageMetadata{Reference: fmt.Sprint("/sessions/s/history/e/image-", i+1)})
		}
		flags := DisplayFlags{Tools: tools}
		_ = other
		compact := Compact(entry, flags)
		if entry.Kind == EntryTool && len(entry.Images) > 0 && compact {
			t.Logf("tool entry with %d images compacted", len(entry.Images))
			return false
		}
		if entry.Kind == EntryTool && len(entry.Images) == 0 && compact != !tools {
			t.Logf("image-free tool entry: compact=%v tools=%v", compact, tools)
			return false
		}
		return true
	}
	if err := quick.Check(f, propConfig(18, 400)); err != nil {
		t.Fatal(err)
	}
}

// --- stream images -------------------------------------------------------

func propImages(seed uint64) []daemon.ImageMetadata {
	var images []daemon.ImageMetadata
	for i := 0; i < int(seed%4); i++ {
		images = append(images, daemon.ImageMetadata{MimeType: daemon.ImageMimeType(fmt.Sprint("image/", seed%2)),
			Width: int(seed%97) + 1, Height: int((seed>>7)%89) + 1, Bytes: int((seed>>13)%1000) + 1,
			Reference: fmt.Sprint("/sessions/s/history/entry", i, "/image-", i+1)})
	}
	return images
}

// TestPropStreamImagesReachEntries keeps a call's images on its entry, in
// order, and keeps a replayed event from disturbing live status.
func TestPropStreamImagesReachEntries(t *testing.T) {
	f := func(seed uint64) bool {
		m := activityChat(t)
		userImages := propImages(seed)
		activityEvent(&m, daemon.StreamEvent{Type: daemon.EventUser, EntryID: "user", Source: "chat", Text: "go", Images: userImages})
		toolImages := propImages(seed >> 3)
		activityFinish2(&m, "call", toolImages)
		var user, tool *HistoryEntry
		for i := range m.History.Entries() {
			entry := &m.History.Entries()[i]
			switch entry.Kind {
			case EntryUser:
				user = entry
			case EntryTool:
				tool = entry
			}
		}
		if user == nil || tool == nil {
			return false
		}
		if !reflect.DeepEqual(user.Images, userImages) || !reflect.DeepEqual(tool.Images, toolImages) {
			t.Logf("user %v want %v, tool %v want %v", user.Images, userImages, tool.Images, toolImages)
			return false
		}
		// A replayed event for the same entry replaces its images.
		replayed := propImages(seed >> 6)
		activityEvent(&m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: tool.ID, ToolName: tool.ToolName,
			ToolResult: tool.ToolResult, Images: replayed, Replayed: true})
		if !reflect.DeepEqual(m.History.Entries()[m.History.Find(tool.ID)].Images, replayed) {
			t.Logf("replayed images not applied")
			return false
		}
		// Replayed events elsewhere in the stream leave the live turn alone.
		activityStart(&m, "live", "live work")
		m.Stopped, m.Stopping, m.TurnFailed = true, true, true
		m.settledToolLabel, m.ThoughtProgressText = "settled", "thinking"
		before := struct {
			status   daemon.AgentStatus
			order    []string
			stopped  bool
			stopping bool
			failed   bool
			label    string
			thought  string
		}{m.Status, append([]string{}, m.progressOrder...), m.Stopped, m.Stopping, m.TurnFailed, m.settledToolLabel, m.ThoughtProgressText}
		old := []daemon.StreamEvent{
			{Type: daemon.EventTurnCompleted, Outcome: daemon.OutcomeFailed},
			{Type: daemon.EventError, Text: "boom"},
			{Type: daemon.EventInterrupted},
			{Type: daemon.EventMessage, Text: "reply"},
			{Type: daemon.EventUser, Source: "chat", Text: "more"},
			{Type: daemon.EventToolProgress},
		}
		event := old[int(seed>>9)%len(old)]
		event.Replayed = true
		activityEvent(&m, event)
		if !reflect.DeepEqual(m.Status, before.status) || !slices.Equal(m.progressOrder, before.order) ||
			m.Stopped != before.stopped || m.Stopping != before.stopping || m.TurnFailed != before.failed ||
			m.settledToolLabel != before.label || m.ThoughtProgressText != before.thought {
			t.Logf("replayed %s disturbed live state: %+v vs %+v", event.Type, m.Status, before.status)
			return false
		}
		return true
	}
	if err := quick.Check(f, propConfig(19, 200)); err != nil {
		t.Fatal(err)
	}
}

// activityFinish2 is activityFinish with images.
func activityFinish2(m *ChatModel, id string, images []daemon.ImageMetadata) {
	activityEvent(m, daemon.StreamEvent{Type: daemon.EventTool, EntryID: "tool-" + id, ProgressCallID: id, ToolName: "python",
		ToolTitle: "work", ToolResult: `{"status":"ok"}`, Images: images})
}

// --- tool image selection ------------------------------------------------

// propToolImages builds a history from the generated kinds and image counts.
func propToolImages(kinds []int, counts []int, seed uint64) *BoundedHistory {
	history := NewBoundedHistory(500, 1<<20)
	kindsOf := []EntryKind{EntryTool, EntryUser, EntryAssistant, EntryNote}
	for i, count := range counts {
		entry := HistoryEntry{ID: fmt.Sprint("entry-", i), Kind: kindsOf[abs(kinds[i%len(kinds)])%len(kindsOf)]}
		for j := 0; j < abs(count)%4; j++ {
			ref := ""
			if (seed>>uint(i+j))%5 != 0 {
				// A small ref domain makes duplicates and ordering observable.
				ref = fmt.Sprint("/sessions/s/history/entry", (i+j)%6, "/image-", (i*j)%3+1)
			}
			entry.Images = append(entry.Images, daemon.ImageMetadata{Reference: ref,
				Width: int((seed>>uint(i*2+j))%90) + 1, Height: int((seed>>uint(i*3+j))%70) + 1})
		}
		history.Append(entry)
	}
	return history
}

// propSelectModel is the model: expanded entries newest first, then the rest
// newest first, each image once, empty references skipped, at most 24.
func propSelectModel(history *BoundedHistory, open map[string]bool) []string {
	var order []string
	seen := map[string]bool{}
	entries := history.Entries()
	add := func(entry HistoryEntry) {
		if entry.Kind != EntryTool && entry.Kind != EntryUser {
			return
		}
		for _, image := range entry.Images {
			if image.Reference == "" || len(order) >= maxToolImagePreviews || seen[image.Reference] {
				continue
			}
			seen[image.Reference] = true
			order = append(order, image.Reference)
		}
	}
	for i := len(entries) - 1; i >= 0; i-- {
		if len(entries[i].Images) > 0 && open[entryKey(entries[i])] {
			add(entries[i])
		}
	}
	for i := len(entries) - 1; i >= 0; i-- {
		add(entries[i])
	}
	return order
}

func propSelect(t *testing.T, history *BoundedHistory, open map[string]bool, width int) ([]string, map[string]daemon.ImageMetadata) {
	t.Helper()
	m := activityChat(t)
	m.History = history
	m.Renderer.Open = open
	m.Renderer.BodyWidth = width
	selection := m.selectToolImages()
	refs := make([]string, len(selection.order))
	copy(refs, selection.order)
	if len(selection.wanted) != len(selection.order) {
		t.Fatalf("wanted %d refs but order lists %d", len(selection.wanted), len(selection.order))
	}
	for _, ref := range selection.order {
		if _, ok := selection.wanted[ref]; !ok {
			t.Fatalf("order names %q that wanted lacks", ref)
		}
	}
	return refs, selection.wanted
}

// TestPropToolImageSelection keeps the retained previews equal to the model.
func TestPropToolImageSelection(t *testing.T) {
	f := func(seed uint64, expanded []int) bool {
		counts := make([]int, int(seed%6)+1)
		kinds := make([]int, len(counts))
		for i := range counts {
			counts[i] = int((seed >> uint(2*i)) % 4)
			kinds[i] = int((seed >> uint(2*i+1)) % 4)
		}
		history := propToolImages(kinds, counts, seed)
		open := map[string]bool{}
		for i, entry := range history.Entries() {
			if i < len(expanded) && abs(expanded[i])%2 == 0 {
				open[entryKey(entry)] = true
			}
		}
		got, _ := propSelect(t, history, open, 80)
		want := propSelectModel(history, open)
		if !slices.Equal(got, want) {
			t.Logf("expanded=%v entries=%d got=%v want=%v", open, len(history.Entries()), got, want)
			return false
		}
		return true
	}
	if err := quick.Check(f, propConfig(20, 300)); err != nil {
		t.Fatal(err)
	}
}

// TestPropToolImageSelectionCap keeps the selection at 24 previews, in visit
// order.
func TestPropToolImageSelectionCap(t *testing.T) {
	f := func(perEntry, entries int) bool {
		// Counts differ per entry so the 24th preview lands inside an entry
		// with images to spare, where the in-entry guard is what stops it.
		entries = abs(entries)%6 + 5
		history := NewBoundedHistory(500, 1<<20)
		for i := 0; i < entries; i++ {
			entry := HistoryEntry{ID: fmt.Sprint("entry-", i), Kind: EntryTool}
			for j := 0; j < abs(perEntry+i)%4+1; j++ {
				entry.Images = append(entry.Images, daemon.ImageMetadata{Reference: fmt.Sprint("/sessions/s/history/entry", i, "/image-", j+1)})
			}
			history.Append(entry)
		}
		got, _ := propSelect(t, history, map[string]bool{}, 80)
		want := propSelectModel(history, map[string]bool{})
		if len(got) > maxToolImagePreviews || !slices.Equal(got, want) {
			t.Logf("entries=%d perEntry=%d got %d want %d", entries, perEntry, len(got), len(want))
			return false
		}
		return true
	}
	if err := quick.Check(f, propConfig(21, 200)); err != nil {
		t.Fatal(err)
	}
}

// TestPropToolImageSelectionCache keeps the cached selection in step with the
// history and the open set, including in-place edits of that set.
func TestPropToolImageSelectionCache(t *testing.T) {
	f := func(seed uint64, prepend bool, expand bool) bool {
		history := propToolImages([]int{0, 1, 0}, []int{2, 2, 2}, seed)
		open := map[string]bool{}
		m := activityChat(t)
		m.History = history
		m.Renderer.Open = open
		m.Renderer.BodyWidth = 80
		selection := m.selectToolImages()
		if again := m.selectToolImages(); again != selection {
			t.Logf("unchanged history rebuilt the selection")
			return false
		}
		check := func(step string) bool {
			selection := m.selectToolImages()
			want := propSelectModel(history, open)
			if !slices.Equal(selection.order, want) || len(selection.wanted) != len(want) {
				t.Logf("%s: got %v want %v", step, selection.order, want)
				return false
			}
			return true
		}
		if prepend {
			older := HistoryEntry{ID: "older", Kind: EntryTool}
			for j := 0; j < 2; j++ {
				older.Images = append(older.Images, daemon.ImageMetadata{Reference: fmt.Sprint("/sessions/s/history/older/image-", j+1)})
			}
			history.Prepend([]HistoryEntry{older})
			if !check("prepend") {
				return false
			}
		}
		if expand {
			// The picker's open set is the same map object; editing it in
			// place must still invalidate the cached selection.
			for _, entry := range history.Entries() {
				if entry.Kind == EntryTool && !open[entryKey(entry)] {
					open[entryKey(entry)] = true
					break
				}
			}
			if !check("expand in place") {
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, propConfig(22, 150)); err != nil {
		t.Fatal(err)
	}
}

// TestPropCurrentRowNamesHighlighted keeps page_view's captured row equal to
// the row the list shows, before and after runAction's reset of the mode.
func TestPropCurrentRowNamesHighlighted(t *testing.T) {
	f := func(rows, cursor, mode int) bool {
		doc := &PageDocument{}
		rows = abs(rows) % 5
		for i := 0; i < rows; i++ {
			doc.Rows = append(doc.Rows, PageRow{ID: protocol.ID(fmt.Sprint("row", i)), Text: fmt.Sprint("row ", i)})
		}
		m := PageViewModel{Doc: doc}
		for i := range doc.Rows {
			m.rows = append(m.rows, listEntry{key: string(doc.Rows[i].ID)})
			m.shown = append(m.shown, listShown{row: i})
		}
		m.Cursor = abs(cursor) % max(1, rows)
		m.Mode = pageModeKind(abs(mode) % 4)
		before := m.currentRow()
		// runAction's reset, which the suite performs after capturing the row.
		m.Mode, m.CurrentAction = modeBrowse, nil
		m.Busy, m.Error, m.Notice = true, "", ""
		m.Generation = nextPageGeneration()
		after := m.currentRow()
		switch {
		case before == nil && after == nil:
			return true
		case before == nil || after == nil:
			t.Logf("rows=%d cursor=%d: %v then %v", rows, m.Cursor, before, after)
			return false
		}
		// The captured row is the one the list shows.
		return before.ID == after.ID && (rows == 0 || before.ID == doc.Rows[m.Cursor].ID)
	}
	if err := quick.Check(f, propConfig(23, 400)); err != nil {
		t.Fatal(err)
	}
}
