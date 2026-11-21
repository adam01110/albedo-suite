
//// Responses error envelopes. A generated envelope carrying a message must
//// report that message, a code-only envelope its code, and an unrecognised
//// shape a typed malformed diagnostic instead of the raw payload. Every
//// envelope carries a unique marker so a leak is visible.

import albedo_model as types
import albedo_model/cost
import albedo_openai/responses
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import proptest
import qcheck

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn token() -> qcheck.Generator(String) {
  qcheck.generic_list(
    pick(["a", "b", "x", "Y", "é", "0"]),
    qcheck.bounded_int(1, 5),
  )
  |> qcheck.map(string.concat)
}

pub type Expectation {
  /// The detail the error must carry.
  Detail(String)
  /// The typed malformed diagnostic, and the marker it must not leak.
  Malformed(context: String, marker: String)
}

type Shape {
  NestedMessage
  TopMessage
  TopMessageNestedCode
  StringError
  NestedCode
  TopCode
  FailedNestedMessage
  FailedNestedCode
  FailedStringError
  FailedResponseMessage
  MalformedObject
  MalformedNonString
}

fn shape() -> qcheck.Generator(Shape) {
  let assert [first, ..rest] = [
    NestedMessage, TopMessage, TopMessageNestedCode, StringError, NestedCode,
    TopCode, FailedNestedMessage, FailedNestedCode, FailedStringError,
    FailedResponseMessage, MalformedObject, MalformedNonString,
  ]
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn event(shape: Shape, marker: String) -> #(json.Json, Expectation) {
  let message = "msg-" <> marker
  let code = "code-" <> marker
  let object = json.object
  case shape {
    NestedMessage ->
      #(
        object([
          #("type", json.string("error")),
          #(
            "error",
            object([
              #("message", json.string(message)),
              #("code", json.string(code)),
            ]),
          ),
        ]),
        Detail(message),
      )
    TopMessage ->
      #(
        object([
          #("type", json.string("error")),
          #("message", json.string(message)),
          #("code", json.string(code)),
        ]),
        Detail(message),
      )
    TopMessageNestedCode ->
      #(
        object([
          #("type", json.string("error")),
          #("message", json.string(message)),
          #("error", object([#("code", json.string(code))])),
        ]),
        Detail(message),
      )
    StringError ->
      #(
        object([
          #("type", json.string("error")),
          #("error", json.string(message)),
        ]),
        Detail(message),
      )
    NestedCode ->
      #(
        object([
          #("type", json.string("error")),
          #("error", object([#("code", json.string(code))])),
        ]),
        Detail(code),
      )
    TopCode ->
      #(
        object([
          #("type", json.string("error")),
          #("code", json.string(code)),
        ]),
        Detail(code),
      )
    FailedNestedMessage ->
      #(
        object([
          #("type", json.string("response.failed")),
          #(
            "response",
            object([
              #("error", object([#("message", json.string(message))])),
            ]),
          ),
        ]),
        Detail(message),
      )
    FailedNestedCode ->
      #(
        object([
          #("type", json.string("response.failed")),
          #(
            "response",
            object([
              #("error", object([#("code", json.string(code))])),
            ]),
          ),
        ]),
        Detail(code),
      )
    FailedStringError ->
      #(
        object([
          #("type", json.string("response.failed")),
          #(
            "response",
            object([#("error", json.string(message))]),
          ),
        ]),
        Detail(message),
      )
    FailedResponseMessage ->
      #(
        object([
          #("type", json.string("response.failed")),
          #("response", object([#("message", json.string(message))])),
        ]),
        Detail(message),
      )
    MalformedObject ->
      #(
        object([
          #("type", json.string("error")),
          #("error", object([#("detail", json.string(marker))])),
          #("unknown", json.string(marker)),
        ]),
        Malformed("error", marker),
      )
    MalformedNonString ->
      #(
        object([
          #("type", json.string("error")),
          #("message", json.int(42)),
          #("error", object([#("code", json.null())])),
          #("unknown", json.string(marker)),
        ]),
        Malformed("error", marker),
      )
  }
}

fn envelope(sample: #(Shape, String)) -> String {
  let #(data, _) = event(sample.0, sample.1)
  json.to_string(data)
}

fn expectation(sample: #(Shape, String)) -> Expectation {
  let #(_, expected) = event(sample.0, sample.1)
  expected
}

fn detail(sample: #(Shape, String)) -> String {
  let data = envelope(sample)
  let assert Error(types.Refused(_, None, detail)) =
    responses.feed(responses.new(cost.none), data)
  detail
}

fn error_property(sample: #(Shape, String)) -> Nil {
  let data = envelope(sample)
  let detail = detail(sample)
  // The raw payload is never the detail.
  string.contains(detail, data) |> should.be_false
  case expectation(sample) {
    Detail(want) -> {
      detail |> should.equal(want)
      proptest.bump("named detail")
    }
    Malformed(context, marker) -> {
      string.starts_with(detail, "malformed " <> context <> ":")
      |> should.be_true
      string.contains(detail, marker) |> should.be_false
      proptest.bump("malformed")
    }
  }
}

pub fn main() {
  proptest.check(
    "error envelope detail",
    100,
    qcheck.map2(shape(), token(), fn(shape, token) { #(shape, token) }),
    error_property,
  )
}
