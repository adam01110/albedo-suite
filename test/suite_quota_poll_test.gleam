import albedo/accounts/quota
import albedo_clock as clock
import albedo_sdk/key_environment
import albedo_sdk/store
import gleam/erlang/process
import gleam/io
import suite_quota_fixtures.{await_error, database, fixture, report, stop}

fn poll_timeout() -> Nil {
  let db = database()
  let workers = process.new_subject()
  let assert Ok(started) =
    quota.start_with(
      "fixture",
      db,
      fn(_, _, _) {
        process.send(workers, process.self())
        let gate = process.new_subject()
        let assert Ok(Nil) = process.receive(gate, 30_000)
        Ok(report())
      },
      fixture(),
      key_environment.empty(),
      fn() { quota.Settings(1, 1, True) },
      100,
    )
  let assert Ok(worker) = process.receive(workers, 1500)
  let monitor = process.monitor(worker)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  await_error(db, "timed out", clock.monotonic_ms() + 1000)
  let assert Ok(retry) = process.receive(workers, 3000)
  assert retry != worker
  stop(started.pid)
  process.kill(retry)
  store.close(db)
}

pub fn main() -> Nil {
  poll_timeout()
  io.println("Quota poll deadline, its error sample and retry cases passed")
}
