import albedo/accounts/quota
import albedo_clock as clock
import albedo_sdk/key_environment
import albedo_sdk/store
import gleam/erlang/process
import gleam/io
import gleam/option.{Some}
import suite_quota_fixtures.{await_error, database, fixture, healthy_fetch, stop}

fn startup_and_crash() -> Nil {
  let db = database()
  let polls = process.new_subject()
  let assert Ok(started) =
    quota.start_with(
      "fixture",
      db,
      healthy_fetch(polls),
      fixture(),
      key_environment.empty(),
      fn() { quota.Settings(600, 120, True) },
      1000,
    )
  // Discovery must shorten the ten-minute timer to poll immediately.
  let assert Ok(Nil) = process.receive(polls, 1500)
  stop(started.pid)
  store.close(db)

  let db = database()
  let calls = process.new_subject()
  let assert Ok(started) =
    quota.start_with(
      "fixture",
      db,
      fn(_, _, _) {
        process.send(calls, Nil)
        panic as "fixture crash"
      },
      fixture(),
      key_environment.empty(),
      fn() { quota.Settings(1, 1, True) },
      1000,
    )
  let assert Ok(Nil) = process.receive(calls, 1500)
  await_error(db, "crashed", clock.monotonic_ms() + 1500)
  let assert Ok([crashed]) = quota.latest(db)
  assert crashed.error == Some("quota feed worker crashed")
  // Failed polls must free their slot and retry after the existing backoff.
  let assert Ok(Nil) = process.receive(calls, 3000)
  stop(started.pid)
  store.close(db)
}

pub fn main() -> Nil {
  startup_and_crash()
  io.println("Quota startup discovery and crash recovery cases passed")
}
