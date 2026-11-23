//// OpenCode Go wire dispatch across Chat Completions (`/chat/completions`),
//// OpenAI Responses (`/responses`), Anthropic Messages (`/messages`), and
//// Google Gemini (`:streamGenerateContent?alt=sse`). Every route converts from
//// and reduces back to portable ChatCompletions replay items, reusing the
//// shared OpenAI, Anthropic Messages, and Gemini encoders and reducers.

import albedo_anthropic/request as messages_request
import albedo_anthropic/stream as messages_stream
import albedo_ext_opencode_go/routing
import albedo_gemini/request as gemini_request
import albedo_gemini/stream as gemini_stream
import albedo_model.{type Error, type Request} as types
import albedo_model/refusal as openai_refusal
import albedo_openai
import albedo_openai/opencode as gateway
import albedo_openai/stream as reducer
import albedo_sdk/network_context
import albedo_sdk/settings
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string

pub type Client {
  Client(connection: albedo_openai.Client, session_id: String, org_id: String)
}

pub fn client(
  base_url: String,
  key: String,
  session: String,
  org: String,
) -> Client {
  Client(
    albedo_openai.client(types.ChatCompletions, base_url, key),
    session,
    org,
  )
}

pub fn validate(client: Client) -> Result(Nil, Error) {
  use _ <- result.try(albedo_openai.validate_client(client.connection))
  case
    string.trim(client.session_id) == ""
    || albedo_openai.unsafe_header(client.session_id)
    || albedo_openai.unsafe_header(client.org_id)
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
  albedo_openai.headers(client.connection, extra)
}

pub type Route {
  ChatRoute
  ResponsesRoute
  MessagesRoute
  GeminiRoute
}

/// Which upstream route OpenCode Go uses for `model`.
pub fn route(model: String) -> Route {
  case routing.metadata_route(settings.home(), model) {
    "messages" -> MessagesRoute
    "responses" -> ResponsesRoute
    "chat_completions" -> ChatRoute
    "gemini" -> GeminiRoute
    _ -> documented_route(model)
  }
}

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

/// what the route takes; the model's catalog still has to say it reads them
pub fn media(model: String) -> List(String) {
  case route(model) {
    GeminiRoute -> types.gemini_clips
    ChatRoute -> types.chat_audio
    ResponsesRoute | MessagesRoute -> []
  }
}

/// nothing is published. its edge took 16 MB bodies and refused one of about
/// 17 MB with a 413, so clips keep 12 MiB, the rest left to text and pictures.
/// https://github.com/anomalyco/opencode/issues/54784
/// https://github.com/anomalyco/opencode/issues/59067
pub const clip_budget = 12_582_912

/// only the gemini route's parts carry a video's frame rate
pub fn frame_rate(model: String) -> Bool {
  route(model) == GeminiRoute
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
      use exchange <- result.try(gateway.encode_responses(
        client.connection,
        headers(client),
        request,
      ))
      albedo_openai.exchange(
        albedo_openai.Exchange(..exchange, refusal:),
        network_context.transport(),
        gateway.responses_reducer(),
        on_event,
      )
    }
    MessagesRoute -> {
      use exchange <- result.try(encode_messages(
        client.connection,
        headers(client),
        request,
      ))
      albedo_openai.exchange(
        exchange,
        network_context.transport(),
        messages_stream.reducer(request.model, request.tools, gateway.cost),
        on_event,
      )
    }
    GeminiRoute -> {
      use exchange <- result.try(encode_gemini(
        client.connection,
        headers(client),
        request,
      ))
      albedo_openai.exchange(
        exchange,
        network_context.transport(),
        gemini_stream.reducer(),
        on_event,
      )
    }
  }
}

/// OpenCode Go's failures on any route. A 403 refuses a model the plan does
/// not include, and a 429 is lasting when it names a usage limit or a plan
/// window, which its body does only by name or in words.
pub fn refusal(status: Int, body: String) -> Error {
  case openai_refusal.openai(status, body), status {
    types.Refused(_, at, detail), 403 ->
      types.Refused(types.AccountBlocked(types.NotEntitled), at, detail)
    types.Refused(_, at, detail), 429 -> {
      let lasting =
        openai_refusal.spent_quota(body)
        || list.any(
          [
            "usage_limit",
            "UsageLimit",
            "RateLimit",
            "monthly",
            "weekly",
            "rolling",
          ],
          string.contains(body, _),
        )
      types.Refused(
        openai_refusal.limited(case lasting {
          True -> types.Lasting
          False -> types.Brief
        }),
        at,
        detail,
      )
    }
    refused, _ -> refused
  }
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
  client: albedo_openai.Client,
  headers: List(#(String, String)),
  request: Request,
) -> Result(albedo_openai.Exchange, Error) {
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
  albedo_openai.Exchange(
    gateway.base_url(client.base_url) <> "/messages",
    headers,
    body,
    120_000,
    None,
    client.max_event_bytes,
    True,
    refusal:,
  )
}

/// Encodes a ChatCompletions-projected request into a Gemini
/// `:streamGenerateContent?alt=sse` exchange via `gemini_request.encode_body`.
pub fn encode_gemini(
  client: albedo_openai.Client,
  headers: List(#(String, String)),
  request: Request,
) -> Result(albedo_openai.Exchange, Error) {
  use body <- result.map(gemini_request.encode_body(request))
  let url =
    gateway.base_url(client.base_url)
    <> "/models/"
    <> request.model
    <> ":streamGenerateContent?alt=sse"
  albedo_openai.Exchange(
    url,
    headers,
    body,
    120_000,
    None,
    client.max_event_bytes,
    True,
    refusal:,
  )
}

pub fn stream_chat(
  client: Client,
  request: Request,
  on_event: fn(types.Event) -> types.Control,
) -> Result(types.Turn, Error) {
  use _ <- result.try(validate(client))
  use prepared <- result.try(albedo_openai.encode_request(
    client.connection,
    request,
    gateway.encode_openai,
  ))
  albedo_openai.exchange(
    albedo_openai.Exchange(..prepared, headers: headers(client), refusal:),
    network_context.transport(),
    reducer.reducer_with(client.connection.protocol, gateway.cost),
    on_event,
  )
}
