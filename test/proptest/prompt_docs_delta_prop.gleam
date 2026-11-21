//// prompt_docs (albedo-suite's optional API reference projection): the
//// availability rule, the compacted instruction list, the retrieval route and
//// the lossless read it promises, checked against a model built from the
//// module's stated contract rather than from its summary table.
////
//// Contract, from `prompt_docs`: a contribution whose startup instructions
//// shrink to a summary stays retrievable through `api_docs.read`, executable
//// contributions keep their text verbatim, the projection only happens when
//// the python extension can serve the route and nothing else claims it, and
//// duplicate prose is said once.

import albedo/composition/prompt_docs
import albedo_sdk/extension
import albedo_sdk/host
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import proptest
import qcheck

pub type Item {
  Item(
    name: String,
    text: String,
    modules: List(String),
    route: Option(String),
  )
}

// Extension names with a startup summary, the only ones that can compact.
const documented = [
  "agents", "remote", "browser", "mail", "schedule", "paperclips",
]

const names = [
  "python", "python", "agents", "custom", "notes", "remote", "browser", "mail",
  "schedule", "paperclips", "docs",
]

// Repeats make deduplication observable; blanks must drop out. Every value
// stays on one line, so a rendered line is one contribution.
const texts = [
  "", " ", "\t", "core rules", "custom instructions", "dup text",
  "different text",
]

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn carrier(value: qcheck.Generator(a)) -> qcheck.Generator(Option(#(Int, a))) {
  qcheck.option_from(qcheck.tuple2(qcheck.bounded_int(0, 7), value))
}

/// Items in contribution order. At most one carries modules and at most one a
/// route, so items never collide with each other and the projection's own
/// collision rule is the only one in play.
pub fn items() -> qcheck.Generator(List(Item)) {
  use pairs, module_at, route_at <- qcheck.map3(
    qcheck.list_from(qcheck.tuple2(pick(names), pick(texts))),
    carrier(pick(["api_docs", "albedo_plugins.api_docs", "other"])),
    carrier(pick(["api_docs", "custom-route"])),
  )
  let size = int.max(1, list.length(pairs))
  list.index_map(pairs, fn(entry, index) {
    let #(name, text) = entry
    let modules = case module_at {
      Some(#(at, module)) if at % size == index -> [module]
      _ -> []
    }
    let route = case route_at {
      Some(#(at, name)) if at % size == index -> Some(name)
      _ -> None
    }
    Item(name, text, modules, route)
  })
}

fn unavailable_route(
  _context: host.Context,
  _method: String,
  _args: decode.Dynamic,
) -> Result(json.Json, #(String, String)) {
  Error(#("unavailable", "test route"))
}

/// The contributions as the composition prepares them.
fn prepared(items: List(Item)) -> List(extension.Prepared) {
  list.map(items, fn(item) {
    extension.Prepared(
      item.name,
      extension.Managed(
        ..extension.empty(),
        instructions: item.text,
        python_modules: item.modules,
        routes: case item.route {
          None -> []
          Some(name) -> [#(name, unavailable_route)]
        },
      ),
    )
  })
}

// Model.

fn summarized(item: Item) -> Bool {
  list.contains(documented, item.name) && nonblank(item.text)
}

fn nonblank(text: String) -> Bool {
  string.trim(text) != ""
}

fn model_available(items: List(Item)) -> Bool {
  list.contains(list.map(items, fn(item) { item.name }), "python")
  && list.any(items, summarized)
  && !list.any(items, fn(item) {
    list.any(item.modules, fn(module) {
      module == "api_docs" || module == "albedo_plugins.api_docs"
    })
  })
  // The projection adds a route named api_docs, so an item's own route of that
  // name collides with it.
  && !list.any(items, fn(item) { item.route == Some("api_docs") })
}

pub type Line {
  /// A contribution's own prose, which must appear verbatim.
  TextLine(String)
  /// A compacted contribution's summary, which names where to read it.
  SummaryLine(String)
}

/// What one contribution reads as: its own text, or a summary keyed by name.
fn model_line(item: Item, compact: Bool) -> Line {
  case compact && summarized(item) {
    True -> SummaryLine(item.name)
    False -> TextLine(item.text)
  }
}

fn expected_lines(items: List(Item), compact: Bool) -> List(Line) {
  items
  |> list.map(fn(item) { model_line(item, compact) })
  |> list.filter(fn(line) {
    case line {
      TextLine(text) -> nonblank(text)
      SummaryLine(_) -> True
    }
  })
  |> list.unique
}

/// A summary line names its extension and points at `api_docs.read`.
fn matches(line: Line, actual: String) -> Bool {
  case line {
    TextLine(text) -> actual == text
    SummaryLine(name) ->
      string.starts_with(actual, name <> ": ")
      && string.contains(actual, "api_docs.read(\"" <> name <> "\")")
  }
}

fn content_lines(text: String) -> List(String) {
  case text {
    "" -> []
    _ ->
      text
      |> string.split("\n")
      |> list.filter(fn(line) {
        !string.starts_with(line, "Optional API references")
      })
  }
}

fn model_topics(items: List(Item)) -> List(String) {
  items
  |> list.filter(fn(item) { nonblank(item.text) })
  |> list.map(fn(item) { item.name })
  |> list.unique
}

fn model_read(items: List(Item), topic: String) -> String {
  items
  |> list.filter(fn(item) { item.name == topic && nonblank(item.text) })
  |> list.map(fn(item) { item.text })
  |> string.join("\n")
}

@external(erlang, "gleam_stdlib", "identity")
fn unused_context(value: Nil) -> host.Context

fn native(value: json.Json) -> decode.Dynamic {
  let assert Ok(decoded) = json.parse(json.to_string(value), decode.dynamic)
  decoded
}

fn topic_args(topic: String) -> decode.Dynamic {
  native(json.object([#("topic", json.string(topic))]))
}

fn no_args() -> decode.Dynamic {
  native(json.string("not an object"))
}

// Properties.

fn availability(items: List(Item)) -> Nil {
  proptest.bump(case model_available(items) {
    True -> "projection"
    False -> "plain"
  })
  let actual = prompt_docs.available(prepared(items))
  assert actual == model_available(items)
}

fn plain_list(items: List(Item)) -> Nil {
  let text = prompt_docs.instructions(prepared(items))
  case prompt_docs.available(prepared(items)) {
    True -> proptest.bump("skipped_projection")
    False -> {
      let expected =
        items
        |> list.map(fn(item) { item.text })
        |> list.filter(nonblank)
        |> list.unique
        |> string.join("\n")
      assert text == expected
    }
  }
}

fn compacted_list(items: List(Item)) -> Nil {
  let compact = prompt_docs.available(prepared(items))
  let text = prompt_docs.instructions(prepared(items))
  let expected = expected_lines(items, compact)
  let content = content_lines(text)
  proptest.bump(case compact {
    True -> "projected"
    False -> "verbatim"
  })
  // One line per distinct contribution, in contribution order.
  assert list.length(content) == list.length(expected)
  list.each(list.zip(expected, content), fn(pair) {
    let #(line, actual) = pair
    assert matches(line, actual)
  })
  // A compacted contribution's full prose is gone; the route serves it.
  list.each(items, fn(item) {
    case compact && summarized(item) {
      True -> {
        proptest.bump("compacted")
        // Its prose is gone unless another contribution says the same text
        // verbatim and keeps it.
        let shown = list.any(items, fn(other) {
          other.text == item.text
            && nonblank(other.text)
            && !{
              compact && summarized(other)
            }
        })
        assert list.contains(content, item.text) == shown
      }
      False -> Nil
    }
  })
}

fn route_items(items: List(Item)) -> Nil {
  let #(_, call) = prompt_docs.route(prepared(items))
  let context = unused_context(Nil)
  let topics = model_topics(items)
  let assert Ok(catalog) = call(context, "api_docs.catalog", no_args())
  assert json.to_string(catalog) == json.to_string(json.array(topics, json.string))
  proptest.bump(case topics {
    [] -> "empty_catalog"
    _ -> "catalog"
  })
  list.each(topics, fn(topic) {
    let assert Ok(read) = call(context, "api_docs.read", topic_args(topic))
    assert json.to_string(read)
      == json.to_string(json.string(model_read(items, topic)))
    // Retrieval is lossless whatever the projection did to the startup text.
    list.each(items, fn(item) {
      case item.name == topic && nonblank(item.text) {
        True -> {
          assert string.contains(model_read(items, topic), item.text)
        }
        False -> Nil
      }
    })
  })
  list.each(["disabled", "agents-extra", ""], fn(topic) {
    case list.contains(topics, topic) {
      True -> Nil
      False -> {
        proptest.bump("unavailable_topic")
        let assert Error(#("unavailable", _)) =
          call(context, "api_docs.read", topic_args(topic))
        Nil
      }
    }
  })
  let assert Error(#("invalid", _)) = call(context, "api_docs.read", no_args())
  let assert Error(#("invalid", _)) =
    call(context, "api_docs.catalog.extra", no_args())
  Nil
}

pub fn main() -> Nil {
  proptest.check("api_docs projection availability", 100, items(), availability)
  proptest.check("unprojected instructions keep their order and dedupe", 100, items(), plain_list)
  proptest.check("projected instructions compact, order and dedupe", 100, items(), compacted_list)
  proptest.check("api_docs route catalog and reads", 100, items(), route_items)
}
