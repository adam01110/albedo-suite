package tui

// Property tests for context usage apportioning and bars, context markdown
// adaptation and quota display helpers, against direct recomputation.

import (
	"albedo/cli/internal/daemon"
	"fmt"
	"math"
	"math/rand"
	"strconv"
	"strings"
	"testing"
	"testing/quick"
	"time"
	"unicode"

	"github.com/charmbracelet/x/ansi"
)

func TestPropApportion(t *testing.T) {
	f := func(total uint32, raw []uint16) bool {
		weights := make([]int, len(raw)%6)
		for i := range weights {
			weights[i] = int(raw[i]) % 5000
			if i%3 == 0 {
				weights[i] = 0
			}
		}
		tot := int(total % 2_000_000)
		out := apportion(tot, weights)
		sum, wsum := 0, 0
		for i, v := range out {
			sum += v
			wsum += weights[i]
		}
		if wsum == 0 || tot == 0 {
			return sum == 0
		}
		if sum != tot {
			t.Logf("sum %d != %d for %v", sum, tot, weights)
			return false
		}
		for i, v := range out {
			exact := float64(tot) * float64(weights[i]) / float64(wsum)
			if math.Abs(float64(v)-exact) >= 1 || weights[i] == 0 && v != 0 {
				t.Logf("part %d = %d, exact %f (%v)", i, v, exact, weights)
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 20000}); err != nil {
		t.Fatal(err)
	}
}

func TestPropContextCells(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	for range 20000 {
		u := contextUsage{Window: []int{0, 1000, 200_000, 1_000_000}[r.Intn(4)]}
		for i := range 1 + r.Intn(4) {
			tokens := 0
			if r.Intn(4) > 0 {
				tokens = r.Intn(max(1, u.Window/2+10))
			}
			u.Parts = append(u.Parts, contextPart{Label: strconv.Itoa(i), Tokens: tokens})
			u.Used += tokens
		}
		if u.Window > 0 && r.Intn(2) == 0 {
			u.Trigger = 1 + r.Intn(u.Window)
		}
		n := 1 + r.Intn(60)
		cells := u.cells(n)
		if len(cells) != n {
			t.Fatalf("%d cells for %d", len(cells), n)
		}
		nonzero := 0
		for _, p := range u.Parts {
			if p.Tokens > 0 {
				nonzero++
			}
		}
		per := float64(max(u.Window, u.Used, 1)) / float64(n)
		counts := make([]int, len(u.Parts))
		lastPart, usedRun := -1, true
		for i, c := range cells {
			if c.used {
				if !usedRun || c.part < lastPart {
					t.Fatalf("%+v n %d: used cell %d out of order: %v", u, n, i, cells)
				}
				lastPart = c.part
				counts[c.part]++
			} else {
				usedRun = false
				wantReserve := u.Trigger > 0 && float64(i) >= math.Round(float64(u.Trigger)/per)
				if c.reserve != wantReserve {
					t.Fatalf("%+v n %d: cell %d reserve %v want %v", u, n, i, c.reserve, wantReserve)
				}
			}
		}
		for i, p := range u.Parts {
			if p.Tokens == 0 && counts[i] != 0 {
				t.Fatalf("empty part %d drew %d cells", i, counts[i])
			}
			if p.Tokens > 0 && nonzero <= n && counts[i] == 0 {
				t.Fatalf("%+v n %d: part %d has tokens but no cell: %v", u, n, i, counts)
			}
			// Without overflow a part's cells are its rounded share, or 1.
			ideal := max(1, int(math.Round(float64(p.Tokens)/per)))
			total := 0
			for _, q := range u.Parts {
				if q.Tokens > 0 {
					total += max(1, int(math.Round(float64(q.Tokens)/per)))
				}
			}
			if p.Tokens > 0 && total <= n && counts[i] != ideal {
				t.Fatalf("%+v n %d: part %d drew %d cells, want %d", u, n, i, counts[i], ideal)
			}
		}
		// Used, free and reserve account for the whole window when the request fits.
		if u.Window > 0 && u.Used <= u.Window {
			reserve := 0
			if u.Trigger > 0 {
				reserve = u.Window - max(u.Trigger, u.Used)
			}
			free := max(0, u.Window-u.Used-max(0, reserve))
			if u.Used+free+max(0, reserve) != u.Window {
				t.Fatalf("%+v: used %d + free %d + reserve %d != window", u, u.Used, free, reserve)
			}
		}
	}
}

func TestPropContextPercent(t *testing.T) {
	r := rand.New(rand.NewSource(2))
	for range 20000 {
		u := contextUsage{Window: r.Intn(3_000_000)}
		tokens := r.Intn(3_500_000)
		got := u.percent(tokens)
		if u.Window <= 0 {
			if got != "" {
				t.Fatalf("no window: %q", got)
			}
			continue
		}
		pct := 100 * float64(tokens) / float64(u.Window)
		v, err := strconv.ParseFloat(strings.TrimSuffix(got, "%"), 64)
		if err != nil || !strings.HasSuffix(got, "%") || math.Abs(v-pct) > 0.5+1e-9 || (tokens > 0 && v == 0 && pct >= 0.05) {
			t.Fatalf("percent(%d of %d) = %q, exact %f", tokens, u.Window, got, pct)
		}
	}
}

func TestPropContextMarkdownKeepsText(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	pieces := []string{"<tag>", "</tag>", "<a b=\"1\">", "{\"k\": [1, 2]}", "[1,", "```", "~~~", "text", "  indented", "- item", "# head", "", "`code`", "x > y", "<", ">", "{", "]", "\t"}
	strip := func(s string) string {
		return strings.Map(func(r rune) rune {
			if unicode.IsSpace(r) {
				return -1
			}
			return r
		}, s)
	}
	for range 20000 {
		var lines []string
		for range r.Intn(8) {
			var b strings.Builder
			for range 1 + r.Intn(3) {
				b.WriteString(pieces[r.Intn(len(pieces))])
			}
			lines = append(lines, b.String())
		}
		in := strings.Join(lines, "\n")
		out := contextMarkdown(in)
		// Every non-space character of the input survives in order.
		want, got := []rune(strip(in)), []rune(strip(out))
		j := 0
		for _, c := range got {
			if j < len(want) && c == want[j] {
				j++
			}
		}
		if j != len(want) {
			t.Fatalf("lost text at %d of %q\ninput  %q\noutput %q", j, string(want), in, out)
		}
	}
}

func TestPropQuotaSpan(t *testing.T) {
	r := rand.New(rand.NewSource(4))
	unit := map[string]time.Duration{"d": 24 * time.Hour, "h": time.Hour, "m": time.Minute}
	parse := func(s string) (time.Duration, time.Duration, bool) {
		var total, smallest time.Duration
		parts := 0
		for s != "" {
			i := strings.IndexFunc(s, func(r rune) bool { return !unicode.IsDigit(r) })
			if i <= 0 {
				return 0, 0, false
			}
			n, _ := strconv.Atoi(s[:i])
			u, ok := unit[s[i:i+1]]
			if !ok {
				return 0, 0, false
			}
			total += time.Duration(n) * u
			smallest = u
			s = s[i+1:]
			parts++
		}
		return total, smallest, parts >= 1 && parts <= 2
	}
	prev := time.Duration(-1)
	prevValue := time.Duration(-1)
	for i := range 50000 {
		d := time.Duration(r.Int63n(int64(40 * 24 * time.Hour)))
		if i%2 == 0 {
			d = prev + time.Duration(r.Int63n(int64(3*time.Hour)))
		}
		got := quotaSpan(d)
		if d < time.Minute {
			if got != "<1m" {
				t.Fatalf("quotaSpan(%v) = %q", d, got)
			}
			continue
		}
		v, small, ok := parse(got)
		// Days and hours show two units; the shown value truncates d to the
		// smaller unit it names, or to the larger unit when the rest is zero.
		if !ok || v > d || d-v >= max(small, unit["h"]) && d >= 24*time.Hour || d < 24*time.Hour && d-v >= small {
			t.Fatalf("quotaSpan(%v) = %q (value %v)", d, got, v)
		}
		if i%2 == 0 && d >= prev && v < prevValue {
			t.Fatalf("quotaSpan not monotone: %v -> %v", prev, d)
		}
		prev, prevValue = d, v
	}
}

func TestPropQuotaBarAndSpark(t *testing.T) {
	r := rand.New(rand.NewSource(5))
	for range 5000 {
		p := float64(r.Intn(10001)) / 100
		bar := ansi.Strip(quotaBar(p, r.Intn(2) == 0))
		filled := strings.Count(bar, "▰")
		want := int(math.Floor(p/10 + 0.5))
		if p > 0 {
			want = max(1, want)
		}
		if filled != want || filled+strings.Count(bar, "▱") != quotaBarSlots {
			t.Fatalf("quotaBar(%v) = %q", p, bar)
		}
	}
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for range 5000 {
		var points []quotaPoint
		at := base.Add(-time.Duration(r.Intn(3)) * time.Hour)
		for range r.Intn(12) {
			at = at.Add(time.Duration(r.Intn(90)) * time.Minute)
			points = append(points, quotaPoint{At: at, Percent: float64(r.Intn(120))})
		}
		from := base
		to := base.Add(time.Duration(1+r.Intn(48)) * time.Hour)
		width := 1 + r.Intn(50)
		rows := quotaSpark(points, from, to, width)
		top, bottom := []rune(ansi.Strip(rows[0])), []rune(ansi.Strip(rows[1]))
		if len(top) != width || len(bottom) != width {
			t.Fatalf("spark widths %d/%d want %d", len(top), len(bottom), width)
		}
		step := to.Sub(from) / time.Duration(width)
		for col := range width {
			end := from.Add(step * time.Duration(col+1))
			// Independent scan: the last reading at or before the column's end.
			idx := -1
			for i, p := range points {
				if !p.At.After(end) {
					idx = i
				}
			}
			blank := idx < 0 || end.Sub(points[idx].At) > quotaStale
			if blank != (bottom[col] == ' ') {
				t.Fatalf("col %d blank=%v got %q (points %v)", col, blank, string(bottom[col]), points)
			}
			if blank {
				continue
			}
			left := max(0, min(100, 100-points[idx].Percent))
			level := int(math.Floor(left/100*16 + 0.5))
			if left > 0 {
				level = max(1, level)
			}
			wantTop := ' '
			if level > 8 {
				wantTop = []rune("▁▂▃▄▅▆▇█")[level-9]
			}
			if top[col] != wantTop {
				t.Fatalf("col %d level %d top %q want %q", col, level, string(top[col]), string(wantTop))
			}
		}
	}
}

func TestPropQuotaPace(t *testing.T) {
	r := rand.New(rand.NewSource(6))
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	for range 20000 {
		// A steady climb at rate percent an hour over the last span.
		rate := float64(r.Intn(400)) / 10
		if rate == 0.5 {
			// Exactly the threshold: truncated point times decide either way.
			rate = 0.6
		}
		start := float64(r.Intn(90))
		span := time.Duration(20+r.Intn(70)) * time.Minute
		var points []quotaPoint
		if r.Intn(2) == 0 {
			// Readings from before a window reset, still inside the lookback.
			span = min(span, 70*time.Minute)
			points = append(points, quotaPoint{At: now.Add(-span - 15*time.Minute), Percent: start + 5}, quotaPoint{At: now.Add(-span - 5*time.Minute), Percent: start + 9})
		}
		for k := 0; k <= 6; k++ {
			at := now.Add(-span + span*time.Duration(k)/6)
			points = append(points, quotaPoint{At: at, Percent: start + rate*span.Hours()*float64(k)/6})
		}
		resets := now.Add(time.Duration(1+r.Intn(600)) * time.Minute).Format(time.RFC3339)
		obs := daemon.QuotaObservation{ResetsAt: &resets}
		got := quotaPace(points, obs, now)
		last := points[len(points)-1].Percent
		left, _ := time.Parse(time.RFC3339, resets)
		hours := left.Sub(now).Hours()
		switch {
		case rate >= 0.5 && math.Abs(last+rate*hours-100) < 0.01:
			// Filling exactly at the reset may read either way.
		case rate < 0.5:
			if got != "holding steady" {
				t.Fatalf("rate %v: %q", rate, got)
			}
		case last+rate*hours >= 100:
			// Fills before the reset: the projection says when, near (100-last)/rate.
			want := time.Duration((100 - last) / rate * float64(time.Hour))
			if !strings.HasPrefix(got, "empty in ~") {
				t.Fatalf("rate %v last %v hours %v: %q", rate, last, hours, got)
			}
			// Point times are whole nanoseconds, so allow a minute of truncation.
			near := strings.HasSuffix(got, "~"+quotaSpan(want)) || strings.HasSuffix(got, "~"+quotaSpan(want-time.Minute)) || strings.HasSuffix(got, "~"+quotaSpan(want+time.Minute))
			if !near && math.Abs((100-last)/rate-hours) > 0.01 {
				t.Fatalf("rate %v last %v: %q want ~%s", rate, last, got, quotaSpan(want))
			}
		default:
			want := 100 - last - rate*hours
			var v float64
			if _, err := fmt.Sscanf(got, "ends near %f%% left", &v); err != nil || math.Abs(v-want) > 1 {
				t.Fatalf("rate %v last %v hours %v: %q want ~%.1f%%", rate, last, hours, got, want)
			}
		}
	}
}
