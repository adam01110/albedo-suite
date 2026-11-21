//// The usage profile and the window summary against exact arithmetic on the
//// counts a provider can report, including the ones near the int64 ceiling
//// where SQLite's SUM leaves the range of the INTEGER it adds.
////
//// The oracle is the BEAM's arbitrary-precision Int: the same fold with no
//// range at all. The profile must answer with the exact totals, each clamped
//// to the int64 range it reports (docs/usage-profile.md), and never refuse.
//// The window summary is upstream's: it is exact or refuses only where the
//// exact answer does not fit in an int64.

import albedo/storage/core_store
import albedo/usage/usage_hours
import albedo/usage/usage_profile
import albedo_sdk/store
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck
import sqlight

const day = 86_400_000

const hour = 3_600_000

/// The largest integer SQLite's INTEGER column and SUM() hold.
pub const int64_max = 9_223_372_036_854_775_807

/// 2026-11-20T00:00Z.
const base_day = 20_412

pub type Row {
  Row(hour: Int, input: Int, output: Int, calls: Int)
}

pub type Case {
  Case(rows: List(Row), now_in_day: Int, offset_ms: Int)
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

/// A token count from the classes that matter to a sum: nothing worth
/// recording, ordinary use, a very busy account's day, half the int64 range,
/// and the ceiling itself.
fn count_generator() -> qcheck.Generator(Int) {
  qcheck.from_weighted_generators(#(6, qcheck.bounded_int(0, 1000)), [
    #(2, qcheck.bounded_int(1_000_000_000, 2_000_000_000)),
    #(2, qcheck.bounded_int(0, int64_max - 8)),
    #(1, qcheck.map(qcheck.bounded_int(0, 8), fn(n) { int64_max / 2 + n })),
    #(1, qcheck.map(qcheck.bounded_int(0, 8), fn(n) { int64_max - n })),
  ])
}

/// The three counts of one hour, each drawn on its own.
fn counts_generator() -> qcheck.Generator(#(Int, Int, Int)) {
  use input, output, calls <- qcheck.map3(
    count_generator(),
    count_generator(),
    qcheck.from_weighted_generators(#(9, qcheck.bounded_int(1, 4)), [
      #(1, qcheck.bounded_int(0, 2)),
    ]),
  )
  #(input, output, calls)
}

fn case_generator() -> qcheck.Generator(Case) {
  let slots =
    qcheck.generic_list(qcheck.bounded_int(0, 60), qcheck.bounded_int(1, 6))
    |> qcheck.map(fn(slots) { slots |> list.unique |> list.sort(int.compare) })
  use slots <- qcheck.bind(slots)
  // One count for each hour, so a day folds several rows into one total.
  use counts <- qcheck.bind(
    qcheck.generic_list(counts_generator(), qcheck.return(list.length(slots))),
  )
  use #(now_in_day, offset_minutes) <- qcheck.bind(
    qcheck.tuple2(
      // Well after every hour above, so no row is a client day in the future.
      qcheck.bounded_int(3 * day, 4 * day - 1),
      pick([0, 0, 0, 180, -420, 330]),
    ),
  )
  qcheck.return(Case(
    list.zip(slots, counts)
      |> list.map(fn(entry) {
        let #(slot, #(input, output, calls)) = entry
        Row(slot * hour, input, output, calls)
      }),
    now_in_day,
    offset_minutes * 60_000,
  ))
}

fn floor_div(a: Int, b: Int) -> Int {
  let q = a / b
  case a % b < 0 {
    True -> q - 1
    False -> q
  }
}

fn row_ms(row: Row) -> Int {
  base_day * day + row.hour
}

fn now_ms(c: Case) -> Int {
  base_day * day + c.now_in_day
}

