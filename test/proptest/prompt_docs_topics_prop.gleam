//// api_docs topic handling: how the retrieval route names, orders and serves
//// documentation topics. The neighbouring prompt_docs suites generate
//// contributions from a small fixed name list; this one concentrates on the
//// topic string itself (near misses, case variants, path-like, quoted and
//// unicode names), on references large enough to matter (up to 200 kB) and on
//// the pointers the inline block leaves behind. The model comes from the
//// module's documented contract, not from its summary table.

import albedo/composition/prompt_docs
import albedo_sdk/extension
import albedo_sdk/host
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import proptest
import qcheck

/// The first words of the block's own prefix; distinctive enough to count.
const prefix_fragment = "Optional API references are available in full through"

pub type Item {
  Item(name: String, text: String)
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

const known = [
  "agents", "remote", "browser", "mail", "schedule", "paperclips", "python",
  "custom",
]

/// Names a topic is not: whitespace, case, path and quoting near misses.
const exotic = [
  "", " ", "  ", "agents ", " agents", "Agents", "AGENTS", "Agents ", ".agents",
  "agents.", "agents/x", "../agents", "agents\n", "agents\t", "\"agents\"",
  "'agents'", "agents\u{0}", "agents()", "api_docs.read(\"agents\")", "é", "🧠",
  "агенты", "agents-agent", "-agents-", "0", "null",
]

/// Strings that survive into JSON quoting: control characters, the quote and
/// backslash, and multi-byte scalars.
fn char_gen() -> qcheck.Generator(String) {
  qcheck.from_weighted_generators(
    #(6, pick(["a", "b", "z", "0", " ", "-", "."])),
    [
      #(2, pick(["\n", "\t", "\r", "\u{0}", "\u{1} ", "\\", "\"", "'", "/"])),
      #(2, pick(["é", "世", "🧠", "e\u{301}"])),
    ],
  )
}

fn chars(max: Int) -> qcheck.Generator(String) {
  qcheck.map(
    qcheck.generic_list(char_gen(), qcheck.bounded_int(1, max)),
    fn(parts) { string.concat(parts) },
  )
}

fn name_gen() -> qcheck.Generator(String) {
  qcheck.from_weighted_generators(#(6, pick(known)), [
    #(3, pick(exotic)),
    #(2, chars(6)),
    #(1, qcheck.map(chars(3), fn(part) { part <> string.repeat("x", 200) })),
  ])
}

fn text_gen() -> qcheck.Generator(String) {
  qcheck.from_weighted_generators(
    #(5, pick(["core rules", "shared text", "other text"])),
    [
      #(2, pick(["", " ", "\n", "\t\n "])),
      #(2, pick(["\"quoted\"\nsecond line", "back\\slash", "é世🧠", "a\u{0}b"])),
      #(1, chars(12)),
    ],
  )
}

/// Half the cases lead with the kernel contribution and a summarised
/// extension, so the compacted projection is the common case rather than a
/// rare one.
fn items() -> qcheck.Generator(List(Item)) {
  qcheck.bind(
    qcheck.generic_list(
      qcheck.map2(name_gen(), text_gen(), Item),
      qcheck.bounded_int(0, 6),
    ),
    fn(values) {
      qcheck.from_weighted_generators(#(5, qcheck.return(values)), [
        #(
          4,
          qcheck.return([
            Item("python", "core rules"),
            Item("agents", "AGENTS REFERENCE"),
            ..values
          ]),
        ),
      ])
    },
  )
}

fn prepared(items: List(Item)) -> List(extension.Prepared) {
  list.map(items, fn(item) {
    extension.Prepared(
      item.name,
      extension.Managed(..extension.empty(), instructions: item.text),
    )
  })
}

// Model of the documented contract.

fn nonblank(text: String) -> Bool {
  string.trim(text) != ""
}

fn documented(items: List(Item)) -> List(Item) {
  list.filter(items, fn(item) { nonblank(item.text) })
}

fn topics(items: List(Item)) -> List(String) {
  documented(items) |> list.map(fn(item) { item.name }) |> list.unique
}

fn full_text(items: List(Item), topic: String) -> String {
  documented(items)
  |> list.filter(fn(item) { item.name == topic })
  |> list.map(fn(item) { item.text })
  |> string.join("\n")
}

@external(erlang, "gleam_stdlib", "identity")
fn unused_context(value: Nil) -> host.Context

