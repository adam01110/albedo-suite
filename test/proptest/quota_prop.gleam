//// The quota readings against a model of what the poller stores and what the
//// projection should answer: report sequences per account and provider are
//// recorded exactly as `record` writes them (one row per limit, or one row
//// carrying the report's error), then `latest` must answer with exactly the
//// newest report's readings per account and provider, and `history` must page
//// the same rows back newest-first without loss, duplication or reordering.
//// Timestamps are distinct and monotone, so no case depends on a tie.
////
//// The Zed account reading is checked against the documented payload shape: a
//// count against a positive numeric limit is that share, "unlimited" is an
//// answer without a percentage, and every other payload is a report error
//// rather than a crash or an invented zero. The schedule's arithmetic is
//// checked against the documented cadence rules: the busy cadence while a
//// limit is at or above 80 percent, doubling backoff after failures capped at
//// an hour, and a tick that never fires early or later than the cadence.

import albedo/accounts/quota
import albedo/accounts/quota_schedule
import albedo/storage/core_store
import albedo_ext_zed/quota as zed_quota
import albedo_protect
import albedo_sdk/store
import albedo_sdk/usage_feed
import albedo_sqlite
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import proptest
import qcheck
import sqlight

// ---- report sequences ---------------------------------------------------

/// One limit a report carried.
pub type Meter {
  Meter(id: String, percent: Option(Float))
}

/// One poll of one account: what the feed answered, at one instant.
pub type Poll {
  Poll(
    account: String,
    provider: String,
    at: Int,
    meters: List(Meter),
    failed: Bool,
  )
}

pub type Case {
  Case(polls: List(Poll), page: Int, since: Option(Int))
}

/// One stored row, as the poller writes it.
type Row {
  Row(
    account: String,
    provider: String,
    limit_id: String,
    percent: Option(Float),
    error: Option(String),
    observed_at: Int,
  )
}

type Shape =
  #(String, String, String, Option(Float), Option(String), Int)

const today = 1_700_000_000_000

/// Every row a case's polls write, in insert order.
fn stored(polls: List(Poll)) -> List(Row) {
  list.flat_map(polls, fn(poll) {
    let error = error_of(poll.failed)
    case poll.meters {
      [] -> [Row(poll.account, poll.provider, "", None, error, poll.at)]
      _ ->
        list.map(poll.meters, fn(meter) {
          Row(
            poll.account,
            poll.provider,
            meter.id,
            meter.percent,
            error,
            poll.at,
          )
        })
    }
  })
}

fn error_of(failed: Bool) -> Option(String) {
  case failed {
    True -> Some("the feed failed")
    False -> None
  }
}

/// The newest report per account and provider; everything before it is
/// history, not the current reading. Order is not part of the contract, so
/// both sides are compared by key.
fn current(polls: List(Poll)) -> List(Row) {
  let newest =
    list.fold(polls, [], fn(kept: List(Poll), poll: Poll) {
      list.filter(kept, fn(earlier) {
        earlier.account != poll.account || earlier.provider != poll.provider
      })
      |> list.append([poll])
    })
  stored(newest)
}

fn key(shape: Shape) -> #(String, String, String) {
  #(shape.0, shape.1, shape.2)
}

fn by_key(shapes: List(Shape)) -> dict.Dict(#(String, String, String), Shape) {
  dict.from_list(list.map(shapes, fn(shape) { #(key(shape), shape) }))
}

fn shape(row: Row) -> Shape {
  #(
    row.account,
    row.provider,
    row.limit_id,
    row.percent,
    row.error,
    row.observed_at,
  )
}

fn sample_shape(sample: quota.Sample) -> Shape {
  #(
    sample.account,
    sample.provider,
    sample.limit_id,
    sample.used_percent,
    sample.error,
    sample.observed_at,
  )
}

// ---- generators ---------------------------------------------------------

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

const meter_ids = ["5h", "weekly", "opus"]

fn percent() -> qcheck.Generator(Option(Float)) {
  qcheck.from_weighted_generators(
    #(12, qcheck.bounded_float(0.0, 100.0) |> qcheck.map(Some)),
    [
      #(
        2,
        pick([0.0, 1.0, 25.0, 79.999, 80.0, 100.0, 150.5]) |> qcheck.map(Some),
      ),
      #(2, qcheck.return(None)),
    ],
  )
}

