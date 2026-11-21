
//// The Responses request encoder: every generated input item and content part
//// must carry a JSON `type` discriminator that a strict endpoint accepts, and
//// Chat Completions tool-result images must follow their results in call and
//// attachment order. This parses the encoded body independently of the
//// production helpers, with its own dynamic-JSON walk.

import albedo_model as types
import albedo_openai/request as encoder
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/string_tree
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
    qcheck.bounded_int(0, 2),
  )
  |> qcheck.map(string.concat)
}

const payloads = ["aGVsbG8=", "d29ybGQ=", "eHl6enk="]

fn image_data() -> qcheck.Generator(#(String, String, String)) {
  qcheck.map2(pick(payloads), pick([
    "image/png", "image/jpeg", "image/webp",
  ]), fn(data, mime) { #(mime, data, "data:" <> mime <> ";base64," <> data) })
}

fn images() -> qcheck.Generator(List(#(types.Image, String))) {
  qcheck.generic_list(image_data(), qcheck.bounded_int(0, 2))
  |> qcheck.map(list.map(_, fn(entry) {
    let assert Ok(image) = types.image(entry.0, entry.1, 2, 3, 5)
    #(image, entry.2)
  }))
}

// ---------- independent JSON walk ----------

fn object(value: Dynamic) -> Result(Dict(String, Dynamic), Nil) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.replace_error(Nil)
}

fn array(value: Dynamic) -> Result(List(Dynamic), Nil) {
  decode.run(value, decode.list(decode.dynamic)) |> result.replace_error(Nil)
}

fn string_field(value: Dynamic, key: String) -> Result(String, Nil) {
  case object(value) {
    Ok(fields) -> dict.get(fields, key) |> result.try(decoding_string)
    Error(_) -> Error(Nil)
  }
}

fn decoding_string(value: Dynamic) -> Result(String, Nil) {
  decode.run(value, decode.string) |> result.replace_error(Nil)
}

fn field(value: Dynamic, key: String) -> Result(Dynamic, Nil) {
  use fields <- result.try(object(value))
  dict.get(fields, key)
}

fn body(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

fn encode(protocol: types.Protocol, inputs: List(types.Input)) -> String {
  let request = types.Request("model", None, inputs, [], None, types.defaults)
  let assert Ok(tree) = encoder.encode(protocol, request)
  string_tree.to_string(tree)
}

// ---------- the typed-items property ----------

type Item {
  Iuser(String)
  Iassistant(String)
  Iimage(String, List(#(types.Image, String)))
  Itool(String, String, List(#(types.Image, String)))
}

fn item() -> qcheck.Generator(Item) {
  qcheck.from_weighted_generators(
    #(4, words() |> qcheck.map(Iuser)),
    [
      #(2, words() |> qcheck.map(Iassistant)),
      #(2, qcheck.map2(words(), images(), Iimage)),
      #(2, qcheck.map3(words(), words(), images(), fn(id, text, images) {
        Itool("call-" <> id, text, images)
      })),
    ],
  )
}

fn assign_items(items: List(Item)) -> List(Item) {
  let #(_, assigned) =
    list.fold(items, #(0, []), fn(acc, item) {
      let #(n, kept) = acc
      case item {
        Itool(_, text, images) -> #(n + 1, [Itool("call-" <> int.to_string(n), text, images), ..kept])
        _ -> #(n, [item, ..kept])
      }
    })
  list.reverse(assigned)
}

fn to_input(item: Item) -> types.Input {
  case item {
    Iuser(text) -> types.User(text)
    Iassistant(text) -> types.Assistant(text)
    Iimage(text, images) -> types.UserImage(text, list.map(images, fn(entry) { entry.0 }))
    Itool(id, text, images) ->
      types.ToolOutput(id, text, list.map(images, fn(entry) { entry.0 }))
  }
}

const item_types = ["message", "function_call", "function_call_output", "reasoning"]

const part_types = ["input_text", "output_text", "input_image"]

fn check_part(part: Dynamic) {
  let assert Ok(kind) = string_field(part, "type")
  list.contains(part_types, kind) |> should.be_true
  case kind {
    "input_image" ->
      string_field(part, "image_url")
      |> should.be_ok
    _ -> string_field(part, "text") |> should.be_ok
  }
}

fn check_item_json(item: Dynamic, input: types.Input) {
  let assert Ok(kind) = string_field(item, "type")
  list.contains(item_types, kind) |> should.be_true
  case input, kind {
    types.User(_), "message" -> {
      string_field(item, "role") |> should.equal(Ok("user"))
      let assert Ok(parts) = field(item, "content") |> result.try(array)
      list.all(parts, fn(part) {
        string_field(part, "type") == Ok("input_text")
      })
      |> should.be_true
      list.each(parts, check_part)
    }
    types.Assistant(_), "message" -> {
      string_field(item, "role") |> should.equal(Ok("assistant"))
      let assert Ok(parts) = field(item, "content") |> result.try(array)
      list.all(parts, fn(part) {
        string_field(part, "type") == Ok("output_text")
      })
      |> should.be_true
      list.each(parts, check_part)
    }
    types.UserImage(_, images), "message" -> {
      string_field(item, "role") |> should.equal(Ok("user"))
      let assert Ok(parts) = field(item, "content") |> result.try(array)
      list.each(parts, check_part)
      list.filter(parts, fn(part) {
        string_field(part, "type") == Ok("input_image")
      })
      |> list.length
      |> should.equal(list.length(images))
    }
    types.ToolOutput(id, text, images), "function_call_output" -> {
      string_field(item, "call_id") |> should.equal(Ok(id))
      let assert Ok(output) = field(item, "output")
      case output |> array {
        Ok(parts) -> {
          list.each(parts, check_part)
          list.filter(parts, fn(part) {
            string_field(part, "type") == Ok("input_image")
          })
          |> list.length
          |> should.equal(list.length(images))
          case text {
            "" -> Nil
            _ ->
              list.filter(parts, fn(part) {
                string_field(part, "type") == Ok("input_text")
              })
              |> list.length
              |> should.equal(1)
          }
        }
        Error(_) -> {
          images |> should.equal([])
          decoding_string(output) |> should.equal(Ok(text))
        }
      }
    }
    _, _ -> should.equal(False, True)
  }
}

fn typed_items_property(items: List(Item)) -> Nil {
  let items = assign_items(items)
  let inputs = list.map(items, to_input)
  let encoded = encode(types.Responses, inputs)
  let parsed = body(encoded)
  let assert Ok(json_items) = field(parsed, "input") |> result.try(array)
  list.length(json_items) |> should.equal(list.length(items))
  list.zip(json_items, items)
  |> list.each(fn(pair) { check_item_json(pair.0, to_input(pair.1)) })
  case items {
    [] -> Nil
    _ -> proptest.bump("typed items")
  }
}

// ---------- Chat Completions tool-result images ----------

fn tool_run_property(run: List(Item)) -> Nil {
  let run = assign_items(run)
  let inputs = list.map(run, to_input)
  let encoded = encode(types.ChatCompletions, inputs)
  let parsed = body(encoded)
  let assert Ok(messages) = field(parsed, "messages") |> result.try(array)
  let expected_parts =
    run
    |> list.filter_map(fn(item) {
      case item {
        Itool(id, _, images) if images != [] ->
          Ok(
            list.append(
              [
                json.object([
                  #("type", json.string("text")),
                  #(
                    "text",
                    json.string("Images from tool call " <> id <> ":"),
                  ),
                ]),
              ],
              list.map(images, fn(entry) {
                json.object([
                  #("type", json.string("image_url")),
                  #(
                    "image_url",
                    json.object([#("url", json.string(entry.1))]),
                  ),
                ])
              }),
            ),
          )
        _ -> Error(Nil)
      }
    })
    |> list.flatten
  let expected_parts =
    list.map(expected_parts, fn(part) {
      let assert Ok(value) = json.parse(json.to_string(part), decode.dynamic)
      value
    })
  let result_count = list.length(run)
  let expected_messages = case expected_parts {
    [] -> result_count
    _ -> result_count + 1
  }
  list.length(messages) |> should.equal(expected_messages)
  list.each(list.take(messages, result_count), fn(message) {
    string_field(message, "role") |> should.equal(Ok("tool"))
  })
  case expected_parts {
    [] -> Nil
    _ -> {
      let assert Ok(image_message) = list.last(messages)
      string_field(image_message, "role") |> should.equal(Ok("user"))
      let assert Ok(parts) = field(image_message, "content") |> result.try(array)
      list.length(parts) |> should.equal(list.length(expected_parts))
      list.zip(parts, expected_parts)
      |> list.each(fn(pair) { pair.0 |> should.equal(pair.1) })
      proptest.bump("image runs")
    }
  }
}

pub fn main() {
  proptest.check(
    "typed Responses items",
    100,
    qcheck.generic_list(item(), qcheck.bounded_int(0, 5)),
    typed_items_property,
  )
  proptest.check(
    "Chat Completions tool-result images",
    100,
    qcheck.generic_list(
      qcheck.map2(words(), images(), fn(id, images) { Itool(id, "out", images) }),
      qcheck.bounded_int(0, 4),
    ),
    tool_run_property,
  )
}
