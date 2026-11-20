package daemon

import (
	"context"
	"errors"
	"io"
	"net/http"
	"time"

	"albedo/cli/internal/daemon/protocol"
)

// The window `GET /usage` counts, and the clock it accepts: a day is the
// client's own, so its offset is bounded to the offsets real clocks keep.
const (
	usageDefaultDays      = 7
	usageMaxDays          = 371
	usageMinOffsetMinutes = -12 * 60
	usageMaxOffsetMinutes = 14 * 60
)

// UsageTotals are what the provider calls used, as the providers reported
// them. CachedInputTokens is part of InputTokens, so the two are never summed.
type UsageTotals struct {
	Calls               int64
	Errors              int64
	InputTokens         int64
	CachedInputTokens   int64
	CacheCreationTokens int64
	OutputTokens        int64
	ReasoningTokens     int64
}

// UsageDay is one day of the client's, beginning at Start.
type UsageDay struct {
	Start time.Time
	UsageTotals
}

// UsageLine is what one profile, account and model used over the whole window.
// Account is empty for a provider without an account pool.
type UsageLine struct {
	Profile  string
	Provider string
	Account  string
	Model    string
	UsageTotals
}

// UsageScope is one provider and account the window's calls were made under,
// named as the lines name them. Account is empty for a provider without an
// account pool.
type UsageScope struct {
	Provider string
	Account  string
}

type UsageSummary struct {
	GeneratedAt time.Time
	// Days has one entry for each day asked for, oldest first.
	Days []UsageDay
	// Lines are the most used first, the busiest hundred of what matched.
	Lines []UsageLine
	// Scopes are every provider and account with use in the window, before the
	// query narrowed the days and lines: what a screen can offer to show.
	Scopes []UsageScope
	// UTCOffsetMinutes is the clock those days were counted on: how far ahead
	// of UTC the client's own clock ran.
	UTCOffsetMinutes int
	// LinesTruncated says more lines matched than Lines lists.
	LinesTruncated bool
	// ScopesTruncated says more scopes used the window than Scopes lists.
	ScopesTruncated bool
	// Profile is every call ever recorded, whatever the query narrowed; nil
	// when the daemon does not report one.
	Profile *UsageProfile
}

// UsageProfile is what every recorded call used, counted in the query's days.
// Tokens are input plus output, as a usage bar measures them.
type UsageProfile struct {
	LifetimeTokens    int64
	LifetimeCalls     int64
	ActiveDays        int64
	FirstDay          time.Time // zero before any use
	PeakDay           time.Time // zero before any use
	PeakDayTokens     int64
	LongestStreakDays int64
	CurrentStreakDays int64
	// LongestTurn is the longest completed turn still recorded; zero when none.
	LongestTurn time.Duration
}

// UsageQuery is what a usage read counts: the window, the clock that decides
// where its days begin, and optionally one provider and account of it.
type UsageQuery struct {
	// Account counts only this account of Provider, matched exactly. Nil
	// counts every account, and the empty string the rows of a provider that
	// had no account. An account needs its provider, because two providers can
	// label accounts the same way.
	Account *string
	// Provider counts only this provider's rows, named as the lines name it;
	// empty counts every provider.
	Provider string
	// Days is how many days the window covers, the current one included: 1 to
	// 90, and 7 when zero.
	Days int
	// UTCOffsetMinutes is how far ahead of UTC the clock that decides where
	// the days begin runs.
	UTCOffsetMinutes int
}

