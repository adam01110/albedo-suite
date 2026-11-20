// `GET /usage` takes a window, the clock its days begin on, and optionally one
// provider and one account, and answers with what a screen cannot rebuild for
// itself: the scopes the window saw and whether the lines and scopes were cut.
// Two of those rules fail silently instead of loudly, so a unit test is the
// only place that holds them. An empty `account` means the provider's rows that
// had no account; leaving it out reads every account of that provider, which
// looks like a narrower answer and is a wider one. And a list the daemon cut
// is only the busiest hundred lines or two hundred scopes, which a row count
// cannot tell from a whole list. E2E reaches neither: its fixture would need
// more than a hundred lines or two hundred scopes, and its assertions would be
// about the query rather than the screen.
package daemon

import (
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// usageServer is a daemon that serves the usage capability the screen needs.
const usageServer = `{"instance_id":"instance-a","protocol":4,"state":"ready","capabilities":{"durable_inputs":1,"session_replay":2,"collection_invalidation":1,"tool_progress":1,"context":1,"catalog":1,"workspace_browsing":1,"host_probes":1,"provider_auth":1,"history_rewind":1,"storage_report":1,"usage_summary":1},"build":null,"digest":null,"extensions":[],"quota":null,"notices":[]}`

// usageAnswer is a summary of one day at UTC-6, one line with no account and
// two scopes, cut in both lists.
const usageAnswer = `{"generated_at":"2026-10-25T18:00:00Z","utc_offset_minutes":-360,` +
	`"days":[{"start":"2026-10-24T06:00:00Z","calls":2,"errors":1,"input_tokens":380000,"cached_input_tokens":310000,"cache_creation_tokens":0,"output_tokens":12000,"reasoning_tokens":2000}],` +
	`"lines":[{"profile":"work","provider":"claude","account":null,"model":"example-large","calls":2,"errors":1,"input_tokens":380000,"cached_input_tokens":310000,"cache_creation_tokens":0,"output_tokens":12000,"reasoning_tokens":2000}],` +
	`"scopes":[{"provider":"claude","account":null},{"provider":"responses:https://api.example.com/v1","account":"dawn@example.com"}],` +
	`"lines_truncated":true,"scopes_truncated":true}`

func usageConnection(t *testing.T, handler http.HandlerFunc) *Connection {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/server" {
			_, _ = w.Write([]byte(usageServer))
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	conn, err := Attach(t.Context(), ConnectionSnapshot{
		Port:    server.Listener.Addr().(*net.TCPAddr).Port,
		Token:   "token",
		Version: ProtocolVersion,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(conn.HTTPClient().CloseIdleConnections)
	return conn
}

func TestGetUsageSendsTheChosenScopeAndReadsWhatWasCut(t *testing.T) {
	conn := usageConnection(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/usage" {
			t.Errorf("unexpected request %s", r.URL.Path)
		}
		q := r.URL.Query()
		if q.Get("days") != "7" {
			t.Errorf("days = %q, want 7", q.Get("days"))
		}
		if q.Get("utc_offset_minutes") != "-360" {
			t.Errorf("utc_offset_minutes = %q, want -360", q.Get("utc_offset_minutes"))
		}
		if q.Get("provider") != "claude" {
			t.Errorf("provider = %q, want claude", q.Get("provider"))
		}
		if !q.Has("account") || q.Get("account") != "" {
			t.Errorf("account = %v, want it sent as empty: that is the provider's no-account rows", q["account"])
		}
		_, _ = w.Write([]byte(usageAnswer))
	})
	account := ""
	summary, err := GetUsage(t.Context(), conn, UsageQuery{Days: 7, UTCOffsetMinutes: -360, Provider: "claude", Account: &account})
	if err != nil {
		t.Fatal(err)
	}
	if want := time.Date(2026, 10, 25, 18, 0, 0, 0, time.UTC); !summary.GeneratedAt.Equal(want) {
		t.Errorf("generated_at = %s, want %s", summary.GeneratedAt, want)
	}
	if summary.UTCOffsetMinutes != -360 {
		t.Errorf("utc_offset_minutes = %d, want -360", summary.UTCOffsetMinutes)
	}
	if len(summary.Days) != 1 || !summary.Days[0].Start.Equal(time.Date(2026, 10, 24, 6, 0, 0, 0, time.UTC)) {
		t.Fatalf("days = %+v, want the day read at its own start", summary.Days)
	}
	if day := summary.Days[0].UsageTotals; day.Calls != 2 || day.Errors != 1 || day.CachedInputTokens != 310_000 {
		t.Errorf("day totals = %+v", day)
	}
	if len(summary.Lines) != 1 || summary.Lines[0].Account != "" || summary.Lines[0].Model != "example-large" {
		t.Fatalf("lines = %+v, want a null account read as none", summary.Lines)
	}
	if len(summary.Scopes) != 2 || summary.Scopes[0].Account != "" || summary.Scopes[1].Account != "dawn@example.com" {
		t.Fatalf("scopes = %+v", summary.Scopes)
	}
	if !summary.LinesTruncated || !summary.ScopesTruncated {
		t.Errorf("a cut answer must say it was cut: %+v", summary)
	}
}

func TestGetUsageKeepsTheQueryInTheRangeTheDaemonAccepts(t *testing.T) {
	tests := []struct {
		name         string
		days, offset string
		query        UsageQuery
	}{
		{name: "a window the daemon counts by default", query: UsageQuery{}, days: "7", offset: "0"},
		{name: "a longer window than the daemon counts", query: UsageQuery{Days: 400, UTCOffsetMinutes: 1000}, days: "371", offset: "840"},
		{name: "a window of less than a day", query: UsageQuery{Days: -3, UTCOffsetMinutes: -1000}, days: "1", offset: "-720"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			conn := usageConnection(t, func(w http.ResponseWriter, r *http.Request) {
				q := r.URL.Query()
				if q.Get("days") != test.days || q.Get("utc_offset_minutes") != test.offset {
					t.Errorf("days=%q offset=%q, want %s and %s", q.Get("days"), q.Get("utc_offset_minutes"), test.days, test.offset)
				}
				if q.Has("provider") || q.Has("account") {
					t.Errorf("no scope was chosen, but the request asked for %v and %v", q["provider"], q["account"])
				}
				_, _ = w.Write([]byte(`{"generated_at":"2026-10-25T18:00:00Z","utc_offset_minutes":0,"days":[],"lines":[],"scopes":[],"lines_truncated":false,"scopes_truncated":false}`))
			})
			if _, err := GetUsage(t.Context(), conn, test.query); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestGetUsageRefusesAnAccountWithoutItsProvider(t *testing.T) {
	// Two providers can label accounts the same way, so an account alone names
	// nothing. It is refused here, where the caller is, rather than sent as a
	// read of every provider's account of that name.
	var asked atomic.Int32
	conn := usageConnection(t, func(w http.ResponseWriter, r *http.Request) {
		asked.Add(1)
		t.Errorf("an account without its provider must not be sent, got %s?%s", r.URL.Path, r.URL.RawQuery)
	})
	account := "dawn@example.com"
	_, err := GetUsage(t.Context(), conn, UsageQuery{Days: 7, Account: &account})
	if err == nil {
		t.Fatal("an account without its provider should be refused")
	}
	if asked.Load() != 0 {
		t.Fatalf("the daemon was asked %d times", asked.Load())
	}
}
