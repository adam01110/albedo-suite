# Zed provider

The `zed` extension calls Zed's hosted `/completions` endpoint directly. No
proxy or zed2cli installation is required. `/login` has a Zed profile row.

Create a profile with extension `zed`, base URL `https://cloud.zed.dev`, protocol
`chat_completions`, and a model returned by Zed's authenticated `/models` catalog.
The protocol names Albedo's portable history format; the catalog's provider
field chooses the native wire protocol for each model.

Authentication is a Zed LLM JWT, saved as the profile's runtime `apiKey` or set
in the daemon's `ZED_TOKEN` environment. JWTs expire after about one hour. This
implementation does not read Zed's keyring, run token scripts, or refresh a
long-lived Zed access token. Obtain a fresh JWT through Zed or an external token
resolver when it expires. Do not put credentials in Nix or version control.

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
usual. Save the JWT separately through runtime login.

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
credential. The endpoint-only picker uses the globally active matching profile
(or the only matching profile); ambiguous endpoints fail discovery rather than
using another account. `/reload` refreshes all configured Zed catalogs. HTTP is
permitted only for loopback test endpoints.

The provider requires Zed's status-envelope NDJSON protocol. It waits for
`stream_ended` after the native model finishes, so a late failure or truncated
stream cannot be reported as success. Transport bounds, UTF-8 validation,
cancellation and timeout handling are shared with existing providers.

## Verification and sources

`test/suite_zed_test.gleam` covers request controls, thinking/usage reduction,
status failures and NDJSON chunk boundaries. `test/zed_e2e_test.py` exercises
native HTTP streaming and tool replay through an isolated daemon. Tests use
fake tokens and local fixtures, not the user's Zed account.

Protocol references:

- [Zed cloud client at 99e70ee4](https://github.com/zed-industries/zed/blob/99e70ee4a02d8dcf1b72f487f81aaf0d3be74f76/crates/cloud_llm_client/src/cloud_llm_client.rs)
- [Zed native model adapters](https://github.com/zed-industries/zed/blob/99e70ee4a02d8dcf1b72f487f81aaf0d3be74f76/crates/language_models_cloud/src/language_models_cloud.rs)
- [zed2cli reference at 51e20772](https://github.com/6yte96/zed2cli/tree/51e20772373fe926a23a6027e328554c17bebe3a)

This is an unofficial integration. Live service compatibility and account
entitlement are not established by offline tests.
