//// The usage endpoint's model: the day buckets a window answers in, its
//// bounded edges, the lines and scopes it lists, and the profile read beside
//// it, against an independent model that buckets every hour by floor division
//// on the client's clock. Windows run across year boundaries and leap days,
//// and the clocks include half-hour zones and both offset limits.

import albedo/generated/sql/usage/usage_hours_sql
import albedo/storage/core_store
import albedo/usage/usage_hours
import albedo/usage/usage_profile
import albedo_sdk/store
import albedo_sqlite
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import proptest
import qcheck
import sqlight

const day = 86_400_000

const hour = 3_600_000

/// Days whose windows end on a leap day, a year boundary or a plain day.
const base_days = [20_777, 21_183, 21_243, 21_244, 21_550, 21_915, 22_644]

/// Every real offset class: whole hours, half hours, quarter hours, and both
/// limits.
const offsets = [-720, -660, -480, -330, -60, 0, 0, 60, 330, 345, 540, 720, 840]

pub type Use {
  Use(
    hour_ms: Int,
    profile: String,
    provider: String,
    account: String,
    model: String,
    calls: Int,
    errors: Int,
    input: Int,
    cached: Int,
    creation: Int,
    output: Int,
    reasoning: Int,
  )
}

/// A row as the generator spells it: an hour slot from the case's base day.
pub type Row {
  Row(
    slot: Int,
    profile: String,
    provider: String,
    account: String,
    model: String,
    calls: Int,
    errors: Int,
    input: Int,
    cached: Int,
    creation: Int,
    output: Int,
    reasoning: Int,
  )
}

pub type Turn {
  Turn(state: String, started: Int, ended: Option(Int))
}

pub type Case {
  Case(
    base_day: Int,
    now_in_day: Int,
    offset_minutes: Int,
    days: Int,
    /// How many of the client's newest days the profile properties leave
    /// without use, so a streak has to end before them.
    tail: Int,
    /// Whether every row carries its own model, so the window has more lines
    /// than the summary keeps.
    wide: Bool,
    /// The scope a narrowed read asks for: a provider, and one account of it or
    /// every account.
    scope: #(String, Option(String)),
    rows: List(Row),
    turns: List(Turn),
  )
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

/// Token and call counts, small enough to tie often: a tie is what puts
/// lines in their documented order rather than in their busiest first.
fn counts() -> qcheck.Generator(Int) {
  qcheck.from_weighted_generators(#(5, qcheck.bounded_int(0, 3)), [
    #(3, qcheck.bounded_int(0, 500)),
    #(2, qcheck.return(0)),
  ])
}

/// Rows placed by their distance from the case's base day: near the present,
/// near the window's far edge, in the client's future, and long ago.
fn row_generator(days: Int, wide: Bool) -> qcheck.Generator(Row) {
  use #(#(slot, ids), #(calls, errors), counters) <- qcheck.bind(qcheck.tuple3(
    qcheck.tuple2(
      case wide {
        // A window with more lines than the summary keeps: every row inside it.
        True -> qcheck.bounded_int(-days * 24 + 1, 0)
        False ->
          qcheck.from_weighted_generators(
            #(10, qcheck.bounded_int(-3 * 24, 3 * 24)),
            [
              #(3, qcheck.bounded_int(-days * 24 - 36, -days * 24 + 36)),
              #(3, qcheck.bounded_int(-400 * 24, -24)),
              #(2, qcheck.bounded_int(24, 30 * 24)),
              #(2, qcheck.bounded_int(-24, 0)),
            ],
          )
      },
      qcheck.tuple4(
        pick(["p1", "p2"]),
        pick(["prov", "prov", "other"]),
        pick(["", "", "acct"]),
        pick(["m1", "m1", "m2"]),
      ),
    ),
    qcheck.tuple2(qcheck.bounded_int(1, 4), qcheck.bounded_int(0, 1)),
    qcheck.tuple5(counts(), counts(), counts(), counts(), counts()),
  ))
  let #(profile, provider, account, model) = ids
  let #(input, cached, creation, output, reasoning) = counters
  qcheck.return(Row(
    slot,
    profile,
    provider,
    account,
    model,
    calls,
    int.min(errors, calls),
    input,
    cached,
    creation,
    output,
    reasoning,
  ))
}

