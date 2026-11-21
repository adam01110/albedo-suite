//// The FFF worker's lifecycle: `albedo_fff` answers each request once with
//// that request's own answer, whatever the worker did for the requests before
//// it. Each case runs a generated sequence of requests through the production
//// entry point against a scripted stand-in worker, and checks every reply
//// against a model built from the request alone. The stand-in can answer, fail,
//// lie about the protocol, write junk or die, but never stalls here, so a case
//// stays quick; the deterministic lifecycle suite that also covers stalls,
//// expiry and worker reuse is `albedo_fff_lifecycle_test:run/0`, called first.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/string
import proptest
import qcheck

@external(erlang, "albedo_fff_lifecycle_test", "scenario")
fn scenario(probes: List(String)) -> List(Result(String, String))

@external(erlang, "albedo_fff_lifecycle_test", "run")
fn lifecycle() -> Nil

@external(erlang, "albedo_fff_lifecycle_test", "stop")
fn stop() -> Nil

const keys = ["a", "b", "v", "e", "mode", "probe", "protocol", "_fff_target"]

/// What a stand-in worker does with the request it reads.
type Mode {
  Answer(Json)
  Fail(String)
  Foreign
  Junk(String)
  Die
  Echo
}

fn mode_name(mode: Mode) -> String {
  case mode {
    Answer(_) -> "value"
    Fail(_) -> "error"
    Foreign -> "proto"
    Junk(_) -> "raw"
    Die -> "die"
    Echo -> "echo"
  }
}

/// The request the kernel would send for this mode.
fn probe(mode: Mode) -> List(#(String, Json)) {
  case mode {
    Answer(v) -> [#("mode", json.string("value")), #("v", v)]
    Fail(message) -> [#("mode", json.string("error")), #("e", json.string(message))]
    Foreign -> [#("mode", json.string("proto"))]
    Junk(raw) -> [#("mode", json.string("raw")), #("raw", json.string(raw))]
    Die -> [#("mode", json.string("die"))]
    Echo -> [#("mode", json.string("echo"))]
  }
}

/// What the search must answer for this mode, from the request alone.
fn expected(mode: Mode) -> Result(Json, String) {
  case mode {
    Answer(v) -> Ok(v)
    Fail(message) -> Error(message)
    Foreign -> Error("FFF protocol mismatch")
    Junk(_) -> Error("FFF worker returned invalid JSON")
    Die -> Error("FFF worker died")
    Echo ->
      // The worker answers with the request it read: the probe and the
      // protocol the proxy stamped on it.
      Ok(
        json.object([
          #("probe", json.object(probe(Echo))),
          #("protocol", json.int(1)),
        ]),
      )
  }
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn text() -> qcheck.Generator(String) {
  qcheck.map(
    qcheck.generic_list(
      pick(["a", "0", "-", "/", " ", "é", "日", "\n", "\t", "\\", "x"]),
      qcheck.bounded_int(0, 5),
    ),
    string.concat,
  )
}

/// A JSON value of any shape, as a reply value or a request field holds one.
fn value(depth: Int) -> qcheck.Generator(Json) {
  let scalar =
    qcheck.from_generators(qcheck.map(text(), json.string), [
      qcheck.return(json.null()),
      qcheck.return(json.bool(True)),
      qcheck.return(json.bool(False)),
      qcheck.map(pick([0, 1, -1, 1_000_000_000]), json.int),
      qcheck.map(pick([1.5, -0.25]), json.float),
    ])
  case depth <= 0 {
    True -> scalar
    False ->
      qcheck.from_generators(scalar, [
        qcheck.map(
          qcheck.generic_list(value(depth - 1), qcheck.bounded_int(0, 3)),
          json.preprocessed_array,
        ),
        qcheck.map(
          qcheck.generic_list(
            qcheck.map2(pick(keys), value(depth - 1), fn(k, v) { #(k, v) }),
            qcheck.bounded_int(0, 3),
          ),
          json.object,
        ),
      ])
  }
}

fn mode() -> qcheck.Generator(Mode) {
  qcheck.from_generators(
    qcheck.map(value(2), Answer),
    [
      qcheck.map(text(), Fail),
      qcheck.return(Foreign),
      // Text that is no JSON, whatever it says.
      qcheck.generic_list(pick(["x", "{", "}", "\"", "1", " "]), qcheck.bounded_int(0, 6))
        |> qcheck.map(string.concat)
        |> qcheck.map(fn(raw) { Junk("not json " <> raw) }),
      qcheck.return(Die),
      qcheck.return(Echo),
    ],
  )
}

/// A history of requests to one worker, honouring how the corpus concentrates:
/// short sequences keep a death or a failure beside the requests that follow
/// it, which is where a stale or shifted answer would show.
fn history() -> qcheck.Generator(List(Mode)) {
  qcheck.generic_list(mode(), qcheck.bounded_int(1, 6))
}

fn decoded(encoded: String) -> Result(Dynamic, Nil) {
  case json.parse(encoded, decode.dynamic) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

/// One step's reply against the answer the request alone calls for.
fn check_step(index: Int, mode: Mode, reply: Result(String, String)) -> Nil {
  let shape = mode_name(mode)
  proptest.bump(shape)
  case reply, expected(mode) {
    Error(message), Error(want) ->
      case message == want {
        True -> Nil
        False ->
          panic as {
            "step "
            <> int.to_string(index)
            <> " ("
            <> shape
            <> ") refused with "
            <> string.inspect(message)
            <> " want "
            <> string.inspect(want)
          }
      }
    Ok(encoded), Ok(want) ->
      case decoded(encoded), decoded(json.to_string(want)) {
        Ok(found), Ok(expect) ->
          case found == expect {
            True -> Nil
            False ->
              panic as {
                "step "
                <> int.to_string(index)
                <> " ("
                <> shape
                <> ") answered "
                <> encoded
                <> " want "
                <> json.to_string(want)
              }
          }
        _, _ ->
          panic as {
            "step "
            <> int.to_string(index)
            <> " ("
            <> shape
            <> ") answered no JSON: "
            <> encoded
          }
      }
    got, want ->
      panic as {
        "step "
        <> int.to_string(index)
        <> " ("
        <> shape
        <> ") gave "
        <> string.inspect(got)
        <> " want "
        <> string.inspect(want)
      }
  }
}

pub fn main() -> Nil {
  lifecycle()
  proptest.check("every request is answered by its own request", 20, history(), fn(modes) {
    let probes =
      list.index_map(modes, fn(mode, index) {
        proptest.bump(case index {
          0 -> "first"
          _ -> "after"
        })
        json.object(probe(mode)) |> json.to_string
      })
    let _ =
      list.index_map(list.zip(modes, scenario(probes)), fn(step, index) {
        check_step(index, step.0, step.1)
      })
    Nil
  })
  // A worker that died is replaced, so the request after any history answers.
  proptest.check(
    "a worker answers after any history",
    10,
    history(),
    fn(modes) {
      proptest.bump("recovery")
      let probes = list.map(modes, fn(mode) { json.object(probe(mode)) |> json.to_string })
      scenario(probes)
      let fresh = [json.object(probe(Answer(json.int(7)))) |> json.to_string]
      case scenario(fresh) {
        [Ok(encoded)] ->
          case json.parse(encoded, decode.int) {
            Ok(7) -> Nil
            _ -> panic as { "the request after a history answered " <> encoded }
          }
        other ->
          panic as {
            "the request after a history gave " <> string.inspect(other)
          }
      }
    },
  )
  stop()
  io.println("FFF worker lifecycle: every generated request kept its own answer")
}
