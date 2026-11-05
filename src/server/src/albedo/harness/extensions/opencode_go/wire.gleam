//// OpenCode Go wire dispatch across Chat Completions (`/chat/completions`),
//// OpenAI Responses (`/responses`), Anthropic Messages (`/messages`), and
//// Google Gemini (`:streamGenerateContent?alt=sse`). Every route converts from
//// and reduces back to portable ChatCompletions replay items, reusing the
//// shared OpenAI, Bedrock/Claude, and Vertex wire/stream encoders and reducers.

import albedo/harness/extensions/bedrock/wire as bedrock_wire
import albedo/harness/extensions/vertex/wire as vertex_wire
import albedo/harness/settings
import albedo/openai_api
import albedo/openai_api/bridge
import albedo/openai_api/request as openai_request
import albedo/openai_api/stream as reducer
import albedo/openai_api/types.{type Client, type Error, type Request, Responses}
import gleam/option.{None}
import gleam/result
import gleam/string

pub type Route {
  ChatRoute
  ResponsesRoute
  MessagesRoute
  GeminiRoute
}

/// Which upstream route OpenCode Go uses for `model`.
pub fn route(model: String) -> Route {
  case metadata_route(settings.home(), model) {
    "messages" -> MessagesRoute
    "responses" -> ResponsesRoute
    "chat_completions" -> ChatRoute
    "gemini" -> GeminiRoute
    _ -> documented_route(model)
  }
}

@external(erlang, "albedo_opencode_go", "metadata_route")
fn metadata_route(home: String, model: String) -> String

fn documented_route(model: String) -> Route {
  let id = string.lowercase(string.trim(model))
  case
    string.starts_with(id, "gemini-"),
    string.starts_with(id, "claude-") || id == "minimax-m2.7",
    string.starts_with(id, "gpt-")
    || string.starts_with(id, "grok-")
    || string.starts_with(id, "muse-spark-")
  {
    True, _, _ -> GeminiRoute
    _, True, _ -> MessagesRoute
    _, _, True -> ResponsesRoute
    False, False, False -> ChatRoute
  }
}

/// Canonical inference base URL; `/zen/go/v1` is rewritten to `/inference/go/v1`
/// so Gemini's `/models/{id}:streamGenerateContent` route resolves on the
/// direct inference gateway.
pub fn base_url(url: String) -> String {
  let trimmed = string.remove_suffix(string.trim(url), "/")
  case trimmed {
    "https://opencode.ai/zen/go/v1" -> "https://opencode.ai/inference/go/v1"
    _ -> trimmed
  }
}

/// Encodes a ChatCompletions-projected request into an OpenAI `/responses`
/// exchange for OpenCode Go models backed by Responses (GPT, Grok, Muse Spark).
pub fn encode_responses(
  client: Client,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use inputs <- result.try(bridge.responses_inputs(request.input))
  let rewritten = types.Request(..request, input: inputs)
  use body <- result.map(openai_request.encode_with_policy(
    Responses,
    client.policy,
    rewritten,
  ))
  openai_api.Exchange(
    base_url(client.base_url) <> "/responses",
    openai_api.request_headers(client, request),
    body,
    client.timeout_ms,
    None,
    client.max_event_bytes,
    True,
  )
}

/// Encodes a ChatCompletions-projected request into an Anthropic `/messages`
/// exchange via `bedrock_wire.encode_body`.
pub fn encode_messages(
  client: Client,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  let request = case string.starts_with(request.model, "claude-") {
    True -> request
    False ->
      types.Request(
        ..request,
        options: types.Options(..request.options, effort: None),
      )
  }
  use body <- result.map(bedrock_wire.encode_body(request))
  let headers = [
    #("anthropic-version", "2023-06-01"),
    #("x-api-key", client.api_key),
    ..openai_api.headers(client, request.model)
  ]
  openai_api.Exchange(
    base_url(client.base_url) <> "/messages",
    headers,
    body,
    120_000,
    None,
    client.max_event_bytes,
    True,
  )
}

/// Encodes a ChatCompletions-projected request into a Gemini
/// `:streamGenerateContent?alt=sse` exchange via `vertex_wire.encode_body`.
pub fn encode_gemini(
  client: Client,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use body <- result.map(vertex_wire.encode_body(request))
  let url =
    base_url(client.base_url)
    <> "/models/"
    <> request.model
    <> ":streamGenerateContent?alt=sse"
  openai_api.Exchange(
    url,
    openai_api.headers(client, request.model),
    body,
    120_000,
    None,
    client.max_event_bytes,
    True,
  )
}

/// Reduces an OpenAI `/responses` SSE stream into a Turn whose replay item is a
/// single portable `ChatCompletions` assistant message.
pub fn responses_reducer() -> reducer.Reducer {
  bridge.responses_reducer()
}