fn turn_generator() -> qcheck.Generator(Turn) {
  use state, started, length, ended <- qcheck.map4(
    pick(["completed", "completed", "interrupted", "running"]),
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
  use days <- qcheck.bind(
    qcheck.from_weighted_generators(#(8, pick([1, 2, 7, 30, 365, 371])), [
      #(1, qcheck.bounded_int(1, 371)),
    ]),
  )
  use #(base_day, now_in_day, offset_minutes) <- qcheck.bind(qcheck.tuple3(
    pick(base_days),
    qcheck.from_weighted_generators(#(4, qcheck.bounded_int(0, day - 1)), [
      #(2, pick([0, day - 1, day / 2, day - hour])),
    ]),
    qcheck.from_weighted_generators(#(3, pick(offsets)), [
      #(1, qcheck.bounded_int(-720, 840)),
    ]),
  ))
  use wide <- qcheck.bind(
    qcheck.from_weighted_generators(#(6, qcheck.return(False)), [
      #(4, qcheck.return(True)),
    ]),
  )
  use scope <- qcheck.bind(qcheck.tuple2(
    pick(["prov", "other", "missing"]),
    qcheck.from_weighted_generators(#(3, qcheck.return(None)), [
      #(2, qcheck.return(Some(""))),
      #(2, qcheck.return(Some("acct"))),
    ]),
  ))
  use #(rows, turns, tail) <- qcheck.bind(qcheck.tuple3(
    qcheck.generic_list(
      row_generator(days, wide),
      qcheck.bounded_int(0, case wide {
        True -> 120
        False -> 24
      }),
    ),
    qcheck.generic_list(turn_generator(), qcheck.bounded_int(0, 3)),
    qcheck.from_weighted_generators(#(5, qcheck.return(0)), [
      #(3, qcheck.return(1)),
      #(2, qcheck.return(2)),
      #(1, qcheck.return(3)),
    ]),
  ))
  qcheck.return(Case(
    base_day,
    now_in_day,
    offset_minutes,
    days,
    tail,
    wide,
    scope,
    rows,
    turns,
  ))
}

fn floor_div(a: Int, b: Int) -> Int {
  let q = a / b
  case a % b < 0 {
    True -> q - 1
    False -> q
  }
}

fn now_ms(c: Case) -> Int {
  c.base_day * day + c.now_in_day
}

fn offset_ms(c: Case) -> Int {
  c.offset_minutes * 60_000
}

fn today(c: Case) -> Int {
  floor_div(now_ms(c) + offset_ms(c), day)
}

/// The window's first instant, and the one the client's tomorrow begins at.
fn window(c: Case) -> #(Int, Int) {
  let first = today(c) - c.days + 1
  #(first * day - offset_ms(c), { today(c) + 1 } * day - offset_ms(c))
}

fn add(a: usage_hours.Total, b: usage_hours.Total) -> usage_hours.Total {
  usage_hours.Total(
    calls: a.calls + b.calls,
    errors: a.errors + b.errors,
    input_tokens: a.input_tokens + b.input_tokens,
    cached_input_tokens: a.cached_input_tokens + b.cached_input_tokens,
    cache_creation_tokens: a.cache_creation_tokens + b.cache_creation_tokens,
    output_tokens: a.output_tokens + b.output_tokens,
    reasoning_tokens: a.reasoning_tokens + b.reasoning_tokens,
  )
}

fn total_of(uses: List(Use)) -> usage_hours.Total {
  list.fold(uses, usage_hours.empty, fn(sum, u) {
    add(
      sum,
      usage_hours.Total(
        calls: u.calls,
        errors: u.errors,
        input_tokens: u.input,
        cached_input_tokens: u.cached,
        cache_creation_tokens: u.creation,
        output_tokens: u.output,
        reasoning_tokens: u.reasoning,
      ),
    )
  })
}

fn key_of(u: Use) -> #(Int, String, String, String, String) {
  #(u.hour_ms, u.profile, u.provider, u.account, u.model)
}

fn add_use(a: Use, b: Use) -> Use {
  Use(
    ..a,
    calls: a.calls + b.calls,
    errors: a.errors + b.errors,
    input: a.input + b.input,
    cached: a.cached + b.cached,
    creation: a.creation + b.creation,
    output: a.output + b.output,
    reasoning: a.reasoning + b.reasoning,
  )
}

