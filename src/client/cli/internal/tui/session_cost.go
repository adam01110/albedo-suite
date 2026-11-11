package tui

import (
	"fmt"
	"math"
)

// estimatedCost formats a daemon session estimate; false means it is unknown.
// Compact drops cents from four-digit totals so they fit a list column.
func estimatedCost(cost *float64, compact bool) (string, bool) {
	if cost == nil || *cost < 0 || math.IsNaN(*cost) || math.IsInf(*cost, 0) {
		return "", false
	}
	switch {
	case *cost > 0 && *cost < 0.01:
		return "$<0.01", true
	case compact && *cost >= 1000:
		return fmt.Sprintf("$%.0f", *cost), true
	}
	return fmt.Sprintf("$%.2f", *cost), true
}
