//// The usage profile against a model that buckets each hour into the
//// client's day by floor division, and against the window summary, which
//// reads the same hours by another query.

import albedo/storage/core_store
import albedo/usage/usage_hours
import albedo/usage/usage_profile
import albedo_sdk/store
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import proptest
import qcheck
import sqlight

const day = 86_400_000

const hour = 3_600_000

/// 2026-11-20T00:00Z.
const base_day = 20_412

pub type Hour {
  Hour(hour: Int, input: Int, output: Int, calls: Int)
}

pub type Turn {
  Turn(state: String, started: Int, ended: Option(Int))
}

pub type Case {
  Case(hours: List(Hour), turns: List(Turn), now: Int, offset_ms: Int)
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

/// Hours clustered near the present so runs of days form, with some in the
/// client's future (a clock set back) and some long ago.
fn hour_generator(span_days: Int) -> qcheck.Generator(Hour) {
  use #(slot, input, output), calls <- qcheck.map2(
    qcheck.tuple3(
      qcheck.from_weighted_generators(
        #(8, qcheck.bounded_int(-24 * span_days, 24)),
        [#(1, qcheck.bounded_int(24, 24 * 4)), #(1, qcheck.bounded_int(-24 * 400, 0))],
      ),
      qcheck.bounded_int(0, 500),
      qcheck.bounded_int(0, 500),
    ),
    qcheck.from_weighted_generators(#(9, qcheck.bounded_int(1, 3)), [#(1, qcheck.return(0))]),
  )
  case calls {
    0 -> Hour(slot, 0, 0, 0)
    _ -> Hour(slot, input, output, calls)
  }
}

fn turn_generator() -> qcheck.Generator(Turn) {
  use state, started, length, ended <- qcheck.map4(
    pick(["completed", "interrupted", "running"]),
    qcheck.bounded_int(0, 1_000_000),
    qcheck.bounded_int(-10, 100_000),
    qcheck.bool(),
  )
  Turn(state, started, case ended {
    True -> Some(started + length)
    False -> None
  })
}

fn case_generator() -> qcheck.Generator(Case) {
  use span <- qcheck.bind(pick([3, 10, 40]))
  use hours, turns, #(now_in_day, offset_minutes) <- qcheck.map3(
    qcheck.generic_list(hour_generator(span), qcheck.bounded_int(0, 30)),
    qcheck.generic_list(turn_generator(), qcheck.bounded_int(0, 4)),
    qcheck.tuple2(
      qcheck.bounded_int(0, day - 1),
      qcheck.from_weighted_generators(#(3, pick([-720, -480, -60, 0, 0, 60, 330, 345, 540, 840])), [
        #(1, qcheck.bounded_int(-720, 840)),
      ]),
    ),
  )
  Case(hours, turns, base_day * day + now_in_day, offset_minutes * 60_000)
}

fn floor_div(a: Int, b: Int) -> Int {
  let q = a / b
  case a % b < 0 {
    True -> q - 1
    False -> q
  }
}

fn hour_ms(h: Hour) -> Int {
  base_day * day + h.hour * hour
}