fn native(value: json.Json) -> Dynamic {
  let assert Ok(decoded) = json.parse(json.to_string(value), decode.dynamic)
  decoded
}

fn topic_args(topic: String) -> Dynamic {
  native(json.object([#("topic", json.string(topic))]))
}

fn no_args() -> Dynamic {
  native(json.string("not an object"))
}

fn decode_topics(value: json.Json) -> List(String) {
  let assert Ok(decoded) =
    json.parse(json.to_string(value), decode.list(decode.string))
  decoded
}

fn decode_text(value: json.Json) -> String {
  let assert Ok(decoded) = json.parse(json.to_string(value), decode.string)
  decoded
}

fn call_read(
  items: List(Item),
  topic: String,
) -> Result(json.Json, #(String, String)) {
  let #(namespace, call) = prompt_docs.route(prepared(items))
  assert namespace == "api_docs"
  call(unused_context(Nil), "api_docs.read", topic_args(topic))
}

fn occurrences(text: String, needle: String) -> Int {
  list.length(string.split(text, needle)) - 1
}

/// Each `api_docs.read("topic")` the block points at, in order.
fn references(block: String) -> List(String) {
  block
  |> string.split("api_docs.read(\"")
  |> list.drop(1)
  |> list.filter_map(fn(rest) {
    case string.split(rest, "\"") {
      [name, ..] -> Ok(name)
      [] -> Error(Nil)
    }
  })
}

/// Near misses of a topic: strings that must not reach its documentation.
fn near_misses(topic: String) -> List(String) {
  [
    " " <> topic,
    topic <> " ",
    topic <> "\n",
    "../" <> topic,
    topic <> ".",
    string.uppercase(topic),
    string.replace(topic, "-", "_"),
    topic <> "/",
    "/" <> topic,
    topic <> "x",
  ]
}

// Properties.

fn catalog_order(items: List(Item)) -> Nil {
  let #(_, call) = prompt_docs.route(prepared(items))
  let context = unused_context(Nil)
  let assert Ok(catalog) = call(context, "api_docs.catalog", no_args())
  let assert Ok(again) = call(context, "api_docs.catalog", no_args())
  let found = decode_topics(catalog)
  let expected = topics(items)
  proptest.bump(case expected {
    [] -> "empty"
    _ -> "cataloged"
  })
  case found == expected {
    True -> Nil
    False -> panic as { "catalog " <> string.inspect(#(found, expected, items)) }
  }
  // Deterministic: the same contributions answer the same way twice.
  assert json.to_string(catalog) == json.to_string(again)
}

fn exact_reads(items: List(Item)) -> Nil {
  list.each(topics(items), fn(topic) {
    let expected = full_text(items, topic)
    case call_read(items, topic) {
      Ok(value) -> {
        proptest.bump("exact_read")
        case json.to_string(value) == json.to_string(json.string(expected)) {
          True -> Nil
          False ->
            panic as {
              "topic "
              <> string.inspect(topic)
              <> " served "
              <> string.inspect(json.to_string(value))
              <> " instead of "
              <> string.inspect(expected)
            }
        }
        // The reference survives the JSON boundary byte for byte.
        assert decode_text(value) == expected
      }
      Error(reason) ->
        panic as {
          "topic "
          <> string.inspect(topic)
          <> " refused: "
          <> string.inspect(reason)
        }
    }
  })
}

fn near_miss_reads(items: List(Item)) -> Nil {
  let cataloged = topics(items)
  list.each(cataloged, fn(topic) {
    list.each(near_misses(topic), fn(miss) {
      case list.contains(cataloged, miss) {
        // A near miss that is itself a topic is served normally.
        True -> Nil
        False -> {
          proptest.bump("near_miss")
          case call_read(items, miss) {
            Ok(value) ->
              panic as {
                "near miss "
                <> string.inspect(miss)
                <> " of "
                <> string.inspect(topic)
                <> " served "
                <> string.inspect(json.to_string(value))
              }
            Error(#("unavailable", _)) -> Nil
            Error(other) ->
              panic as {
                "near miss "
                <> string.inspect(miss)
                <> ": "
                <> string.inspect(other)
              }
          }
        }
      }
    })
  })
}

fn block_pointers(items: List(Item)) -> Nil {
  let block = prompt_docs.instructions(prepared(items))
  let compact = prompt_docs.available(prepared(items))
  let cataloged = topics(items)
  proptest.bump(case compact {
    True -> "compacted"
    False -> "verbatim"
  })
  // The prefix appears once, first, and only when retrieval is offered.
  case compact {
    True -> {
      let assert [first, ..] = string.split(block, "\n")
      assert string.starts_with(first, prefix_fragment)
      assert occurrences(block, prefix_fragment) == 1
    }
    False -> {
      assert occurrences(block, prefix_fragment) == 0
    }
  }
  // Every pointer the block leaves resolves to a cataloged topic.
  list.each(references(block), fn(topic) {
    proptest.bump("pointer")
    case list.contains(cataloged, topic) {
      True -> Nil
      False ->
        panic as {
          "the block points at "
          <> string.inspect(topic)
          <> ", which the catalog does not list: "
          <> string.inspect(#(cataloged, block))
        }
    }
  })
  // A compacted contribution's composition is not inline any more: the
  // summary points at the route instead of repeating the reference.
  list.each(documented(items), fn(item) {
    case compact && list.contains(["agents", "mail", "remote"], item.name) {
      True -> {
        proptest.bump("summary_inline")
        assert string.contains(block, "api_docs.read(\"" <> item.name <> "\")")
      }
      False -> Nil
    }
  })
}

fn whole_references(size: Int) -> Nil {
  let item = Item("custom", string.repeat("a", size) <> "é")
  let items = [Item("python", "core rules"), item]
  let text = item.text
  // "custom" has no summary, so nothing compacts and the text stays verbatim.
  let block = prompt_docs.instructions(prepared(items))
  proptest.bump(
    "size="
    <> int.to_string(size)
    <> " bytes="
    <> case size < 4096 {
      True -> "small"
      False -> "large"
    },
  )
  assert string.contains(block, text)
  case call_read(items, "custom") {
    Ok(value) -> {
      let served = decode_text(value)
      case served == text {
        True -> Nil
        False ->
          panic as {
            "a "
            <> int.to_string(size)
            <> "-byte reference came back as "
            <> int.to_string(string.byte_size(served))
            <> " bytes"
          }
      }
    }
    Error(reason) ->
      panic as {
        "a "
        <> int.to_string(size)
        <> "-byte reference failed: "
        <> string.inspect(reason)
      }
  }
}

fn sized() -> qcheck.Generator(Int) {
  pick([0, 1, 2, 3, 4095, 4096, 65_535, 65_536, 65_537, 200_000])
}

/// The topic argument is a string and nothing else: absent, null, numeric,
/// list, object and whole-argument shapes are all invalid, never a read.
fn argument_shapes(items: List(Item)) -> Nil {
  let #(_, call) = prompt_docs.route(prepared(items))
  let context = unused_context(Nil)
  let shapes = [
    json.object([]),
    json.object([#("topic", json.null())]),
    json.object([#("topic", json.int(1))]),
    json.object([#("topic", json.array([], json.string))]),
    json.object([#("topic", json.object([]))]),
    json.object([#("topic", json.bool(True))]),
    json.array(["agents"], json.string),
    json.int(7),
    json.null(),
  ]
  list.each(shapes, fn(shape) {
    proptest.bump("invalid_shape")
    let assert Error(#("invalid", _)) =
      call(context, "api_docs.read", native(shape))
    Nil
  })
  // An unrelated field beside the topic changes nothing.
  let with_extra =
    native(
      json.object([#("topic", json.string("agents")), #("other", json.int(2))]),
    )
  assert string.inspect(call(context, "api_docs.read", with_extra))
    == string.inspect(call(context, "api_docs.read", topic_args("agents")))
  // The catalog ignores arguments entirely, valid or not.
  let assert Ok(_) = call(context, "api_docs.catalog", no_args())
  let assert Ok(_) = call(context, "api_docs.catalog", topic_args("agents"))
  Nil
}

pub fn main() -> Nil {
  proptest.check(
    "catalog lists topics in contribution order",
    100,
    items(),
    catalog_order,
  )
  proptest.check(
    "every cataloged topic reads back its complete reference",
    100,
    items(),
    exact_reads,
  )
  proptest.check(
    "near misses of a topic are refused",
    100,
    items(),
    near_miss_reads,
  )
  proptest.check(
    "the block's pointers resolve and its prefix appears once",
    100,
    items(),
    block_pointers,
  )
  proptest.check(
    "references are served whole at every size",
    100,
    sized(),
    whole_references,
  )
  proptest.check("only a string topic reads", 100, items(), argument_shapes)
}
