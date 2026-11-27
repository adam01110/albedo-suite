//// The agents sidebar glance: a parent's open children in creation order,
//// active while mid-turn and plain while idle; closed children, other
//// sessions' children and the parent itself stay out.

import albedo/history/conversation
import albedo/session/family as core_family
import albedo/storage/core_store
import albedo/workspace/worktree
import albedo_ext_agents
import albedo_ext_agents/sidebar
import albedo_model as types
import albedo_sdk/extension
import albedo_sdk/page
import albedo_sdk/session_info
import albedo_sdk/store
import albedo_sqlite
import gleam/io
import gleam/list
import gleam/option.{None}
import sqlight

pub fn main() -> Nil {
  let assert Ok(ledger) =
    store.start(":memory:", fn(_) { Ok(Nil) }, core_store.tables())
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = core_family.initialise(ledger)
  session(ledger, "lead", session_info.Model)
  session(ledger, "other", session_info.Idle)
  session(ledger, "scout", session_info.Tool)
  session(ledger, "coder", session_info.Idle)
  session(ledger, "done", session_info.Idle)
  session(ledger, "stray", session_info.Model)
  session(ledger, "stopped", session_info.Interrupted)
  child(ledger, "scout", "lead", 1, False)
  child(ledger, "coder", "lead", 2, False)
  child(ledger, "done", "lead", 3, True)
  child(ledger, "stopped", "lead", 4, False)
  child(ledger, "stray", "other", 5, False)

  let agents = albedo_ext_agents.extension()
  let assert [read] =
    list.filter_map(agents.plugins, fn(plugin) {
      case plugin {
        extension.GlancePlugin(read, _) -> Ok(read)
        _ -> Error(Nil)
      }
    })
  let glance = fn(session) {
    read(extension.Sidebar(
      session:,
      workspace: "/work",
      origins: worktree.origins(),
      storage: extension.session_storage_of(agents, ledger, session),
    ))
  }
  let assert Ok(page.Glance("agents", rows)) = glance("lead")
  assert rows
    == [
      page.Row("scout", "scout", "working", page.Active, ""),
      page.Row("coder", "coder", "idle", page.Plain, ""),
      page.Row("stopped", "stopped", "idle", page.Plain, ""),
    ]
  let assert Ok(page.Glance("agents", [])) = glance("scout")
  assert sidebar.resource_url("lead", "/work") == "/sessions/lead"
  store.close(ledger)
  io.println(
    "Agents glance: open children in order, working and idle tones, closed and foreign children omitted passed",
  )
}

fn session(ledger: store.Store, id: String, stage: session_info.Stage) -> Nil {
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
        stage,
        None,
        None,
        False,
        None,
      ),
    )
  // create starts every session idle; the stage is what a turn later writes.
  let assert Ok(_) =
    store.writing(ledger, fn(db) {
      albedo_sqlite.run("UPDATE sessions SET stage=? WHERE id=?", on: db, with: [
        sqlight.text(session_info.stage_name(stage)),
        sqlight.text(id),
      ])
    })
  Nil
}

fn child(
  ledger: store.Store,
  id: String,
  parent: String,
  created_at: Int,
  closed: Bool,
) -> Nil {
  let closed_at = case closed {
    True -> sqlight.int(created_at)
    False -> sqlight.null()
  }
  let assert Ok(_) =
    store.writing(ledger, fn(db) {
      albedo_sqlite.run(
        "INSERT INTO session_family(session,parent,name,depth,created_at,closed_at) VALUES(?,?,?,1,?,?)",
        on: db,
        with: [
          sqlight.text(id),
          sqlight.text(parent),
          sqlight.text(id),
          sqlight.int(created_at),
          closed_at,
        ],
      )
    })
  Nil
}