/// The exact totals of each day with use, oldest first, with no range at all.
fn model_days(c: Case) -> List(#(Int, Int, Int)) {
  list.fold(c.rows, dict.new(), fn(days, row) {
    let key = floor_div(row_ms(row) + c.offset_ms, day)
    let #(tokens, calls) =
      dict.get(days, key) |> option.from_result |> option.unwrap(#(0, 0))
    dict.insert(days, key, #(tokens + row.input + row.output, calls + row.calls))
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

/// The exact model with the totals the profile reports saturated at int64.
fn saturated(c: Case) -> usage_profile.Profile {
  let clamp = int.clamp(_, min: -int64_max - 1, max: int64_max)
  let exact = model(c)
  usage_profile.Profile(
    ..exact,
    lifetime_tokens: clamp(exact.lifetime_tokens),
    lifetime_calls: clamp(exact.lifetime_calls),
    peak_day_tokens: clamp(exact.peak_day_tokens),
    longest_turn_ms: option.map(exact.longest_turn_ms, clamp),
  )
}

fn model(c: Case) -> usage_profile.Profile {
  let days = model_days(c)
  let active = list.map(days, fn(d) { d.0 })
  let today = floor_div(now_ms(c) + c.offset_ms, day)
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
  usage_profile.Profile(
    lifetime_tokens: list.fold(days, 0, fn(sum, d) { sum + d.1 }),
    lifetime_calls: list.fold(days, 0, fn(sum, d) { sum + d.2 }),
    active_days: list.length(days),
    first_day_ms: list.first(days) |> result.map(fn(d) { start(d.0) }) |> option.from_result,
    peak_day_ms: option.map(peak, fn(p) { start(p.0) }),
    peak_day_tokens: option.map(peak, fn(p) { p.1 }) |> option.unwrap(0),
    longest_streak_days: list.map(active, fn(d) { run_ending(active, d) })
      |> list.fold(0, int.max),
    current_streak_days: current,
    longest_turn_ms: None,
  )
}

/// Whether every exact total either read computes fits in an int64: SQLite's
/// SUM() raises rather than wrap once the whole column's sum leaves it, and a
/// column holding a float leaves it for whoever decodes the rows.
fn fits(c: Case) -> Bool {
  let within = fn(n) { n >= -int64_max - 1 && n <= int64_max }
  let total = fn(get: fn(#(Int, Int, Int)) -> Int) {
    list.fold(model_days(c), 0, fn(sum, d) { sum + get(d) })
  }
  within(total(fn(d) { d.1 }))
  && within(total(fn(d) { d.2 }))
  && within(model(c).lifetime_tokens)
  && list.all(c.rows, fn(row) { within(row.input + row.output) })
}

fn with_ledger(c: Case, body: fn(store.Store) -> a) -> a {
  let assert Ok(ledger) =
    store.start(
      ":memory:",
      usage_hours.schema
        <> "CREATE TABLE input_turns(id TEXT PRIMARY KEY,session TEXT NOT NULL,state TEXT NOT NULL,started_at INTEGER NOT NULL,ended_at INTEGER);",
      core_store.tables(),
    )
  list.index_map(c.rows, fn(row, i) {
    let assert Ok(_) =
      store.write(
        ledger,
        "INSERT INTO usage_hours(hour_ms,profile,provider,account,model,kind,calls,errors,input_tokens,cached_input_tokens,cache_creation_tokens,output_tokens,reasoning_tokens) VALUES(?,'p','prov','',?,'turn',?,0,?,0,0,?,0)",
        [
          sqlight.int(row_ms(row)),
          sqlight.text("m" <> int.to_string(i)),
          sqlight.int(row.calls),
          sqlight.int(row.input),
          sqlight.int(row.output),
        ],
      )
    Nil
  })
  let found = body(ledger)
  store.close(ledger)
  found
}

fn coverage(c: Case, found: Result(a, String)) -> Nil {
  proptest.bump(case fits(c) {
    True -> "in_range"
    False -> "past_int64"
  })
  proptest.bump(case found {
    Ok(_) -> "answered"
    Error(_) -> "refused"
  })
  proptest.bump(case list.any(c.rows, fn(row) { row.input > int64_max / 4 || row.output > int64_max / 4 }) {
    True -> "extreme_row"
    False -> "ordinary_row"
  })
  Nil
}

pub fn main() -> Nil {
  proptest.check("profile is exact, saturated past int64, never refused", 40, case_generator(), fn(
    c,
  ) {
    let expected = saturated(c)
    let found = with_ledger(c, usage_profile.read(_, now_ms(c), c.offset_ms))
    coverage(c, found)
    case found {
      Ok(profile) ->
        case profile == expected {
          True -> Nil
          False ->
            panic as {
              "profile differs from the saturated exact model: expected "
              <> string.inspect(expected)
              <> ", found "
              <> string.inspect(profile)
            }
        }
      Error(error) ->
        panic as {
          case fits(c) {
            True -> "profile refused exact data inside int64: "
            False -> "profile refused data past int64 instead of saturating: "
          }
          <> error
        }
    }
  })

  proptest.check("window summary is exact or refuses only past int64", 40, case_generator(), fn(
    c,
  ) {
    let found =
      with_ledger(
        c,
        usage_hours.summary(_, now_ms(c), 371, c.offset_ms, usage_hours.AllScopes),
      )
    coverage(c, found)
    case found {
      Ok(summary) -> {
        let expected =
          list.map(model_days(c), fn(d) { #(d.0 * day - c.offset_ms, d.1, d.2) })
        let found_days =
          list.filter_map(summary.days, fn(d) {
            case d.total.calls > 0 {
              True ->
                Ok(#(
                  d.start_ms,
                  d.total.input_tokens + d.total.output_tokens,
                  d.total.calls,
                ))
              False -> Error(Nil)
            }
          })
        case found_days == expected {
          True -> Nil
          False ->
            panic as {
              "summary differs from the exact model: expected "
              <> string.inspect(expected)
              <> ", found "
              <> string.inspect(found_days)
            }
        }
      }
      Error(error) ->
        case fits(c) {
          True -> panic as { "summary refused exact data inside int64: " <> error }
          False -> Nil
        }
    }
  })
}
