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
      100,
    )
  let assert Ok(#(worker, _)) = process.receive(discoveries, 1000)
  let monitor = process.monitor(worker)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  let assert Ok(#(_, answer)) = process.receive(discoveries, 2000)
  process.send(answer, [#("account", json.object([]))])
  let assert Ok(Nil) = process.receive(polls, 1500)
  // A later discovery timeout must not discard the previously known target.
  let assert Ok(#(blocked, _)) = process.receive(discoveries, 2000)
  let assert Ok(Nil) = process.receive(polls, 2000)
  stop(started.pid)
  process.kill(blocked)
  store.close(db)
}

pub fn main() -> Nil {
  discovery_timeout()
  io.println("Quota account discovery deadline and kept target cases passed")
}
