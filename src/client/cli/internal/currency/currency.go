// Package currency shows the daemon's USD estimates in the currency named by
// ALBEDO_CURRENCY (albedo-suite), such as EUR, converted at the European
// Central Bank's daily euro reference rates. The rates are fetched in the
// background and cached; until a rate is known, and for a code the ECB does
// not publish, amounts stay in USD.
package currency

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// The ECB publishes once each working day, around 16:00 CET.
const (
	feedURL      = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
	refreshAfter = 12 * time.Hour
	fetchTimeout = 15 * time.Second
	feedLimit    = 1 << 20
)

var (
	source    = feedURL
	cachePath = defaultCachePath
	startOnce sync.Once
	current   atomic.Pointer[display]
)

type display struct {
	symbol string
	perUSD float64
}

// symbols holds the marks written before an amount; other codes are
// written as the code and a space, such as "CHF 1.20".
var symbols = map[string]string{"EUR": "€", "GBP": "£", "JPY": "¥", "USD": "$"}

// Convert returns usd in the configured currency and the mark to write
// before it. The first call reads the cached rates and starts a refresh when
// they are old.
func Convert(usd float64) (float64, string) {
	startOnce.Do(func() {
		code := Configured()
		if code != "" && load(code, time.Now()) {
			go func() { _ = refresh(code) }()
		}
	})
	if d := current.Load(); d != nil {
		return usd * d.perUSD, d.symbol
	}
	return usd, "$"
}

// Configured is the ISO 4217 code in ALBEDO_CURRENCY, or "" for USD.
func Configured() string {
	code := strings.ToUpper(strings.TrimSpace(os.Getenv("ALBEDO_CURRENCY")))
	if code == "USD" || len(code) != 3 || strings.Trim(code, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") != "" {
		return ""
	}
	return code
}

// rates are units of each currency per euro.
type rates map[string]float64

func parse(data []byte) (rates, error) {
	var doc struct {
		Cubes []struct {
			Currency string  `xml:"currency,attr"`
			Rate     float64 `xml:"rate,attr"`
		} `xml:"Cube>Cube>Cube"`
	}
	if err := xml.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	parsed := rates{"EUR": 1}
	for _, cube := range doc.Cubes {
		if cube.Rate > 0 && !math.IsInf(cube.Rate, 0) {
			parsed[strings.ToUpper(cube.Currency)] = cube.Rate
		}
	}
	if parsed["USD"] == 0 {
		return nil, errors.New("reference rates have no USD rate")
	}
	return parsed, nil
}

func (r rates) display(code string) (*display, bool) {
	rate, ok := r[code]
	if !ok {
		return nil, false
	}
	symbol, ok := symbols[code]
	if !ok {
		symbol = code + " "
	}
	return &display{symbol: symbol, perUSD: rate / r["USD"]}, true
}

func defaultCachePath() (string, error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "albedo", "ecb-eurofxref-daily.xml"), nil
}

// load applies the cached rates for code and reports whether they need a
// refresh: missing, unreadable, without code, or older than refreshAfter.
func load(code string, now time.Time) bool {
	path, err := cachePath()
	if err != nil {
		return true
	}
	info, err := os.Stat(path)
	if err != nil {
		return true
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return true
	}
	parsed, err := parse(data)
	if err != nil {
		return true
	}
	d, ok := parsed.display(code)
	if !ok {
		return true
	}
	current.Store(d)
	return now.Sub(info.ModTime()) > refreshAfter
}

// refresh fetches the reference rates, applies code's and caches the feed.
// A failure keeps whatever rate is in use.
func refresh(code string) error {
	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("reference rates: %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, feedLimit))
	if err != nil {
		return err
	}
	parsed, err := parse(data)
	if err != nil {
		return err
	}
	d, ok := parsed.display(code)
	if !ok {
		return fmt.Errorf("reference rates have no %s rate", code)
	}
	current.Store(d)
	return writeCache(data)
}

// writeCache replaces the cache atomically, so a reader never sees half a feed.
func writeCache(data []byte) error {
	path, err := cachePath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".ecb-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