/// Which of the account's limits one report carried: usually some, sometimes
/// none, so a report can drop a limit or stop answering.
fn meters() -> qcheck.Generator(List(Meter)) {
  use rolls, percents <- qcheck.map2(
    qcheck.fixed_length_list_from(qcheck.bounded_int(0, 2), 3),
    qcheck.fixed_length_list_from(percent(), 3),
  )
  list.zip(rolls, list.zip(meter_ids, percents))
  |> list.filter_map(fn(entry) {
    case entry.0 {
      0 -> Error(Nil)
      _ -> Ok(Meter(entry.1.0, entry.1.1))
    }
  })
}

fn poll_entry() -> qcheck.Generator(#(String, String, List(Meter), Bool)) {
  qcheck.map4(
    pick(["a", "b", "c"]),
    pick(["p", "q"]),
    meters(),
    qcheck.from_weighted_generators(#(4, qcheck.return(False)), [
      #(1, qcheck.return(True)),
    ]),
    fn(account, provider, meters, failed) {
      #(account, provider, meters, failed)
    },
  )
}

fn case_generator() -> qcheck.Generator(Case) {
  use entries, page, since <- qcheck.map3(
    qcheck.generic_list(poll_entry(), qcheck.bounded_int(0, 24)),
    qcheck.bounded_int(1, 5),
    qcheck.map2(
      qcheck.from_weighted_generators(#(1, qcheck.return(False)), [
        #(3, qcheck.return(True)),
      ]),
      qcheck.bounded_int(0, 24),
      fn(present, offset) {
        case present {
          True -> Some(today + offset * 1000)
          False -> None
        }
      },
    ),
  )
  // Distinct, monotone milliseconds: one report per instant, in order.
  Case(
    list.index_map(entries, fn(entry, index) {
      Poll(entry.0, entry.1, today + index * 1000, entry.2, entry.3)
    }),
    page,
    since,
  )
}

// ---- the database -------------------------------------------------------

fn database() -> store.Store {
  let assert Ok(db) =
    store.start(":memory:", fn(_) { Ok(Nil) }, core_store.tables())
  let assert Ok(Nil) = quota.initialise(db)
  db
}

fn clear(db: store.Store) -> Nil {
  let assert Ok(_) =
    store.query(db, fn(connection) {
      albedo_sqlite.run("DELETE FROM quota_sample", on: connection, with: [])
    })
  Nil
}

fn insert(db: store.Store, row: Row) -> Nil {
  let assert Ok(_) =
    store.query(db, fn(connection) {
      albedo_sqlite.run(
        "INSERT INTO quota_sample(account, provider, plan, limit_id, label, used_percent, window_label, window_seconds, resets_at, scope, status, error, observed_at, source)
         VALUES (?, ?, NULL, ?, ?, ?, NULL, NULL, NULL, NULL, 'ok', ?, ?, 'poll')",
        on: connection,
        with: [
          sqlight.text(row.account),
          sqlight.text(row.provider),
          sqlight.text(row.limit_id),
          sqlight.text(row.limit_id),
          sqlight.nullable(sqlight.float, row.percent),
          sqlight.nullable(sqlight.text, row.error),
          sqlight.int(row.observed_at),
        ],
      )
    })
  Nil
}

fn load(db: store.Store, polls: List(Poll)) -> List(Row) {
  clear(db)
  let rows = stored(polls)
  list.each(rows, fn(row) { insert(db, row) })
  rows
}

// ---- the projections ----------------------------------------------------

