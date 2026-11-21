
//// The Chat Completions -> Responses input bridge. A generated history with
//// text turns, images, tool calls, their results and encrypted reasoning must
//// replay in order: each call exactly once, each result after its call, and
//// every provider reasoning item preserved exactly. The second property
//// drives the Responses stream reducer back into a portable message and
//// checks that sparse output indices stay correlated with their calls.

import albedo_model as types
import albedo_model/cost
import albedo_model/replay
import albedo_openai/bridge
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import proptest
import qcheck

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn words() -> qcheck.Generator(String) {
  qcheck.generic_list(
    pick(["alpha", "beta", " ", "é", "\"", "{x}"]),
    qcheck.bounded_int(0, 3),
  )
  |> qcheck.map(string.concat)
}

fn image() -> qcheck.Generator(types.Image) {
  use data, mime <- qcheck.map2(
    pick(["aGVsbG8=", "d29ybGQ=", "eHl6enk=", "cG5n"]),
    pick(["image/png", "image/jpeg", "image/webp"]),
  )
  let assert Ok(image) = types.image(mime, data, 2, 3, 5)
  image
}

fn images() -> qcheck.Generator(List(types.Image)) {
  qcheck.generic_list(image(), qcheck.bounded_int(0, 2))
}

// ---------- the portable-history property ----------

type Call {
  Call(id: String, name: String, arguments: String)
}

type Recorded {
  Recorded(id: String, encrypted: String, summary: String)
}

type Block {
  Plain(input: types.Input)
  ToolTurn(
    text: String,
    thinking: String,
    calls: List(Call),
    reasoning: List(Recorded),
    results: Bool,
  )
}

fn plain() -> qcheck.Generator(Block) {
  qcheck.from_weighted_generators(
    #(4, words() |> qcheck.map(fn(text) { Plain(types.User(text)) })),
    [
      #(2, words() |> qcheck.map(fn(text) { Plain(types.Assistant(text)) })),
      #(
        2,
        qcheck.map2(words(), images(), fn(text, images) {
          Plain(types.UserImage(text, images))
        }),
      ),
    ],
  )
}

fn recorded() -> qcheck.Generator(Recorded) {
  qcheck.map2(words(), words(), fn(encrypted, summary) {
    Recorded("", "enc-" <> encrypted, summary)
  })
}

fn tool_turn() -> qcheck.Generator(Block) {
  use text, thinking, calls, reasoning, results <- qcheck.map5(
    words(),
    words(),
    qcheck.generic_list(
      qcheck.map2(pick(["python", "read_file", "grep"]), pick([
        "{}", "{\"code\":\"x\"}", "",
      ]), fn(name, arguments) { Call("", name, arguments) }),
      qcheck.bounded_int(0, 3),
    ),
    qcheck.generic_list(recorded(), qcheck.bounded_int(0, 2)),
    qcheck.bool(),
  )
  ToolTurn(text, thinking, calls, reasoning, results)
}

fn blocks() -> qcheck.Generator(List(Block)) {
  qcheck.generic_list(
    qcheck.from_weighted_generators(#(3, plain()), [#(4, tool_turn())]),
    qcheck.bounded_int(0, 4),
  )
}

/// Give every call and reasoning item an id unique in the history, so an
/// oracle can tell a duplicated item from a repeated one.
fn assign(blocks: List(Block)) -> List(Block) {
  let #(_, assigned) =
    list.fold(blocks, #(0, []), fn(acc, block) {
      let #(next, kept) = acc
      case block {
        Plain(input) -> #(next, [Plain(input), ..kept])
        ToolTurn(text, thinking, calls, reasoning, results) -> {
          let #(next, calls) =
            list.fold(calls, #(next, []), fn(acc, call) {
              let #(n, kept) = acc
              let id = "call-" <> int.to_string(n)
              #(n + 1, [Call(id, call.name, call.arguments), ..kept])
            })
          let #(next, reasoning) =
            list.fold(reasoning, #(next, []), fn(acc, item) {
              let #(n, kept) = acc
              let id = "reasoning-" <> int.to_string(n)
              #(
                n + 1,
                [Recorded(id, item.encrypted, item.summary), ..kept],
              )
            })
          #(
            next,
            [
              ToolTurn(
                text,
                thinking,
                list.reverse(calls),
                list.reverse(reasoning),
                results,
              ),
              ..kept
            ],
          )
        }
      }
    })
  list.reverse(assigned)
}

fn reasoning_json(item: Recorded) -> Json {
  json.object([
    #("type", json.string("reasoning")),
    #("id", json.string(item.id)),
    #("encrypted_content", json.string(item.encrypted)),
    #(
      "summary",
      json.preprocessed_array([
        json.object([
          #("type", json.string("summary_text")),
          #("text", json.string(item.summary)),
        ]),
      ]),
    ),
    #("future_provider_field", json.object([#("keep", json.bool(True))])),
  ])
}

