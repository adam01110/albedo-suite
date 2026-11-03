# Zed provider

The `zed` extension calls Zed's hosted `/completions` endpoint directly. No
proxy or zed2cli installation is required. `/login` has a Zed profile row.

Create a profile with extension `zed`, base URL `https://cloud.zed.dev`, protocol
`chat_completions`, and a model returned by Zed's authenticated `/models` catalog.
The protocol names Albedo's portable history format; the catalog's provider
field chooses the native wire protocol for each model.

## Browser sign-in

Run `/login zed` (or choose **add Zed account** in `/login`), open the printed
`https://zed.dev/native_app_signin` URL, sign in with the Zed account's GitHub
identity, and return to Albedo. The browser ends on zed.dev's success page;
Albedo then shows the identity validated by `cloud.zed.dev`, including the GitHub
login, user ID and organization. Check that it is yours, type `confirm`, and
select a model. Cancel if the identity is unexpected. No credential is saved
until that current identity is explicitly confirmed.

The identity confirmation is a distinct login state, `confirming`: the daemon
publishes the validated account in that state, accepts only `confirm` as input,
and moves to `complete` once the account is saved. The published schema lists it
alongside the other states, and the CLI reads it like any other.

Only Albedo, a browser and a Zed account are required. Neither the Zed editor nor
zed2cli is installed, invoked or read. There is no `zed://` handler, editor
configuration, keychain, exported credential or helper-script dependency. Albedo
sends `native_app_port` and `native_app_public_key` only; the editor's optional
`system_id` is omitted because Albedo has no editor system identity, and zed.dev
forwards that parameter only when it is present.

### Observed browser path

Inspected unauthenticated on 2026-11-03:

1. `GET https://zed.dev/native_app_signin?-query` returns 200. Its client script
   reads `native_app_port`, `native_app_public_key` and the optional `system_id`,
   sets the `zed_signup_redirect` cookie, and navigates to
   `https://cloud.zed.dev/frontend/auth/sign_in?next=%2Fapi%2Fauth%2Fcallback%2Fnative_app...`.
2. That route redirects to GitHub OAuth
   (`github.com/login?client_id=Iv1.7e72654f487b56be&return_to=%2Flogin%2Foauth%2Fauthorize...redirect_uri=https%3A%2F%2Fcloud.zed.dev%2Ffrontend%2Fauth%2Fgithub%2Fcallback`).
   A browser with no zed.dev session stops here, on GitHub's sign-in page.
3. After GitHub authorization, the session-authenticated callback
   `https://cloud.zed.dev/frontend/api/auth/callback/native_app?native_app_port=..&native_app_public_key=..`
   encrypts the account's access token for that public key and redirects the
   browser to the loopback listener.
4. The listener answers `302` to `https://zed.dev/native_app_signin_succeeded`,
   which renders "Authentication Successful".

Nothing in that page or its scripts checks for an installed editor. The dead
paths are `https://zed.dev/api/auth/callback/native_app` (HTTP 404) and
`https://cloud.zed.dev/api/auth/callback/native_app` (`Not Found`); the `/frontend`
callback answers `401 unauthorized` without a zed.dev session. A browser whose
`next` resolves to a dead path reports the 404 of zed issue #28932, which is a
zed.dev-side failure for specific accounts, not an editor requirement.

Steps 1, 2 and 4 were observed live, step 4 against Albedo's own listener; step
3's authenticated redirect was not, because it needs a Zed account that this
integration must not use. What is verified instead is the receiving side, against
the editor's own contract: any
callback path with any extra query parameters, `user_id` plus a base64url
ciphertext of the access token decrypted with RSA-OAEP-SHA256 or the older
PKCS#1 v1.5 padding, and a `302` to the success page. Both loopback addresses share
one port, so a browser resolving `localhost` to `::1` reaches the same attempt.
`test/albedo_zed_login_test.erl` drives that contract over a real loopback socket.

The browser must reach the daemon's loopback listener. This works directly when
they run on the same machine. A browser on another machine cannot complete the
remote daemon's loopback callback without an explicitly arranged tunnel; Albedo
does not expose that listener on the network or provide a callback-paste bypass.
Attempts expire after five minutes, and cancellation closes the listener and
discards pending credentials. The editor gives its own attempt 100 seconds; the
longer window is deliberate, so a sign-in that needs a password manager or a
second factor is not lost.

