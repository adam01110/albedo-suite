//// The files extension's FFF hop: `albedo_fff` owns the worker that answers
//// `files.fff`, strips the kernel's `_fff_target` routing hint, stamps the
//// protocol and returns the worker's value or its error, bounded on both
//// sides. Each property runs a stand-in worker (an escript this module
//// writes) that answers from a `probe` object inside the request, so the
//// expected answer comes from the request the property built rather than from
//// the proxy's own encoding.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import proptest
import qcheck

/// The largest request `albedo_fff.search` sends and the largest reply it
/// accepts, as the module's own refusals name them.
const request_bound = 1_048_576

const response_bound = 8_388_608

const request_refusal = "FFF request exceeds 1 MiB bound"

const response_refusal = "FFF response exceeds 8 MiB bound"

/// The stand-in worker. It reads one request per line and answers according
/// to `probe.mode`: `echo` returns the request it read, `size` the size of
/// that request, `value` returns `probe.v`, `error` answers `probe.e`, `proto`
/// a foreign protocol number, `raw` writes `probe.raw` verbatim, `pad` writes
/// a reply of exactly `probe.len` bytes and `die` exits without answering.
const worker =
  "#!/usr/bin/env escript\nmain(_) -> loop().\nloop() ->\n    case io:get_line(\"\") of\n        eof -> ok;\n        Line -> respond(Line), loop()\n    end.\nrespond(Line) ->\n    Request = json:decode(unicode:characters_to_binary(Line)),\n    Probe = case maps:get(<<\"probe\">>, Request, #{}) of\n        Meta when is_map(Meta) -> Meta;\n        _ -> #{}\n    end,\n    Mode = maps:get(<<\"mode\">>, Probe, <<\"echo\">>),\n    case Mode of\n        <<\"echo\">> -> send(#{<<\"protocol\">> => 1, <<\"ok\">> => true, <<\"value\">> => Request});\n        <<\"size\">> -> send(#{<<\"protocol\">> => 1, <<\"ok\">> => true, <<\"value\">> => erlang:byte_size(unicode:characters_to_binary(Line)) - 1});\n        <<\"value\">> -> send(#{<<\"protocol\">> => 1, <<\"ok\">> => true, <<\"value\">> => maps:get(<<\"v\">>, Probe, null)});\n        <<\"error\">> -> send(#{<<\"protocol\">> => 1, <<\"ok\">> => false, <<\"error\">> => maps:get(<<\"e\">>, Probe, <<\"boom\">>)});\n        <<\"proto\">> -> send(#{<<\"protocol\">> => 2, <<\"ok\">> => true, <<\"value\">> => null});\n        <<\"raw\">> -> send_raw(maps:get(<<\"raw\">>, Probe, <<\"nope\">>));\n        <<\"pad\">> -> send_raw(pad(maps:get(<<\"len\">>, Probe, 1)));\n        <<\"die\">> -> halt(1)\n    end.\nsend(Term) -> send_raw(json:encode(Term)).\nsend_raw(Bin) -> try io:put_chars([Bin, \"\\n\"]) catch _:_ -> halt(0) end.\npad(Len) ->\n    Prefix = <<\"{\\\"protocol\\\":1,\\\"ok\\\":true,\\\"value\\\":\\\"\">>,\n    Suffix = <<\"\\\"}\">>,\n    Fill = max(0, Len - byte_size(Prefix) - byte_size(Suffix)),\n    <<Prefix/binary, (binary:copy(<<\"x\">>, Fill))/binary, Suffix/binary>>.\n"

@external(erlang, "albedo_fff", "search")
fn search(
  key: String,
  argv: List(String),
  auth: Option(String),
  args: Dynamic,
) -> Result(String, String)

@external(erlang, "proptest_ffi", "escript")
fn escript() -> Result(String, Nil)

