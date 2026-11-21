// Property test for validation of a saved profile: the suite's enabled flag must
// survive validation along with every other saved choice.
package config

import (
	"fmt"
	"math/rand"
	"strings"
	"testing"
)

// TestPropValidatePreservesProfile checks field-wise preservation: validation
// may normalize the extension, model and endpoint, and must change nothing else.
func TestPropValidatePreservesProfile(t *testing.T) {
	r := rand.New(rand.NewSource(6))
	endpoints := []string{"https://api.example.com", "https://api.example.com/", " http://localhost:8080/v1/ ", "https://host.example/v1//"}
	for i := 0; i < 300; i++ {
		settings := Settings{
			ProfileName: fmt.Sprintf("profile-%d", r.Intn(100)),
			Model:       fmt.Sprintf(" model-%d ", r.Intn(1000)),
			Protocol:    []string{"responses", "chat_completions"}[r.Intn(2)],
			Extension:   []string{"", "openai", "anthropic-api", "bedrock"}[r.Intn(4)],
			BaseURL:     endpoints[r.Intn(len(endpoints))],
			APIKey:      fmt.Sprintf("key-%d", r.Intn(1000)),
			Rotation:    []string{"", "failover", "spread", "first"}[r.Intn(4)],
		}
		if r.Intn(2) == 0 {
			enabled := r.Intn(2) == 0
			settings.Enabled = &enabled
		}
		if r.Intn(2) == 0 {
			effort := []string{"low", "medium", "high"}[r.Intn(3)]
			settings.Effort = &effort
		}
		if r.Intn(2) == 0 {
			edge := r.Intn(2048)
			settings.ImageEdge = &edge
		}
		if r.Intn(2) == 0 {
			account := fmt.Sprintf("account-%d", r.Intn(100))
			settings.AccountID = &account
		}
		if r.Intn(3) == 0 {
			settings.AccountIDs = []string{fmt.Sprintf("a-%d", r.Intn(10)), fmt.Sprintf("a-%d", r.Intn(10))}
		}
		if r.Intn(2) == 0 {
			project := fmt.Sprintf("project-%d", r.Intn(10))
			settings.Project = &project
		}
		if r.Intn(2) == 0 {
			location := fmt.Sprintf("location-%d", r.Intn(10))
			settings.Location = &location
		}
		settings.HasKey = r.Intn(2) == 0

		validated, err := settings.Validate()
		if err != nil {
			t.Fatalf("case %d: valid settings rejected: %v (%+v)", i, err, settings)
		}
		samePointer := func(field string, got, want *string) {
			if (got == nil) != (want == nil) || got != nil && *got != *want {
				t.Fatalf("case %d: %s = %v, want %v", i, field, show(got), show(want))
			}
		}
		samePointer("effort", validated.Effort, settings.Effort)
		samePointer("account id", validated.AccountID, settings.AccountID)
		samePointer("project", validated.Project, settings.Project)
		samePointer("location", validated.Location, settings.Location)
		if (validated.Enabled == nil) != (settings.Enabled == nil) || validated.Enabled != nil && *validated.Enabled != *settings.Enabled {
			t.Fatalf("case %d: enabled = %v, want %v", i, showBool(validated.Enabled), showBool(settings.Enabled))
		}
		if validated.Enabled == nil && settings.Enabled != nil {
			t.Fatalf("case %d: enabled flag lost", i)
		}
		if validated.IsEnabled() != (settings.Enabled == nil || *settings.Enabled) {
			t.Fatalf("case %d: IsEnabled disagrees with the stored flag: %v", i, validated.IsEnabled())
		}
		if (validated.ImageEdge == nil) != (settings.ImageEdge == nil) || validated.ImageEdge != nil && *validated.ImageEdge != *settings.ImageEdge {
			t.Fatalf("case %d: image edge = %v, want %v", i, validated.ImageEdge, settings.ImageEdge)
		}
		if validated.Rotation != settings.Rotation || validated.ProfileName != settings.ProfileName || validated.HasKey != settings.HasKey || validated.APIKey != settings.APIKey {
			t.Fatalf("case %d: saved choices changed: %+v -> %+v", i, settings, validated)
		}
		if len(validated.AccountIDs) != len(settings.AccountIDs) {
			t.Fatalf("case %d: account ids lost: %v -> %v", i, settings.AccountIDs, validated.AccountIDs)
		}
		for n := range settings.AccountIDs {
			if validated.AccountIDs[n] != settings.AccountIDs[n] {
				t.Fatalf("case %d: account id %d changed: %v -> %v", i, n, settings.AccountIDs[n], validated.AccountIDs[n])
			}
		}
		wantExtension := settings.Extension
		if wantExtension == "" {
			wantExtension = "openai"
		}
		if validated.Extension != wantExtension {
			t.Fatalf("case %d: extension = %q, want %q", i, validated.Extension, wantExtension)
		}
		if validated.Model != strings.TrimSpace(settings.Model) {
			t.Fatalf("case %d: model = %q, want %q", i, validated.Model, strings.TrimSpace(settings.Model))
		}
		if want := strings.TrimRight(strings.TrimSpace(settings.BaseURL), "/"); validated.BaseURL != want {
			t.Fatalf("case %d: endpoint = %q, want %q", i, validated.BaseURL, want)
		}
	}
}

func show(value *string) string {
	if value == nil {
		return "unset"
	}
	return *value
}

func showBool(value *bool) string {
	if value == nil {
		return "unset"
	}
	return fmt.Sprint(*value)
}