The listener checks the `Host` header and accepts any callback path, and a
callback that does not decrypt is answered `404` while the attempt keeps
waiting. The editor answers `302` before parsing anything, checks no `Host`, and
aborts the whole sign-in on malformed parameters. Each is deliberate: the
stricter sender check keeps another local process from finishing the attempt, and
the tolerant receiver keeps a mistyped or unrelated request from ending it.

The callback protocol has no verified state/nonce echo or sender signature.
Fresh RSA-2048 OAEP-SHA256 keys bind each encrypted callback to its receiver and
attempt, **not** to its sender. A callback that does not decrypt is answered `404`
and the attempt keeps waiting, so a wrong or hostile request never reports success
and never ends the flow early. The listener is loopback-only, requires a loopback
`Host`, and returns at expiry, on cancel, or when the flow is abandoned rather than
waiting forever. Keep the official sign-in URL private; the local listener never
serves that URL or its public-key material to web origins.

The listener accepts any callback path and any extra query parameters, and it
does not reject a browser `Origin` or `Sec-Fetch-Site` header. Both are
deliberate: zed.dev owns the path and may append parameters, and a browser
top-level redirect carries no `Origin` at all. The check that matters is the
ciphertext: only the attempt's own RSA key decrypts it, so a cross-site page can
make the browser *reach* the listener but cannot make it report an identity. A
decrypted callback only shows an identity for the user to confirm, and nothing is
stored before that confirmation, so a forged callback costs the user one
cancelled confirmation screen rather than a credential.

If zed.dev's own callback fails, the failure is at zed.dev: Albedo cannot complete
that hop for the account, and no other credential can stand in. Albedo never
stores a credential the callback did not deliver and never substitutes another
account's identity.

### One authentication path

`/login zed` browser sign-in, saved in the daemon's native credential store
`creds.json` (mode `0600`), is the only Zed credential. That store holds the
`cloud.zed.dev` account and its inference JWT; the JWT is renewed under the
settings lock before it expires, at most one refresh and one retry happen before
any model output, and a partial response is never replayed. A Zed profile has no
`apiKey` and the daemon has no `ZED_TOKEN` for it. Both are refused with a message
naming the leftover field or variable and never its value, so a profile that still
carries `apiKey`, or a daemon environment that still sets `ZED_TOKEN`, fails with
instructions to remove it and sign in again. Removing the key means signing in
again: `/login zed` clears the `apiKey` a Zed profile still carries, so the refusal
does not survive a completed sign-in. The accounts list reports such a key as
unused rather than as the profile's credential. Removing an account through
`/login` removes its credentials and inference JWT with it.

A Zed profile holds exactly one account and there is no automatic rotation: a
profile may pin an account with `accountId` or select a rotation with
`accountIds`, never both, and a profile bound to neither uses its only Zed
account. Setting both at once, or selecting accounts while the profile still
carries an api key, is refused as a credential conflict.

Native credentials and JWT minting use verified HTTPS to the fixed origin
`https://cloud.zed.dev` only. Account calls refuse redirects, a non-200 status,
non-JSON bodies, responses above 1 MiB and calls above 15 seconds, so a redirect
to another host cannot receive the account credential.

A Zed profile's base URL must be `https://cloud.zed.dev`. Any other base URL is
refused, because the native account credential is bound to that origin and is
never sent elsewhere; there is no custom Zed endpoint. One exception is accepted:
`http://127.0.0.1:PORT`, `http://localhost:PORT` and `http://[::1]:PORT` without
userinfo, query or fragment. Offline tests of the real transport need a local
fixture, and that allowance is the only seam they use; there is no test-only
setting, credential injection or origin override. It is a deliberate production
allowance with a real cost: a profile pointed at a loopback HTTP URL sends its
native account JWT and its prompts in cleartext to whatever listens on that local
port, so such a profile is a test configuration and not a way to reach Zed. Every
other origin, including another loopback name or any `https` host, fails with that
origin named.

Do not put secrets in Nix or version control. Zed's browser billing session
cookie is a separate credential: inference never reads or uses it, and only the
opt-in `/zed-budget` page below reads it, from `ZED_BILLING_SESSION` in the
daemon's environment.

Public Home Manager configuration can select the provider without storing a
secret:

```nix
programs.albedo.providers.zed = {
  extension = "zed";
  baseUrl = "https://cloud.zed.dev";
  protocol = "chat_completions";
  model = "claude-sonnet-4-6";
};
```

