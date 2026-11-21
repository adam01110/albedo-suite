//// The memory store's startup topic index and its 16 MiB documents answer,
//// against a model read from the documented rule (docs/prompt-context.md: "up
//// to 12 recent paragraphs per workspace, using at most 120 characters of
//// each first line, within a shared 1600-character topic budget. Each
//// workspace has a heading, the current workspace first, then linked
//// sources"). Generated memories hold only whole grapheme tokens, so the
//// generator's own token list is the oracle for where a cut may fall.
////
//// Independent checks: the index equals the model, the shared budget bounds
//// the listed topic text, no topic line is a fragment of a grapheme, a spent
//// budget still names every later workspace, and `documents` fills exactly
//// its byte budget.

import albedo_ext_memory/files as memory
import gleam/int
import gleam/list
import gleam/string
import proptest
import qcheck

const index_budget = 1600

const topic_chars = 120

const index_topics = 12

const max_file = 1_048_576

const documents_budget = 16_777_216

/// The marker an index ends with once the shared budget is spent.
const omitted = "\n[more topics omitted; search spans all linked workspaces]"

/// One grapheme each, including clusters a codepoint-wise cut would split: a
/// base with a combining mark, a lone combining mark, two ZWJ sequences, a
/// regional indicator pair, and a skin-toned emoji. A token is never only
/// whitespace, so a line holding one is never blank.
fn word() -> qcheck.Generator(String) {
  qcheck.from_generators(
    qcheck.return("a"),
    list.map(
      [
        "b",
        "z",
        "中",
        "ß",
        "-",
        "e\u{0301}",
        "🙂",
        "☺\u{fe0f}",
        "👨\u{200d}👩\u{200d}👧\u{200d}👦",
        "🏳\u{fe0f}\u{200d}🌈",
        "🇦🇺",
        "👍🏽",
        "W",
      ],
      qcheck.return,
    ),
  )
}

