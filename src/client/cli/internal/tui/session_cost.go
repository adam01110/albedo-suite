package tui

import (
	"fmt"
	"math"

	"albedo/cli/internal/currency"
)

// estimatedCost formats a daemon session estimate; false means it is unknown.
// Compact drops cents from four-digit totals so they fit a list column. The
// amount is shown in the currency ALBEDO_CURRENCY names (albedo-suite).
func estimatedCost(cost *float64, compact bool) (string, bool) {
	if cost == nil || *cost < 0 || math.IsNaN(*cost) || math.IsInf(*cost, 0) {
		return "", false
	}
	amount, symbol := currency.Convert(*cost)
	switch {
	case amount > 0 && amount < 0.01:
		return symbol + "<0.01", true
	case compact && amount >= 1000:
		return fmt.Sprintf("%s%.0f", symbol, amount), true
	}
	return fmt.Sprintf("%s%.2f", symbol, amount), true
}