Set `activeProvider = "zed"` when managing profiles; preserve other profiles as
usual. Sign in separately through runtime `/login zed`.

## Native protocols

- Claude: Anthropic Messages, including tool choice, adaptive thinking effort,
  thinking deltas, tool argument deltas, and input/output/cache usage.
- GPT: OpenAI Responses, including reasoning effort and summary deltas, tool
  calls and usage; output is converted to portable history. Every input item is
  a `type`-tagged item, and a message's text is a typed content part, because
  the cloud service parses the body as a tagged union before forwarding it.
- Gemini: Google GenerateContent, including supported thinking levels/budgets,
  tool choice, thought parts, tool calls and usage.
- Grok: OpenAI Chat Completions, including tool choice and streaming usage.

The Zed service and selected model must support the requested controls. Not all
models expose thinking text. Model discovery supplies the account's context,
output and effort limits rather than a fixed list. Discovery is cached for one
hour, isolated by endpoint and credential; inference uses its selected profile's
credential. Saved-profile catalogs and the post-login model picker carry the
selected public profile/account identity, rather than choosing an account by
name. Endpoint-only discovery uses the globally active matching profile (or the
only matching profile); ambiguous endpoints fail rather than using another
account. `/reload` refreshes all configured Zed catalogs. Discovery and inference
use the same browser-signed account credential; HTTP is permitted only for
loopback test endpoints.

The provider requires Zed's status-envelope NDJSON protocol. It waits for
`stream_ended` after the native model finishes, so a late failure or truncated
stream cannot be reported as success. Transport bounds, UTF-8 validation,
cancellation and timeout handling are shared with existing providers.

## Wire parity with the editor

Compared field by field against the pinned Zed sources listed below, these
follow the editor because the wire shape decides whether the request works:

- Discovery sends `/models` through the same refresh-once path as inference: a
  rejected token is dropped, refreshed from the account's own credential and
  retried once, and a second rejection is reported as a credential problem
  rather than an unreachable service. Any other non-200 answer reports its
  status.
- An unrecognised `status` envelope is ignored, as the editor ignores its own
  `Unknown` status; a `failed` status still fails the turn.
- Claude: a replayed turn from the same model carries the signed thinking blocks
  the reducer recorded, in order, ahead of its text and tool calls. Thinking is
  requested only when the model's catalog entry supports it.
- Gemini: a replayed part carries the `thoughtSignature` the model issued, and
  none when it issued none; no placeholder is invented. Tool-result media is
  nested under `functionResponse.parts` except for `gemini-2.5-pro`,
  `gemini-2.5-flash` and `gemini-2.5-flash-lite`, which take sibling parts.
  Function calls and responses carry their call ids. An effort the local
  thinking table does not list for a model is forwarded as a level instead of
  failing the request.
- GPT: `reasoning.encrypted_content` is requested only when the request reasons
  or replays a reasoning item, `reasoning.summary` is `auto` whenever the
  request reasons, an effort of `none` sends no reasoning object, and
  provider-issued reasoning items are replayed ahead of the message they
  preceded.
- The status-message capability header is checked for presence, not for the
  value `true`.

Deliberate deviations, kept because the editor's choice depends on data this
integration does not carry:

- `strict` on Responses tools is the harness's own claim, emitted only for a
  schema that satisfies OpenAI's rules where the editor sends `false` for every
  cloud tool. Sending `false` would drop the claim the harness asks for.
- `top_p` is forwarded when the harness sets one; the editor hard-codes `None`
  for cloud Responses requests.
- `parallel_tool_calls` is omitted when the harness has no value; the editor
  always sends the model's capability alongside tools.
- `prompt_cache_key` and the assistant `phase` are not sent on the Responses
  route: the encoder has neither a session id nor a replayed phase, and the
  field affects cache reuse only.
- A Responses `input_image` carries an extra `detail: "auto"` key that the
  pinned request type does not have. OpenAI documents the key, so it is a
  compatible addition rather than a fabricated field.
- Claude `cache_control` is not sent. The Anthropic encoder is shared with the
  Bedrock route, where the top-level breakpoint is unverified, so prompt caching
  stays with the provider's defaults. Cache usage is still reported whenever a
  provider caches.
- Claude `max_tokens` is the request's limit, or 8192 when the harness has none,
  where the editor uses the catalog's `max_output_tokens`. `stream: true` is
  part of the provider body because this integration calls Anthropic directly;
  the editor's transport adds streaming outside the body. `temperature` is
  omitted, which is Anthropic's own default of 1.0.
