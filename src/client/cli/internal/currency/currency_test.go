package currency

import (
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const feed = `<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
	<gesmes:subject>Reference rates</gesmes:subject>
	<Cube>
		<Cube time='2026-11-27'>
			<Cube currency='USD' rate='1.25'/>
			<Cube currency='GBP' rate='0.85'/>
			<Cube currency='CHF' rate='0.9157'/>
		</Cube>
	</Cube>
</gesmes:Envelope>`

// isolate points the cache and feed at test fixtures and clears the rate.
func isolate(t *testing.T, url string) string {
	t.Helper()
	t.Setenv("ALBEDO_CURRENCY", "")
	path := filepath.Join(t.TempDir(), "albedo", "rates.xml")
	oldSource, oldCache := source, cachePath
	source, cachePath = url, func() (string, error) { return path, nil }
	current.Store(nil)
	t.Cleanup(func() { source, cachePath = oldSource, oldCache; current.Store(nil) })
	return path
}

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestCurrencyConfigured(t *testing.T) {
	for value, want := range map[string]string{"": "", "usd": "", " eur ": "EUR", "GBP": "GBP", "EURO": "", "E1R": "", "€": ""} {
		t.Setenv("ALBEDO_CURRENCY", value)
		if got := Configured(); got != want {
			t.Fatalf("Configured(%q) = %q, want %q", value, got, want)
		}
	}
}

func TestCurrencyCrossRates(t *testing.T) {
	parsed, err := parse([]byte(feed))
	if err != nil {
		t.Fatal(err)
	}
	eur, _ := parsed.display("EUR")
	gbp, _ := parsed.display("GBP")
	chf, _ := parsed.display("CHF")
	if eur.symbol != "€" || !near(eur.perUSD, 0.8) || gbp.symbol != "£" || !near(gbp.perUSD, 0.68) || chf.symbol != "CHF " {
		t.Fatalf("cross rates: %+v %+v %+v", eur, gbp, chf)
	}
	if _, ok := parsed.display("XYZ"); ok {
		t.Fatal("unpublished currency accepted")
	}
	if _, err := parse([]byte(`<Envelope><Cube><Cube><Cube currency='GBP' rate='0.85'/></Cube></Cube></Envelope>`)); err == nil {
		t.Fatal("feed without USD accepted")
	}
}

func TestCurrencyRefreshCachesAndConverts(t *testing.T) {
	hits := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits++
		_, _ = w.Write([]byte(feed))
	}))
	defer server.Close()
	path := isolate(t, server.URL)
	if !load("EUR", time.Now()) {
		t.Fatal("missing cache not stale")
	}
	if amount, symbol := Convert(10); amount != 10 || symbol != "$" {
		// Convert's once may already have run in this binary; either way no
		// rate is known yet.
		t.Fatalf("before refresh: %v %q", amount, symbol)
	}
	if err := refresh("EUR"); err != nil || hits != 1 {
		t.Fatalf("refresh: %v, %d hits", err, hits)
	}
	if amount, symbol := Convert(10); !near(amount, 8) || symbol != "€" {
		t.Fatalf("after refresh: %v %q", amount, symbol)
	}
	current.Store(nil)
	if load("EUR", time.Now()) {
		t.Fatal("fresh cache reported stale")
	}
	if amount, _ := Convert(10); !near(amount, 8) {
		t.Fatalf("cached rate not applied: %v", amount)
	}
	old := time.Now().Add(-refreshAfter - time.Minute)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if !load("EUR", time.Now()) {
		t.Fatal("old cache not stale")
	}
	if amount, _ := Convert(10); !near(amount, 8) {
		t.Fatalf("old cache not used while refreshing: %v", amount)
	}
}

func TestCurrencyFailedRefreshKeepsRate(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	defer server.Close()
	path := isolate(t, server.URL)
	if err := refresh("EUR"); err == nil {
		t.Fatal("failed fetch reported success")
	}
	if amount, symbol := Convert(10); amount != 10 || symbol != "$" {
		t.Fatalf("failed fetch changed the display: %v %q", amount, symbol)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("failed fetch wrote a cache: %v", err)
	}
	if err := writeCache([]byte(feed)); err != nil {
		t.Fatal(err)
	}
	load("GBP", time.Now())
	if err := refresh("GBP"); err == nil {
		t.Fatal("failed fetch reported success")
	}
	if amount, symbol := Convert(10); !near(amount, 6.8) || symbol != "£" {
		t.Fatalf("failed fetch dropped the cached rate: %v %q", amount, symbol)
	}
}