const keys = ["a", "b", "op", "query", "pad", "probe", "protocol", "_fff_target"]

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn text() -> qcheck.Generator(String) {
  qcheck.map(
    qcheck.generic_list(
      pick(["a", "0", "-", "/", " ", "é", "日", "\n", "\t", "\\", "x"]),
      qcheck.bounded_int(0, 6),
    ),
    string.concat,
  )
}

/// A JSON value of any shape, as a worker reply or a request field holds one.
fn value(depth: Int) -> qcheck.Generator(Json) {
  let scalar =
    qcheck.from_generators(qcheck.map(text(), json.string), [
      qcheck.return(json.null()),
      qcheck.return(json.bool(True)),
      qcheck.return(json.bool(False)),
      qcheck.return(json.float(1.5)),
      qcheck.map(pick([0, 1, -1, 1_000_000_000]), json.int),
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

/// A request the kernel would send: an object of arbitrary fields.
fn request() -> qcheck.Generator(Dict(String, Json)) {
  qcheck.map(
    qcheck.generic_list(
      qcheck.map2(pick(keys), value(2), fn(k, v) { #(k, v) }),
      qcheck.bounded_int(0, 4),
    ),
    dict.from_list,
  )
}

fn to_dynamic(encoded: Json) -> Dynamic {
  case json.parse(json.to_string(encoded), decode.dynamic) {
    Ok(value) -> value
    Error(_) -> panic as "a JSON value this module built did not parse"
  }
}

fn decoded(encoded: String) -> Result(Dynamic, String) {
  json.parse(encoded, decode.dynamic) |> result.replace_error("invalid JSON")
}

fn call(argv: List(String), body: Json) -> Result(String, String) {
  search("local", argv, None, to_dynamic(body))
}

fn probe(fields: List(#(String, Json))) -> Json {
  json.object([#("probe", json.object(fields))])
}

fn mode(name: String, fields: List(#(String, Json))) -> Json {
  probe([#("mode", json.string(name)), ..fields])
}

fn matches(got: Result(String, String), expected: Json, body: Json) -> Nil {
  case got {
    Error(message) ->
      panic as {
        "refused with "
        <> string.inspect(message)
        <> " want "
        <> json.to_string(expected)
        <> " for "
        <> json.to_string(body)
      }
    Ok(encoded) ->
      case decoded(encoded), decoded(json.to_string(expected)) {
        Ok(found), Ok(want) ->
          case found == want {
            True -> Nil
            False ->
              panic as {
                "answered "
                <> encoded
                <> " want "
                <> json.to_string(expected)
                <> " for "
                <> json.to_string(body)
              }
          }
        _, _ -> panic as { "the worker's reply was not JSON: " <> encoded }
      }
  }
}

/// The largest `n` in `low..high` that `accepts`, for a monotone predicate.
fn largest(low: Int, high: Int, accepts: fn(Int) -> Bool) -> Int {
  largest_from(low, high, low - 1, accepts)
}

fn largest_from(
  low: Int,
  high: Int,
  best: Int,
  accepts: fn(Int) -> Bool,
) -> Int {
  case low > high {
    True -> best
    False -> {
      let middle = { low + high } / 2
      case accepts(middle) {
        True -> largest_from(middle + 1, high, middle, accepts)
        False -> largest_from(low, middle - 1, best, accepts)
      }
    }
  }
}

/// A reply of exactly `len` bytes, from the stand-in worker's `pad` mode.
fn padded(argv: List(String), len: Int) -> Result(String, String) {
  call(argv, mode("pad", [#("len", json.int(len))]))
}

/// The size of the request the worker reads, from its `size` mode.
fn sized(argv: List(String), pad: Int) -> Result(Int, String) {
  let body =
    json.object([
      #("probe", json.object([#("mode", json.string("size"))])),
      #("pad", json.string(string.repeat("x", pad))),
    ])
  case call(argv, body) {
    Error(message) -> Error(message)
    // The proxy hands back the worker's value alone, not its envelope.
    Ok(encoded) ->
      json.parse(encoded, decode.int)
      |> result.replace_error("no size in " <> encoded)
  }
}

pub fn main() -> Nil {
  let worker_path =
    "/tmp/fff-proptest-worker-"
    <> int.to_string(proptest.unique())
    <> ".escript"
  proptest.write_file(worker_path, <<worker:utf8>>, 0)
  let assert Ok(escript_path) = escript()
  let argv = [escript_path, worker_path]

  // A reply value reaches the caller unchanged, whatever JSON it is.
  proptest.check(
    "a worker value passes through unchanged",
    100,
    value(3),
    fn(v) {
      proptest.bump("value")
      let body = mode("value", [#("v", v)])
      matches(call(argv, body), v, body)
    },
  )

  // The payload the worker reads is the caller's, without the routing hint
  // and with the protocol stamped on it.
  proptest.check(
    "the worker reads the caller's payload",
    100,
    request(),
    fn(fields) {
      proptest.bump("payload")
      let body = json.object(dict.to_list(fields))
      let expected =
        fields
        |> dict.delete("_fff_target")
        |> dict.insert("protocol", json.int(1))
        |> dict.to_list
        |> json.object
      matches(call(argv, body), expected, body)
    },
  )

  // An error the worker reports is the search's error, verbatim.
  proptest.check(
    "a worker error is the search's error",
    100,
    text(),
    fn(message) {
      proptest.bump("error")
      let body = mode("error", [#("e", json.string(message))])
      case call(argv, body) == Error(message) {
        True -> Nil
        False ->
          panic as {
            "got "
            <> string.inspect(call(argv, body))
            <> " want "
            <> string.inspect(Error(message))
          }
      }
    },
  )

  // Anything that is not an object is refused before a worker is asked.
  proptest.check(
    "a request that is not an object is refused",
    50,
    value(2),
    fn(v) {
      proptest.bump("not_object")
      let text = json.to_string(v)
      case string.starts_with(text, "{") {
        True -> Nil
        False ->
          case search("local", argv, None, to_dynamic(v)) {
            Ok(encoded) -> panic as { "answered " <> encoded <> " for " <> text }
            Error(message) ->
              case message == "invalid FFF arguments" {
                True -> Nil
                False ->
                  panic as {
                    "refused with "
                    <> string.inspect(message)
                    <> " for "
                    <> text
                  }
              }
          }
      }
    },
  )

  // A reply that is not JSON is refused with the documented text.
  proptest.check("a reply that is not JSON is refused", 50, text(), fn(junk) {
    proptest.bump("not_json")
    let raw = "not json " <> junk
    let body = mode("raw", [#("raw", json.string(raw))])
    case call(argv, body) {
      Ok(encoded) ->
        panic as { "answered " <> encoded <> " for " <> string.inspect(raw) }
      Error(message) ->
        case message == "FFF worker returned invalid JSON" {
          True -> Nil
          False ->
            panic as {
              "refused with "
              <> string.inspect(message)
              <> " for "
              <> string.inspect(raw)
            }
        }
    }
  })

  // A foreign protocol number is a mismatch, whatever else the reply holds.
  proptest.check("a foreign protocol is a mismatch", 20, value(1), fn(_) {
    proptest.bump("protocol")
    let body = mode("proto", [])
    case call(argv, body) {
      Ok(encoded) -> panic as { "answered " <> encoded }
      Error(message) ->
        case message == "FFF protocol mismatch" {
          True -> Nil
          False -> panic as { "refused with " <> string.inspect(message) }
        }
    }
  })

  // A worker that dies answers rather than hanging.
  proptest.check("a dying worker is reported", 10, value(1), fn(_) {
    proptest.bump("died")
    let body = mode("die", [])
    case call(argv, body) {
      Ok(encoded) -> panic as { "answered " <> encoded }
      Error(message) ->
        case message == "FFF worker died" {
          True -> Nil
          False -> panic as { "refused with " <> string.inspect(message) }
        }
    }
  })

  // One worker answers search after search, in any order of replies.
  proptest.check(
    "a worker keeps answering across searches",
    50,
    qcheck.generic_list(
      pick(["echo", "error", "value", "proto", "raw"]),
      qcheck.bounded_int(1, 5),
    ),
    fn(modes) {
      proptest.bump("history")
      list.each(modes, fn(name) {
        let body = case name {
          "error" -> mode("error", [#("e", json.string(name))])
          "value" -> mode("value", [#("v", json.int(7))])
          "proto" -> mode("proto", [])
          "raw" -> mode("raw", [#("raw", json.string("}"))])
          _ -> mode("echo", [])
        }
        let got = call(argv, body)
        case name {
          "error" ->
            case got == Error("error") {
              True -> Nil
              False -> panic as { "got " <> string.inspect(got) }
            }
          "value" ->
            case got == Ok("7") {
              True -> Nil
              False -> panic as { "got " <> string.inspect(got) }
            }
          "proto" ->
            case got == Error("FFF protocol mismatch") {
              True -> Nil
              False -> panic as { "got " <> string.inspect(got) }
            }
          "raw" ->
            case got == Error("FFF worker returned invalid JSON") {
              True -> Nil
              False -> panic as { "got " <> string.inspect(got) }
            }
          _ ->
            case got {
              Error(message) -> panic as { "refused with " <> message }
              Ok(encoded) -> {
                let expected =
                  body
                  |> json.to_string
                  |> string.drop_end(1)
                  |> fn(prefix) { prefix <> ",\"protocol\":1}" }
                case decoded(encoded), decoded(expected) {
                  Ok(found), Ok(want) ->
                    case found == want {
                      True -> Nil
                      False ->
                        panic as {
                          "echo gave " <> encoded <> " want " <> expected
                        }
                    }
                  _, _ -> panic as { "the echo was not JSON: " <> encoded }
                }
              }
            }
        }
      })
    },
  )

  // The reply bound holds exactly at 8 MiB.
  let accepted_reply =
    largest(1, response_bound + 1000, fn(len) {
      case padded(argv, len) {
        Ok(_) -> True
        Error(_) -> False
      }
    })
  io.println(
    "reply bound: "
    <> int.to_string(accepted_reply)
    <> " bytes accepted, "
    <> int.to_string(accepted_reply + 1)
    <> " bytes refused",
  )
  case accepted_reply == response_bound {
    True -> Nil
    False ->
      panic as {
        "accepted a reply of "
        <> int.to_string(accepted_reply)
        <> " bytes, and the module names "
        <> int.to_string(response_bound)
      }
  }
  case padded(argv, response_bound + 1) {
    Ok(encoded) ->
      panic as {
        "answered a reply of "
        <> int.to_string(string.length(encoded))
        <> " bytes past the bound"
      }
    Error(message) ->
      case message == response_refusal {
        True -> Nil
        False ->
          panic as {
            "refused with "
            <> string.inspect(message)
            <> " want "
            <> response_refusal
          }
      }
  }

  // The request bound holds exactly at 1 MiB.
  let accepted_request =
    largest(1, request_bound + 1000, fn(pad) {
      case sized(argv, pad) {
        Ok(size) -> size <= request_bound
        Error(_) -> False
      }
    })
  let assert Ok(reported) = sized(argv, accepted_request)
  io.println(
    "request bound: pad of "
    <> int.to_string(accepted_request)
    <> " sent "
    <> int.to_string(reported)
    <> " bytes",
  )
  case reported == request_bound {
    True -> Nil
    False ->
      panic as {
        "the largest request the worker read was "
        <> int.to_string(reported)
        <> " bytes, and the module names "
        <> int.to_string(request_bound)
      }
  }
  case sized(argv, accepted_request + 1) {
    Ok(size) ->
      panic as {
        "accepted a request of "
        <> int.to_string(size)
        <> " bytes past the bound"
      }
    Error(message) ->
      case message == request_refusal {
        True -> Nil
        False ->
          panic as {
            "refused with "
            <> string.inspect(message)
            <> " want "
            <> request_refusal
          }
      }
  }

  proptest.remove_tree(worker_path)
}