- The catalog keeps a disabled model with its `disabled_reason`, but the harness
  cannot display a disabled model: it is left out of the model list and out of
  lookup, and routing names the reason it cannot be selected.
- Catalog `is_default` and `supports_disabling_thinking` are still dropped, so
  the harness's default effort is its own rule rather than the level the editor
  preselects. A catalog entry's `supports_tools` is likewise not consulted:
  every model is offered the harness's tools.
- The callback's `user_id` is accepted up to twelve digits where the editor
  parses a `u64`; the shorter bound is deliberate and does not affect an
  account whose id fits it.
- The account's `organizations` list is optional and its default organization
  stands when the list is absent; the callback's `user_id` is the credential
  identity and is not compared with `legacy_user_id`, as the editor does. The
  organization choice chain and the account's model-provider flag are unchanged.

## Account quota in /quota

With the `zed` extension enabled, `/quota` lists each signed-in Zed account as
`zed · <account label>` with one row. **Edit predictions** is account-level
edit-prediction usage from `GET /client/users/me`, read with the same stored
credential the request path uses. A numeric plan limit is shown as the share of
that limit used; an `unlimited` plan is a reading with no percentage, not a full
bar. Zed reports no window and no reset time for this reading, so the row shows
neither and none is inferred. A credential that was rejected or has expired
fails the poll with a message naming `/login zed`; no other credential stands in.

This row is not a token budget. Hosted-model spend in USD needs a separate
browser billing session and stays in `/zed-budget`; the two readings are never
merged, and neither is attributed to the other. Polling is the daemon's ordinary
quota polling: one poll per account at a time, backoff on failure, readings
recorded as reported, and the existing quota settings disable it.

## Opt-in browser billing budget

With the `zed` extension enabled, `/zed-budget` opens a native CLI status page
showing hosted-model USD spend, limit and remaining budget. It is **not** the
inference-account quota row, which carries edit-prediction usage only (see
above). The quota store records percentages rather than currency budgets, and an
inference-account credential cannot authenticate this browser billing endpoint.

Explicitly supply the **value only** of a manually obtained `zed.session` browser
cookie as `ZED_BILLING_SESSION` in the **daemon's environment** before starting
Albedo. Do not include `zed.session=`, a `Cookie:` header or other cookies. An
already-running daemon does not inherit a new CLI environment. Use your normal
secret environment injection mechanism; never put the value in shell history,
public configuration, Nix, a repository or a command argument. The cookie is a
separate sensitive browser-session credential, not the inference credential saved
by `/login zed`. Albedo never falls back to inference credentials and does not
read browser storage, keyrings or the editor's credentials.

The page is explicitly labeled **Zed browser billing session** and **unverified
association**: it applies to the account behind that cookie, which may differ
from the active inference profile. It never attaches the reading to an inference
account or displays browser identity/personal metadata. Edit-prediction quota is
separate and is not included. A missing/null spend or limit remains unknown;
zero is a known zero, and over-limit remaining is negative. Malformed/negative/
nonfinite or unsafe-range amounts fail with a schema error rather than becoming
zero, unlimited or a percentage. Reset time is unknown; a plan subscription
period is not treated as a spend reset. Plan metadata is not retained.

Nothing fetches until the page is explicitly opened, and no request is made
without a valid configured cookie value. Requests use only the fixed HTTPS
`https://cloud.zed.dev/frontend/billing/usage` origin with verified TLS, no
redirect following and no custom inference endpoint. Responses are capped at
64 KiB, with a ten-second whole-call deadline. Only sanitized budget fields and
a credential hash are cached in one memory-only slot for up to 60 seconds
(failures for 15 seconds); the cookie and raw response are not written to disk.
The page reports observation time so cached readings are identifiable. Rejected
sessions (401/403), redirects, transport errors and schema changes produce
sanitized status messages, never server response bodies. After replacing an
expired cookie in the daemon environment, use the normal daemon lifecycle to
apply it; this feature does not refresh or recover browser sessions.