/// One row per primary key, its counters summed, as the recorder's upsert
/// leaves them.
fn merge(uses: List(Use)) -> List(Use) {
  list.fold(uses, dict.new(), fn(rows, u) {
    dict.upsert(rows, key_of(u), fn(found) {
      case found {
        Some(row) -> add_use(row, u)
        None -> u
      }
    })
  })
  |> dict.values
  |> list.sort(fn(a, b) { compare_key(key_of(a), key_of(b)) })
}

fn compare_key(
  a: #(Int, String, String, String, String),
  b: #(Int, String, String, String, String),
) -> order.Order {
  case int.compare(a.0, b.0) {
    order.Eq ->
      case string.compare(a.1, b.1) {
        order.Eq ->
          case string.compare(a.2, b.2) {
            order.Eq ->
              case string.compare(a.3, b.3) {
                order.Eq -> string.compare(a.4, b.4)
                found -> found
              }
            found -> found
          }
        found -> found
      }
    found -> found
  }
}

fn placed(c: Case) -> List(Use) {
  list.index_map(c.rows, fn(r, index) {
    Use(
      c.base_day * day + r.slot * hour,
      r.profile,
      r.provider,
      r.account,
      case c.wide {
        True -> "m" <> int.to_string(index)
        False -> r.model
      },
      r.calls,
      r.errors,
      r.input,
      r.cached,
      r.creation,
      r.output,
      r.reasoning,
    )
  })
}

/// One hour of four lines that tie on tokens across two accounts and two
/// models of one provider, where the line order's tie-break shows.
fn cross_rows(c: Case) -> List(Use) {
  let at = now_ms(c) / hour * hour
  list.flat_map(["", "acct"], fn(account) {
    list.map(["m1", "m2"], fn(model) {
      Use(at, "p1", "prov", account, model, 1, 0, 10, 0, 0, 5, 0)
    })
  })
}

/// Every row a case carries: the generated ones and the edge and tie rows.
fn all_rows(c: Case) -> List(Use) {
  merge(list.append(list.append(edge_rows(c), cross_rows(c)), placed(c)))
}

/// The case's rows without use on its newest `tail` client days, leaving
/// anything in the client's future in place.
fn without_newest(c: Case, uses: List(Use)) -> List(Use) {
  let today = today(c)
  list.filter(uses, fn(u) {
    let bucket = floor_div(u.hour_ms + offset_ms(c), day)
    bucket > today || bucket <= today - c.tail
  })
}

/// Rows on the window's own edges, where an hour is in or out: one before it
/// opens, the instant it opens, one before it closes, the instant it closes.
fn edge_rows(c: Case) -> List(Use) {
  let #(since, until) = window(c)
  list.map([since - hour, since, until - hour, until], fn(at) {
    Use(at, "p1", "prov", "", "edge", 1, 0, 5, 0, 0, 7, 0)
  })
}

fn expected_days(c: Case, uses: List(Use)) -> List(usage_hours.Day) {
  let #(since, until) = window(c)
  let first = today(c) - c.days + 1
  let offset = offset_ms(c)
  let totals =
    uses
    |> list.filter(fn(u) { u.hour_ms >= since && u.hour_ms < until })
    |> list.fold(dict.new(), fn(acc, u) {
      dict.upsert(acc, floor_div(u.hour_ms + offset, day), fn(found) {
        case found {
          Some(sum) -> add(sum, total_of([u]))
          None -> total_of([u])
        }
      })
    })
  list.repeat(Nil, c.days)
  |> list.index_map(fn(_, index) {
    let start = first + index
    usage_hours.Day(
      start_ms: start * day - offset,
      total: dict.get(totals, start) |> result.unwrap(usage_hours.empty),
    )
  })
}

fn compare_lines(a: usage_hours.Line, b: usage_hours.Line) -> order.Order {
  let tokens = fn(line: usage_hours.Line) {
    line.total.input_tokens + line.total.output_tokens
  }
  case int.compare(tokens(b), tokens(a)) {
    order.Eq ->
      case string.compare(a.profile, b.profile) {
        order.Eq ->
          case string.compare(a.provider, b.provider) {
            order.Eq ->
              case string.compare(a.account, b.account) {
                order.Eq -> string.compare(a.model, b.model)
                found -> found
              }
            found -> found
          }
        found -> found
      }
    found -> found
  }
}

