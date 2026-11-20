//// The usage profile: days counted on the client's clock, streak runs, the
//// current streak surviving a day with no use yet, and only completed turns.

import albedo/storage/core_store
import albedo/usage/usage_hours
import albedo/usage/usage_profile
import albedo_sdk/store
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import sqlight

const day = 86_400_000

const hour = 3_600_000

pub fn main() -> Nil {
  let assert Ok(ledger) =
    store.start(
      ":memory:",
      usage_hours.schema
        <> "CREATE TABLE input_turns(id TEXT PRIMARY KEY,session TEXT NOT NULL,state TEXT NOT NULL,started_at INTEGER NOT NULL,ended_at INTEGER);",
      core_store.tables(),
    )
  let assert Ok(empty) = usage_profile.read(ledger, 100 * day, 0)
  assert empty == usage_profile.Profile(0, 0, 0, None, None, 0, 0, 0, None)
  // Two hours of day 96 sum into one day, the peak.
  list.each(
    [
      #(95 * day + 9 * hour, 10, 1),
      #(96 * day + 9 * hour, 300, 2),
      #(96 * day + 15 * hour, 200, 1),
      #(97 * day + 9 * hour, 40, 1),
      #(98 * day + 22 * hour, 7, 1),
      #(100 * day + 12 * hour, 3, 1),
      // An hour with no calls is no use.
      #(80 * day, 0, 0),
    ],
    fn(row) {
      let #(at, tokens, calls) = row
      let assert Ok(_) =
        store.write(
          ledger,
          "INSERT INTO usage_hours VALUES(?,'p','prov','','m','turn',?,0,?,0,0,?,0)",
          [
            sqlight.int(at),
            sqlight.int(calls),
            sqlight.int(tokens - 1),
            sqlight.int(1),
          ],
        )
      Nil
    },
  )
  list.each(
    [
      #("a", "completed", 1000, Some(6000)),
      #("b", "interrupted", 0, Some(99_999)),
      #("c", "running", 0, None),
    ],
    fn(turn) {
      let #(id, state, started, ended) = turn
      let assert Ok(_) =
        store.write(ledger, "INSERT INTO input_turns VALUES(?,'s',?,?,?)", [
          sqlight.text(id),
          sqlight.text(state),
          sqlight.int(started),
          sqlight.nullable(sqlight.int, ended),
        ])
      Nil
    },
  )
  let now = 100 * day + 13 * hour
  let assert Ok(utc) = usage_profile.read(ledger, now, 0)
  assert utc
    == usage_profile.Profile(
      lifetime_tokens: 560,
      lifetime_calls: 7,
      active_days: 5,
      first_day_ms: Some(95 * day),
      peak_day_ms: Some(96 * day),
      peak_day_tokens: 500,
      longest_streak_days: 4,
      current_streak_days: 1,
      longest_turn_ms: Some(5000),
    )
  // Three hours ahead of UTC, 22:00 on day 98 is day 99: the run breaks after
  // day 97 and the current one is two days long.
  let assert Ok(ahead) = usage_profile.read(ledger, now, 3 * hour)
  assert ahead.longest_streak_days == 3
  assert ahead.current_streak_days == 2
  assert ahead.first_day_ms == Some(95 * day - 3 * hour)
  // Tomorrow with no use yet keeps today's run; the day after ends it.
  let assert Ok(tomorrow) = usage_profile.read(ledger, now + day, 0)
  assert tomorrow.current_streak_days == 1
  let assert Ok(later) = usage_profile.read(ledger, now + 2 * day, 0)
  assert later.current_streak_days == 0
  store.close(ledger)
  io.println("Usage profile: client days, streaks, completed turns passed")
}
