//// Property tests for the api_docs projection of extension instructions:
//// which contributions are compacted and retrievable, what the inline block
//// keeps, and how the retrieval route answers. The expected block is derived
//// from the documented contract (docs/prompt-context.md) with its own table of
//// summaries, not by calling the module under test for an expectation.

import albedo/composition/prompt_docs
import albedo_sdk/extension
import albedo_sdk/host
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import proptest
import qcheck

@external(erlang, "gleam_stdlib", "identity")
fn unused_context(value: Nil) -> host.Context

/// The summaries `prompt_docs` keeps inline instead of the whole reference,
/// copied as data from the module's own documentation table.
fn known_summary(name: String) -> String {
  case name {
    "agents" ->
      "agents: spawn, inspect and cancel child sessions. Before spawning, read api_docs.read(\"agents\") and await agents.models(); children share the workspace. Independent children start back to back; results arrive as mail, never poll/sleep."
    "remote" ->
      "remote: SSH tools via await remote.connect(host), not run(\"ssh\", ...). Before use read api_docs.read(\"remote\"); remote file/tool operations require await. Do not retry authentication or failed operations blindly."
    "browser" ->
      "browser: CDP browser automation. Before use read api_docs.read(\"browser\"); close browsers when finished."
    "mail" ->
      "mail: await mail.submit(to, body) sends inter-agent messages; incoming letters arrive automatically as <mail>. Before use read api_docs.read(\"mail\")."
    "schedule" ->
      "schedule: durable scheduled prompts and heartbeats. Before use read api_docs.read(\"schedule\")."
    "paperclips" ->
      "paperclips: vent reviewable workflow/tool problems without interrupting the user; not a substitute for urgent reporting. Before use read api_docs.read(\"paperclips\")."
    _ -> ""
  }
}

const prefix =
  "Optional API references are available in full through await api_docs.read(topic); await api_docs.catalog() lists active topics. Read the reference before first use or when uncertain. No capabilities are disabled."

type Item {
  Item(
    name: String,
    text: String,
    module: Option(String),
    route: Option(String),
  )
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn item_gen() -> qcheck.Generator(Item) {
  let names =
    qcheck.from_weighted_generators(#(4, pick(["agents", "remote", "mail"])), [
      #(1, pick(["python"])),
      #(2, pick(["browser", "schedule", "paperclips"])),
      #(3, pick(["custom", "custom-two", "python-core", "agents"])),
    ])
  let texts =
    qcheck.from_weighted_generators(
      #(5, pick(["SHARED text", "custom instructions"])),
      [
        #(1, pick(["", " ", "\n", "\t\n "])),
        #(2, pick(["core rules", "OTHER text", "SHARED text"])),
      ],
    )
  let modules =
    qcheck.from_weighted_generators(#(12, qcheck.return(None)), [
      #(1, qcheck.return(Some("api_docs"))),
      #(1, qcheck.return(Some("albedo_plugins.api_docs"))),
      #(1, qcheck.return(Some("broken"))),
      #(1, qcheck.return(Some("api_docs.extra"))),
    ])
  let routes =
    qcheck.from_weighted_generators(#(20, qcheck.return(None)), [
      #(1, qcheck.return(Some("api_docs"))),
      #(1, qcheck.return(Some("api_docs.nested"))),
      #(1, qcheck.return(Some("commands"))),
      #(1, qcheck.return(Some("other"))),
      #(1, qcheck.return(Some(""))),
    ])
  qcheck.tuple4(names, texts, modules, routes)
  |> qcheck.map(fn(parts) {
    let #(name, text, module, route) = parts
    Item(name, text, module, route)
  })
}

/// A case: one to six contributions, half of them led by the kernel
/// extension's own contribution, which is what enables compaction at all.
fn case_gen() -> qcheck.Generator(List(Item)) {
  qcheck.bind(
    qcheck.tuple2(
      qcheck.generic_list(item_gen(), qcheck.bounded_int(1, 6)),
      qcheck.bool(),
    ),
    fn(pair) {
      let #(items, python) = pair
      case python {
        False -> qcheck.return(items)
        True ->
          qcheck.return([Item("python", "core rules", None, None), ..items])
      }
    },
  )
}

fn fixture_route(namespace: String) -> host.Route {
  #(namespace, fn(_, _, _) { Ok(json.null()) })
}

fn prepared(item: Item) -> extension.Prepared {
  extension.Prepared(
    item.name,
    extension.Managed(
      ..extension.empty(),
      instructions: item.text,
      python_modules: case item.module {
        None -> []
        Some(module) -> [module]
      },
      routes: case item.route {
        None -> []
        Some(namespace) -> [fixture_route(namespace)]
      },
    ),
  )
}

fn documented(items: List(Item)) -> List(Item) {
  list.filter(items, fn(item) { string.trim(item.text) != "" })
}

fn names_of(items: List(Item)) -> List(String) {
  list.unique(list.map(documented(items), fn(item) { item.name }))
}

fn compactable(item: Item) -> Bool {
  known_summary(item.name) != "" && string.trim(item.text) != ""
}

fn route_namespaces(items: List(Item)) -> List(String) {
  list.filter_map(items, fn(item) {
    case item.route {
      None -> Error(Nil)
      Some(namespace) -> Ok(namespace)
    }
  })
}

fn overlaps(namespaces: List(String)) -> Bool {
  case namespaces {
    [] -> False
    [first, ..rest] ->
      first == ""
      || list.any(rest, fn(other) {
        first == other
        || string.starts_with(first, other <> ".")
        || string.starts_with(other, first <> ".")
      })
      || overlaps(rest)
  }
}

