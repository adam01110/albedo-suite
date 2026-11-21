//// The Gemini stream against the parts it was fed: in a tool-call turn every
//// streamed argument delta names a published call, and the replay message
//// keeps the model's own parts in arrival order with each thought signature.

import albedo_gemini/stream
import albedo_model as types
import albedo_model_stream.{type Reducer}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck

pub type Piece {
  Words(text: String, thought: Bool, signature: Option(String))
  Call(
    name: String,
    args: List(#(String, String)),
    id: String,
    signature: Option(String),
  )
}

type Case {
  Case(chunks: List(List(Piece)), finish: Option(String))
}

type Detail {
  DetailText(text: String, thought: Bool, signature: Option(String))
  DetailCall(id: String, name: String, signature: Option(String))
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn words() -> qcheck.Generator(String) {
  qcheck.from_weighted_generators(#(6, qcheck.non_empty_string()), [
    #(1, qcheck.return("")),
    #(1, pick([" ", "a", "thought", "{\"text\":1}"])),
  ])
}

fn signature() -> qcheck.Generator(Option(String)) {
  qcheck.option_from(pick(["sig-a", "sig-b", "", "sig with space"]))
}

fn piece() -> qcheck.Generator(Piece) {
  use kind <- qcheck.bind(
    qcheck.from_weighted_generators(#(6, qcheck.bounded_int(0, 1)), [
      #(4, qcheck.return(2)),
    ]),
  )
  case kind < 2 {
    // A thought or an answer.
    True -> {
      use text <- qcheck.bind(words())
      use signature <- qcheck.bind(signature())
      qcheck.return(Words(text, kind == 1, signature))
    }
    // A call, with a provider id or a fresh one.
    False -> {
      use name <- qcheck.bind(pick(["bash", "read", "write"]))
      use fields <- qcheck.bind(qcheck.generic_list(
        qcheck.map2(
          pick(["command", "path", "text"]),
          qcheck.string(),
          fn(key, value) { #(key, value) },
        ),
        qcheck.bounded_int(0, 2),
      ))
      use id <- qcheck.bind(pick(["call-1", "call-2", ""]))
      use signature <- qcheck.bind(signature())
      qcheck.return(Call(name, fields, id, signature))
    }
  }
}

fn chunk() -> qcheck.Generator(List(Piece)) {
  qcheck.generic_list(piece(), qcheck.bounded_int(0, 2))
}

fn scenario() -> qcheck.Generator(Case) {
  use chunks <- qcheck.bind(qcheck.generic_list(
    chunk(),
    qcheck.bounded_int(1, 4),
  ))
  use finish <- qcheck.bind(
    qcheck.from_weighted_generators(#(5, qcheck.return(Some("STOP"))), [
      #(2, qcheck.return(Some("MAX_TOKENS"))),
      #(2, qcheck.return(Some("SAFETY"))),
      #(1, qcheck.return(None)),
    ]),
  )
  qcheck.return(Case(chunks, finish))
}