The billing endpoint is undocumented and may change independently of the public
editor API. No live service compatibility or inference/billing identity match is
assumed. Endpoint and field research:
[CodexBar Zed notes](https://github.com/steipete/CodexBar/blob/main/docs/zed.md)
and [firsthand billing report](https://github.com/steipete/CodexBar/issues/3172).

## Verification and sources

`test/suite_zed_test.gleam` covers request controls, each model family's
`provider_request` field by field (Anthropic messages, Responses input items and
their `type`, Gemini parts and function responses, Chat Completions messages),
replayed signed thinking, model-issued and absent Gemini signatures, tool-result
media placement, conditional encrypted reasoning with its replay, thinking/usage
reduction with exact totals, the strict-schema rules and every schema-bearing
keyword they are checked behind, the Codex policy branch, status failures, the
capability header and NDJSON chunk boundaries. `test/suite_zed_login_test.gleam`
and its Erlang fixture exercise RSA callback decryption with both paddings,
permissive callback paths and query parameters, the 302 success answer, wrong
attempts and malformed ciphertext, loopback `localhost`/`::1` reachability,
validated identity including an account without a default organization,
revision-bound confirmation, cancellation/expiry,
persistence/logout, account/organization cache isolation, concurrent renewal,
malformed JWT caches, pre-output 401 retry and expired/outdated headers. Its
clean-home case creates credentials only through the browser callback, confirms,
persists, discovers models and completes inference after a token refresh. It also
refuses a profile `apiKey`, a daemon `ZED_TOKEN` and a custom base URL, and checks
that the catalog advertises no environment credential. Public
HTTPS URLs are mapped to isolated HTTP fixtures only by test-loaded transport
code. Production has no test origin, credential injection or origin override
setting: the loopback HTTP base URLs described above are the only allowance, and
they still send the profile's own credential.
`test/suite_quota_test.gleam` covers the Zed account reading: a numeric limit
becomes a used percentage, `unlimited` carries none, a payload without a usable
reading is an error rather than a zero, a rejected credential says so, and the
poller records the row `/quota` lists. `test/zed_e2e_test.py` exercises native
HTTP streaming, thinking/usage reduction, a split multibyte reply and tool replay
through an isolated daemon whose credential store is seeded with a browser-signed
account. It drives one GenerateContent turn on the Gemini route end to end,
asserts that a profile `apiKey`, a daemon `ZED_TOKEN` and a custom base URL are
each refused before any request, checks that the `/zed-budget` route rejects
other methods, query parameters and paths, and clears a stored `apiKey` with the
save a browser sign-in issues so the refused profile then infers with its stored
account. Tests use fake
credentials and local fixtures, not the user's Zed account. The same daemon suite
verifies `/zed-budget` discovery/invocation without a billing cookie and rejects
invalid configuration without contacting billing. `checks.zed-budget` runs offline transport fixtures against the
production billing reader, covering USD/unknown/zero/over-limit values, schema
errors, credential isolation, redirects, expired sessions, response bounds,
caching and source labeling. Those fixtures stand in for the HTTP client, so the
reader's branching and the options it passes are verified, not the installed
`hackney`'s own redirect, pooling or TLS behaviour.

Protocol references:

- [Zed cloud client at 99e70ee4](https://github.com/zed-industries/zed/blob/99e70ee4a02d8dcf1b72f487f81aaf0d3be74f76/crates/cloud_llm_client/src/cloud_llm_client.rs)
- [Zed native model adapters](https://github.com/zed-industries/zed/blob/99e70ee4a02d8dcf1b72f487f81aaf0d3be74f76/crates/language_models_cloud/src/language_models_cloud.rs)
- [Zed native browser protocol](https://github.com/zed-industries/zed/blob/main/crates/client/src/client.rs)
- [RSA OAEP protocol](https://github.com/zed-industries/zed/blob/main/crates/rpc/src/auth.rs)
- [Cloud account and token client](https://github.com/zed-industries/zed/blob/main/crates/cloud_api_client/src/cloud_api_client.rs)
- [Account/organization/token schema](https://github.com/zed-industries/zed/blob/main/crates/cloud_api_types/src/cloud_api_types.rs)
- [Public browser sign-in route](https://zed.dev/native_app_signin) and its callback route, inspected unauthenticated on 2026-11-03
- [Account-specific 404 after sign-in](https://github.com/zed-industries/zed/issues/28932), closed as not planned
- [Loopback redirect reported as not received](https://github.com/zed-industries/zed/issues/57693)
- [zed2cli reference only at 51e20772](https://github.com/6yte96/zed2cli/tree/51e20772373fe926a23a6027e328554c17bebe3a)

This is an unofficial integration. Live service compatibility and account
entitlement are not established by offline tests.
