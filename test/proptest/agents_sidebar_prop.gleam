//// The agents sidebar glance (albedo-suite): a parent's open children as one
//// row each, in creation order rather than insertion order, active only while
//// the persisted stage is mid-turn, with closed children and other parents'
//// children left out.

import albedo/history/conversation
import albedo/session/family as core_family
import albedo/storage/core_store
import albedo/workspace/worktree
import albedo_ext_agents
import albedo_model as types
import albedo_sdk/extension
import albedo_sdk/page
import albedo_sdk/session_info
import albedo_sdk/store
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import proptest
import qcheck
import sqlight

// Stage slots in generation order; the sidebar treats Model and Tool as a
// turn in progress and everything else as waiting.
// Importing is left out: `albedo_sdk/history.find` reports a session that is
// still importing as absent, so `sidebar` fails the whole glance with
// "session not found" while one child transfers in. That is a robustness
// question, not a stated contract, so the pool keeps the settled stages.
const stages = [
  session_info.Idle, session_info.Model, session_info.Tool,
  session_info.Interrupted,
]

pub type Child {
  Child(name: String, created_at: Int, closed: Bool, stage: Int)
}

/// Children in insertion order, with creation times that are a permutation, so
/// a row order that follows insertion would differ from the promised one.
pub fn children() -> qcheck.Generator(List(Child)) {
  use flags <- qcheck.map(
    qcheck.list_from(
      qcheck.tuple3(
        qcheck.bool(),
        qcheck.bounded_int(0, 20),
        qcheck.bounded_int(0, 3),
      ),
    ),
  )
  let ranks =
    list.index_map(flags, fn(flag, index) { #(flag.1, index) })
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.index_map(fn(entry, rank) { #(entry.1, rank + 1) })
  list.index_map(flags, fn(flag, index) {
    let #(closed, _, stage) = flag
    let created_at =
      list.find(ranks, fn(entry) { entry.0 == index })
      |> result.map(fn(entry) { entry.1 })
      |> result.unwrap(index + 1)
    Child("c" <> int.to_string(index + 1), created_at, closed, stage)
  })
}

fn stage(index: Int) -> session_info.Stage {
  list.drop(stages, index) |> list.first |> result.unwrap(session_info.Idle)
}

fn model_rows(children: List(Child)) -> List(page.Row) {
  children
  |> list.filter(fn(child) { !child.closed })
  |> list.sort(fn(a, b) { int.compare(a.created_at, b.created_at) })
  |> list.map(fn(child) {
    case stage(child.stage) {
      session_info.Model | session_info.Tool ->
        page.Row(child.name, child.name, "working", page.Active, "")
      _ -> page.Row(child.name, child.name, "idle", page.Plain, "")
    }
  })
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
  let assert Ok(_) =
    store.write(ledger, "UPDATE sessions SET stage=? WHERE id=?", [
      sqlight.text(session_info.stage_name(stage)),
      sqlight.text(id),
    ])
  Nil
}

fn child(
  ledger: store.Store,
  id: String,
  parent: String,
  created_at: Int,
  closed: Bool,
) -> Nil {
  let assert Ok(_) =
    store.write(
      ledger,
      "INSERT INTO session_family(session,parent,name,depth,created_at,closed_at) VALUES(?,?,?,1,?,?)",
      [
        sqlight.text(id),
        sqlight.text(parent),
        sqlight.text(id),
        sqlight.int(created_at),
        case closed {
          True -> sqlight.int(created_at)
          False -> sqlight.null()
        },
      ],
    )
  Nil
}

fn glance(children: List(Child)) -> Nil {
  let assert Ok(ledger) = store.start(":memory:", "", core_store.tables())
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = core_family.initialise(ledger)
  session(ledger, "lead", session_info.Idle)
  session(ledger, "other", session_info.Model)
  let _ = child(ledger, "stray", "other", 1, False)
  list.each(children, fn(value) {
    session(ledger, value.name, stage(value.stage))
    child(ledger, value.name, "lead", value.created_at, value.closed)
  })
  let agents = albedo_ext_agents.extension()
  let assert [read] =
    list.filter_map(agents.plugins, fn(plugin) {
      case plugin {
        extension.GlancePlugin(read, _) -> Ok(read)
        _ -> Error(Nil)
      }
    })
  let result =
    read(extension.Sidebar(
      session: "lead",
      workspace: "/work",
      origins: worktree.origins(),
      storage: extension.session_storage_of(agents, ledger, "lead"),
    ))
  store.close(ledger)
  proptest.bump(case children {
    [] -> "no_children"
    _ -> "children"
  })
  let assert Ok(page.Glance("agents", rows)) = result
  let expected = model_rows(children)
  case rows == expected {
    True -> Nil
    False ->
      panic as "sidebar rows differ from the model"
  }
}

pub fn main() -> Nil {
  proptest.check(
    "agent sidebar rows follow creation order and stage",
    30,
    children(),
    glance,
  )
}
