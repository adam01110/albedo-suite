import albedo/harness/extension
import albedo/harness/extensions/zed/extension as zed
import albedo/harness/extensions/zed/quota as zed_quota
import albedo/harness/extensions/zed/stream as zed_stream
import albedo/harness/extensions/zed/wire
import albedo/harness/oauth
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import harness/oauth_test

@external(erlang, "albedo_zed_login_test", "run")
fn native() -> Nil

pub fn main() {
  let plugins = zed.extension().plugins
  let assert Some(extension.LoginPlugin(login)) =
    list.find(plugins, fn(plugin) {
      case plugin {
        extension.LoginPlugin(_) -> True
        _ -> False
      }
    })
    |> option.from_result
  // The extension's own record, not a fixture copy: a regression in the Zed
  // wiring has to fail here, and the shared-engine cases below cannot see it.
  login.provider |> should.equal("zed")
  login.store |> should.equal("zed")
  login.label |> should.equal("add Zed account")
  login.kind |> should.equal(oauth.Model)
  string.contains(login.detail, "browser sign-in") |> should.be_true
  string.contains(login.detail, "automatically renewed") |> should.be_true
  let assert oauth.Device(_) = login.callback
  // Account naming is the native one: user and organization from the callback.
  let assert Ok(credential) =
    json.parse(
      "{\"user_id\":\"42\",\"github_login\":\"github-user\",\"organization_id\":\"org-42\"}",
      decode.dynamic,
    )
  let account = login.account(credential)
  account.id |> should.equal("42:org-42")
  account.label |> should.equal("github-user")
  account.selected |> should.be_false
  oauth_test.a_pasted_redirect_races_the_callback_test()
  oauth_test.a_pasted_code_for_another_attempt_is_rejected_test()
  oauth_test.a_device_code_flow_publishes_instructions_and_completes_test()
  native()
}

pub fn header_case(endpoint: String) -> Nil {
  let request = openai_api.request("fixture-model", [types.User("hello")])
  let assert Ok(exchange) =
    wire.encode("anthropic", endpoint, "fixture-jwt", "session", request)
  let assert Error(types.HttpError(401, _)) =
    zed_stream.exchange("anthropic", exchange, request, fn(_) { types.Continue })
  Nil
}

@external(erlang, "albedo_zed", "route")
fn route(
  home: String,
  endpoint: String,
  token: String,
  model: String,
) -> Result(String, String)

pub fn inference(
  home: String,
  endpoint: String,
  token: String,
  emit: fn(types.Event) -> types.Control,
) -> Result(types.Turn, types.Error) {
  let request =
    openai_api.request("browser-fixture-model", [types.User("hello")])
  let assert Ok(provider) = route(home, endpoint, token, request.model)
  let assert Ok(exchange) =
    wire.encode(provider, endpoint, token, "clean-home-session", request)
  zed_stream.exchange(provider, exchange, request, emit)
}

pub fn quota_case() -> Nil {
  let credential =
    json.object([
      #("kind", json.string("oauth")),
      #("accountId", json.string("42")),
      #("access", json.string("quota-fixture-secret")),
    ])
  let assert Ok(report) = zed_quota.fetch(credential)
  assert report.error == None
  let assert [limit] = report.limits
  assert limit.id == "edit-predictions"
  assert limit.used_percent == Some(25.0)
  let assert Ok(missing) = zed_quota.fetch(json.object([]))
  assert missing.error == Some("Zed account credential is unavailable")
  Nil
}