fn expected_lines(c: Case, uses: List(Use)) -> List(usage_hours.Line) {
  let #(since, until) = window(c)
  uses
  |> list.filter(fn(u) { u.hour_ms >= since && u.hour_ms < until })
  |> list.fold(dict.new(), fn(acc, u) {
    let key = #(u.profile, u.provider, u.account, u.model)
    dict.upsert(acc, key, fn(found) {
      case found {
        Some(sum) -> add(sum, total_of([u]))
        None -> total_of([u])
      }
    })
  })
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(#(profile, provider, account, model), total) = entry
    usage_hours.Line(profile, provider, account, model, total)
  })
  |> list.sort(compare_lines)
}

fn expected_scopes(c: Case, uses: List(Use)) -> List(usage_hours.Scope) {
  let #(since, until) = window(c)
  uses
  |> list.filter(fn(u) { u.hour_ms >= since && u.hour_ms < until })
  |> list.fold(dict.new(), fn(acc, u) {
    dict.insert(acc, #(u.provider, u.account), Nil)
  })
  |> dict.keys
  |> list.map(fn(key) { usage_hours.Scope(key.0, key.1) })
  |> list.sort(fn(a, b) {
    case string.compare(a.provider, b.provider) {
      order.Eq -> string.compare(a.account, b.account)
      found -> found
    }
  })
}

const turns_schema =
  "CREATE TABLE input_turns(id TEXT PRIMARY KEY,session TEXT NOT NULL,state TEXT NOT NULL,started_at INTEGER NOT NULL,ended_at INTEGER);"

fn with_ledger(c: Case, uses: List(Use), body: fn(store.Store) -> a) -> a {
  let assert Ok(ledger) =
    store.start(
      ":memory:",
      fn(db) {
        use _ <- result.try(usage_hours_sql.create_usage_hours(db:))
        albedo_sqlite.exec(turns_schema, on: db)
      },
      core_store.tables(),
    )
  list.each(uses, fn(u) {
    let assert Ok(_) =
      store.writing(ledger, fn(db) {
        albedo_sqlite.run(
          "INSERT INTO usage_hours VALUES(?,?,?,?,?,'turn',?,?,?,?,?,?,?)",
          on: db,
          with: [
            sqlight.int(u.hour_ms),
            sqlight.text(u.profile),
            sqlight.text(u.provider),
            sqlight.text(u.account),
            sqlight.text(u.model),
            sqlight.int(u.calls),
            sqlight.int(u.errors),
            sqlight.int(u.input),
            sqlight.int(u.cached),
            sqlight.int(u.creation),
            sqlight.int(u.output),
            sqlight.int(u.reasoning),
          ],
        )
      })
    Nil
  })
  list.index_map(c.turns, fn(t, index) {
    let assert Ok(_) =
      store.writing(ledger, fn(db) {
        albedo_sqlite.run(
          "INSERT INTO input_turns VALUES(?,'s',?,?,?)",
          on: db,
          with: [
            sqlight.text(int.to_string(index)),
            sqlight.text(t.state),
            sqlight.int(t.started),
            sqlight.nullable(sqlight.int, t.ended),
          ],
        )
      })
    Nil
  })
  let found = body(ledger)
  store.close(ledger)
  found
}

/// The days with use, oldest first, as the profile counts them.
fn active_days(uses: List(Use), offset: Int) -> List(#(Int, Int, Int)) {
  uses
  |> list.fold(dict.new(), fn(days, u) {
    let key = floor_div(u.hour_ms + offset, day)
    dict.upsert(days, key, fn(found) {
      case found {
        Some(#(tokens, calls)) -> #(
          tokens + u.input + u.output,
          calls + u.calls,
        )
        None -> #(u.input + u.output, u.calls)
      }
    })
  })
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    let #(key, #(tokens, calls)) = entry
    case calls > 0 {
      True -> Ok(#(key, tokens, calls))
      False -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
}

fn run_ending(active: List(Int), last: Int) -> Int {
  case list.contains(active, last) {
    True -> 1 + run_ending(active, last - 1)
    False -> 0
  }
}

fn profile_model(c: Case, uses: List(Use)) -> usage_profile.Profile {
  let offset = offset_ms(c)
  let days = active_days(uses, offset)
  let active = list.map(days, fn(d) { d.0 })
  let start = fn(d) { d * day - offset }
  let today = today(c)
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
  let runs =
    c.turns
    |> list.filter_map(fn(t) {
      case t.state, t.ended {
        "completed", Some(ended) -> Ok(ended - t.started)
        _, _ -> Error(Nil)
      }
    })
  let longest_turn = option.from_result(list.max(runs, int.compare))
  usage_profile.Profile(
    lifetime_tokens: list.fold(days, 0, fn(sum, d) { sum + d.1 }),
    lifetime_calls: list.fold(days, 0, fn(sum, d) { sum + d.2 }),
    active_days: list.length(days),
    first_day_ms: option.from_result(list.first(active)) |> option.map(start),
    peak_day_ms: option.map(peak, fn(p) { start(p.0) }),
    peak_day_tokens: option.map(peak, fn(p) { p.1 }) |> option.unwrap(0),
    longest_streak_days: list.map(active, run_ending(active, _))
      |> list.fold(0, int.max),
    current_streak_days: current,
    longest_turn_ms: longest_turn,
  )
}

fn describe(c: Case) -> String {
  "base_day="
  <> int.to_string(c.base_day)
  <> " now_in_day="
  <> int.to_string(c.now_in_day)
  <> " offset_minutes="
  <> int.to_string(c.offset_minutes)
  <> " days="
  <> int.to_string(c.days)
}

pub fn main() -> Nil {
  proptest.check(
    "day buckets and totals follow the client's clock",
    100,
    case_generator(),
    fn(c) {
      let uses = all_rows(c)
      let found =
        with_ledger(c, uses, fn(ledger) {
          usage_hours.summary(
            ledger,
            now_ms(c),
            c.days,
            offset_ms(c),
            usage_hours.AllScopes,
          )
        })
      let expected = expected_days(c, uses)
      proptest.bump("days_" <> int.to_string(int.min(c.days, 7)))
      proptest.bump("offset_" <> int.to_string(c.offset_minutes / 60))
      let #(since, until) = window(c)
      proptest.bump(
        case
          list.any(uses, fn(u) { u.hour_ms == since || u.hour_ms == until })
        {
          True -> "edge_row"
          False -> "no_edge_row"
        },
      )
      let assert Ok(summary) = found
      case summary.days == expected {
        True -> Nil
        False ->
          panic as {
            "days differ at "
            <> describe(c)
            <> ": expected "
            <> string.inspect(expected)
            <> ", found "
            <> string.inspect(summary.days)
          }
      }
    },
  )

  proptest.check(
    "lines and scopes group the window as a dict does",
    100,
    case_generator(),
    fn(c) {
      let uses = all_rows(c)
      let found =
        with_ledger(c, uses, fn(ledger) {
          usage_hours.summary(
            ledger,
            now_ms(c),
            c.days,
            offset_ms(c),
            usage_hours.AllScopes,
          )
        })
      let assert Ok(summary) = found
      let lines = expected_lines(c, uses)
      proptest.bump(case list.length(lines) > usage_hours.most_lines {
        True -> "lines_cut"
        False -> "lines_whole"
      })
      assert summary.lines == list.take(lines, usage_hours.most_lines)
      assert summary.lines_truncated
        == { list.length(lines) > usage_hours.most_lines }
      assert summary.scopes == expected_scopes(c, uses)
      assert summary.scopes_truncated == False
      Nil
    },
  )

  proptest.check(
    "the window is half open on the client's clock",
    60,
    case_generator(),
    fn(c) {
      let uses = merge(edge_rows(c))
      let assert Ok(summary) =
        with_ledger(c, uses, fn(ledger) {
          usage_hours.summary(
            ledger,
            now_ms(c),
            c.days,
            offset_ms(c),
            usage_hours.AllScopes,
          )
        })
      let inside =
        list.fold(summary.days, 0, fn(sum, d) { sum + d.total.calls })
      // Two of the four edge hours fall inside every window.
      assert inside == 2
      assert summary.days == expected_days(c, uses)
      assert summary.lines
        == list.take(expected_lines(c, uses), usage_hours.most_lines)
      Nil
    },
  )

  proptest.check(
    "totals do not depend on the order rows arrive in",
    40,
    case_generator(),
    fn(c) {
      let uses = all_rows(c)
      let forwards =
        with_ledger(c, uses, fn(ledger) {
          #(
            usage_hours.summary(
              ledger,
              now_ms(c),
              c.days,
              offset_ms(c),
              usage_hours.AllScopes,
            ),
            usage_profile.read(ledger, now_ms(c), offset_ms(c)),
          )
        })
      let reversed =
        with_ledger(c, list.reverse(uses), fn(ledger) {
          #(
            usage_hours.summary(
              ledger,
              now_ms(c),
              c.days,
              offset_ms(c),
              usage_hours.AllScopes,
            ),
            usage_profile.read(ledger, now_ms(c), offset_ms(c)),
          )
        })
      assert forwards == reversed
      Nil
    },
  )

  proptest.check(
    "the profile matches the day-bucketing model",
    100,
    case_generator(),
    fn(c) {
      let uses = without_newest(c, all_rows(c))
      let found =
        with_ledger(c, uses, fn(ledger) {
          usage_profile.read(ledger, now_ms(c), offset_ms(c))
        })
      let expected = profile_model(c, uses)
      proptest.bump(
        "future_"
        <> case
          list.any(uses, fn(u) {
            floor_div(u.hour_ms + offset_ms(c), day) > today(c)
          })
        {
          True -> "yes"
          False -> "no"
        },
      )
      proptest.bump(
        "current_" <> int.to_string(int.min(expected.current_streak_days, 3)),
      )
      proptest.bump(
        "tail_"
        <> case
          list.any(uses, fn(u) {
            floor_div(u.hour_ms + offset_ms(c), day) == today(c)
          })
        {
          True -> "today"
          False -> "no_today"
        },
      )
      case found == Ok(expected) {
        True -> Nil
        False ->
          panic as {
            "profile differs at "
            <> describe(c)
            <> ": expected "
            <> string.inspect(expected)
            <> ", found "
            <> string.inspect(found)
          }
      }
    },
  )

  proptest.check(
    "a provider filter narrows the days and lines, never the scopes",
    60,
    case_generator(),
    fn(c) {
      let uses = all_rows(c)
      let #(provider, account) = c.scope
      let filter = usage_hours.OfProvider(provider, account)
      let narrowed =
        list.filter(uses, fn(u) {
          u.provider == provider
          && case account {
            Some(wanted) -> u.account == wanted
            None -> True
          }
        })
      let found =
        with_ledger(c, uses, fn(ledger) {
          usage_hours.summary(ledger, now_ms(c), c.days, offset_ms(c), filter)
        })
      let assert Ok(summary) = found
      let lines = expected_lines(c, narrowed)
      proptest.bump(case narrowed {
        [] -> "empty_scope"
        _ -> "used_scope"
      })
      assert summary.days == expected_days(c, narrowed)
      assert summary.lines == list.take(lines, usage_hours.most_lines)
      assert summary.lines_truncated
        == { list.length(lines) > usage_hours.most_lines }
      // The scopes are what the window saw, not what the filter kept.
      assert summary.scopes == expected_scopes(c, uses)
      Nil
    },
  )

  proptest.check(
    "the profile agrees with a window summary of the same days",
    60,
    case_generator(),
    fn(c) {
      // Only rows the widest window can show: none in the client's future and
      // none older than its 371 days.
      let wide = Case(..c, days: 371)
      let today = today(wide)
      let uses =
        all_rows(wide)
        |> list.filter(fn(u) {
          let d = floor_div(u.hour_ms + offset_ms(wide), day)
          d <= today && d > today - 371
        })
      let found =
        with_ledger(wide, uses, fn(ledger) {
          #(
            usage_profile.read(ledger, now_ms(wide), offset_ms(wide)),
            usage_hours.summary(
              ledger,
              now_ms(wide),
              371,
              offset_ms(wide),
              usage_hours.AllScopes,
            ),
          )
        })
      let #(profile, summary) = found
      let assert Ok(profile) = profile
      let assert Ok(summary) = summary
      let used = list.filter(summary.days, fn(d) { d.total.calls > 0 })
      assert profile.lifetime_tokens
        == list.fold(used, 0, fn(sum, d) {
          sum + d.total.input_tokens + d.total.output_tokens
        })
      assert profile.lifetime_calls
        == list.fold(used, 0, fn(sum, d) { sum + d.total.calls })
      assert profile.active_days == list.length(used)
      assert profile.first_day_ms
        == list.first(used)
        |> option.from_result
        |> option.map(fn(d) { d.start_ms })
      assert profile.peak_day_tokens
        == list.fold(used, 0, fn(best, d) {
          int.max(best, d.total.input_tokens + d.total.output_tokens)
        })
      Nil
    },
  )
}
