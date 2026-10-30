# Zed provider

The `zed` extension calls Zed's hosted `/completions` endpoint directly. No
proxy or zed2cli installation is required. `/login` has a Zed profile row.

Create a profile with extension `zed`, base URL `https://cloud.zed.dev`, protocol
`chat_completions`, and a model returned by Zed's authenticated `/models` catalog.
The protocol names Albedo's portable history format; the catalog's provider
field chooses the native wire protocol for each model.

## Browser sign-in

Run `/login zed` (or choose **add Zed account** in `/login`), sign in on the
ordinary browser page at `https://zed.dev/native_app_signin`, then return to
Albedo. Albedo shows the account identity validated by `cloud.zed.dev`, including
the GitHub login, user ID and default organization. Check that it is yours, type
`confirm`, and select a model. Cancel if the identity is unexpected. No credential
is saved until that current identity is explicitly confirmed.

Only Albedo, a browser and a Zed account are required. Neither the Zed editor nor
zed2cli is installed, invoked or read. There is no `zed://` handler, editor
configuration, keychain, exported credential or helper-script dependency. The
public browser route forwards the ephemeral port/public key into its web
sign-in callback; it does not check for an installed editor.

The browser must reach the daemon's loopback listener. This works directly when
they run on the same machine. A browser on another machine cannot complete the
remote daemon's loopback callback without an explicitly arranged tunnel; Albedo
does not expose that listener on the network or provide a callback-paste bypass.
Attempts expire after five minutes, and cancellation closes the listener and
discards pending credentials.

Albedo stores the confirmed editor access credential, account organization and
cached inference JWT in its native `creds.json` secret store (0600). Profiles bind
to public account IDs, not secrets. Inference JWTs are renewed before expiry,
under the credential-store lock; a rejected token gets at most one refresh/retry
before any model/tool output. Partial responses are never replayed by this retry.
Removing the account through `/login` removes its stored credentials and JWT;
first remove or rebind profiles that reference it. This does not revoke the
credential at Zed's service.

Native credentials and JWT minting use only verified HTTPS to the fixed
`cloud.zed.dev` origin. Account calls and model discovery refuse redirects and
bound response size/time. The confirmed default organization remains attached to
that account; another account's organization is never substituted. Select exactly
one account per Zed profile; automatic multi-account rotation is not supported.

The callback protocol has no verified state/nonce echo or sender signature.
Fresh RSA-2048 OAEP-SHA256 keys bind each encrypted callback to its receiver and
attempt, **not** to its sender. Fixed-origin account validation and explicit
confirmation of the resulting identity are therefore mandatory. Keep the official
sign-in URL private; the local listener never serves that URL or its public-key
material to web origins.

An explicit runtime `apiKey` or daemon `ZED_TOKEN` remains an optional manual JWT
fallback and takes precedence over browser credentials. Manual JWTs are not
renewed. Custom inference endpoints require this explicit manual credential;
native account credentials are never sent to them. Do not put secrets in Nix or
version control. Zed's browser billing session cookie is separate and is not read
or used by this integration.

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
  calls and usage; output is converted to portable history.
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
account. `/reload` refreshes all configured Zed catalogs. HTTP is
permitted only for loopback test endpoints.

The provider requires Zed's status-envelope NDJSON protocol. It waits for
`stream_ended` after the native model finishes, so a late failure or truncated
stream cannot be reported as success. Transport bounds, UTF-8 validation,
cancellation and timeout handling are shared with existing providers.

## Verification and sources

`test/suite_zed_test.gleam` covers request controls, thinking/usage reduction,
status failures and NDJSON chunk boundaries. `test/suite_zed_login_test.gleam`
and its Erlang fixture exercise RSA callback decryption, wrong-attempt/malformed
ciphertext, validated identity, revision-bound confirmation, cancellation/expiry,
persistence/logout, account/organization cache isolation, concurrent renewal,
malformed JWT caches, pre-output 401 retry and expired/outdated headers. Its
clean-home case creates credentials only through the browser callback, confirms,
persists, discovers models and completes inference after a token refresh. Public
HTTPS URLs are mapped to isolated HTTP fixtures only by test-loaded transport
code; production has no test origin or credential injection setting.
`test/zed_e2e_test.py` exercises
native HTTP streaming and tool replay through an isolated daemon. Tests use
fake tokens and local fixtures, not the user's Zed account.

Protocol references:

- [Zed cloud client at 99e70ee4](https://github.com/zed-industries/zed/blob/99e70ee4a02d8dcf1b72f487f81aaf0d3be74f76/crates/cloud_llm_client/src/cloud_llm_client.rs)
- [Zed native model adapters](https://github.com/zed-industries/zed/blob/99e70ee4a02d8dcf1b72f487f81aaf0d3be74f76/crates/language_models_cloud/src/language_models_cloud.rs)
- [Zed native browser protocol](https://github.com/zed-industries/zed/blob/main/crates/client/src/client.rs)
- [RSA OAEP protocol](https://github.com/zed-industries/zed/blob/main/crates/rpc/src/auth.rs)
- [Cloud account and token client](https://github.com/zed-industries/zed/blob/main/crates/cloud_api_client/src/cloud_api_client.rs)
- [Account/organization/token schema](https://github.com/zed-industries/zed/blob/main/crates/cloud_api_types/src/cloud_api_types.rs)
- [Public browser sign-in route](https://zed.dev/native_app_signin), inspected unauthenticated on 2026-10-30
- [zed2cli reference only at 51e20772](https://github.com/6yte96/zed2cli/tree/51e20772373fe926a23a6027e328554c17bebe3a)

This is an unofficial integration. Live service compatibility and account
entitlement are not established by offline tests.