fn projection(db: store.Store, scenario: Case) -> Nil {
  load(db, scenario.polls)
  let assert Ok(actual) = quota.latest(db)
  let got = list.map(actual, sample_shape)
  let want = list.map(current(scenario.polls), shape)
  assert list.length(got) == list.length(want)
  assert by_key(got) == by_key(want)
  proptest.bump("reports=" <> int.to_string(list.length(scenario.polls)))
}

fn paging(db: store.Store, scenario: Case) -> Nil {
  let rows = load(db, scenario.polls)
  let newest_first = list.reverse(list.map(rows, shape))
  assert pages(db, 0, scenario.page, []) == newest_first
  proptest.bump("paged")
}

fn pages(
  db: store.Store,
  before: Int,
  size: Int,
  acc: List(Shape),
) -> List(Shape) {
  let assert Ok(page) = quota.history(db, quota.Everything, before, size)
  case page {
    [] -> list.reverse(acc)
    _ -> {
      let assert Ok(last) = list.last(page)
      // Paging must move backwards through the ids, or a page repeats forever.
      assert last.id < before || before == 0
      pages(
        db,
        last.id,
        size,
        list.reverse(list.map(page, sample_shape)) |> list.append(acc),
      )
    }
  }
}

/// A limit's own trail: its rows newest-first, and only those from `since`
/// on when one is asked for.
fn trail(db: store.Store, scenario: Case) -> Nil {
  let rows = load(db, scenario.polls)
  case rows {
    [] -> Nil
    [first, ..] -> trail_of(db, rows, first, scenario.since)
  }
}

fn trail_of(
  db: store.Store,
  rows: List(Row),
  first: Row,
  since: Option(Int),
) -> Nil {
  let filter = quota.Trail(first.provider, first.account, first.limit_id, since)
  let since = unwrap_since(since)
  let expected =
    rows
    |> list.filter(fn(row) {
      row.account == first.account
      && row.provider == first.provider
      && row.limit_id == first.limit_id
      && row.observed_at >= since
    })
    |> list.reverse
    |> list.map(shape)
  let assert Ok(actual) = quota.history(db, filter, 0, 100)
  assert list.map(actual, sample_shape) == expected
  proptest.bump("trail")
}

fn unwrap_since(since: Option(Int)) -> Int {
  case since {
    Some(value) -> value
    None -> 0
  }
}

// ---- the schedule -------------------------------------------------------

pub type Schedule {
  Schedule(poll_seconds: Int, busy_poll_seconds: Int, failures: Int, busy: Bool)
}

fn schedule() -> qcheck.Generator(Schedule) {
  // Intervals around the default, where the backoff is observable below its
  // hour cap, plus long ones where the cap saturates it.
  qcheck.map4(
    qcheck.from_weighted_generators(#(8, qcheck.bounded_int(1, 600)), [
      #(2, qcheck.bounded_int(1, 86_400)),
    ]),
    qcheck.from_weighted_generators(#(8, qcheck.bounded_int(1, 600)), [
      #(2, qcheck.bounded_int(1, 86_400)),
    ]),
    qcheck.bounded_int(0, 12),
    qcheck.bool(),
    Schedule,
  )
}

/// The documented cadence: the busy poll at once while busy, the ordinary
/// poll otherwise, and after any failure a backoff that doubles per failure
/// up to six doublings and never passes an hour.
fn wait_seconds(scenario: Schedule) -> Nil {
  let settings =
    quota_schedule.Settings(
      scenario.poll_seconds,
      int.min(scenario.busy_poll_seconds, scenario.poll_seconds),
      True,
    )
  let wait = quota.wait_seconds(settings, scenario.failures, scenario.busy)
  // The documented cadence: the busy poll at once while busy, the ordinary
  // poll otherwise, and after a failure a backoff that doubles per failure
  // up to six doublings and never waits past an hour.
  let expected = case scenario.failures {
    0 ->
      case scenario.busy {
        True -> settings.busy_poll_seconds
        False -> settings.poll_seconds
      }
    failures ->
      int.min(settings.poll_seconds * pow2(int.min(failures, 6)), 3600)
  }
  assert wait == expected
  assert wait >= 1
  proptest.bump(case scenario.failures {
    0 -> "cadence"
    _ -> "backoff"
  })
  // Only the backoff is capped at an hour; the ordinary cadence may be longer.
  case scenario.failures {
    0 -> Nil
    _ -> {
      assert wait <= 3600
      Nil
    }
  }
  proptest.bump("wait")
}

