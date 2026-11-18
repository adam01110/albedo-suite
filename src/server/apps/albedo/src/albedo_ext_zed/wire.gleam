import albedo_anthropic/request as messages
import albedo_gemini/request as gemini
import albedo_model as types
import albedo_model/refusal
import albedo_openai as openai_api
import albedo_openai/opencode as portable
import albedo_openai/request as chat
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/string_tree

pub fn encode(
  provider: String,
  endpoint: String,
  token: String,
  session: String,
  request: types.Request,
) -> Result(openai_api.Exchange, types.Error) {
  let client = openai_api.client(types.ChatCompletions, endpoint, token)
  use body <- result.try(case provider {
    "anthropic" -> messages.encode_body(request)
    "open_ai" ->
      portable.encode_responses(client, [], request)
      |> result.map(fn(exchange) { exchange.body })
    "google" -> gemini.encode_body(request)
    "x_ai" -> chat.encode(types.ChatCompletions, request)
    _ -> Error(types.InvalidRequest("unsupported Zed model family"))
  })
  use body <- result.try(
    wrap(string_tree.to_string(body), session, provider, request.model)
    |> result.map_error(types.InvalidRequest),
  )
  Ok(openai_api.Exchange(
    string.remove_suffix(endpoint, "/") <> "/completions",
    [
      #("authorization", "Bearer " <> token),
      #("content-type", "application/json"),
      #("accept", "application/x-ndjson"),
      #("x-zed-client-supports-status-messages", "true"),
      #("x-zed-client-supports-stream-ended-request-completion-status", "true"),
    ],
    string_tree.from_string(body),
    120_000,
    None,
    8 * 1024 * 1024,
    False,
    refusal: refusal.openai,
  ))
}

@external(erlang, "albedo_zed", "wrap")
fn wrap(
  body: String,
  session: String,
  provider: String,
  model: String,
) -> Result(String, String)
