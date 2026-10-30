import albedo/harness/extension
import albedo/harness/extensions/zed/extension as zed
import albedo/harness/extensions/zed/stream as zed_stream
import albedo/harness/extensions/zed/wire
import albedo/harness/oauth
import albedo/openai_api
import albedo/openai_api/types
import gleam/list
import gleam/option.{Some}
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
  assert login.provider == "zed"
  let assert oauth.Device(_) = login.callback
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
