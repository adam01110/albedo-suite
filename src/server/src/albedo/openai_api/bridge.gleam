//// The bridge between portable Chat Completions replay items and the Responses
//// wire: a ChatCompletions history replayed as Responses input, and a Responses
//// stream reduced back into one portable chat message.
////
//// A provider whose portable protocol is ChatCompletions but whose upstream
//// speaks Responses keeps one history shape across its routes, so switching
//// models keeps the conversation. OpenCode Go and GitHub Copilot both need it.

import albedo/openai_api/cost
import albedo/openai_api/decoding
import albedo/openai_api/replay
import albedo/openai_api/stream as reducer
import albedo/openai_api/types.{
  type Error, type Input, Assistant, ChatCompletions, InvalidRequest, Replay,
  Responses,
}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The detail type retained by earlier OpenCode Go histories.
const reasoning_detail = "openai.reasoning"

/// Replays portable input as the Responses items they correspond to: a
/// ChatCompletions assistant message becomes its text and one `function_call`
/// item per tool call, and anything else passes through unchanged.
pub fn responses_inputs(
  inputs: List(types.Input),
) -> Result(List(types.Input), types.Error) {
  list.try_fold(inputs, [], fn(acc, input) {
    use items <- result.map(responses_input(input))
    list.append(list.reverse(items), acc)
  })
  |> result.map(list.reverse)
}

fn responses_input(
  input: types.Input,
) -> Result(List(types.Input), types.Error) {
  case input {
    Replay(item) ->
      case types.replay_protocol(item) {
        Responses -> Ok([Replay(item)])
        ChatCompletions -> {
          use message <- result.try(
            types.inspect_item(item, replay.message_decoder(detail_decoder()))
            |> result.replace_error(InvalidRequest(
              "replayed assistant message is not portable",
            )),
          )
          use reasoning_items <- result.try(list.try_map(
            recorded_reasoning(message.details),
            responses_replay_item,
          ))
          let text_inputs = case message.text {
            "" -> []
            text -> [Assistant(text)]
          }
          use call_inputs <- result.map(list.try_map(message.calls, call_item))
          list.append(reasoning_items, list.append(text_inputs, call_inputs))
        }
      }
    other -> Ok([other])
  }
}

type Recorded {
  Recorded(items: List(json.Json))
}

fn detail_decoder() -> decode.Decoder(Option(Recorded)) {
  use kind <- decode.field("type", decode.string)
  use items <- decode.optional_field("items", [], decode.list(decode.dynamic))
  decode.success(case kind == reasoning_detail {
    True -> Some(Recorded(list.map(items, types.encode_value)))
    False -> None
  })
}

/// The reasoning items a turn recorded, in the order the provider issued
/// them: a reasoning item comes before the message it precedes.
fn recorded_reasoning(details: List(Recorded)) -> List(json.Json) {
  details
  |> list.filter_map(fn(detail) {
    case detail {
      Recorded(items) -> Ok(items)
    }
  })
  |> list.flatten
}

fn responses_replay_item(item: json.Json) -> Result(Input, Error) {
  json.parse(json.to_string(item), types.replay_decoder(Responses))
  |> result.map(Replay)
  |> result.replace_error(InvalidRequest(
    "could not replay a recorded reasoning item",
  ))
}

fn call_item(call: types.ToolCall) -> Result(types.Input, types.Error) {
  let raw =
    json.object([
      #("type", json.string("function_call")),
      #("call_id", json.string(call.id)),
      #("name", json.string(call.name)),
      #("arguments", json.string(call.arguments)),
    ])
    |> json.to_string
  json.parse(raw, types.replay_decoder(Responses))
  |> result.map(Replay)
  |> result.replace_error(InvalidRequest(
    "could not encode tool call for the Responses route",
  ))
}

type TurnState {
  TurnState(inner: reducer.Reducer, thinking: List(String))
}

/// Reduces an OpenAI `/responses` SSE stream into a Turn whose replay item is a
/// single portable `ChatCompletions` assistant message. `reader` reads the
/// price of this route. A route that names no price gives `cost.none`.
pub fn responses_reducer(reader: cost.Reader) -> reducer.Reducer {
  reducer.wrap(
    TurnState(reducer.reducer_with(Responses, reader), []),
    step,
    fn(_) { Error(types.UnexpectedEnd) },
  )
}

fn step(
  state: TurnState,
  data: String,
) -> Result(#(TurnState, List(types.Event), Option(types.Turn)), types.Error) {
  use #(next_inner, events, turn) <- result.try(state.inner.feed(data))
  let thinking =
    list.fold(events, state.thinking, fn(acc, event) {
      case event {
        types.ThinkingDelta(delta) -> [delta, ..acc]
        _ -> acc
      }
    })
  let next_state = TurnState(next_inner, thinking)
  case turn {
    None -> Ok(#(next_state, events, None))
    Some(turn) -> {
      use converted <- result.map(turn_to_chat(turn, thinking))
      #(next_state, events, Some(converted))
    }
  }
}

fn turn_to_chat(
  turn: types.Turn,
  thinking_chunks: List(String),
) -> Result(types.Turn, types.Error) {
  let text =
    turn.output
    |> list.map(item_text)
    |> string.concat
  let thinking = case thinking_chunks {
    [] ->
      turn.output
      |> list.map(item_thinking)
      |> list.filter(fn(s) { s != "" })
      |> string.join("\n\n")
    chunks -> chunks |> list.reverse |> string.concat
  }
  let calls = case turn.finish {
    types.ToolCalls -> turn.tool_calls
    _ -> []
  }
  let content = case text {
    "" -> json.null()
    _ -> json.string(text)
  }
  // The provider's reasoning items are kept whole: encrypted reasoning only
  // continues a conversation if the next request sends it back.
  let reasoning =
    turn.output
    |> list.filter(fn(item) { item_kind(item) == "reasoning" })
    |> list.map(types.replay_json)
  let details = case reasoning {
    [] -> None
    items ->
      Some(
        json.preprocessed_array([
          json.object([
            #("type", json.string(reasoning_detail)),
            #("items", json.preprocessed_array(items)),
          ]),
        ]),
      )
  }
  use item <- result.map(
    json.parse(
      json.to_string(replay.message(content, thinking, details, calls)),
      types.replay_decoder(ChatCompletions),
    )
    |> result.map_error(fn(error) {
      types.InvalidEvent(
        "could not build a portable replay message: "
        <> decoding.json_error(error),
      )
    }),
  )
  types.Turn(..turn, output: [item], tool_calls: calls)
}

fn item_text(item: types.ReplayItem) -> String {
  let part = decode.field("text", decode.string, decode.success)
  types.inspect_item(
    item,
    decode.field(
      "content",
      decode.list(decode.one_of(part, [decode.success("")])),
      decode.success,
    ),
  )
  |> result.unwrap([])
  |> string.concat
}

fn item_kind(item: types.ReplayItem) -> String {
  types.inspect_item(item, decode.field("type", decode.string, decode.success))
  |> result.unwrap("")
}

fn item_thinking(item: types.ReplayItem) -> String {
  let kind =
    types.inspect_item(
      item,
      decode.field("type", decode.string, decode.success),
    )
    |> result.unwrap("")
  case kind {
    "reasoning" -> {
      let part = decode.field("text", decode.string, decode.success)
      let fragments = fn(name: String) {
        types.inspect_item(
          item,
          decode.field(name, decode.list(part), decode.success),
        )
        |> result.unwrap([])
      }
      let parts = case fragments("summary") {
        [] -> fragments("content")
        summary -> summary
      }
      string.join(parts, "\n\n")
    }
    _ -> ""
  }
}
