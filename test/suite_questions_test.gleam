import albedo/daemon/store
import albedo/harness/extensions/questions/ledger
import gleam/io

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

fn terminal_transitions(storage: store.Store) -> Nil {
  let assert Ok(Nil) = ledger.initialise(storage)
  let assert Ok(answering) = ledger.ask(storage, "origin", "Deploy?", ["yes"])
  let assert Ok(cancelling) = ledger.ask(storage, "origin", "Another?", [])
  let assert Ok(foreign) = ledger.ask(storage, "other", "Foreign?", [])
  let assert Error(_) = ledger.finish(storage, answering, "answered", "")
  let assert Ok(unchanged) = ledger.get(storage, "origin", answering.id)
  assert unchanged == answering
  let assert Ok(answered) =
    ledger.finish(storage, answering, "answered", "custom answer")
  assert answered.status == "answered"
  assert answered.answer == "custom answer"
  assert answered.revision == answering.revision + 1
  let assert Ok(saved) = ledger.get(storage, "origin", answering.id)
  assert saved == answered
  let assert Error(_) = ledger.finish(storage, answering, "answered", "stale")
  let assert Error(_) = ledger.finish(storage, answering, "cancelled", "")
  let assert Error(_) = ledger.get(storage, "other", answering.id)
  let assert Ok(cancelled) = ledger.finish(storage, cancelling, "cancelled", "")
  assert cancelled.status == "cancelled"
  assert cancelled.revision == cancelling.revision + 1
  let assert Error(_) = ledger.finish(storage, cancelling, "answered", "stale")
  let assert Ok([]) = ledger.pending(storage, "origin")
  let assert Ok([remaining]) = ledger.pending(storage, "other")
  assert remaining == foreign
}

pub fn main() -> Nil {
  let assert Ok(memory) = store.start(":memory:", "")
  terminal_transitions(memory)
  store.close(memory)

  let path = temporary_database()
  let assert Ok(database) = store.start(path, "")
  terminal_transitions(database)
  let assert Ok(pending) = ledger.ask(database, "resume", "Survives?", [])
  store.close(database)
  let assert Ok(reopened) = store.start(path, "")
  let assert Ok(saved) = ledger.get(reopened, "resume", pending.id)
  assert saved == pending
  let assert Ok(answered) = ledger.finish(reopened, saved, "answered", "yes")
  assert answered.revision == pending.revision + 1
  let assert Ok([]) = ledger.pending(reopened, "resume")
  store.close(reopened)
  cleanup(path)
  io.println(
    "Question writer transitions: memory, file and restart cases passed",
  )
}
