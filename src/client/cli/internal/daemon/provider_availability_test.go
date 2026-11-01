package daemon

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestProviderAvailabilitySettingsRetainEnabledState(t *testing.T) {
	for _, enabled := range []any{nil, false, true} {
		profile := map[string]any{"extension": "openai", "endpoint": "https://fixture.example/v1", "model": "fixture", "protocol": "responses", "effort": nil, "image_edge": nil, "account_id": nil, "account_ids": nil, "project": nil, "location": nil, "has_key": false}
		if enabled != nil {
			profile["enabled"] = enabled
		}
		conn := controlledConnection(t, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			groups := map[string]any{}
			for _, group := range []string{"providers", "mcp", "extensions", "extension_settings", "capabilities", "models", "ui"} {
				groups[group] = map[string]any{"url": "/settings?group=" + group, "etag": `"` + group + `-1"`}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"providers":          map[string]any{"default_profile": "fixture", "profiles": map[string]any{"fixture": profile}},
				"group_resources":    groups,
				"mcp":                map[string]any{"definitions": map[string]any{}},
				"extensions":         map[string]any{"defaults": map[string]bool{}},
				"extension_settings": map[string]any{"sections": []any{}},
				"capabilities":       map[string]any{"preferences": map[string]bool{}},
				"models":             map[string]any{"raised_caps": map[string]bool{}, "compact_at": map[string]int{}, "cache_ttl_priors": []any{}},
				"ui":                 map[string]any{"thinking": false, "tools": false, "dismissed_notices": []string{}, "web_allow": []string{}},
			})
		})
		profiles, err := ProviderProfiles(t.Context(), conn)
		if err != nil {
			t.Fatal(err)
		}
		got := profiles.Providers["fixture"]
		want := enabled == nil || enabled == true
		if got.IsEnabled() != want {
			t.Fatalf("enabled=%v decoded as %+v", enabled, got.Enabled)
		}
		validated, err := got.Validate()
		if err != nil || validated.IsEnabled() != want {
			t.Fatalf("validation lost enabled=%v: %+v, %v", enabled, validated, err)
		}
	}
}
