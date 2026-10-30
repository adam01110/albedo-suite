import albedo/clock
import albedo/daemon/quota
import albedo/daemon/store
import albedo/harness/usage_feed
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import sqlight

fn database() -> store.Store {
  let assert Ok(db) = store.start(":memory:", "")
  let assert Ok(Nil) = quota.initialise(db)
  db
}

fn row(
  db: store.Store,
  account: String,
  meter: String,
  observed: Int,
  error: String,
) -> Nil {
  let assert Ok(_) =
    store.query(db, fn(connection) {
      store.run(
        connection,
        "INSERT INTO quota_sample(account, provider, limit_id, label, used_percent, status, error, observed_at, source) VALUES (?, 'fixture', ?, ?, 100, 'exhausted', ?, ?, 'poll')",
        [
          sqlight.text(account),
          sqlight.text(meter),
          sqlight.text(meter),
          sqlight.text(error),
          sqlight.int(observed),
        ],
      )
    })
  Nil
}

fn projection() -> Nil {
  let db = database()
  row(db, "a", "5h", 1000, "")
  row(db, "a", "weekly", 1000, "")
  row(db, "b", "5h", 500, "")
  let assert Ok(first) = quota.latest(db)
  assert list.length(first) == 3
  row(db, "a", "", 2000, "core unavailable")
  let assert Ok(failed) = quota.latest(db)
  assert list.map(failed, fn(sample) { #(sample.account, sample.limit_id) })
    == [#("a", ""), #("b", "5h")]
  row(db, "a", "weekly", 3000, "")
  let assert Ok(recovered) = quota.latest(db)
  assert list.map(recovered, fn(sample) { #(sample.account, sample.limit_id) })
    == [#("a", "weekly"), #("b", "5h")]
  let assert Ok(history) = quota.history(db, quota.Everything, 0, 20)
  assert list.length(history) == 5
  store.close(db)
}

fn target() -> quota.Target {
  quota.Target("fixture", "account", json.object([]))
}

fn report() -> usage_feed.Report {
  usage_feed.Report(
    None,
    None,
    None,
    [
      usage_feed.Limit(
        "weekly",
        "Weekly",
        Some(40.0),
        None,
        None,
        None,
        None,
        "ok",
      ),
    ],
    None,
  )
}

fn stop(pid: process.Pid) -> Nil {
  process.unlink(pid)
  process.kill(pid)
}

fn healthy_fetch(notify: process.Subject(Nil)) -> quota.Fetch {
  fn(_, _, _) {
    process.send(notify, Nil)
    Ok(report())
  }
}

fn startup_and_crash() -> Nil {
  let db = database()
  let polls = process.new_subject()
  let assert Ok(started) =
    quota.start_with(
      "fixture",
      db,
      healthy_fetch(polls),
      fn(_) { [target()] },
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
      fn(_) { [target()] },
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

fn await_error(db: store.Store, expected: String, deadline: Int) -> Nil {
  let assert Ok(readings) = quota.latest(db)
  case readings {
    [sample] -> {
      let assert Some(error) = sample.error
      assert string.contains(error, expected)
    }
    _ -> {
      assert clock.monotonic_ms() < deadline as "no failure sample recorded"
      clock.sleep(10)
      await_error(db, expected, deadline)
    }
  }
}

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
      fn(_) { [target()] },
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

fn discovery_timeout() -> Nil {
  let db = database()
  let discoveries = process.new_subject()
  let polls = process.new_subject()
  let assert Ok(started) =
    quota.start_with(
      "fixture",
      db,
      healthy_fetch(polls),
      fn(_) {
        let answer = process.new_subject()
        process.send(discoveries, #(process.self(), answer))
        let assert Ok(targets) = process.receive(answer, 30_000)
        targets
      },
      fn() { quota.Settings(1, 1, True) },
      100,
    )
  let assert Ok(#(worker, _)) = process.receive(discoveries, 1000)
  let monitor = process.monitor(worker)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  let assert Ok(#(_, answer)) = process.receive(discoveries, 2000)
  process.send(answer, [target()])
  let assert Ok(Nil) = process.receive(polls, 1500)
  // A later discovery timeout must not discard the previously known target.
  let assert Ok(#(blocked, _)) = process.receive(discoveries, 2000)
  let assert Ok(Nil) = process.receive(polls, 2000)
  stop(started.pid)
  process.kill(blocked)
  store.close(db)
}

fn scheduling() -> Nil {
  let settings = quota.Settings(600, 120, True)
  assert quota.next_delay(settings, 1000, 1000, False, [#(0, True)]) == 600_000
  assert quota.next_delay(settings, 1000, 0, True, [#(0, True)]) == 600_000
  assert quota.next_delay(settings, 1000, 0, True, [#(2000, False)]) == 1000
  assert quota.next_delay(settings, 1000, 0, True, [#(1000, False)]) == 250
}

pub fn main() -> Nil {
  projection()
  scheduling()
  startup_and_crash()
  poll_timeout()
  discovery_timeout()
  io.println(
    "Quota projection, immediate startup, deadlines, crash recovery and schedule tests passed",
  )
}