fn piece_json(piece: Piece) -> json.Json {
  case piece {
    Words(text, thought, signature) ->
      json.object([
        #("text", json.string(text)),
        ..list.append(
          case thought {
            True -> [#("thought", json.bool(True))]
            False -> []
          },
          case signature {
            Some(signature) -> [#("thoughtSignature", json.string(signature))]
            None -> []
          },
        )
      ])
    Call(name, args, id, signature) ->
      json.object([
        #(
          "functionCall",
          json.object([
            #("name", json.string(name)),
            #(
              "args",
              json.object(
                list.map(args, fn(field) { #(field.0, json.string(field.1)) }),
              ),
            ),
            ..case id {
              "" -> []
              _ -> [#("id", json.string(id))]
            }
          ]),
        ),
        ..case signature {
          Some(signature) -> [#("thoughtSignature", json.string(signature))]
          None -> []
        }
      ])
  }
}

fn chunk_json(parts: List(Piece), finish: Option(String)) -> String {
  json.to_string(
    json.object([
      #(
        "candidates",
        json.array(
          [
            json.object([
              #(
                "content",
                json.object([#("parts", json.array(parts, piece_json))]),
              ),
              ..case finish {
                Some(reason) -> [#("finishReason", json.string(reason))]
                None -> []
              }
            ]),
          ],
          fn(candidate) { candidate },
        ),
      ),
    ]),
  )
}

/// The chunks with a finish reason on the last one.
fn payloads(c: Case) -> List(String) {
  let last = list.length(c.chunks) - 1
  list.index_map(c.chunks, fn(parts, index) {
    chunk_json(parts, case index == last {
      True -> c.finish
      False -> None
    })
  })
}

/// Feeds every chunk and answers the events in order, then settles the turn.
fn drive(
  reducer: Reducer,
  chunks: List(String),
  events: List(types.Event),
) -> Result(#(List(types.Event), types.Turn), types.Error) {
  case chunks {
    [] ->
      case reducer.finish() {
        Ok(turn) -> Ok(#(list.reverse(events), turn))
        Error(error) -> Error(error)
      }
    [chunk, ..rest] -> {
      use #(reducer, new, _) <- result.try(reducer.feed(chunk))
      drive(reducer, rest, list.append(list.reverse(new), events))
    }
  }
}

fn pieces(c: Case) -> List(Piece) {
  list.flatten(c.chunks)
}

fn deltas(events: List(types.Event)) -> List(#(Int, String, String)) {
  list.filter_map(events, fn(event) {
    case event {
      types.ArgumentsDelta(index, name, text) -> Ok(#(index, name, text))
      _ -> Error(Nil)
    }
  })
}

fn same_json(left: String, right: String) -> Bool {
  json.parse(left, decode.dynamic) == json.parse(right, decode.dynamic)
}

fn present(object: Dict(String, Dynamic), field: String) -> Option(Dynamic) {
  case dict.get(object, field) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn present_string(
  object: Dict(String, Dynamic),
  field: String,
) -> Option(String) {
  case present(object, field) {
    Some(value) ->
      case decode.run(value, decode.optional(decode.string)) {
        Ok(found) -> found
        Error(_) -> None
      }
    None -> None
  }
}

fn object_of(value: Dynamic) -> Dict(String, Dynamic) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.unwrap(dict.new())
}

fn detail_decoder() -> decode.Decoder(Detail) {
  use part <- decode.then(decode.dict(decode.string, decode.dynamic))
  let signature = present_string(part, "thoughtSignature")
  case present(part, "functionCall") {
    Some(call) -> {
      let call = object_of(call)
      decode.success(DetailCall(
        present_string(call, "id") |> option.unwrap(""),
        present_string(call, "name") |> option.unwrap(""),
        signature,
      ))
    }
    None ->
      decode.success(DetailText(
        present_string(part, "text") |> option.unwrap(""),
        case present(part, "thought") {
          Some(value) ->
            decode.run(value, decode.optional(decode.bool))
            |> result.unwrap(None)
            |> option.unwrap(False)
          None -> False
        },
        signature,
      ))
  }
}

/// The message's `reasoning_details` parts, in order.
fn replayed_parts(message: Dynamic) -> List(Detail) {
  case present(object_of(message), "reasoning_details") {
    Some(details) ->
      case decode.run(details, decode.list(decode.dynamic)) {
        Ok([first, ..]) ->
          case present(object_of(first), "parts") {
            Some(parts) ->
              decode.run(parts, decode.list(detail_decoder()))
              |> result.unwrap([])
            None -> []
          }
        _ -> []
      }
    None -> []
  }
}

fn replayed_string(message: Dynamic, field: String) -> String {
  present_string(object_of(message), field) |> option.unwrap("")
}

fn collapse(kinds: List(String)) -> List(String) {
  kinds
  |> list.fold([], fn(kept, kind) {
    case kept {
      [last, ..] if last == kind -> kept
      _ -> [kind, ..kept]
    }
  })
  |> list.reverse
}

fn assert_deltas(c: Case) -> Nil {
  let assert Ok(#(events, turn)) = drive(stream.reducer(), payloads(c), [])
  let deltas = deltas(events)
  proptest.bump("deltas_" <> int.to_string(list.length(deltas)))
  proptest.bump(case turn.finish {
    types.ToolCalls -> "tool_calls"
    types.LengthLimit -> "length_limit"
    types.ContentFiltered -> "content_filtered"
    types.Complete -> "complete"
    types.OtherFinish(_) -> "other_finish"
  })
  case turn.finish {
    types.ToolCalls -> {
      // Every published call has exactly one binding, and its index names
      // the same call with the same arguments.
      list.each(turn.tool_calls, fn(call) {
        let found =
          list.filter(turn.call_indices, fn(binding) { binding.0 == call.id })
        assert list.length(found) == 1
        let assert [#(_, index)] = found
        let named = list.filter(deltas, fn(delta) { delta.0 == index })
        assert list.length(named) == 1
        let assert [#(_, name, text)] = named
        assert name == call.name
        assert same_json(text, call.arguments)
        Nil
      })
      // Each call id appears once, and every delta index is published once.
      assert list.length(turn.call_indices) == list.length(turn.tool_calls)
      assert list.length(
          list.unique(list.map(turn.call_indices, fn(binding) { binding.0 })),
        )
        == list.length(turn.call_indices)
      assert list.length(deltas) == list.length(turn.tool_calls)
      list.each(deltas, fn(delta) {
        let bindings =
          list.filter(turn.call_indices, fn(binding) { binding.1 == delta.0 })
        assert list.length(bindings) == 1
        Nil
      })
    }
    _ -> {
      assert turn.tool_calls == []
      assert turn.call_indices == []
      Nil
    }
  }
}

fn expect_unexpected_end(
  result: Result(#(List(types.Event), types.Turn), types.Error),
) -> Nil {
  case result {
    Error(types.UnexpectedEnd) -> Nil
    Error(error) ->
      panic as {
        "a stream with no finish reason failed as " <> string.inspect(error)
      }
    Ok(#(_, turn)) ->
      panic as {
        "a stream with no finish reason settled as "
        <> string.inspect(turn.finish)
      }
  }
}

fn assert_replay(c: Case) -> Nil {
  let assert Ok(#(_, turn)) = drive(stream.reducer(), payloads(c), [])
  let assert [item] = turn.output
  let message = types.replay_value(item)
  let content = replayed_string(message, "content")
  let thinking = replayed_string(message, "reasoning_content")
  let details = replayed_parts(message)
  let all = pieces(c)
  proptest.bump("parts_" <> int.to_string(list.length(all)))
  // The flat fields are the stream's two kinds, each in order.
  let answers =
    all
    |> list.filter_map(fn(piece) {
      case piece {
        Words(text, False, _) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> string.concat
  let thoughts =
    all
    |> list.filter_map(fn(piece) {
      case piece {
        Words(text, True, _) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> string.concat
  case content == answers {
    True -> Nil
    False ->
      panic as {
        "flat text is not the answers in order: expected "
        <> string.inspect(answers)
        <> ", found "
        <> string.inspect(content)
      }
  }
  case thinking == thoughts {
    True -> Nil
    False ->
      panic as {
        "flat thinking is not the thoughts in order: expected "
        <> string.inspect(thoughts)
        <> ", found "
        <> string.inspect(thinking)
      }
  }
  // The details are the same parts, in arrival order: the sequence of kinds
  // agrees, and a run of one kind may be one part or many.
  let expected_kinds =
    collapse(
      list.filter_map(all, fn(piece) {
        case piece {
          Words("", _, None) -> Error(Nil)
          Words(_, thought, _) ->
            Ok(case thought {
              True -> "k"
              False -> "t"
            })
          Call(..) -> Ok("c")
        }
      }),
    )
  let kinds =
    collapse(
      list.map(details, fn(detail) {
        case detail {
          DetailText(_, True, _) -> "k"
          DetailText(_, False, _) -> "t"
          DetailCall(..) -> "c"
        }
      }),
    )
  case kinds == expected_kinds {
    True -> Nil
    False ->
      panic as {
        "details reordered the stream: expected "
        <> string.inspect(expected_kinds)
        <> ", found "
        <> string.inspect(kinds)
      }
  }
  // Every thought signature the model sent is replayed once, in order.
  let expected_signatures =
    list.filter_map(all, fn(piece) {
      case piece {
        Words(_, _, Some(signature)) -> Ok(signature)
        Call(_, _, _, Some(signature)) -> Ok(signature)
        _ -> Error(Nil)
      }
    })
  let signatures =
    list.filter_map(details, fn(detail) {
      case detail {
        DetailText(_, _, Some(signature)) -> Ok(signature)
        DetailCall(_, _, Some(signature)) -> Ok(signature)
        _ -> Error(Nil)
      }
    })
  case signatures == expected_signatures {
    True -> Nil
    False ->
      panic as {
        "replayed thought signatures differ: expected "
        <> string.inspect(expected_signatures)
        <> ", found "
        <> string.inspect(signatures)
      }
  }
  // The published calls are the stream's calls, in order, named as fed.
  let expected_calls =
    list.filter_map(all, fn(piece) {
      case piece {
        Call(name, ..) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  let published = list.map(turn.tool_calls, fn(call) { call.name })
  case published == expected_calls {
    True -> Nil
    False ->
      panic as {
        "published calls are not the stream's calls in order: expected "
        <> string.inspect(expected_calls)
        <> ", found "
        <> string.inspect(published)
      }
  }
  let replayed =
    list.filter_map(details, fn(detail) {
      case detail {
        DetailCall(_, name, _) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  case replayed == expected_calls {
    True -> Nil
    False ->
      panic as {
        "replayed calls are not the stream's calls in order: expected "
        <> string.inspect(expected_calls)
        <> ", found "
        <> string.inspect(replayed)
      }
  }
}

pub fn main() -> Nil {
  proptest.check(
    "stream deltas agree with the published calls",
    100,
    scenario(),
    fn(c) {
      case c.finish {
        None -> expect_unexpected_end(drive(stream.reducer(), payloads(c), []))
        Some(_) -> assert_deltas(c)
      }
    },
  )

  proptest.check(
    "the replay keeps the stream's parts in order",
    100,
    qcheck.map(scenario(), fn(c) { Case(..c, finish: Some("STOP")) }),
    assert_replay,
  )

  proptest.check(
    "a stream with no finish reason ends unexpectedly",
    40,
    scenario(),
    fn(c) {
      let chunks = list.map(c.chunks, fn(parts) { chunk_json(parts, None) })
      expect_unexpected_end(drive(stream.reducer(), chunks, []))
    },
  )
}