fn pow2(times: Int) -> Int {
  case times {
    0 -> 1
    _ -> 2 * pow2(times - 1)
  }
}

pub type Deadlines {
  Deadlines(
    settings: quota.Settings,
    now: Int,
    last_enumerated: Int,
    enumerating: Bool,
    accounts: List(#(Int, Bool)),
  )
}

fn deadlines() -> qcheck.Generator(Deadlines) {
  use times, enumerating, accounts <- qcheck.map3(
    qcheck.tuple3(
      qcheck.bounded_int(1, 3600),
      qcheck.bounded_int(0, 10_000_000),
      qcheck.bounded_int(0, 10_000_000),
    ),
    qcheck.bool(),
    qcheck.generic_list(
      qcheck.tuple2(qcheck.bounded_int(0, 10_000_000), qcheck.bool()),
      qcheck.bounded_int(0, 4),
    ),
  )
  Deadlines(
    quota_schedule.Settings(times.0, int.min(60, times.0), True),
    times.1,
    times.2,
    enumerating,
    accounts,
  )
}

/// The tick never comes sooner than a quarter second or later than the whole
/// poll interval, and lands on the soonest deadline the poller is waiting for:
/// a poll-free account's next due time, and the next discovery unless one is
/// already running.
fn tick(scenario: Deadlines) -> Nil {
  let delay =
    quota.next_delay(
      scenario.settings,
      scenario.now,
      scenario.last_enumerated,
      scenario.enumerating,
      scenario.accounts,
    )
  assert delay >= 250
  assert delay <= scenario.settings.poll_seconds * 1000
  let idle =
    list.filter_map(scenario.accounts, fn(account) {
      case account.1 {
        True -> Error(Nil)
        False -> Ok(account.0)
      }
    })
  let discovery = case scenario.enumerating {
    True -> []
    False -> [scenario.last_enumerated + scenario.settings.poll_seconds * 1000]
  }
  let expected = case soonest(list.append(idle, discovery)) {
    None -> scenario.settings.poll_seconds * 1000
    Some(when) ->
      int.max(
        250,
        int.min(when - scenario.now, scenario.settings.poll_seconds * 1000),
      )
  }
  assert delay == expected
  proptest.bump("tick")
}

fn soonest(values: List(Int)) -> Option(Int) {
  case values {
    [] -> None
    [first, ..rest] ->
      Some(list.fold(rest, first, fn(best, value) { int.min(best, value) }))
  }
}

// ---- the Zed reading ----------------------------------------------------

pub type Used {
  Amount(Int)
  AmountNull
  AmountText(String)
  AmountFloat
  AmountMissing
}

pub type Cap {
  Count(Int)
  CountText(String)
  CapNull
  CapFloat
  CapMissing
}

pub type Outcome {
  Counted(used: Int, limit: Int)
  Unlimited
  Refused
}

pub type ZedCase {
  ZedCase(used: Used, cap: Cap, shaped: Bool, body: String)
}

/// The credential the poller hands a Zed account.
fn credential() -> json.Json {
  json.object([
    #("kind", json.string("oauth")),
    #("access", json.string("access-token")),
    #("accountId", json.string("42")),
  ])
}

fn used_generator() -> qcheck.Generator(Used) {
  qcheck.from_weighted_generators(
    #(10, qcheck.bounded_int(0, 500) |> qcheck.map(Amount)),
    [
      #(1, qcheck.return(Amount(-1))),
      #(1, qcheck.return(Amount(0))),
      #(1, qcheck.return(AmountNull)),
      #(
        1,
        qcheck.bounded_int(0, 500)
          |> qcheck.map(int.to_string)
          |> qcheck.map(AmountText),
      ),
      #(1, qcheck.return(AmountFloat)),
      #(1, qcheck.return(AmountMissing)),
    ],
  )
}

