# Provider availability

In the providers menu (`/login`), highlight a saved provider profile and press
**Ctrl+T** to disable or re-enable it. The footer shows the action. Disabled
profiles remain visible with a `disabled` label, but Enter cannot select them.
The menu keeps its search and highlighted profile after the change. There is
no separate provider-availability slash command or Python command.

Disabling removes the profile from `agents.models()` and automatic provider
selection. Explicit new selections and child-agent requests reject disabled
profiles too. Changes take effect without restarting and survive daemon restarts.

The menu updates the existing conditional providers settings resource, saving
`enabled: false` in the named profile in `config.json`. Missing `enabled` means
enabled. Keys, OAuth accounts, account bindings and unrelated profile fields
remain intact. Re-enabling restores discovery without logging in again.

Existing sessions using a disabled profile may fail when they next bind their
provider; switch them to another profile or re-enable it. In-flight requests
are not cancelled, and the default profile is not silently changed.

This is a **profile-level** switch, not global credential/account revocation.
An account shared with another enabled profile remains usable there. Public
provider catalogs remain available for explicit catalog lookups.

`provider_availability_test.go` exercises the toggle key, disabled-row state,
conditional patch body, refusal handling and selection/search retention.
The isolated `provider_availability_e2e_test.py` regression exercises discovery,
explicit child refusal, restart persistence, re-enable, stale-write rejection,
invalid values, unknown-profile rejection and credential preservation using
local fake providers.
