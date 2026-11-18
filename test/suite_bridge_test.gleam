import albedo/harness/sdk/opencode_gateway as wire
import albedo/openai_api/bridge
import albedo_model as types
import albedo_model/replay
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/option.{Some}
import gleeunit/should

fn reasoning(id: String, encrypted: String) -> json.Json {
  json.object([
    #("type", json.string("reasoning")),
    #("id", json.string(id)),
    #("encrypted_content", json.string(encrypted)),
    #(
      "summary",
      json.preprocessed_array([
        json.object([
          #("type", json.string("summary_text")),
          #("text", json.string("consider")),
        ]),
      ]),
    ),
    #("future_provider_field", json.object([#("keep", json.bool(True))])),
  ])
}

fn call(id: String) -> json.Json {
  json.object([
    #("type", json.string("function_call")),
    #("id", json.string("item-" <> id)),
    #("call_id", json.string(id)),
    #("name", json.string("python")),
    #("arguments", json.string("{}")),
  ])
}

fn message() -> json.Json {
  json.object([
    #("type", json.string("message")),
    #("id", json.string("message-1")),
    #("role", json.string("assistant")),
    #("status", json.string("completed")),
    #(
      "content",
      json.preprocessed_array([
        json.object([
          #("type", json.string("output_text")),
          #("text", json.string("reply")),
          #("annotations", json.preprocessed_array([])),
        ]),
      ]),
    ),
  ])
}

fn replay_item(value: json.Json, protocol: types.Protocol) -> types.ReplayItem {
  let assert Ok(item) =
    json.parse(json.to_string(value), types.replay_decoder(protocol))
  item
}

fn same_json(actual: json.Json, expected: json.Json) {
  json.parse(json.to_string(actual), decode.dynamic)
  |> should.equal(json.parse(json.to_string(expected), decode.dynamic))
}

fn completed(output: List(json.Json)) -> String {
  json.object([
    #("type", json.string("response.completed")),
    #(
      "response",
      json.object([
        #("id", json.string("response-test")),
        #("status", json.string("completed")),
        #("output", json.preprocessed_array(output)),
      ]),
    ),
  ])
  |> json.to_string
}

fn assert_replayed(turn: types.Turn, first: json.Json, second: json.Json) {
  let assert [portable] = turn.output
  types.replay_protocol(portable) |> should.equal(types.ChatCompletions)
  let assert Ok([
    types.Replay(one),
    types.Replay(two),
    types.Assistant("reply"),
    types.Replay(first_call),
    types.Replay(second_call),
  ]) = bridge.responses_inputs([types.Replay(portable)])
  same_json(types.replay_json(one), first)
  same_json(types.replay_json(two), second)
  let assert Ok(one_id) =
    json.parse(
      json.to_string(types.replay_json(first_call)),
      decode.field("call_id", decode.string, decode.success),
    )
  let assert Ok(two_id) =
    json.parse(
      json.to_string(types.replay_json(second_call)),
      decode.field("call_id", decode.string, decode.success),
    )
  one_id |> should.equal("call-a")
  two_id |> should.equal("call-b")
}

fn legacy_details_replay_without_loss() {
  let first = reasoning("old-one", "opaque-old-one")
  let second = reasoning("old-two", "opaque-old-two")
  let portable =
    replay_item(
      replay.message(
        json.string("reply"),
        "consider",
        Some(
          json.preprocessed_array([
            json.object([
              #("type", json.string("openai.reasoning")),
              #("items", json.preprocessed_array([first, second])),
            ]),
          ]),
        ),
        [types.ToolCall("call-a", "python", "{}")],
      ),
      types.ChatCompletions,
    )
  let assert Ok([
    types.Replay(one),
    types.Replay(two),
    types.Assistant("reply"),
    types.Replay(_),
  ]) = bridge.responses_inputs([types.Replay(portable)])
  same_json(types.replay_json(one), first)
  same_json(types.replay_json(two), second)
  let native = replay_item(first, types.Responses)
  bridge.responses_inputs([types.Replay(native)])
  |> should.equal(Ok([types.Replay(native)]))
}

fn completed_output_preserves_indices_and_reasoning() {
  let first = reasoning("new-one", "opaque-new-one")
  let second = reasoning("new-two", "opaque-new-two")
  let output = [first, message(), call("call-a"), second, call("call-b")]
  let reducer = wire.responses_reducer()
  let assert Ok(#(_, _, Some(turn))) = reducer.feed(completed(output))
  turn.call_indices |> should.equal([#("call-a", 2), #("call-b", 4)])
  turn.finish |> should.equal(types.ToolCalls)
  assert_replayed(turn, first, second)
}

pub fn main() {
  legacy_details_replay_without_loss()
  completed_output_preserves_indices_and_reasoning()
  io.println(
    "Responses bridge legacy/new encrypted reasoning and native output indices passed",
  )
}
