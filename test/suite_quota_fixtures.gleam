import albedo/accounts/quota
import albedo/storage/core_store
import albedo_clock as clock
import albedo_sdk/store
import albedo_sdk/usage_feed
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string

// Setup shared by the modules the quota poller's deadline cases are split
// across, so each module still runs beside the others in its own VM.

pub fn database() -> store.Store {
  let assert Ok(db) = store.start(":memory:", "", core_store.tables())
  let assert Ok(Nil) = quota.initialise(db)
  db
}

/// One extension's quota source offering `accounts`, as the daemon composes
/// installed extensions' sources.
pub fn sources(
  provider: String,
  accounts: fn() -> List(#(String, json.Json)),
) -> List(#(String, usage_feed.Source)) {
  [#(provider, usage_feed.accounts_source(provider, fn(_) { accounts() }))]
}

pub fn fixture() -> List(#(String, usage_feed.Source)) {
  sources("fixture", fn() { [#("account", json.object([]))] })
}

pub fn report() -> usage_feed.Report {
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

// ---- the Zed account reading -------------------------------------------

pub fn stop(pid: process.Pid) -> Nil {
  process.unlink(pid)
  process.kill(pid)
}

pub fn healthy_fetch(notify: process.Subject(Nil)) -> quota.Fetch {
  fn(_, _, _) {
    process.send(notify, Nil)
    Ok(report())
  }
}

pub fn await_error(db: store.Store, expected: String, deadline: Int) -> Nil {
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