fn replay_item(value: Json, protocol: types.Protocol) -> types.ReplayItem {
  let assert Ok(item) =
    json.parse(json.to_string(value), types.replay_decoder(protocol))
  item
}

fn portable_message(
  text: String,
  thinking: String,
  recorded: List(Recorded),
  calls: List(Call),
) -> types.Input {
  let content = case text {
    "" -> json.null()
    _ -> json.string(text)
  }
  let details = case recorded {
    [] -> None
    items ->
      Some(
        json.preprocessed_array([
          json.object([
            #("type", json.string("openai.reasoning")),
            #(
              "items",
              json.preprocessed_array(list.map(items, reasoning_json)),
            ),
          ]),
        ]),
      )
  }
  let calls =
    list.map(calls, fn(call) {
      types.ToolCall(call.id, call.name, call.arguments)
    })
  types.Replay(
    replay_item(
      replay.message(content, thinking, details, calls),
      types.ChatCompletions,
    ),
  )
}

type Expect {
  Same(types.Input)
  Ereason(Json)
  Etext(String)
  Ecall(Call)
  Eresult(String)
}

/// The portable history and, item by item, what the Responses input must be.
fn history(blocks: List(Block)) -> #(List(types.Input), List(Expect)) {
  let #(inputs, expects) =
    list.fold(blocks, #([], []), fn(acc, block) {
      let #(inputs, expects) = acc
      case block {
        Plain(input) -> #([input, ..inputs], [Same(input), ..expects])
        ToolTurn(text, thinking, calls, reasoning, results) -> {
          let details = list.map(reasoning, reasoning_json)
          let message = portable_message(text, thinking, reasoning, calls)
          let outputs = case results {
            True ->
              list.map(calls, fn(call) {
                types.ToolOutput(call.id, "result for " <> call.id, [])
              })
            False -> []
          }
          let text_expects = case text {
            "" -> []
            text -> [Etext(text)]
          }
          let new_expects =
            list.append(
              list.map(details, Ereason),
              list.append(
                text_expects,
                list.append(
                  list.map(calls, Ecall),
                  case results {
                    True -> list.map(calls, fn(call) { Eresult(call.id) })
                    False -> []
                  },
                ),
              ),
            )
          #(
            list.append(list.reverse([message, ..outputs]), inputs),
            list.append(list.reverse(new_expects), expects),
          )
        }
      }
    })
  #(list.reverse(inputs), list.reverse(expects))
}

fn same_json(actual: Json, expected: Json) {
  let assert Ok(actual) = json.parse(json.to_string(actual), decode.dynamic)
  let assert Ok(expected) =
    json.parse(json.to_string(expected), decode.dynamic)
  actual |> should.equal(expected)
}

fn field_string(value: Json, key: String) -> Result(String, Nil) {
  json.parse(
    json.to_string(value),
    decode.at([key], decode.string),
  )
  |> result.replace_error(Nil)
}

fn check_item(actual: types.Input, expect: Expect) {
  case actual, expect {
    types.Replay(item), Ereason(want) -> {
      types.replay_protocol(item) |> should.equal(types.Responses)
      let got = types.replay_json(item)
      same_json(got, want)
      field_string(got, "encrypted_content")
      |> should.equal(field_string(want, "encrypted_content"))
      field_string(got, "id") |> should.equal(field_string(want, "id"))
    }
    types.Replay(item), Ecall(want) -> {
      types.replay_protocol(item) |> should.equal(types.Responses)
      let got = types.replay_json(item)
      field_string(got, "type") |> should.equal(Ok("function_call"))
      field_string(got, "call_id") |> should.equal(Ok(want.id))
      field_string(got, "name") |> should.equal(Ok(want.name))
      field_string(got, "arguments") |> should.equal(Ok(want.arguments))
    }
    types.Assistant(text), Etext(want) -> text |> should.equal(want)
    types.ToolOutput(id, _, _), Eresult(want) -> id |> should.equal(want)
    _, Same(want) -> actual |> should.equal(want)
    _, _ -> should.equal(False, True)
  }
}

