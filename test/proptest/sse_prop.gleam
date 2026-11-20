//// The incremental SSE and NDJSON parser: any chunking of a byte stream must
//// give the outcome of feeding it whole, and well-formed streams must match a
//// small whole-stream reference parser written from the SSE standard.

import albedo_sse
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck

pub type Outcome {
  Parsed(events: List(albedo_sse.Event), last_id: String, retry: Option(Int))
  Failed(albedo_sse.Error)
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn text() -> qcheck.Generator(String) {
  qcheck.generic_list(
    pick(["a", "b", " ", ":", "é", "😀", "\u{0301}", "\u{0000}", "x", "1", "{}", "\""]),
    qcheck.bounded_int(0, 4),
  )
  |> qcheck.map(string.concat)
}

/// One line of a stream, without its terminator; mostly well-formed.
fn line(valid: Bool) -> qcheck.Generator(BitArray) {
  let lines = [
    #(5, text() |> qcheck.map(fn(t) { "data:" <> t })),
    #(3, text() |> qcheck.map(fn(t) { "data: " <> t })),
    #(1, pick(["data", "data:", "event", "id", "retry", ""])),
    #(2, pick(["event:delta", "event: done", "event:é", "event:a\u{0000}"])),
    #(2, text() |> qcheck.map(fn(t) { "id:" <> t })),
    #(1, pick(["retry:100", "retry: 2500", "retry:12a", "retry:", "retry:٣"])),
    #(1, text() |> qcheck.map(fn(t) { ":" <> t })),
    #(4, qcheck.return("")),
    #(1, text() |> qcheck.map(fn(t) { "other:" <> t })),
  ]
  let strings = case lines {
    [first, ..rest] -> qcheck.from_weighted_generators(first, rest)
    [] -> panic
  }
  let as_bits = strings |> qcheck.map(bit_array.from_string)
  case valid {
    True -> as_bits
    False ->
      qcheck.from_weighted_generators(#(8, as_bits), [
        #(1, pick([<<"data:", 0xFF>>, <<"data:", 0xC3>>, <<0xE2, 0x82>>, <<"id:", 0xED, 0xA0, 0x80>>])),
      ])
  }
}

fn terminator() -> qcheck.Generator(BitArray) {
  pick([<<"\n">>, <<"\n">>, <<"\r\n">>, <<"\r">>])
}

fn stream(valid: Bool) -> qcheck.Generator(BitArray) {
  use bom, lines, ending <- qcheck.map3(
    qcheck.from_weighted_generators(#(6, qcheck.return(<<>>)), [
      #(2, qcheck.return(<<0xEF, 0xBB, 0xBF>>)),
      #(1, qcheck.return(<<0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF>>)),
    ]),
    qcheck.generic_list(qcheck.tuple2(line(valid), terminator()), qcheck.bounded_int(0, 12)),
    qcheck.option_from(line(valid)),
  )
  let body = list.flat_map(lines, fn(entry) { [entry.0, entry.1] })
  bit_array.concat([bom, ..list.append(body, [option.unwrap(ending, <<>>)])])
}

/// Splits `bytes` at sorted cut points, keeping empty chunks.
fn chunks(bytes: BitArray, cuts: List(Int)) -> List(BitArray) {
  let size = bit_array.byte_size(bytes)
  let cuts =
    list.map(cuts, fn(cut) { int.clamp(cut, 0, size) })
    |> list.sort(int.compare)
  let #(pieces, last) =
    list.fold(cuts, #([], 0), fn(state, cut) {
      let #(pieces, from) = state
      let assert Ok(piece) = bit_array.slice(bytes, from, cut - from)
      #([piece, ..pieces], cut)
    })
  let assert Ok(tail) = bit_array.slice(bytes, last, size - last)
  list.reverse([tail, ..pieces])
}

