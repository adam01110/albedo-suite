//// The usage profile past int64: SQLite's SUM() raises "integer overflow" once
//// a day's hours leave the int64 range, and an hour whose running sum already
//// crossed it is stored as a REAL. The profile still answers, exact below the
//// ceiling and saturated at it.

import albedo/storage/core_store
import albedo/usage/usage_hours
import albedo/usage/usage_profile
import albedo_sdk/store
import gleam/io
import gleam/list
import gleam/option.{Some}
import sqlight

const day = 86_400_000

const hour = 3_600_000

const max = 9_223_372_036_854_775_807

fn ledger(hours: List(#(Int, sqlight.Value, Int))) -> store.Store {
  let assert Ok(ledger) =
    store.start(
      ":memory:",
      usage_hours.schema
        <> "CREATE TABLE input_turns(id TEXT PRIMARY KEY,session TEXT NOT NULL,state TEXT NOT NULL,started_at INTEGER NOT NULL,ended_at INTEGER);",
      core_store.tables(),
    )
  list.index_map(hours, fn(row, i) {
    let #(at, input, calls) = row
    let assert Ok(_) =
      store.write(
        ledger,
        "INSERT INTO usage_hours VALUES(?,'p','prov','',?,'turn',?,0,?,0,0,0,0)",
        [sqlight.int(at), sqlight.int(i), sqlight.int(calls), input],
      )
    Nil
  })
  ledger
}

pub fn main() -> Nil {
  let now = 10 * day + 12 * hour
  // Two hours of one day at the ceiling: the day and the lifetime saturate.
  let full =
    ledger([
      #(9 * day, sqlight.int(max), 1),
      #(9 * day + hour, sqlight.int(max), 2),
    ])
  let assert Ok(profile) = usage_profile.read(full, now, 0)
  assert profile.lifetime_tokens == max
  assert profile.peak_day_tokens == max
  assert profile.lifetime_calls == 3
  assert profile.active_days == 1
  assert profile.peak_day_ms == Some(9 * day)
  store.close(full)

  // Two days of half the range each: both fit, the lifetime saturates, and the
  // peak is the exact larger day.
  let halves =
    ledger([
      #(8 * day, sqlight.int(max / 2 + 10), 1),
      #(9 * day, sqlight.int(max / 2), 1),
      #(10 * day, sqlight.int(5), 1),
    ])
  let assert Ok(profile) = usage_profile.read(halves, now, 0)
  assert profile.lifetime_tokens == max
  assert profile.peak_day_tokens == max / 2 + 10
  assert profile.peak_day_ms == Some(8 * day)
  assert profile.current_streak_days == 3
  store.close(halves)

  // An hour the upstream trigger already summed past int64 holds a REAL.
  let real =
    ledger([
      #(7 * day, sqlight.float(1.0e19), 4),
      #(10 * day, sqlight.int(42), 1),
    ])
  let assert Ok(profile) = usage_profile.read(real, now, 0)
  assert profile.lifetime_tokens == max
  assert profile.peak_day_tokens == max
  assert profile.peak_day_ms == Some(7 * day)
  assert profile.lifetime_calls == 5
  assert profile.active_days == 2
  store.close(real)

  // A completed turn whose span leaves int64 saturates too.
  let turns = ledger([])
  let assert Ok(_) =
    store.write(
      turns,
      "INSERT INTO input_turns VALUES('t','s','completed',?,?)",
      [sqlight.int(-max), sqlight.int(max)],
    )
  let assert Ok(profile) = usage_profile.read(turns, now, 0)
  assert profile.longest_turn_ms == Some(max)
  store.close(turns)
  io.println("Usage profile: totals past int64 saturate passed")
}