fn cap_generator() -> qcheck.Generator(Cap) {
  qcheck.from_weighted_generators(
    #(8, qcheck.bounded_int(1, 500) |> qcheck.map(Count)),
    [
      #(
        2,
        qcheck.bounded_int(1, 500)
          |> qcheck.map(int.to_string)
          |> qcheck.map(CountText),
      ),
      #(1, qcheck.return(CountText("unlimited"))),
      #(1, qcheck.return(CountText(" unlimited "))),
      #(1, qcheck.return(CountText("Unlimited"))),
      #(1, qcheck.return(CountText("some"))),
      #(1, qcheck.return(CountText(""))),
      #(1, qcheck.return(Count(0))),
      #(1, qcheck.return(Count(-5))),
      #(1, qcheck.return(CapNull)),
      #(1, qcheck.return(CapFloat)),
      #(1, qcheck.return(CapMissing)),
    ],
  )
}

fn used_fields(used: Used) -> List(#(String, json.Json)) {
  case used {
    Amount(value) -> [#("used", json.int(value))]
    AmountNull -> [#("used", json.null())]
    AmountText(value) -> [#("used", json.string(value))]
    AmountFloat -> [#("used", json.float(1.5))]
    AmountMissing -> []
  }
}

fn cap_fields(cap: Cap) -> List(#(String, json.Json)) {
  case cap {
    Count(value) -> [#("limit", json.int(value))]
    CountText(value) -> [#("limit", json.string(value))]
    CapNull -> [#("limit", json.null())]
    CapFloat -> [#("limit", json.float(120.5))]
    CapMissing -> []
  }
}

/// The payload Zed's identity endpoint answers, nested the way the service
/// nests it; a false `shaped` drops the reading, and a bootstrap body is not
/// JSON at all.
fn body(used: Used, cap: Cap, shaped: Bool, kind: String) -> String {
  case kind {
    "json-null" -> "null"
    "json-list" -> "[]"
    "html" -> "<html>not json"
    _ ->
      case shaped {
        False -> json.object([#("plan", json.object([]))]) |> json.to_string
        True ->
          json.object([
            #(
              "plan",
              json.object([
                #(
                  "usage",
                  json.object([
                    #(
                      "edit_predictions",
                      json.object(list.append(
                        used_fields(used),
                        cap_fields(cap),
                      )),
                    ),
                  ]),
                ),
              ]),
            ),
          ])
          |> json.to_string
      }
  }
}

fn zed_case() -> qcheck.Generator(ZedCase) {
  use used, cap, shaped, kind <- qcheck.map4(
    used_generator(),
    cap_generator(),
    qcheck.from_weighted_generators(#(9, qcheck.return(True)), [
      #(1, qcheck.return(False)),
    ]),
    pick(["full", "full", "full", "json-null", "json-list", "html"]),
  )
  ZedCase(used, cap, shaped && kind == "full", body(used, cap, shaped, kind))
}

/// What the documented shape says the reading is: a count within a positive
/// limit is that share, "unlimited" is an answer, and anything else is no
/// reading at all.
fn expected(used: Used, cap: Cap, shaped: Bool) -> Outcome {
  case shaped, used {
    False, _ -> Refused
    // The reading is a count of predictions even when the plan is unlimited.
    _, Amount(_) ->
      case cap {
        CountText(text) ->
          case string.trim(text) {
            "unlimited" -> Unlimited
            count ->
              case int.parse(count) {
                Ok(limit) -> counted(used, limit)
                Error(_) -> Refused
              }
          }
        Count(limit) -> counted(used, limit)
        _ -> Refused
      }
    _, _ -> Refused
  }
}

fn counted(used: Used, limit: Int) -> Outcome {
  case used {
    Amount(value) if value >= 0 && limit > 0 -> Counted(value, limit)
    _ -> Refused
  }
}

fn read_zed(zed: ZedCase) -> usage_feed.Report {
  let assert Ok(report) =
    zed_quota.fetch_with(credential(), fn(_) { Ok(#(200, zed.body)) })
  report
}

fn zed_reading(db: store.Store, zed: ZedCase) -> Nil {
  let report = read_zed(zed)
  assert report.plan == None
  assert report.account_id == None
  assert report.email == None
  case expected(zed.used, zed.cap, zed.shaped) {
    Counted(used, limit) -> {
      assert report.error == None
      let assert [row] = report.limits
      assert row.id == "edit-predictions"
      assert row.label == "Edit predictions"
      assert row.status == "ok"
      assert row.used_percent
        == Some(int.to_float(used) *. 100.0 /. int.to_float(limit))
      assert row.window_label == None
      assert row.window_seconds == None
      assert row.resets_at == None
      assert row.scope != None
    }
    Unlimited -> {
      assert report.error == None
      let assert [row] = report.limits
      assert row.status == "unlimited"
      assert row.used_percent == None
      assert row.resets_at == None
      assert row.window_seconds == None
    }
    Refused -> {
      assert report.limits == []
      assert report.error != None
    }
  }
  proptest.bump("zed")
  let _ = db
  Nil
}

// ---- RFC3339 stamps -----------------------------------------------------

pub type Stamp {
  Stamp(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    second: Int,
    millis: Int,
    offset_minutes: Int,
  )
}

fn pad2(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}

fn pad3(value: Int) -> String {
  case value < 10 {
    True -> "00" <> int.to_string(value)
    False ->
      case value < 100 {
        True -> "0" <> int.to_string(value)
        False -> int.to_string(value)
      }
  }
}

fn stamp_generator() -> qcheck.Generator(Stamp) {
  use date, clock, fraction <- qcheck.map3(
    qcheck.tuple3(
      qcheck.bounded_int(1970, 2100),
      qcheck.bounded_int(1, 12),
      qcheck.bounded_int(1, 28),
    ),
    qcheck.tuple3(
      qcheck.bounded_int(0, 23),
      qcheck.bounded_int(0, 59),
      qcheck.bounded_int(0, 59),
    ),
    qcheck.tuple2(
      qcheck.bounded_int(0, 999),
      qcheck.from_weighted_generators(#(6, qcheck.return(0)), [
        #(1, qcheck.bounded_int(-720, 840)),
      ]),
    ),
  )
  Stamp(
    date.0,
    date.1,
    date.2,
    clock.0,
    clock.1,
    clock.2,
    fraction.0,
    fraction.1,
  )
}

fn stamp_text(stamp: Stamp) -> String {
  let fraction = case stamp.millis {
    0 -> ""
    millis -> "." <> pad3(millis)
  }
  let zone = case stamp.offset_minutes {
    0 -> "Z"
    minutes if minutes > 0 ->
      "+" <> pad2(minutes / 60) <> ":" <> pad2(minutes % 60)
    minutes -> "-" <> pad2(-minutes / 60) <> ":" <> pad2(-minutes % 60)
  }
  int.to_string(stamp.year)
  <> "-"
  <> pad2(stamp.month)
  <> "-"
  <> pad2(stamp.day)
  <> "T"
  <> pad2(stamp.hour)
  <> ":"
  <> pad2(stamp.minute)
  <> ":"
  <> pad2(stamp.second)
  <> fraction
  <> zone
}

/// Days from 1970-01-01 to a civil date by the Gregorian calendar's own rules.
fn days_from_civil(year: Int, month: Int, day: Int) -> Int {
  let adjusted_year = case month <= 2 {
    True -> year - 1
    False -> year
  }
  let era = case adjusted_year >= 0 {
    True -> adjusted_year / 400
    False -> { adjusted_year - 399 } / 400
  }
  let year_of_era = adjusted_year - era * 400
  let shifted_month = case month > 2 {
    True -> month - 3
    False -> month + 9
  }
  let day_of_year = { 153 * shifted_month + 2 } / 5 + day - 1
  let day_of_era =
    year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
  era * 146_097 + day_of_era - 719_468
}

fn epoch_millis(stamp: Stamp) -> Int {
  days_from_civil(stamp.year, stamp.month, stamp.day)
  * 86_400_000
  + stamp.hour
  * 3_600_000
  + stamp.minute
  * 60_000
  + stamp.second
  * 1000
  + stamp.millis
  - stamp.offset_minutes
  * 60_000
}

fn rfc3339(stamp: Stamp) -> Nil {
  assert quota.parse_rfc3339(stamp_text(stamp)) == Ok(epoch_millis(stamp))
  proptest.bump("stamp")
}

/// Counts a percentage cannot be computed from: beyond what a float can hold.
pub type Extremes {
  Extremes(used: Int, limit: Int)
}

fn huge(times: Int) -> Int {
  list.fold(list.repeat(10, times), 1, fn(acc, _) { acc * 10 })
}

fn extremes() -> qcheck.Generator(Extremes) {
  // Past 1e308 a count is beyond any Erlang float, so no percentage exists.
  use used, limit <- qcheck.map2(
    qcheck.from_weighted_generators(#(2, qcheck.return(huge(309))), [
      #(2, qcheck.return(huge(400))),
    ]),
    qcheck.from_weighted_generators(#(2, qcheck.return(huge(309))), [
      #(2, qcheck.return(huge(400))),
    ]),
  )
  Extremes(used, limit)
}

/// A count that cannot be turned into a percentage is no reading, like any
/// other count that is not within a positive limit: a report error, never a
/// crash out of the parser.
fn extreme_reading(db: store.Store, extremes: Extremes) -> Nil {
  let body =
    json.object([
      #(
        "plan",
        json.object([
          #(
            "usage",
            json.object([
              #(
                "edit_predictions",
                json.object([
                  #("used", json.int(extremes.used)),
                  #("limit", json.int(extremes.limit)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ])
    |> json.to_string
  let outcome =
    albedo_protect.rescue(fn() {
      zed_quota.fetch_with(credential(), fn(_) { Ok(#(200, body)) })
    })
  // A crash prints as the report the rescue caught, with the payload beside it.
  let assert Ok(Ok(report)) = outcome
  assert report.limits == []
  assert report.error != None
  proptest.bump("extremes")
  let _ = db
  Nil
}

pub fn main() -> Nil {
  proptest.check(
    "quota stamps: an RFC3339 stamp parses to the instant its fields name",
    80,
    stamp_generator(),
    rfc3339,
  )
  let db = database()
  proptest.check(
    "quota projection: latest is exactly the newest report per account and provider",
    100,
    case_generator(),
    fn(scenario) { projection(db, scenario) },
  )
  proptest.check(
    "quota history: keyset paging loses, repeats and reorders nothing",
    100,
    case_generator(),
    fn(scenario) { paging(db, scenario) },
  )
  proptest.check(
    "quota history: a limit's trail is its own rows from since on",
    100,
    case_generator(),
    fn(scenario) { trail(db, scenario) },
  )
  store.close(db)
  proptest.check(
    "quota schedule: the failure backoff doubles up to an hour",
    60,
    schedule(),
    fn(scenario) { wait_seconds(scenario) },
  )
  proptest.check(
    "quota schedule: the tick lands on the soonest deadline, between 250ms and one poll",
    60,
    deadlines(),
    fn(scenario) { tick(scenario) },
  )
  proptest.check(
    "zed quota: the reading follows the documented payload shape and never crashes",
    80,
    zed_case(),
    fn(zed) { zed_reading(db, zed) },
  )
  proptest.check(
    "zed quota: a count no percentage can be computed from is a report error",
    40,
    extremes(),
    fn(extremes) { extreme_reading(db, extremes) },
  )
}
