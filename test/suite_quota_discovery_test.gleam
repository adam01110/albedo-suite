import albedo/accounts/quota
import albedo_sdk/key_environment
import albedo_sdk/store
import gleam/erlang/process
import gleam/io
import gleam/json
import suite_quota_fixtures.{database, healthy_fetch, sources, stop}

fn discovery_timeout() -> Nil {
  let db = database()
  let discoveries = process.new_subject()
  let polls = process.new_subject()
  let assert Ok(started) =
    quota.start_with(
      "fixture",
      db,
      healthy_fetch(polls),
      sources("fixture", fn() {
        let answer = process.new_subject()
        process.send(discoveries, #(process.self(), answer))
        let assert Ok(accounts) = process.receive(answer, 30_000)
        accounts
      }),
      key_environment.empty(),
      fn() { quota.Settings(1, 1, True) },
      // Discovery gets 2.5 times this; a cold VM beside the other suite VMs
      // can take longer than a quarter second to reach the source.
      1000,
    )
  let assert Ok(#(worker, _)) = process.receive(discoveries, 5000)
  await_down(worker, 5000)
  let assert Ok(#(_, answer)) = process.receive(discoveries, 5000)
  process.send(answer, [#("account", json.object([]))])
  let assert Ok(Nil) = process.receive(polls, 5000)
  // A later discovery timeout must not discard the previously known target.
  let assert Ok(#(blocked, _)) = process.receive(discoveries, 5000)
  await_down(blocked, 5000)
  drain(polls)
  let assert Ok(Nil) = process.receive(polls, 5000)
  stop(started.pid)
  process.kill(blocked)
  store.close(db)
}

fn await_down(pid: process.Pid, timeout: Int) -> Nil {
  let monitor = process.monitor(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(timeout)
  Nil
}

fn drain(subject: process.Subject(Nil)) -> Nil {
  case process.receive(subject, 0) {
    Ok(Nil) -> drain(subject)
    Error(Nil) -> Nil
  }
}

pub fn main() -> Nil {
  discovery_timeout()
  io.println("Quota account discovery deadline and kept target cases passed")
}
