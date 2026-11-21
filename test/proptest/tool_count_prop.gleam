//// The session tool count against generated transcripts: the count is the
//// number of committed tool results, whatever text the other rows carry.

import albedo/history/conversation
import albedo/history/tool_count
import albedo/storage/core_store
import albedo_model as types
import albedo_sdk/session_info
import albedo_sdk/store
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import proptest
import qcheck

pub type Row {
  Utterance(text: String)
  Reply(text: String)
  Output(id: String, text: String)
}

type Case {
  Case(rows: List(Row), split: Int)
}

const tags = [
  "tool_output",
  "tool_output\n",
  "[tool output call-1 omitted]",
  "user",
  "assistant",
  "\u{0001}tool_output",
  "tool_output\u{0000}",
  "<|tool_output|>",
  "",
]

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

/// Text that mentions the packed tag, alone and around generated text.
fn text() -> qcheck.Generator(String) {
  use base <- qcheck.bind(qcheck.string())
  use tag <- qcheck.bind(pick(tags))
  use placement <- qcheck.bind(qcheck.bounded_int(0, 2))
  qcheck.return(case placement {
    0 -> tag <> base
    1 -> base <> tag
    _ -> base
  })
}

fn row() -> qcheck.Generator(Row) {
  use kind <- qcheck.bind(qcheck.bounded_int(0, 2))
  case kind {
    0 -> qcheck.map(text(), Utterance)
    1 -> qcheck.map(text(), Reply)
    _ -> {
      use id <- qcheck.bind(qcheck.string())
      use output <- qcheck.bind(text())
      qcheck.return(Output(id, output))
    }
  }
}

fn scenario() -> qcheck.Generator(Case) {
  use rows <- qcheck.bind(qcheck.generic_list(row(), qcheck.bounded_int(0, 8)))
  use split <- qcheck.bind(qcheck.bounded_int(0, list.length(rows)))
  qcheck.return(Case(rows, split))
}

fn input(row: Row) -> types.Input {
  case row {
    Utterance(text) -> types.User(text)
    Reply(text) -> types.Assistant(text)
    Output(id, text) -> types.ToolOutput(id, text, [])
  }
}

fn open(ledger: store.Store, id: String) -> Nil {
  let assert Ok(_) =
    conversation.create(
      ledger,
      session_info.Info(
        id,
        id,
        "/work",
        "provider",
        "model",
        types.Responses,
        session_info.Idle,
        None,
        None,
        False,
        None,
      ),
    )
  Nil
}

pub fn main() -> Nil {
  proptest.check("total counts committed tool results", 100, scenario(), fn(c) {
    let assert Ok(ledger) = store.start(":memory:", "", core_store.tables())
    let assert Ok(_) = conversation.initialise(ledger)
    open(ledger, "s")
    let #(before, after) = list.split(c.rows, c.split)
    let commit = fn(rows) {
      case rows {
        [] -> Nil
        rows -> {
          let assert Ok(_) =
            conversation.commit(
              ledger,
              "s",
              list.map(rows, input),
              session_info.Tool,
            )
          Nil
        }
      }
    }
    commit(before)
    commit(after)
    proptest.bump("rows_" <> int.to_string(list.length(c.rows)))
    let expected =
      list.count(c.rows, fn(row) {
        case row {
          Output(_, _) -> True
          _ -> False
        }
      })
    proptest.bump(case expected > 0 {
      True -> "with_output"
      False -> "without_output"
    })
    assert tool_count.total(ledger, "s") == Some(expected)
    store.close(ledger)
    Nil
  })

  proptest.check(
    "a message mentioning the tag does not count",
    60,
    qcheck.generic_list(text(), qcheck.bounded_int(0, 6)),
    fn(texts) {
      let assert Ok(ledger) = store.start(":memory:", "", core_store.tables())
      let assert Ok(_) = conversation.initialise(ledger)
      open(ledger, "talk")
      open(ledger, "quiet")
      case texts {
        [] -> Nil
        texts -> {
          let assert Ok(_) =
            conversation.commit(
              ledger,
              "talk",
              list.map(texts, types.User),
              session_info.Tool,
            )
          Nil
        }
      }
      assert tool_count.total(ledger, "talk") == Some(0)
      assert tool_count.total(ledger, "quiet") == Some(0)
      store.close(ledger)
      Nil
    },
  )

  proptest.check(
    "a session counts only its own rows",
    60,
    qcheck.generic_list(qcheck.bounded_int(0, 4), qcheck.bounded_int(1, 5)),
    fn(batches) {
      let assert Ok(ledger) = store.start(":memory:", "", core_store.tables())
      let assert Ok(_) = conversation.initialise(ledger)
      open(ledger, "one")
      open(ledger, "two")
      list.each(batches, fn(count) {
        case count {
          0 -> Nil
          _ -> {
            let assert Ok(_) =
              conversation.commit(
                ledger,
                "one",
                list.map(range(1, count), fn(i) {
                  types.ToolOutput("call-" <> int.to_string(i), "out", [])
                }),
                session_info.Tool,
              )
            Nil
          }
        }
      })
      let expected = list.fold(batches, 0, fn(sum, count) { sum + count })
      assert tool_count.total(ledger, "one") == Some(expected)
      assert tool_count.total(ledger, "two") == Some(0)
      store.close(ledger)
      Nil
    },
  )
}
