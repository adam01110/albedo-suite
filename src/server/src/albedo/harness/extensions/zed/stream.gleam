import albedo/harness/extensions/claude/stream as messages
import albedo/harness/extensions/opencode_go/wire as portable
import albedo/harness/extensions/vertex/stream as gemini
import albedo/openai_api
import albedo/openai_api/chat
import albedo/openai_api/sse
import albedo/openai_api/stream
import albedo/openai_api/stream_http
import albedo/openai_api/types
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn reducer(
  provider: String,
  model: String,
  tools: List(types.Tool),
) -> stream.Reducer {
  let reducer = case provider {
    "anthropic" -> messages.reducer(model, tools)
    "open_ai" -> portable.responses_reducer()
    "google" -> gemini.reducer()
    _ ->
      stream.wrap(chat.new(), chat.feed, fn(state) {
        use #(_, _, turn) <- result.try(chat.feed(state, "[DONE]"))
        option.to_result(turn, types.UnexpectedEnd)
      })
  }
  stream.wrap(#(reducer, None), step, fn(_) { Error(types.UnexpectedEnd) })
}

fn step(
  state: #(stream.Reducer, Option(types.Turn)),
  line: String,
) -> Result(
  #(
    #(stream.Reducer, Option(types.Turn)),
    List(types.Event),
    Option(types.Turn),
  ),
  types.Error,
) {
  use event <- result.try(unwrap(line) |> result.map_error(types.ProviderError))
  case event {
    "" -> Ok(#(state, [], None))
    "stream_ended" ->
      case state.1 {
        Some(turn) -> Ok(#(state, [], Some(turn)))
        None -> {
          use turn <- result.map(state.0.finish())
          #(state, [], Some(turn))
        }
      }
    data -> {
      use #(next, events, turn) <- result.map(state.0.feed(data))
      #(#(next, option.or(turn, state.1)), events, None)
    }
  }
}

@external(erlang, "albedo_zed", "unwrap")
fn unwrap(line: String) -> Result(String, String)

pub fn exchange(
  provider: String,
  exchange: openai_api.Exchange,
  request: types.Request,
  on_event: fn(types.Event) -> types.Control,
) -> Result(types.Turn, types.Error) {
  stream_http.exchange_with_status(
    openai_api.to_pump(exchange),
    stream_http.Wire(
      start: sse.new_ndjson,
      feed: fn(parser, bytes) {
        sse.feed(parser, bytes) |> result.map_error(framing_error)
      },
      finish: fn(parser) {
        sse.finish(parser) |> result.map_error(framing_error)
      },
      payload: fn(event: sse.Event) { Ok(event.data) },
      body: fn(headers) {
        case
          list.any(headers, fn(header) {
            string.lowercase(header.0)
            == "x-zed-server-supports-status-messages"
            && string.lowercase(header.1) == "true"
          })
        {
          True -> stream_http.Pump
          False ->
            stream_http.Refuse(
              "Zed server does not support status-envelope streaming",
            )
        }
      },
      settle: stream_http.BeforeEnd,
      discard_on_error: True,
    ),
    reducer(provider, request.model, request.tools),
    on_event,
    fn(status, headers) {
      case
        status >= 400
        && list.any(headers, fn(header) {
          let key = string.lowercase(header.0)
          key == "x-zed-expired-token" || key == "x-zed-outdated-token"
        })
      {
        True -> 401
        False -> status
      }
    },
  )
}

fn framing_error(error: sse.Error) -> types.Error {
  case error {
    sse.EventTooLarge -> types.EventTooLarge
    sse.InvalidUtf8 -> types.InvalidEvent("invalid UTF-8 in Zed stream")
    sse.Malformed(message) -> types.InvalidEvent(message)
  }
}
