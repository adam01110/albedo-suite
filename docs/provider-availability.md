# Provider availability

Availability has two switches, both on **Ctrl+T** in `/accounts` (alias
`/login`); the footer names the action. There is no separate
provider-availability slash command or Python command.

## One account

On the accounts list, highlight a saved model sign-in or API key and press
**Ctrl+T** to disable or re-enable that account alone. The other accounts of
its service, its place in the rotation and every setup stay as they are, so a
service with two accounts keeps running on the other one. A disabled account
stays signed in and listed with a `disabled` status; rotation and setups pinned
to it skip it until it is enabled again. Signing in to it again keeps it
disabled. Environment accounts and tool sign-ins have no switch.

The menu sends `PATCH /auth/accounts/{id}` with `{"enabled": false}`, which
stores `"enabled": false` on that account in `creds.json`; enabling removes the
mark. `GET /auth` reports `enabled` for every account. The daemon's shared
account ordering (`albedo_sdk/accounts.arrange_by`) leaves disabled accounts
out, as it does accounts that need sign-in, so every sign-in and key provider
honours the switch. A service whose accounts are all disabled reports that it
has no usable account.

`account_availability_test.go`, `suite_account_availability_test.gleam` and the
isolated `account_availability_e2e_test.py` cover the key, the patch, the stored
mark, rotation skipping and restore, re-sign-in and refused bodies.

## One setup

Open **advanced** to reach the named setups, highlight a saved provider profile
and press **Ctrl+T** to disable or re-enable the whole setup, whichever
accounts it uses. Disabled profiles remain visible with a `disabled` label, but
Enter cannot select them. The list keeps its search and highlighted profile
after the change.

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
