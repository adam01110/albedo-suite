// Property test for `albedo resume`'s arity: no argument resumes the newest
// session in cwd, one argument opens it by ID, and more is refused before any
// connection is obtained.
package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"strings"
	"testing"

	"albedo/cli/internal/app"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/terminal"
)

// TestPropResumeArgumentArity checks that only the documented argument counts
// reach the daemon, for every count cobra has to accept or refuse.
func TestPropResumeArgumentArity(t *testing.T) {
	r := rand.New(rand.NewSource(5))
	connectError := errors.New("stopped before use")
	for arguments := 0; arguments <= 3; arguments++ {
		for i := 0; i < 20; i++ {
			args := []string{"resume"}
			for n := 0; n < arguments; n++ {
				args = append(args, fmt.Sprintf("%08x", r.Uint32()))
			}
			calls := 0
			deps := Dependencies{
				Application: &app.Service{Connect: func(context.Context) (*daemon.Connection, error) {
					calls++
					return nil, connectError
				}},
				Terminal: &terminal.Service{},
			}
			err := ExecuteComponent(t.Context(), TUIRoot, args, deps, Streams{In: strings.NewReader(""), Out: io.Discard, Err: io.Discard})
			switch {
			case arguments <= 1 && (err == nil || calls != 1):
				t.Fatalf("%v: err=%v connections=%d, want one connection", args, err, calls)
			case arguments > 1 && (err == nil || calls != 0):
				t.Fatalf("%v: err=%v connections=%d, want a refusal before connecting", args, err, calls)
			}
		}
	}
}
