//// OpenCode Go wire dispatch across Chat Completions (`/chat/completions`),
//// OpenAI Responses (`/responses`), Anthropic Messages (`/messages`), and
//// Google Gemini (`:streamGenerateContent?alt=sse`). Every route converts from
//// and reduces back to portable ChatCompletions replay items, reusing the
//// shared OpenAI, Anthropic Messages, and Gemini encoders and reducers.

import albedo/anthropic_api/request as messages_request
import albedo/anthropic_api/stream as messages_stream
import albedo/gemini_api/request as gemini_request
import albedo/gemini_api/stream as gemini_stream
import albedo/harness/settings
import albedo/openai_api
import albedo/openai_api/bridge
import albedo/openai_api/cost
import albedo/openai_api/request as openai_request
import albedo/openai_api/stream as reducer
import albedo/openai_api/types.{type Error, type Request, Responses}
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

pub type Client {
  Client(connection: types.Client, session_id: String, org_id: String)
}

pub fn client(
  base_url: String,
  key: String,
  session: String,
  org: String,
) -> Client {
  Client(openai_api.client(types.ChatCompletions, base_url, key), session, org)
}

pub fn validate(client: Client) -> Result(Nil, Error) {
  use _ <- result.try(openai_api.validate_client(client.connection))
  case
    string.trim(client.session_id) == ""
    || openai_api.unsafe_header(client.session_id)
    || openai_api.unsafe_header(client.org_id)
  {
    True -> Error(types.InvalidRequest("invalid OpenCode Go session identity"))
    False -> Ok(Nil)
  }
}

pub fn headers(client: Client) -> List(#(String, String)) {
  let extra = [
    #("user-agent", "albedo/1.0"),
    #("x-opencode-client", "albedo"),
    #("x-opencode-session", client.session_id),
  ]
  let extra = case client.org_id {
    "" -> extra
    org -> [#("x-opencode-org-id", org), ..extra]
  }
  openai_api.headers(client.connection, extra)
}

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

/// Send a request using the route and reducer selected for its model.
pub fn stream(
  client: Client,
  request: types.Request,
  on_event: fn(types.Event) -> types.Control,
) -> Result(types.Turn, types.Error) {
  use _ <- result.try(validate(client))
  case route(request.model) {
    ChatRoute -> stream_chat(client, request, on_event)
    ResponsesRoute -> {
      use exchange <- result.try(encode_responses(
        client.connection,
        headers(client),
        request,
      ))
      openai_api.exchange(exchange, responses_reducer(), on_event)
    }
    MessagesRoute -> {
      use exchange <- result.try(encode_messages(
        client.connection,
        headers(client),
        request,
      ))
      openai_api.exchange(
        exchange,
        messages_stream.reducer(request.model, request.tools, cost),
        on_event,
      )
    }
    GeminiRoute -> {
      use exchange <- result.try(encode_gemini(
        client.connection,
        headers(client),
        request,
      ))
      openai_api.exchange(exchange, gemini_stream.reducer(), on_event)
    }
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
  client: types.Client,
  headers: List(#(String, String)),
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use inputs <- result.try(bridge.responses_inputs(request.input))
  let rewritten = types.Request(..request, input: inputs)
  use body <- result.map(encode_openai(Responses, rewritten))
  openai_api.Exchange(
    base_url(client.base_url) <> "/responses",
    headers,
    body,
    client.timeout_ms,
    None,
    client.max_event_bytes,
    True,
  )
}

/// The lease OpenCode Go keeps on a marked prefix: its `/messages` route
/// answered 200 to the hour-long beta on 2026-11-09 but still wrote
/// five-minute entries, so that is what a request asks for.
pub const cache_ttl_seconds = 300

/// Explicit breakpoints sent by the selected route, as recorded in the ledger.
pub fn cache_marks(request: Request) -> List(types.CacheMark) {
  case route(request.model) {
    MessagesRoute -> messages_request.cache_marks(request, cache_ttl_seconds)
    _ -> []
  }
}

/// Encodes a ChatCompletions-projected request into an Anthropic `/messages`
/// exchange via `messages_request.encode_body_cached`, marking the prefixes the gateway
/// can serve from its cache.
pub fn encode_messages(
  client: types.Client,
  headers: List(#(String, String)),
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
  use body <- result.map(messages_request.encode_body_cached(
    request,
    cache_ttl_seconds,
  ))
  let headers = [
    #("anthropic-version", "2023-06-01"),
    #("x-api-key", client.api_key),
    ..headers
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
/// `:streamGenerateContent?alt=sse` exchange via `gemini_request.encode_body`.
pub fn encode_gemini(
  client: types.Client,
  headers: List(#(String, String)),
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use body <- result.map(gemini_request.encode_body(request))
  let url =
    base_url(client.base_url)
    <> "/models/"
    <> request.model
    <> ":streamGenerateContent?alt=sse"
  openai_api.Exchange(
    url,
    headers,
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
  bridge.responses_reducer(cost)
}

/// The cost that OpenCode Go reports for a call. `cost` is money charged to a
/// balance or a key. `opencode.allowance` is the amount that a Go plan counted
/// against its limit. `opencode.list_cost` is the list price of the call when a
/// plan included it. A call that a plan covers reports zero charged and still
/// names the last two figures.
pub fn cost(frame: Dynamic) -> Option(types.Cost) {
  let figures =
    types.Cost(
      charged_usd: cost.in_usage(frame, ["cost"]),
      counted_usd: cost.in_usage(frame, ["opencode", "allowance"]),
      listed_usd: cost.in_usage(frame, ["opencode", "list_cost"]),
    )
  case cost.priced(figures) {
    True -> Some(figures)
    False -> None
  }
}

/// The gateway does not accept OpenAI service tiers on either OpenAI route.
pub fn encode_openai(
  protocol: types.Protocol,
  request: Request,
) -> Result(StringTree, Error) {
  use fields <- result.map(openai_request.fields(protocol, request))
  json.to_string_tree(
    json.object(list.filter(fields, fn(field) { field.0 != "service_tier" })),
  )
}

pub fn stream_chat(
  client: Client,
  request: Request,
  on_event: fn(types.Event) -> types.Control,
) -> Result(types.Turn, Error) {
  use _ <- result.try(validate(client))
  use prepared <- result.try(openai_api.encode_request(
    client.connection,
    request,
    encode_openai,
  ))
  openai_api.exchange(
    openai_api.Exchange(..prepared, headers: headers(client)),
    reducer.reducer_with(client.connection.protocol, cost),
    on_event,
  )
}