/// Every tool call id appears exactly once in the replayed input.
fn call_ids(items: List(types.Input)) -> List(String) {
  list.filter_map(items, fn(item) {
    case item {
      types.Replay(replayed) ->
        case field_string(types.replay_json(replayed), "type") {
          Ok("function_call") ->
            field_string(types.replay_json(replayed), "call_id")
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

fn portable_history_property(blocks: List(Block)) -> Nil {
  let blocks = assign(blocks)
  let #(inputs, expects) = history(blocks)
  let assert Ok(output) = bridge.responses_inputs(inputs)
  list.length(output) |> should.equal(list.length(expects))
  list.zip(output, expects)
  |> list.each(fn(pair) { check_item(pair.0, pair.1) })
  let ids = call_ids(output)
  list.length(ids) |> should.equal(list.length(list.unique(ids)))
  case blocks {
    [] -> Nil
    _ -> proptest.bump("histories")
  }
}


// ---------- the reducer property ----------

type OutItem {
  Oreason(Recorded)
  Ocall(Call)
  Otext(String)
}

fn out_item() -> qcheck.Generator(OutItem) {
  qcheck.from_weighted_generators(
    #(3, recorded() |> qcheck.map(Oreason)),
    [
      #(4, qcheck.map2(pick(["python", "read_file"]), pick([
        "{}", "{\"path\":\"/tmp\"}",
      ]), fn(name, arguments) { Ocall(Call("", name, arguments)) })),
      #(2, words() |> qcheck.map(Otext)),
    ],
  )
}

fn assign_outputs(items: List(OutItem)) -> List(OutItem) {
  let #(_, assigned) =
    list.fold(items, #(0, []), fn(acc, item) {
      let #(n, kept) = acc
      case item {
        Oreason(recorded) ->
          #(
            n + 1,
            [Oreason(Recorded("reasoning-" <> int.to_string(n), recorded.encrypted, recorded.summary)), ..kept],
          )
        Ocall(call) ->
          #(
            n + 1,
            [Ocall(Call("call-" <> int.to_string(n), call.name, call.arguments)), ..kept],
          )
        Otext(text) -> #(n, [Otext(text), ..kept])
      }
    })
  list.reverse(assigned)

}

fn output_json(item: OutItem) -> Json {
  case item {
    Oreason(recorded) -> reasoning_json(recorded)
    Ocall(call) ->
      json.object([
        #("type", json.string("function_call")),
        #("id", json.string("item-" <> call.id)),
        #("call_id", json.string(call.id)),
        #("name", json.string(call.name)),
        #("arguments", json.string(call.arguments)),
      ])
    Otext(text) ->
      json.object([
        #("type", json.string("message")),
        #("id", json.string("message-1")),
        #("role", json.string("assistant")),
        #(
          "content",
          json.preprocessed_array([
            json.object([
              #("type", json.string("output_text")),
              #("text", json.string(text)),
            ]),
          ]),
        ),
      ])
  }
}

fn completed(output: List(Json)) -> String {
  json.object([
    #("type", json.string("response.completed")),
    #(
      "response",
      json.object([
        #("id", json.string("response-prop")),
        #("status", json.string("completed")),
        #("output", json.preprocessed_array(output)),
      ]),
    ),
  ])
  |> json.to_string
}

/// The reducer keeps each call's sparse output index, and the portable message
/// it builds replays as the same reasoning items and calls in the same order.
fn reducer_property(items: List(OutItem)) -> Nil {
  let items = assign_outputs(items)
  let json_items = list.map(items, output_json)
  let reducer = bridge.responses_reducer(cost.none)
  let assert Ok(#(_, _, Some(turn))) = reducer.feed(completed(json_items))
  let calls = list.filter_map(items, fn(item) {
    case item {
      Ocall(call) -> Ok(call)
      _ -> Error(Nil)
    }
  })
  let indices =
    items
    |> list.index_map(fn(item, index) {
      case item {
        Ocall(call) -> Ok(#(call.id, index))
        _ -> Error(Nil)
      }
    })
    |> list.filter_map(fn(value) { value })
  turn.call_indices |> should.equal(indices)
  turn.finish
  |> should.equal(
    case calls {
      [] -> types.Complete
      _ -> types.ToolCalls
    },
  )
  let assert [portable] = turn.output
  types.replay_protocol(portable) |> should.equal(types.ChatCompletions)
  let assert Ok(replayed) = bridge.responses_inputs([types.Replay(portable)])
  let reasoning =
    list.filter_map(items, fn(item) {
      case item {
        Oreason(recorded) -> Ok(recorded)
        _ -> Error(Nil)
      }
    })
  let text =
    items
    |> list.filter_map(fn(item) {
      case item {
        Otext(text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> string.concat
  let expected =
    list.append(
      list.map(reasoning, fn(recorded) { Ereason(reasoning_json(recorded)) }),
      list.append(
        case text {
          "" -> []
          _ -> [Etext(text)]
        },
        list.map(calls, Ecall),
      ),
    )
  list.length(replayed) |> should.equal(list.length(expected))
  list.zip(replayed, expected)
  |> list.each(fn(pair) { check_item(pair.0, pair.1) })
  case calls, reasoning {
    [], [] -> Nil
    _, _ -> proptest.bump("reducer turns")
  }
}

pub fn main() {
  proptest.check("portable history replay", 100, blocks(), portable_history_property)
  proptest.check(
    "reducer round trip",
    100,
    qcheck.generic_list(out_item(), qcheck.bounded_int(0, 5)),
    reducer_property,
  )
}
