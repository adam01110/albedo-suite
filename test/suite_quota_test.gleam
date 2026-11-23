import albedo/accounts/quota
import albedo/accounts/quota_schedule
import albedo_clock as clock
import albedo_ext_zed/quota as zed_quota
import albedo_sdk/key_environment
import albedo_sdk/store
import albedo_sdk/usage_feed
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import sqlight
import suite_quota_fixtures.{database, sources, stop}

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

// ---- the Zed account reading -------------------------------------------

/// The credential the poller hands a Zed account: its stored access token and
/// the legacy user id the endpoint pairs with it.
fn zed_credential() -> json.Json {
  json.object([
    #("kind", json.string("oauth")),
    #("access", json.string("access-token")),
    #("accountId", json.string("42")),
  ])
}

/// Zed's own account payload, nested the way the service nests it.
fn zed_body(used: json.Json, limit: json.Json) -> String {
  json.object([
    #(
      "plan",
      json.object([
        #(
          "usage",
          json.object([
            #(
              "edit_predictions",
              json.object([#("used", used), #("limit", limit)]),
            ),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string
}

fn zed_reads(body: String) -> fn(json.Json) -> Result(#(Int, String), String) {
  fn(_) { Ok(#(200, body)) }
}

fn zed_status(status: Int) -> fn(json.Json) -> Result(#(Int, String), String) {
  fn(_) { Ok(#(status, "")) }
}

fn read_zed(body: String) -> usage_feed.Report {
  let assert Ok(report) =
    zed_quota.fetch_with(zed_credential(), zed_reads(body))
  report
}

fn read_zed_status(status: Int) -> usage_feed.Report {
  let assert Ok(report) =
    zed_quota.fetch_with(zed_credential(), zed_status(status))
  report
}

fn zed_readings() -> Nil {
  // A count against a numeric limit is that share of the limit, and nothing
  // else is claimed: no window, no reset, no plan.
  let counted = read_zed(zed_body(json.int(30), json.string("120")))
  assert counted.error == None
  assert counted.plan == None
  let assert [limit] = counted.limits
  assert limit.id == "edit-predictions"
  assert limit.label == "Edit predictions"
  assert limit.used_percent == Some(25.0)
  assert limit.window_label == None
  assert limit.window_seconds == None
  assert limit.resets_at == None
  assert limit.status == "ok"
  let assert Some(scope) = limit.scope
  assert string.contains(scope, "edit-prediction")

  // Over its limit stays the raw percentage; a reading is never clamped or
  // turned into a remaining budget.
  let assert [over] = read_zed(zed_body(json.int(60), json.string("40"))).limits
  assert over.used_percent == Some(150.0)

  // "unlimited" is an answer, not a full bar: no percentage is invented.
  let unlimited = read_zed(zed_body(json.int(7), json.string("unlimited")))
  assert unlimited.error == None
  let assert [open] = unlimited.limits
  assert open.used_percent == None
  assert open.status == "unlimited"
  assert open.resets_at == None
  assert open.window_seconds == None

  // A payload without the reading, or with a count that has no usable limit,
  // reports an error instead of a zero reading.
  let cases = [
    #("a payload without the reading", "{}"),
    #("a reading without a count", zed_body(json.null(), json.string("120"))),
    #("a reading without a limit", zed_body(json.int(3), json.null())),
    #("a zero limit", zed_body(json.int(3), json.string("0"))),
    #("a negative count", zed_body(json.int(-1), json.string("120"))),
    #("an unreadable limit", zed_body(json.int(3), json.string("some"))),
    #("no JSON at all", "<html>"),
  ]
  list.each(cases, fn(entry) {
    let report = read_zed(entry.1)
    assert report.limits == []
    assert report.error != None
  })

  // A count no percentage can be computed from is no reading either: it is
  // past what a float holds, so converting it would crash the worker instead
  // of answering with the account's failure.
  let enormous = list.fold(list.repeat(10, 400), 1, fn(acc, _) { acc * 10 })
  list.each(
    [
      #(
        "a count beyond a float",
        zed_body(json.int(enormous), json.string("120")),
      ),
      #("a limit beyond a float", zed_body(json.int(3), json.int(enormous))),
    ],
    fn(entry) {
      let report = read_zed(entry.1)
      assert report.limits == []
      assert report.error != None
    },
  )

  // A rejected credential is a reading's failure, and says what to do about it.
  let expired = read_zed_status(401)
  assert expired.limits == []
  let assert Some(rejected) = expired.error
  assert string.contains(rejected, "HTTP 401")
  assert string.contains(rejected, "/login zed")
  assert read_zed_status(403).error != None
  let assert Some(redirect) = read_zed_status(302).error
  assert string.contains(redirect, "redirected")
  let assert Some(unavailable) = read_zed_status(503).error
  assert string.contains(unavailable, "HTTP 503")
}

/// Zed is the one provider read here rather than by the core, so the choice
/// itself is what this pins.
fn zed_feed_dispatch() -> Nil {
  let zed = usage_feed.Report(None, None, None, [], Some("zed reading"))
  let core = usage_feed.Report(None, None, None, [], Some("core reading"))
  let zed_feed: fn(json.Json) -> Result(usage_feed.Report, String) = fn(_) {
    Ok(zed)
  }
  let core_feed: quota.Fetch = fn(_, _, _) { Ok(core) }
  assert quota.feed("zed", zed_credential(), 0, zed_feed, core_feed) == Ok(zed)
  assert quota.feed("anthropic", zed_credential(), 0, zed_feed, core_feed)
    == Ok(core)
}

fn await_rows(db: store.Store, deadline: Int) -> List(quota.Sample) {
  case quota.latest(db) {
    Ok([]) -> {
      assert clock.monotonic_ms() < deadline as "the Zed reading was recorded"
      clock.sleep(10)
      await_rows(db, deadline)
    }
    Ok(rows) -> rows
    Error(message) -> panic as message
  }
}

/// /quota lists the Zed account as edit-prediction usage: the poller stores the
/// label, the percentage, and no window or reset the service never reported.
fn zed_poller() -> Nil {
  let db = database()
  let polls = process.new_subject()
  let body = zed_body(json.int(30), json.string("120"))
  let assert Ok(started) =
    quota.start_with(
      "fixture",
      db,
      fn(provider, credential, now) {
        let report =
          quota.feed(
            provider,
            credential,
            now,
            fn(credential) { zed_quota.fetch_with(credential, zed_reads(body)) },
            fn(_, _, _) { Error("the core has no Zed feed") },
          )
        process.send(polls, Nil)
        report
      },
      sources("zed", fn() { [#("okami", zed_credential())] }),
      key_environment.empty(),
      fn() { quota_schedule.Settings(600, 120, True) },
      1000,
    )
  let assert Ok(Nil) = process.receive(polls, 1500)
  let assert [sample] = await_rows(db, clock.monotonic_ms() + 1500)
  assert sample.provider == "zed"
  assert sample.account == "okami"
  assert sample.limit_id == "edit-predictions"
  assert sample.label == "Edit predictions"
  assert sample.used_percent == Some(25.0)
  assert sample.window_label == None
  assert sample.window_seconds == None
  assert sample.resets_at == None
  assert sample.error == None
  stop(started.pid)
  store.close(db)
}

fn scheduling() -> Nil {
  let settings = quota_schedule.Settings(600, 120, True)
  assert quota.next_delay(settings, 1000, 1000, False, [#(0, True)]) == 600_000
  assert quota.next_delay(settings, 1000, 0, True, [#(0, True)]) == 600_000
  assert quota.next_delay(settings, 1000, 0, True, [#(2000, False)]) == 1000
  assert quota.next_delay(settings, 1000, 0, True, [#(1000, False)]) == 250
}

pub fn main() -> Nil {
  projection()
  scheduling()
  zed_readings()
  zed_feed_dispatch()
  zed_poller()
  io.println("Quota projection, schedule and Zed account reading cases passed")
}
