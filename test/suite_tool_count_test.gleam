//// The session tool count: committed tool results only, per session, and a
//// message that merely mentions the packed tag does not count.

import albedo/history/conversation
import albedo/history/tool_count
import albedo/storage/core_store
import albedo_model as types
import albedo_sdk/session_info
import albedo_sdk/store
import gleam/io
import gleam/option.{None, Some}

pub fn main() -> Nil {
  let assert Ok(ledger) = store.start(":memory:", "", core_store.tables())
  let assert Ok(_) = conversation.initialise(ledger)
  session(ledger, "busy")
  session(ledger, "quiet")
  assert tool_count.total(ledger, "busy") == Some(0)
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "busy",
      [
        types.User("why does tool_output appear here?"),
        types.Assistant("tool_output is the tag"),
        types.ToolOutput("call-1", "{\"status\":\"ok\"}", []),
      ],
      session_info.Tool,
    )
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "busy",
      [types.ToolOutput("call-2", "done", [])],
      session_info.Tool,
    )
  assert tool_count.total(ledger, "busy") == Some(2)
  assert tool_count.total(ledger, "quiet") == Some(0)
  store.close(ledger)
  io.println(
    "Tool count: committed results per session, mentions of the tag ignored passed",
  )
}

fn session(ledger: store.Store, id: String) -> Nil {
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