fn run(parser: albedo_sse.Parser, pieces: List(BitArray)) -> Outcome {
  let fed =
    list.try_fold(pieces, #(parser, []), fn(state, piece) {
      let #(parser, events) = state
      use #(parser, found) <- result.map(albedo_sse.feed(parser, piece))
      #(parser, list.append(events, found))
    })
  case fed {
    Error(error) -> Failed(error)
    Ok(#(parser, events)) ->
      case albedo_sse.finish(parser) {
        Error(error) -> Failed(error)
        Ok(last) ->
          Parsed(
            list.append(events, last),
            albedo_sse.last_event_id(parser),
            albedo_sse.retry(parser),
          )
      }
  }
}

// Reference parser over the whole stream.

/// Lines split at CRLF, LF or CR; a final unterminated line is kept.
fn split_lines(bytes: BitArray, current: BitArray, lines: List(BitArray)) -> List(BitArray) {
  case bytes {
    <<>> ->
      case current {
        <<>> -> list.reverse(lines)
        _ -> list.reverse([current, ..lines])
      }
    <<"\r\n", rest:bytes>> | <<"\n", rest:bytes>> | <<"\r", rest:bytes>> ->
      split_lines(rest, <<>>, [current, ..lines])
    <<byte, rest:bytes>> -> split_lines(rest, <<current:bits, byte>>, lines)
    _ -> panic as "unaligned"
  }
}

type Reading {
  Reading(events: List(albedo_sse.Event), name: String, data: List(String), id: String, last_id: String, retry: Option(Int))
}

fn digits(value: String) -> Bool {
  value != "" && string.to_graphemes(value) |> list.all(fn(c) { string.contains("0123456789", c) && c != "" })
}

fn colon(bytes: BitArray, at: Int) -> Result(Int, Nil) {
  case bytes {
    <<":", _:bytes>> -> Ok(at)
    <<_, rest:bytes>> -> colon(rest, at + 1)
    _ -> Error(Nil)
  }
}

fn reference_dispatch(r: Reading) -> Reading {
  let events = case r.data {
    [] -> r.events
    data -> [albedo_sse.Event(r.name, string.join(list.reverse(data), "\n")), ..r.events]
  }
  Reading(..r, events: events, name: "", data: [], last_id: r.id)
}

fn strip_space(value: String) -> String {
  case value {
    " " <> rest -> rest
    _ -> value
  }
}

/// The standard's field handling for valid UTF-8 within the size limit,
/// with this parser's documented choices: an unterminated final event is
/// dispatched, and an event name holding NUL is malformed.
pub fn reference(bytes: BitArray, ndjson: Bool) -> Outcome {
  let bytes = case bytes {
    <<0xEF, 0xBB, 0xBF, rest:bytes>> -> rest
    _ -> bytes
  }
  let initial = Reading([], "", [], "", "", None)
  let lines = split_lines(bytes, <<>>, [])
  // The parser completes an unterminated last line, or one ended by a CR
  // that may begin a CRLF, only in `finish`, which reports events but no
  // later id or retry: those come from the lines completed before it.
  let pending = case bit_array.byte_size(bytes) {
    0 -> 0
    size ->
      case bit_array.slice(bytes, size - 1, 1) {
        Ok(<<"\n">>) -> 0
        Ok(<<"\r">>) -> 1
        _ -> 1
      }
  }
  let read_lines = fn(lines) {
    list.try_fold(lines, initial, fn(r, raw) {
      let assert Ok(line) = bit_array.to_string(raw)
      // The field name ends at the first colon byte; a grapheme-aware split
      // would miss a colon followed by a combining mark.
      let #(name, value) = case colon(raw, 0) {
        Ok(at) -> {
          let assert Ok(name) = bit_array.slice(raw, 0, at)
          let assert Ok(value) = bit_array.slice(raw, at + 1, bit_array.byte_size(raw) - at - 1)
          let assert Ok(name) = bit_array.to_string(name)
          let assert Ok(value) = bit_array.to_string(value)
          #(name, strip_space(value))
        }
        Error(Nil) -> #(line, "")
      }
      case ndjson, line {
        True, "" -> Ok(r)
        True, _ -> Ok(Reading(..r, events: [albedo_sse.Event("", line), ..r.events]))
        False, "" -> Ok(reference_dispatch(r))
        False, ":" <> _ -> Ok(r)
        False, _ -> {
          case name {
            "data" -> Ok(Reading(..r, data: [value, ..r.data]))
            "event" ->
              case string.contains(value, "\u{0000}") {
                True -> Error(albedo_sse.Malformed("invalid SSE field: event"))
                False -> Ok(Reading(..r, name: value))
              }
            "id" ->
              case string.contains(value, "\u{0000}") {
                True -> Ok(r)
                False -> Ok(Reading(..r, id: value))
              }
            "retry" ->
              case digits(value), int.parse(value) {
                True, Ok(ms) -> Ok(Reading(..r, retry: Some(ms)))
                _, _ -> Ok(r)
              }
            _ -> Ok(r)
          }
        }
      }
    })
  }
  let completed = list.take(lines, list.length(lines) - pending)
  case read_lines(lines), read_lines(completed) {
    Error(error), _ | _, Error(error) -> Failed(error)
    // `finish` dispatches the last event but hands back only events, so the
    // observable id is the one dispatched before the end of the stream.
    Ok(r), Ok(before) -> {
      let flushed = reference_dispatch(r)
      Parsed(list.reverse(flushed.events), before.last_id, before.retry)
    }
  }
}

