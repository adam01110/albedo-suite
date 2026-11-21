//// Property tests for the memory startup topic index.
////
//// The model is constructive: notes are built as paragraphs joined by blank
//// lines, so the paragraphs, their first lines and their order are known
//// before the index is asked for them. The index must list the newest
//// paragraphs' first lines, newest first, at most 120 characters each, at
//// most 12 per workspace, within the shared 1600-character topic budget, and
//// must never show text that no note holds. A shown topic may be cut only at
//// the very end of the topics, where the budget runs out.
////
//// Run in a server overlay tree:
////   cp test/suite_memory_index_property_test.gleam <tree>/test/
////   <tree>/shell bash -c 'cd ../../apps/albedo && gleam run -m suite_memory_index_property_test'

import albedo_ext_memory/files
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/io
import gleam/list
import gleam/string

const topic_chars = 120
const index_topics = 12
const index_budget = 1600
const notice = "[more topics omitted; search spans all linked workspaces]"
const cases = 300

pub fn main() -> Nil {
  let home = "/tmp/albedo-suite-memory-prop-" <> int.to_string(unique())
  set_env("ALBEDO_HOME", home)
  let _ = run(cases, 0, 0, 0)
  let _ = del_dir_r(home)
  Nil
}

fn run(remaining: Int, passed: Int, failed: Int, cuts: Int) -> Nil {
  case remaining {
    0 ->
      io.println(
        "Memory index properties: "
        <> int.to_string(passed)
        <> " passed, "
        <> int.to_string(failed)
        <> " failed of "
        <> int.to_string(cases)
        <> " cases; "
        <> int.to_string(cuts)
        <> " exceeded the topic budget",
      )
    _ -> {
      let own = "/w/own" <> int.to_string(remaining)
      let linked = [
        "host:/w/linked" <> int.to_string(remaining) <> "/a",
        "host:/w/linked" <> int.to_string(remaining) <> "/b",
      ]
      // One to three workspaces, in the order a session sees them.
      let count = 1 + rand(2)
      let workspaces = [own, ..list.take(linked, count - 1)]
      let parts =
        list.map(workspaces, fn(workspace) { #(workspace, paragraphs(1 + rand(24))) })
      let _ =
        list.map(parts, fn(part) {
          let assert Ok(_) = files.save(part.0, string.join(part.1, "\n\n"))
          Nil
        })
      let group =
        list.filter_map(parts, fn(part) {
          Ok(part.0)
        })
      // An empty memory has no section at all.
      let model =
        list.map(parts, fn(part) { #(part.0, expected_topics(part.1)) })
      let note_lines = lines_of(list.map(parts, fn(part) { part.1 }))
      let assert Ok(index) = files.load(group)
      let failures = checks(own, model, note_lines, index)
      let failed = failed + list.length(failures)
      let cuts = case body_chars(model) > index_budget {
        True -> cuts + 1
        False -> cuts
      }
      case failures {
        [] -> run(remaining - 1, passed + 1, failed, cuts)
        _ -> {
          io.println(
            "case "
            <> int.to_string(remaining)
            <> " failed: "
            <> string.join(failures, "; "),
          )
          io.println("  index: " <> string.replace(index, "\n", "|"))
          run(remaining - 1, passed, failed, cuts)
        }
      }
    }
  }
}

fn checks(
  own: String,
  model: List(#(String, List(String))),
  note_lines: List(String),
  index: String,
) -> List(String) {
  let sections = sections(index)
  let listed: List(#(String, Bool)) = [
    #("the headings name the group in order", headings_match(sections, model, index)),
    #("the own workspace heads the index", own_heads(sections, own)),
    #(
      "no more than twelve topics per workspace",
      list.all(sections, fn(section) { list.length(section.1) <= index_topics }),
    ),
    #(
      "every shown topic starts a line the notes hold",
      list.all(sections, fn(section) {
        list.all(section.1, fn(topic) {
          string.length(topic) <= topic_chars
          && list.any(note_lines, fn(line) { string.starts_with(line, topic) })
        })
      }),
    ),
    #(
      "shown topics are the newest first lines, in order",
      list.all(model, fn(part) { topics_match(part.1, section_for(sections, part.0)) }),
    ),
    #("the shared topic budget holds", budget_holds(sections)),
    #("the whole model is shown when it fits", fits_means_exact(sections, model)),
  ]
  listed
  |> list.filter_map(fn(pair: #(String, Bool)) {
    case pair.1 {
      True -> Error(Nil)
      False -> Ok(pair.0)
    }
  })
}

/// Shown topics are the model's topics from the start, in order. Only the last
/// shown one may be a prefix, because the budget can cut inside a line.
fn topics_match(expected: List(String), shown: List(String)) -> Bool {
  case list.length(shown) <= list.length(expected) {
    False -> False
    True ->
      list.all(indexed(shown), fn(pair: #(Int, String)) {
        let #(index, topic) = pair
        case at(expected, index) {
          Error(Nil) -> False
          Ok(wanted) ->
            case index + 1 == list.length(shown) {
              True -> wanted == topic || string.starts_with(wanted, topic)
              False -> wanted == topic
            }
        }
      })
  }
}

/// When every workspace's model body fits the shared budget, nothing is cut.
fn fits_means_exact(
  sections: List(#(String, List(String), Int)),
  model: List(#(String, List(String))),
) -> Bool {
  case body_chars(model) <= index_budget {
    False -> True
    True -> list.all(model, fn(part) { section_for(sections, part.0) == part.1 })
  }
}

fn body_chars(model: List(#(String, List(String)))) -> Int {
  list.fold(model, 0, fn(total, part) {
    total
    + list.fold(part.1, 0, fn(chars, topic) { chars + string.length(topic) + 3 })
  })
}

/// A workspace whose whole section the budget dropped is replaced by the
/// omission notice instead of a heading.
fn headings_match(
  sections: List(#(String, List(String), Int)),
  model: List(#(String, List(String))),
  index: String,
) -> Bool {
  let shown = list.map(sections, fn(section) { section.0 })
  let wanted = list.map(model, fn(part) { part.0 })
  case prefix_names(shown, wanted) {
    False -> False
    True ->
      case list.length(shown) < list.length(wanted) {
        True -> string.contains(index, "more topics omitted")
        False -> True
      }
  }
}

fn prefix_names(shown: List(String), wanted: List(String)) -> Bool {
  case shown, wanted {
    [], _ -> True
    _, [] -> False
    [first, ..rest], [wanted_first, ..wanted_rest] ->
      first == wanted_first && prefix_names(rest, wanted_rest)
  }
}

/// The characters a section's body spends on topics. The omission notice is
/// appended behind one newline, and a cut topic line ends where the notice
/// starts, so removing the notice and its newline leaves the sliced text.
fn topic_chars_shown(body: String) -> Int {
  case string.ends_with(body, notice) {
    True -> string.length(body) - string.length(notice) - 1
    False -> string.length(body)
  }
}

/// The shared topic budget covers the sliced topic text, which is what the
/// index spends before it stops.
fn budget_holds(sections: List(#(String, List(String), Int))) -> Bool {
  list.fold(sections, 0, fn(total, section) { total + section.2 }) <= index_budget
}

fn own_heads(sections: List(#(String, List(String), Int)), own: String) -> Bool {
  case sections {
    [] -> True
    [#(first, _, _), ..] -> first == own
  }
}

/// The first line of each paragraph, newest first, cut to the shown length.
fn expected_topics(paragraphs: List(String)) -> List(String) {
  paragraphs
  |> list.reverse
  |> list.take(index_topics)
  |> list.map(fn(paragraph) { string.slice(first_line(paragraph), 0, topic_chars) })
}

fn first_line(paragraph: String) -> String {
  case string.split(paragraph, "\n") |> list.first {
    Ok(line) -> line
    Error(Nil) -> ""
  }
}

/// `#(workspace, topic lines, body characters)` for each section, in order.
fn sections(index: String) -> List(#(String, List(String), Int)) {
  index
  |> string.split("\n## ")
  |> list.drop(1)
  |> list.map(fn(part) {
    case string.split_once(part, "\n") {
      Ok(#(name, body)) ->
        #(
          name,
          string.split(body, "\n") |> list.filter_map(topic_line),
          topic_chars_shown(body),
        )
      Error(Nil) -> #(part, [], 0)
    }
  })
}

fn topic_line(line: String) -> Result(String, Nil) {
  case string.starts_with(line, "- ") {
    True -> Ok(string.drop_start(line, 2))
    False -> Error(Nil)
  }
}

fn section_for(
  sections: List(#(String, List(String), Int)),
  workspace: String,
) -> List(String) {
  case list.find(sections, fn(section) { section.0 == workspace }) {
    Ok(found) -> found.1
    Error(Nil) -> []
  }
}

fn at(items: List(a), index: Int) -> Result(a, Nil) {
  case items, index {
    _, 0 -> case items {
      [first, ..] -> Ok(first)
      [] -> Error(Nil)
    }
    [_, ..rest], _ -> at(rest, index - 1)
    [], _ -> Error(Nil)
  }
}

fn indexed(items: List(String)) -> List(#(Int, String)) {
  items
  |> list.index_map(fn(item, index) { #(index, item) })
}

/// Every line of the notes the index may show.
fn lines_of(parts: List(List(String))) -> List(String) {
  parts
  |> list.flat_map(fn(paragraphs) {
    list.flat_map(paragraphs, fn(paragraph) { string.split(paragraph, "\n") })
  })
}

fn paragraphs(count: Int) -> List(String) {
  upto(count)
  |> list.map(fn(index) {
    let first = "P" <> int.to_string(index) <> " " <> words(1 + rand(14))
    let rest = list.map(upto(rand(2)), fn(_) { "  " <> words(1 + rand(3)) })
    string.join([first, ..rest], "\n")
  })
}

fn words(count: Int) -> String {
  list.map(upto(count), fn(_) { word() }) |> string.join(" ")
}

/// Words long enough that twelve first lines can fill the shared budget.
fn word() -> String {
  case rand(7) {
    0 -> "alphabetically"
    1 -> "beta"
    2 -> "秘密のメモ"
    3 -> "topical"
    4 -> "x"
    5 -> "gamma-delta-epsilon"
    _ -> "é"
  }
}

fn upto(count: Int) -> List(Int) {
  case count <= 0 {
    True -> []
    False -> count_down(count - 1, [])
  }
}

fn count_down(last: Int, acc: List(Int)) -> List(Int) {
  case last < 0 {
    True -> acc
    False -> count_down(last - 1, [last, ..acc])
  }
}

@external(erlang, "rand", "uniform")
fn rand_uniform(n: Int) -> Int

fn rand(n: Int) -> Int {
  rand_uniform(n + 1) - 1
}

@external(erlang, "os", "putenv")
fn putenv(name: List(Int), value: List(Int)) -> Bool

fn set_env(name: String, value: String) -> Nil {
  let _ = putenv(charlist(name), charlist(value))
  Nil
}

@external(erlang, "unicode", "characters_to_list")
fn charlist(text: String) -> List(Int)

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> Dynamic

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int