// GetUsage reads what the provider calls used over the query's days, the
// current one included.
func GetUsage(ctx context.Context, conn *Connection, query UsageQuery) (UsageSummary, error) {
	if query.Account != nil && query.Provider == "" {
		return UsageSummary{}, errors.New("a usage account filter needs its provider")
	}
	days := query.Days
	if days == 0 {
		days = usageDefaultDays
	}
	days = min(usageMaxDays, max(1, days))
	offset := min(usageMaxOffsetMinutes, max(usageMinOffsetMinutes, query.UTCOffsetMinutes))
	params := protocol.GetUsageParams{Days: new(int64(days)), UtcOffsetMinutes: new(int64(offset))}
	if query.Provider != "" {
		params.Provider = &query.Provider
	}
	if query.Account != nil {
		account := *query.Account
		params.Account = &account
	}
	var w protocol.UsageSummary
	err := executeRead(ctx, conn, operation{Capability: "usage_summary", Name: "read usage", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewGetUsageRequest(base, &params)
	}, Policy: readRecovery}, func(data []byte) error {
		return decodeRequired(data, &w)
	})
	if err != nil {
		return UsageSummary{}, err
	}
	summary, err := usageSummary(w)
	if err != nil {
		return UsageSummary{}, err
	}
	return summary, nil
}

// usageSummary is the wire summary with its stamps read: the days and the lines
// the screen draws.
func usageSummary(w protocol.UsageSummary) (UsageSummary, error) {
	generated, err := time.Parse(time.RFC3339, w.GeneratedAt)
	if err != nil {
		return UsageSummary{}, err
	}
	summary := UsageSummary{
		GeneratedAt:      generated,
		UTCOffsetMinutes: int(w.UtcOffsetMinutes),
		Days:             make([]UsageDay, 0, len(w.Days)),
		Lines:            make([]UsageLine, 0, len(w.Lines)),
		Scopes:           make([]UsageScope, 0, len(w.Scopes)),
		LinesTruncated:   w.LinesTruncated,
		ScopesTruncated:  w.ScopesTruncated,
	}
	for _, day := range w.Days {
		start, err := time.Parse(time.RFC3339, day.Start)
		if err != nil {
			return UsageSummary{}, err
		}
		summary.Days = append(summary.Days, UsageDay{Start: start, UsageTotals: UsageTotals{day.Calls, day.Errors, day.InputTokens, day.CachedInputTokens, day.CacheCreationTokens, day.OutputTokens, day.ReasoningTokens}})
	}
	for _, line := range w.Lines {
		account := ""
		if line.Account != nil {
			account = *line.Account
		}
		summary.Lines = append(summary.Lines, UsageLine{Profile: line.Profile, Provider: line.Provider, Account: account, Model: line.Model, UsageTotals: UsageTotals{line.Calls, line.Errors, line.InputTokens, line.CachedInputTokens, line.CacheCreationTokens, line.OutputTokens, line.ReasoningTokens}})
	}
	for _, scope := range w.Scopes {
		account := ""
		if scope.Account != nil {
			account = *scope.Account
		}
		summary.Scopes = append(summary.Scopes, UsageScope{Provider: scope.Provider, Account: account})
	}
	if p := w.Profile; p != nil {
		profile := UsageProfile{
			LifetimeTokens:    p.LifetimeTokens,
			LifetimeCalls:     p.LifetimeCalls,
			ActiveDays:        p.ActiveDays,
			PeakDayTokens:     p.PeakDayTokens,
			LongestStreakDays: p.LongestStreakDays,
			CurrentStreakDays: p.CurrentStreakDays,
		}
		var err error
		if profile.FirstDay, err = usageStamp(p.FirstDay); err != nil {
			return UsageSummary{}, err
		}
		if profile.PeakDay, err = usageStamp(p.PeakDay); err != nil {
			return UsageSummary{}, err
		}
		if p.LongestTurnMs != nil {
			profile.LongestTurn = time.Duration(*p.LongestTurnMs) * time.Millisecond
		}
		summary.Profile = &profile
	}
	return summary, nil
}

// usageStamp is an optional wire stamp, zero when the daemon sent none.
func usageStamp(stamp *protocol.Timestamp) (time.Time, error) {
	if stamp == nil {
		return time.Time{}, nil
	}
	return time.Parse(time.RFC3339, *stamp)
}