fn new(ndjson: Bool, limit: Int) -> albedo_sse.Parser {
  case ndjson {
    True -> albedo_sse.new_ndjson(limit)
    False -> albedo_sse.new(limit)
  }
}

fn label(outcome: Outcome) -> String {
  case outcome {
    Parsed(events, _, _) -> "events_" <> int.to_string(int.min(list.length(events), 3))
    Failed(albedo_sse.EventTooLarge) -> "too_large"
    Failed(albedo_sse.InvalidUtf8) -> "invalid_utf8"
    Failed(albedo_sse.Malformed(_)) -> "malformed"
  }
}

pub fn main() -> Nil {
  let chunked =
    qcheck.tuple4(
      stream(False),
      qcheck.generic_list(qcheck.bounded_int(0, 200), qcheck.bounded_int(0, 12)),
      qcheck.bool(),
      pick([1, 3, 8, 16, 40, 100_000]),
    )
  proptest.check("any chunking gives the whole-stream outcome", 300, chunked, fn(input) {
    let #(bytes, cuts, ndjson, limit) = input
    let whole = run(new(ndjson, limit), [bytes])
    proptest.bump(label(whole))
    let split = run(new(ndjson, limit), chunks(bytes, cuts))
    case split == whole {
      True -> Nil
      False ->
        panic as {
          "chunking changed the outcome: "
          <> string.inspect(#(bytes, chunks(bytes, cuts), ndjson, limit, whole, split))
        }
    }
  })

  // Every byte boundary at once: one byte per chunk.
  proptest.check("byte-at-a-time gives the whole-stream outcome", 100, qcheck.tuple2(stream(False), qcheck.bool()), fn(input) {
    let #(bytes, ndjson) = input
    let size = bit_array.byte_size(bytes)
    let singles = chunks(bytes, list.index_map(list.repeat(Nil, size + 1), fn(_, i) { i }))
    assert run(new(ndjson, 100_000), singles) == run(new(ndjson, 100_000), [bytes])
  })

  proptest.check("well-formed streams match the reference parser", 300, qcheck.tuple2(stream(True), qcheck.bool()), fn(input) {
    let #(bytes, ndjson) = input
    let found = run(new(ndjson, 100_000), [bytes])
    let expected = reference(bytes, ndjson)
    proptest.bump(label(expected))
    case found == expected {
      True -> Nil
      False ->
        panic as {
          "parser differs from the reference: "
          <> string.inspect(#(bytes, found, expected))
        }
    }
  })
}