fn grapheme() -> qcheck.Generator(String) {
  qcheck.from_weighted_generators(#(10, word()), [#(1, qcheck.return(" "))])
}

fn line(most: Int) -> qcheck.Generator(List(String)) {
  qcheck.map2(
    word(),
    qcheck.generic_list(grapheme(), qcheck.bounded_int(0, most - 1)),
    fn(first, rest) { [first, ..rest] },
  )
}

/// A memory file: `#(graphemes of the line, blank)` lines joined by `sep`.
pub type Memory {
  Memory(lines: List(#(List(String), Bool)), sep: String)
}

/// Lines of a workspace's memory, drawn from three families so a group can
/// reach each documented limit: dense long lines fill the shared budget, many
/// short lines exceed the twelve-paragraph cap, and sparse lines are the
/// ordinary mixed case.
fn lines() -> qcheck.Generator(List(#(List(String), Bool))) {
  qcheck.from_weighted_generators(#(1, dense()), [#(1, many()), #(2, sparse())])
}

/// A first line of 110 to 130 graphemes, so twelve of them approach the
/// shared budget.
fn long_line() -> qcheck.Generator(List(String)) {
  qcheck.map2(
    word(),
    qcheck.generic_list(grapheme(), qcheck.bounded_int(109, 129)),
    fn(first, rest) { [first, ..rest] },
  )
}

fn dense() -> qcheck.Generator(List(#(List(String), Bool))) {
  qcheck.map(
    qcheck.bind(qcheck.bounded_int(10, 16), fn(count) {
      qcheck.fixed_length_list_from(long_line(), count)
    }),
    fn(paragraphs) {
      list.flat_map(paragraphs, fn(tokens) { [#(tokens, False), #([], True)] })
    },
  )
}

fn many() -> qcheck.Generator(List(#(List(String), Bool))) {
  qcheck.generic_list(
    qcheck.from_weighted_generators(
      #(9, qcheck.map(line(4), fn(tokens) { #(tokens, False) })),
      [#(1, qcheck.return(#([], True)))],
    ),
    qcheck.bounded_int(1, 32),
  )
}

fn sparse() -> qcheck.Generator(List(#(List(String), Bool))) {
  qcheck.generic_list(
    qcheck.from_weighted_generators(
      #(7, qcheck.map(line(6), fn(tokens) { #(tokens, False) })),
      [
        #(1, qcheck.return(#([], True))),
        #(1, qcheck.return(#([" "], True))),
        #(1, qcheck.return(#([" ", " "], True))),
        #(3, qcheck.map(line(130), fn(tokens) { #(tokens, False) })),
      ],
    ),
    qcheck.bounded_int(0, 20),
  )
}

fn memory() -> qcheck.Generator(Memory) {
  qcheck.map2(
    lines(),
    qcheck.from_generators(qcheck.return("\n"), [qcheck.return("\r\n")]),
    fn(mine, sep) { Memory(mine, sep) },
  )
}

fn rendered(memory: Memory) -> String {
  memory.lines
  |> list.map(fn(entry) { string.concat(entry.0) })
  |> string.join(memory.sep)
}

/// Each line as `string.split(text, "\n")` leaves it: a CRLF file keeps a
/// trailing `\r` on every line that a separator follows.
fn split_lines(memory: Memory) -> List(#(List(String), Bool)) {
  let count = list.length(memory.lines)
  list.index_map(memory.lines, fn(entry, index) {
    let #(tokens, blank) = entry
    case memory.sep, index == count - 1 {
      "\r\n", False -> #(list.append(tokens, ["\r"]), blank)
      _, _ -> #(tokens, blank)
    }
  })
}

/// The first line of each of the newest paragraphs, newest first, at most
/// `index_topics`: a blank line starts a paragraph and the next non-blank line
/// is that paragraph's first line.
fn model_topics(memory: Memory) -> List(List(String)) {
  let #(_, found) =
    list.fold(split_lines(memory), #(True, []), fn(state, entry) {
      let #(after_blank, found) = state
      let #(tokens, blank) = entry
      case blank, after_blank {
        True, _ -> #(True, found)
        False, True -> #(False, [tokens, ..found])
        False, False -> #(False, found)
      }
    })
  list.take(found, index_topics)
}

/// A workspace's modelled section body as single graphemes: `- `, the first
/// line cut to `topic_chars`, and a newline per listed paragraph. A CRLF
/// file's `\r` and the newline that follows it are one grapheme cluster, so
/// the budget counts them once.
fn model_body(memory: Memory) -> List(String) {
  model_topics(memory)
  |> list.flat_map(fn(tokens) {
    let cut = list.take(tokens, topic_chars)
    let #(cut, ending) = case list.last(cut) {
      Ok("\r") -> #(list.take(cut, list.length(cut) - 1), ["\r\n"])
      _ -> #(cut, ["\n"])
    }
    list.append(["-", " "], list.append(cut, ending))
  })
}

fn model_sections(parts: List(#(String, Memory)), budget: Int) -> String {
  case parts {
    [] -> ""
    // A spent budget stops topics, not the headings that name each workspace.
    _ if budget <= 0 ->
      omitted
      <> string.concat(list.map(parts, fn(part) { "\n## " <> part.0 <> "\n" }))
    [#(where, mine), ..rest] -> {
      let shown = list.take(model_body(mine), budget)
      "\n## "
      <> where
      <> "\n"
      <> string.concat(shown)
      <> model_sections(rest, budget - list.length(shown))
    }
  }
}

/// An index without its fixed preamble: everything from the first heading.
fn sections_of(text: String) -> String {
  case string.split_once(text, "\n## ") {
    Ok(#(_, rest)) -> "\n## " <> rest
    Error(Nil) -> ""
  }
}

fn workspace(label: String) -> String {
  "/workspace/" <> label <> "-" <> int.to_string(proptest.unique())
}

/// One to three working spaces, each with its own memory.
fn group() -> qcheck.Generator(List(Memory)) {
  use count <- qcheck.bind(
    qcheck.from_weighted_generators(#(1, qcheck.return(1)), [
      #(3, qcheck.return(2)),
      #(3, qcheck.return(3)),
    ]),
  )
  qcheck.fixed_length_list_from(memory(), count)
}

fn place(memories: List(Memory)) -> List(#(String, Memory)) {
  list.index_map(memories, fn(mine, index) {
    let where = workspace(int.to_string(index))
    let assert Ok(_) = memory.save(where, rendered(mine))
    #(where, mine)
  })
}

fn body_lines(text: String) -> List(String) {
  text
  |> string.split("\n")
  |> list.filter(fn(row) { string.starts_with(row, "- ") })
}

/// Byte sizes of every whole-grapheme prefix of a line.
fn prefix_sizes(tokens: List(String)) -> List(Int) {
  let #(_, sizes) =
    list.fold(tokens, #(0, [0]), fn(state, token) {
      let #(size, sizes) = state
      let size = size + string.byte_size(token)
      #(size, [size, ..sizes])
    })
  sizes
}

/// The graphemes an index spends on topic text: every section body, without
/// its heading line or the omission marker, counted as the budget counts.
fn listed_chars(index: String) -> Int {
  case string.split_once(index, "\n## ") {
    Error(Nil) -> 0
    Ok(#(_, rest)) ->
      string.split(rest, "\n## ")
      |> list.map(fn(chunk) {
        let body = case string.split_once(chunk, "\n") {
          Ok(#(_, body)) -> body
          Error(Nil) -> ""
        }
        case string.ends_with(body, omitted) {
          True -> string.remove_suffix(body, omitted)
          False -> body
        }
      })
      |> string.concat
      |> string.length
  }
}

/// `count` paragraphs whose first lines are 120 graphemes of multibyte text.
fn dense_memory(count: Int) -> Memory {
  Memory(
    list.flat_map(numbers(1, count), fn(_) {
      [#(dense_line(), False), #([], True)]
    }),
    "\n",
  )
}

fn dense_line() -> List(String) {
  ["中", ..list.repeat(".", 119)]
}

fn numbers(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..numbers(from + 1, to)]
  }
}

fn pad(value: Int) -> String {
  string.pad_start(int.to_string(value), 2, "0")
}

pub fn main() -> Nil {
  let home =
    "/tmp/albedo-proptest-memory-budget-" <> int.to_string(proptest.unique())
  let _ = proptest.remove_tree(home)
  proptest.putenv("ALBEDO_HOME", home)

  proptest.check(
    "the startup index equals the model of the documented rule",
    100,
    group(),
    fn(memories) {
      let parts = place(memories)
      let names = list.map(parts, fn(part) { part.0 })
      let kept = list.filter(parts, fn(part) { rendered(part.1) != "" })
      let assert Ok(index) = memory.load(names)
      assert sections_of(index) == model_sections(kept, index_budget)
      proptest.bump(case list.length(kept) {
        0 -> "no-notes"
        1 -> "own-only"
        _ -> "with-linked"
      })
    },
  )

  proptest.check(
    "the shared budget bounds the listed topic text",
    100,
    group(),
    fn(memories) {
      let names = list.map(place(memories), fn(part) { part.0 })
      let assert Ok(index) = memory.load(names)
      let listed = listed_chars(index)
      assert listed <= index_budget
      proptest.bump(case listed == index_budget {
        True -> "budget-spent"
        False -> "budget-slack"
      })
    },
  )

  proptest.check(
    "no listed topic line is a fragment of a grapheme",
    100,
    group(),
    fn(memories) {
      let parts = place(memories)
      let names = list.map(parts, fn(part) { part.0 })
      let assert Ok(index) = memory.load(names)
      let firsts =
        list.flat_map(parts, fn(part) {
          list.map(model_topics(part.1), fn(tokens) {
            #(string.concat(tokens), prefix_sizes(tokens))
          })
        })
      list.each(body_lines(index), fn(row) {
        let shown = string.drop_start(row, 2)
        assert list.any(firsts, fn(first) {
          string.starts_with(first.0, shown)
          && list.contains(first.1, string.byte_size(shown))
        })
      })
      proptest.bump("graphemes")
    },
  )

  proptest.check(
    "documents fills exactly its byte budget",
    4,
    qcheck.tuple2(qcheck.bounded_int(1, 2000), qcheck.bounded_int(-1, 1)),
    fn(sample) {
      let #(own_bytes, delta) = sample
      let where = workspace("documents")
      let assert Ok(memory_file) =
        memory.save(where, string.repeat("a", own_bytes))
      let root = string.remove_suffix(memory_file, "/memory.md")
      // Fifteen journals at the 1 MiB file limit, and a last one sized so the
      // total is the 16 MiB budget or one byte either side.
      list.each(numbers(1, 15), fn(day) {
        proptest.write_file(
          root <> "/journal/2024-01-" <> pad(day) <> ".md",
          <<string.repeat("b", max_file):utf8>>,
          0,
        )
      })
      proptest.write_file(
        root <> "/journal/2024-02-01.md",
        <<string.repeat("c", max_file - own_bytes + delta):utf8>>,
        0,
      )
      let #(found, truncated) = memory.documents([where])
      let total =
        list.fold(found, 0, fn(sum, document) {
          sum + string.byte_size(document.2)
        })
      assert total <= documents_budget
      let complete = delta <= 0
      assert truncated == !complete
      assert list.length(found)
        == case complete {
          True -> 17
          False -> 16
        }
      proptest.bump(case delta {
        0 -> "exactly-full"
        _ -> "one-off"
      })
    },
  )

  proptest.check(
    "a dense index spends its budget in graphemes, not bytes",
    1,
    qcheck.return(Nil),
    fn(_) {
      let own = workspace("own-dense")
      let joined = workspace("joined-dense")
      let mine = dense_memory(12)
      let theirs = dense_memory(2)
      let assert Ok(_) = memory.save(own, rendered(mine))
      let assert Ok(_) = memory.save(joined, rendered(theirs))
      let assert Ok(index) = memory.load([own, joined])
      // Twelve 120-grapheme topics fill 1476 of the shared budget, leaving
      // 124: the joining workspace shows a 124-grapheme prefix of its own.
      assert listed_chars(index) == index_budget
      assert sections_of(index)
        == model_sections([#(own, mine), #(joined, theirs)], index_budget)
      proptest.bump("dense-edge")
    },
  )

  proptest.check(
    "a spent budget still names every later workspace",
    1,
    qcheck.return(Nil),
    fn(_) {
      let own = workspace("own-spent")
      let joined = workspace("joined-spent")
      let later = workspace("later-spent")
      let mine = dense_memory(12)
      let theirs = dense_memory(2)
      let last = Memory([#(["z"], False)], "\r\n")
      let assert Ok(_) = memory.save(own, rendered(mine))
      let assert Ok(_) = memory.save(joined, rendered(theirs))
      let assert Ok(_) = memory.save(later, rendered(last))
      let assert Ok(index) = memory.load([own, joined, later])
      // The joining workspace spends the last 124 graphemes, so the later one
      // keeps only its heading, after the omission marker.
      assert string.ends_with(index, omitted <> "\n## " <> later <> "\n")
      assert sections_of(index)
        == model_sections(
          [#(own, mine), #(joined, theirs), #(later, last)],
          index_budget,
        )
      proptest.bump("spent-headings")
    },
  )

  let _ = proptest.remove_tree(home)
  Nil
}