/// Days with use, oldest first: day number, tokens, calls.
fn model_days(c: Case) -> List(#(Int, Int, Int)) {
  list.fold(c.hours, dict.new(), fn(days, h) {
    let key = floor_div(hour_ms(h) + c.offset_ms, day)
    let #(tokens, calls) = dict.get(days, key) |> option.from_result |> option.unwrap(#(0, 0))
    dict.insert(days, key, #(tokens + h.input + h.output, calls + h.calls))
  })
  |> dict.to_list
  |> list.filter(fn(entry) { { entry.1 }.1 > 0 })
  |> list.map(fn(entry) { #(entry.0, { entry.1 }.0, { entry.1 }.1) })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
}

/// The length of the run of active days ending at `last`.
fn run_ending(active: List(Int), last: Int) -> Int {
  case list.contains(active, last) {
    True -> 1 + run_ending(active, last - 1)
    False -> 0
  }
}

pub fn model(c: Case) -> usage_profile.Profile {
  let days = model_days(c)
  let active = list.map(days, fn(d) { d.0 })
  let today = floor_div(c.now + c.offset_ms, day)
  let start = fn(d) { d * day - c.offset_ms }
  let peak =
    list.fold(days, None, fn(best, d) {
      case best {
        Some(#(_, tokens)) if tokens >= d.1 -> best
        _ if d.1 > 0 -> Some(#(d.0, d.1))
        _ -> best
      }
    })
  let current = case list.contains(active, today) {
    True -> run_ending(active, today)
    False -> run_ending(active, today - 1)
  }
  let longest_turn =
    c.turns
    |> list.filter_map(fn(t) {
      case t.state, t.ended {
        "completed", Some(ended) -> Ok(ended - t.started)
        _, _ -> Error(Nil)
      }
    })
    |> list.max(int.compare)
    |> option.from_result
  usage_profile.Profile(
    lifetime_tokens: list.fold(days, 0, fn(sum, d) { sum + d.1 }),
    lifetime_calls: list.fold(days, 0, fn(sum, d) { sum + d.2 }),
    active_days: list.length(days),
    first_day_ms: list.first(active) |> option.from_result |> option.map(start),
    peak_day_ms: option.map(peak, fn(p) { start(p.0) }),
    peak_day_tokens: option.map(peak, fn(p) { p.1 }) |> option.unwrap(0),
    longest_streak_days: list.map(active, fn(d) { run_ending(active, d) }) |> list.fold(0, int.max),
    current_streak_days: current,
    longest_turn_ms: longest_turn,
  )
}

fn with_ledger(c: Case, body: fn(store.Store) -> a) -> a {
  let assert Ok(ledger) =
    store.start(
      ":memory:",
      usage_hours.schema
        <> "CREATE TABLE input_turns(id TEXT PRIMARY KEY,session TEXT NOT NULL,state TEXT NOT NULL,started_at INTEGER NOT NULL,ended_at INTEGER);",
      core_store.tables(),
    )
  list.index_map(c.hours, fn(h, i) {
    let assert Ok(_) =
      store.write(
        ledger,
        "INSERT INTO usage_hours VALUES(?,'p','prov','',?,'turn',?,0,?,0,0,?,0)",
        [
          sqlight.int(hour_ms(h)),
          sqlight.text("m" <> int.to_string(i)),
          sqlight.int(h.calls),
          sqlight.int(h.input),
          sqlight.int(h.output),
        ],
      )
    Nil
  })
  list.index_map(c.turns, fn(t, i) {
    let assert Ok(_) =
      store.write(ledger, "INSERT INTO input_turns VALUES(?,'s',?,?,?)", [
        sqlight.text(int.to_string(i)),
        sqlight.text(t.state),
        sqlight.int(t.started),
        sqlight.nullable(sqlight.int, t.ended),
      ])
    Nil
  })
  let found = body(ledger)
  store.close(ledger)
  found
}

pub fn main() -> Nil {
  proptest.check("profile matches the day-bucketing model", 30, case_generator(), fn(c) {
    let found = with_ledger(c, usage_profile.read(_, c.now, c.offset_ms))
    let expected = model(c)
    let today = floor_div(c.now + c.offset_ms, day)
    let days = model_days(c)
    proptest.bump(case list.any(days, fn(d) { d.0 > today }) {
      True -> "future_day"
      False -> "no_future_day"
    })
    proptest.bump("current_streak_" <> int.to_string(int.min(expected.current_streak_days, 3)))
    proptest.bump("longest_streak_" <> int.to_string(int.min(expected.longest_streak_days, 5)))
    case found == Ok(expected) {
      True -> Nil
      False ->
        panic as {
          "profile differs from the model: expected "
          <> string.inspect(expected)
          <> ", found "
          <> string.inspect(found)
        }
    }
  })

  proptest.check("profile agrees with a whole-history window summary", 30, case_generator(), fn(c) {
    // Only hours the window can show: none in the client's future and none
    // older than its 371 days.
    let today = floor_div(c.now + c.offset_ms, day)
    let c =
      Case(
        ..c,
        hours: list.filter(c.hours, fn(h) {
          let d = floor_div(hour_ms(h) + c.offset_ms, day)
          d <= today && d > today - 371
        }),
      )
    let #(profile, summary) =
      with_ledger(c, fn(ledger) {
        #(
          usage_profile.read(ledger, c.now, c.offset_ms),
          usage_hours.summary(ledger, c.now, 371, c.offset_ms, usage_hours.AllScopes),
        )
      })
    let assert Ok(profile) = profile
    let assert Ok(summary) = summary
    let used = list.filter(summary.days, fn(d) { d.total.calls > 0 })
    assert profile.lifetime_tokens
      == list.fold(used, 0, fn(sum, d) { sum + d.total.input_tokens + d.total.output_tokens })
    assert profile.lifetime_calls == list.fold(used, 0, fn(sum, d) { sum + d.total.calls })
    assert profile.active_days == list.length(used)
    assert profile.first_day_ms == list.first(used) |> option.from_result |> option.map(fn(d) { d.start_ms })
    Nil
  })
}