/// Whether compaction applies, worked out from the documented rules: the
/// kernel extension's own contribution must be present, something must have a
/// summary to keep inline, and no contribution may already occupy the
/// retrieval module, its route namespace, or another contribution's route
/// namespace (the command routes take `commands`).
fn expected_available(items: List(Item)) -> Bool {
  let namespaces =
    ["commands", "api_docs"]
    |> list.append(route_namespaces(items))
  list.any(items, fn(item) { item.name == "python" })
  && list.any(items, compactable)
  && !list.any(items, fn(item) {
    case item.module {
      Some("api_docs") | Some("albedo_plugins.api_docs") -> True
      _ -> False
    }
  })
  && !overlaps(namespaces)
}

/// The block the contract describes: compacted names keep their summary,
/// everything else keeps its instructions, empty text drops out, and text
/// already present is not repeated.
fn expected_block(items: List(Item), compact: Bool) -> String {
  let body =
    items
    |> list.map(fn(item) {
      case compact && compactable(item) {
        True -> known_summary(item.name)
        False -> item.text
      }
    })
    |> list.filter(fn(text) { string.trim(text) != "" })
    |> list.unique
    |> string.join("\n")
  case compact {
    True -> prefix <> "\n" <> body
    False -> body
  }
}

/// The complete reference the route serves for `topic`: every documented
/// contribution with that name, in order.
fn full_text(items: List(Item), topic: String) -> String {
  documented(items)
  |> list.filter(fn(item) { item.name == topic })
  |> list.map(fn(item) { item.text })
  |> string.join("\n")
}

fn topic_arg(topic: String) -> Dynamic {
  let assert Ok(value) =
    json.parse(
      json.to_string(json.object([#("topic", json.string(topic))])),
      decode.dynamic,
    )
  value
}

pub fn main() -> Nil {
  let cases = case_gen()

  proptest.check(
    "availability follows the documented collision and compaction rules",
    200,
    cases,
    fn(items) {
      let expected = expected_available(items)
      proptest.bump(case expected {
        True -> "available"
        False -> "fallback"
      })
      let found = prompt_docs.available(list.map(items, prepared))
      case found == expected {
        True -> Nil
        False ->
          panic as {
            "availability differs from the contract: "
            <> string.inspect(#(items, found, expected))
          }
      }
    },
  )

  proptest.check(
    "the inline block keeps summaries for compacted names and text for the rest",
    200,
    cases,
    fn(items) {
      let prepared_items = list.map(items, prepared)
      let compact = prompt_docs.available(prepared_items)
      let block = prompt_docs.instructions(prepared_items)
      let expected = expected_block(items, compact)
      proptest.bump(case compact {
        True -> "compacted_block"
        False -> "inline_block"
      })
      case block == expected {
        True -> Nil
        False ->
          panic as {
            "inline block differs from the contract: "
            <> string.inspect(#(items, compact, block, expected))
          }
      }
    },
  )

  proptest.check(
    "every catalog topic reads back the complete documented reference",
    200,
    cases,
    fn(items) {
      let prepared_items = list.map(items, prepared)
      let #(namespace, call) = prompt_docs.route(prepared_items)
      assert namespace == "api_docs"
      let context = unused_context(Nil)
      let found = case call(context, "api_docs.catalog", proptest.undefined()) {
        Ok(listed) ->
          json.parse(json.to_string(listed), decode.list(decode.string))
        Error(reason) ->
          panic as { "the catalog refused: " <> string.inspect(reason) }
      }
      let assert Ok(topics) = found
      proptest.bump(case prompt_docs.available(prepared_items) {
        True -> "catalog_compacted"
        False -> "catalog_plain"
      })
      case topics == names_of(items) {
        True -> Nil
        False ->
          panic as {
            "catalog lists "
            <> string.inspect(#(topics, names_of(items), items))
          }
      }
      list.each(topics, fn(topic) {
        let expected = json.to_string(json.string(full_text(items, topic)))
        case call(context, "api_docs.read", topic_arg(topic)) {
          Ok(value) ->
            case json.to_string(value) == expected {
              True -> Nil
              False ->
                panic as {
                  "topic "
                  <> topic
                  <> " read back "
                  <> string.inspect(#(json.to_string(value), expected))
                }
            }
          Error(reason) ->
            panic as {
              "topic " <> topic <> " unreadable: " <> string.inspect(reason)
            }
        }
      })
      case call(context, "api_docs.read", topic_arg("no-such-topic")) {
        Ok(_) ->
          panic as {
            "an undocumented topic read back: " <> string.inspect(items)
          }
        Error(#("unavailable", _)) -> Nil
        Error(other) ->
          panic as { "unexpected refusal: " <> string.inspect(other) }
      }
    },
  )

  proptest.check(
    "appending a duplicate contribution leaves the block unchanged",
    200,
    cases,
    fn(items) {
      let prepared_items = list.map(items, prepared)
      let before = prompt_docs.instructions(prepared_items)
      case list.last(items) {
        Error(Nil) -> proptest.bump("empty")
        Ok(extra) -> {
          // Only a contribution that brings no capability of its own: a
          // repeated route namespace is a real conflict, and the collision
          // check then turns compaction off.
          let after =
            prompt_docs.instructions(
              list.append(prepared_items, [
                prepared(Item(..extra, module: None, route: None)),
              ]),
            )
          proptest.bump("duplicated")
          case before == after {
            True -> Nil
            False ->
              panic as {
                "a repeated contribution changed the block: "
                <> string.inspect(#(items, before, after))
              }
          }
        }
      }
    },
  )
}
