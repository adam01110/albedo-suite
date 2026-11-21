//// The profile beside a usage window: what every provider call ever used, its
//// busiest day, the runs of days with use, and the longest turn. It reads the
//// hourly totals once and the turn ledger once, so it costs the same however
//// the window is narrowed.
////
//// The hours are summed here rather than by SQLite's SUM(), which raises
//// "integer overflow" past int64, and a bucket that already crossed int64 is
//// stored as a REAL. Sums are exact BEAM integers, and each total the profile
//// reports saturates at the int64 range the wire and the client hold.

import albedo_clock
import albedo_sdk/store
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

const day_ms = 86_400_000

const int64_max = 9_223_372_036_854_775_807

const int64_min = -9_223_372_036_854_775_808

pub type Profile {
  Profile(
    /// Input and output tokens over every day, as the window's bars measure.
    lifetime_tokens: Int,
    lifetime_calls: Int,
    active_days: Int,
    /// The midnight, as a Unix time, of the first day with use.
    first_day_ms: Option(Int),
    peak_day_ms: Option(Int),
    peak_day_tokens: Int,
    longest_streak_days: Int,
    /// The run of days ending today, or yesterday while today has no use yet.
    current_streak_days: Int,
    /// The longest completed turn still in the turn ledger.
    longest_turn_ms: Option(Int),
  )
}

/// One day with use, in the client's days since the epoch.
type Active {
  Active(day: Int, tokens: Int, calls: Int)
}

/// A count as SQLite holds it: an INTEGER, or the REAL an addition past int64
/// leaves behind, truncated to the integer it approximates.
fn count() -> decode.Decoder(Int) {
  decode.one_of(decode.int, [decode.map(decode.float, float.truncate)])
}

/// Every provider call ever recorded, for a client whose clock is `offset_ms`
/// ahead of UTC, read in one snapshot.
pub fn read(
  ledger: store.Store,
  now_ms: Int,
  offset_ms: Int,
) -> Result(Profile, String) {
  store.snapshot(ledger, fn(db) {
    use hours <- result.try(
      store.rows(
        db,
        "SELECT (hour_ms+?)/86400000,input_tokens,output_tokens,calls FROM usage_hours ORDER BY 1",
        [sqlight.int(offset_ms)],
        {
          use day <- decode.field(0, decode.int)
          use input <- decode.field(1, count())
          use output <- decode.field(2, count())
          use calls <- decode.field(3, count())
          decode.success(Active(day, input + output, calls))
        },
      ),
    )
    use turns <- result.try(store.rows(
      db,
      "SELECT MAX(ended_at-started_at) FROM input_turns WHERE state='completed' AND ended_at IS NOT NULL",
      [],
      decode.field(0, decode.optional(count()), decode.success),
    ))
    let longest_turn = list.first(turns) |> result.unwrap(None)
    let profile =
      summarise(
        days(hours),
        { now_ms + offset_ms } / day_ms,
        offset_ms,
        longest_turn,
      )
    Ok(
      Profile(
        ..profile,
        lifetime_tokens: saturate(profile.lifetime_tokens),
        lifetime_calls: saturate(profile.lifetime_calls),
        peak_day_tokens: saturate(profile.peak_day_tokens),
        longest_turn_ms: option.map(profile.longest_turn_ms, saturate),
      ),
    )
  })
}

/// The hours, oldest day first, summed into the days that had calls.
fn days(hours: List(Active)) -> List(Active) {
  list.chunk(hours, fn(hour) { hour.day })
  |> list.filter_map(fn(day) {
    let assert [first, ..] = day
    let total =
      list.fold(day, Active(first.day, 0, 0), fn(sum, hour) {
        Active(sum.day, sum.tokens + hour.tokens, sum.calls + hour.calls)
      })
    case total.calls > 0 {
      True -> Ok(total)
      False -> Error(Nil)
    }
  })
}

fn saturate(n: Int) -> Int {
  int.clamp(n, min: int64_min, max: int64_max)
}

/// Folds the active days, oldest first, in one pass.
fn summarise(
  days: List(Active),
  today: Int,
  offset_ms: Int,
  longest_turn: Option(Int),
) -> Profile {
  let start = fn(day) { day * day_ms - offset_ms }
  let empty = Profile(0, 0, 0, None, None, 0, 0, 0, longest_turn)
  // The current streak is the run as of the last day up to today: an hour
  // stamped later (a clock set back since) cannot extend or replace it.
  let #(profile, _, _, #(last, run)) =
    list.fold(days, #(empty, -2, 0, #(-2, 0)), fn(state, active) {
      let #(p, previous, run, current) = state
      let run = case active.day == previous + 1 {
        True -> run + 1
        False -> 1
      }
      let current = case active.day <= today {
        True -> #(active.day, run)
        False -> current
      }
      let #(peak_ms, peak_tokens) = case active.tokens > p.peak_day_tokens {
        True -> #(Some(start(active.day)), active.tokens)
        False -> #(p.peak_day_ms, p.peak_day_tokens)
      }
      #(
        Profile(
          ..p,
          lifetime_tokens: p.lifetime_tokens + active.tokens,
          lifetime_calls: p.lifetime_calls + active.calls,
          active_days: p.active_days + 1,
          first_day_ms: option.or(p.first_day_ms, Some(start(active.day))),
          peak_day_ms: peak_ms,
          peak_day_tokens: peak_tokens,
          longest_streak_days: case run > p.longest_streak_days {
            True -> run
            False -> p.longest_streak_days
          },
        ),
        active.day,
        run,
        current,
      )
    })
  case last >= today - 1 {
    True -> Profile(..profile, current_streak_days: run)
    False -> profile
  }
}

pub fn to_json(profile: Profile) -> json.Json {
  let stamp = fn(ms) {
    json.nullable(option.map(ms, albedo_clock.format_rfc3339), json.string)
  }
  json.object([
    #("lifetime_tokens", json.int(profile.lifetime_tokens)),
    #("lifetime_calls", json.int(profile.lifetime_calls)),
    #("active_days", json.int(profile.active_days)),
    #("first_day", stamp(profile.first_day_ms)),
    #("peak_day", stamp(profile.peak_day_ms)),
    #("peak_day_tokens", json.int(profile.peak_day_tokens)),
    #("longest_streak_days", json.int(profile.longest_streak_days)),
    #("current_streak_days", json.int(profile.current_streak_days)),
    #("longest_turn_ms", json.nullable(profile.longest_turn_ms, json.int)),
  ])
}
