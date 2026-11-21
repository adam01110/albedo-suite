//// The quota poller's schedule against the contract in its docstrings: the
//// backoff doubles until the hour cap, and `next_delay` never waits past an
//// account's deadline nor longer than one poll period.

import albedo/accounts/quota
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import proptest
import qcheck

type Case {
  Case(settings: quota.Settings, failures: Int, busy: Bool)
}

fn settings() -> qcheck.Generator(quota.Settings) {
  use poll <- qcheck.bind(
    qcheck.from_weighted_generators(#(6, qcheck.bounded_int(1, 900)), [
      #(2, qcheck.bounded_int(901, 3600)),
      #(1, qcheck.bounded_int(3601, 86_400)),
    ]),
  )
  use busy <- qcheck.bind(qcheck.bounded_int(1, poll))
  qcheck.return(quota.Settings(poll, busy, True))
}

fn scenario() -> qcheck.Generator(Case) {
  use config <- qcheck.bind(settings())
  use failures <- qcheck.bind(
    qcheck.from_weighted_generators(#(8, qcheck.bounded_int(1, 9)), [
      #(1, qcheck.bounded_int(10, 1000)),
    ]),
  )
  use busy <- qcheck.bind(qcheck.bool())
  qcheck.return(Case(config, failures, busy))
}

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}

fn minimum(values: List(Int)) -> Option(Int) {
  list.fold(values, None, fn(best, value) {
    case best {
      Some(current) -> Some(int.min(current, value))
      None -> Some(value)
    }
  })
}

fn wait(c: Case, failures: Int) -> Int {
  quota.wait_seconds(c.settings, failures, c.busy)
}

/// Ticks as the poller would, serving each idle account whose deadline has
/// passed, and counts the services until `until`.
fn tick(
  config: quota.Settings,
  enumerated: Int,
  now: Int,
  until: Int,
  served: Int,
  pending: List(Int),
) -> Int {
  case now >= until {
    True -> served
    False -> {
      let delay =
        quota.next_delay(
          config,
          now,
          enumerated,
          False,
          list.map(pending, fn(when) { #(when, False) }),
        )
      let now = now + delay
      let due = list.filter(pending, fn(when) { when <= now })
      let rest = list.filter(pending, fn(when) { when > now })
      tick(
        config,
        enumerated,
        now,
        until,
        served + list.length(due),
        list.append(
          rest,
          list.map(due, fn(_) { now + config.poll_seconds * 1000 }),
        ),
      )
    }
  }
}

pub fn main() -> Nil {
  proptest.check("wait_seconds backs off for failures", 100, scenario(), fn(c) {
    case c.busy {
      True -> {
        assert wait(c, 0) == c.settings.busy_poll_seconds
        Nil
      }
      False -> {
        assert wait(c, 0) == c.settings.poll_seconds
        Nil
      }
    }
    // The first failure backs off from the ordinary cadence, then each
    // further one doubles, and six doublings are the most promised.
    assert wait(c, 1) == int.min(c.settings.poll_seconds * 2, 3600)
    list.each(range(1, 5), fn(failures) {
      proptest.bump("doubling")
      assert wait(c, failures + 1) == int.min(wait(c, failures) * 2, 3600)
      Nil
    })
    let capped = wait(c, 6)
    list.each(range(6, 40), fn(failures) {
      assert wait(c, failures) == capped
      Nil
    })
    // A backoff never waits past an hour, and never stops waiting. From the
    // first failure on it is monotone; an ordinary cadence longer than the
    // hour cap starts below the cap instead.
    proptest.bump(case c.settings.poll_seconds > 3600 {
      True -> "poll_past_hour"
      False -> "poll_within_hour"
    })
    list.each(range(1, 40), fn(failures) {
      proptest.bump("backoff")
      assert wait(c, failures) <= 3600
      assert wait(c, failures) > 0
      case failures {
        1 -> Nil
        _ -> {
          assert wait(c, failures) >= wait(c, failures - 1)
          Nil
        }
      }
    })
    proptest.bump(case capped == 3600 {
      True -> "capped"
      False -> "uncapped"
    })
    Nil
  })

  proptest.check(
    "next_delay waits for the earliest deadline",
    100,
    qcheck.map2(scenario(), accounts(), fn(c, generated) { #(c, generated) }),
    fn(pair) {
      let #(c, #(accounts, last_enumerated, enumerating)) = pair
      let now = 1_000_000
      let poll_ms = c.settings.poll_seconds * 1000
      let delay =
        quota.next_delay(
          c.settings,
          now,
          last_enumerated,
          enumerating,
          accounts,
        )
      // A poll period at most, a quarter second at least.
      assert delay >= 250
      assert delay <= poll_ms
      // The earliest deadline the poller must wait for: in-flight work has
      // its own, an idle account's is its poll time.
      let idle =
        list.filter_map(accounts, fn(account) {
          case account.1 {
            True -> Error(Nil)
            False -> Ok(account.0)
          }
        })
      let due = case enumerating {
        True -> idle
        False -> [last_enumerated + poll_ms, ..idle]
      }
      case minimum(due) {
        // An overdue deadline polls as soon as the clamp allows.
        Some(when) if when - now < 250 -> {
          proptest.bump("overdue")
          assert delay == 250
          Nil
        }
        // A deadline inside one period is waited for exactly.
        Some(when) if when - now <= poll_ms -> {
          proptest.bump("exact")
          assert delay == when - now
          Nil
        }
        // Anything further waits one poll period.
        Some(_) -> {
          proptest.bump("period")
          assert delay == poll_ms
          Nil
        }
        None -> {
          proptest.bump("empty")
          assert delay == poll_ms
          Nil
        }
      }
    },
  )

  proptest.check(
    "no idle account starves",
    100,
    qcheck.map2(
      scenario(),
      qcheck.map2(
        qcheck.generic_list(
          qcheck.map(qcheck.bounded_int(-3000, 3000), fn(offset) { offset }),
          qcheck.bounded_int(1, 5),
        ),
        qcheck.bounded_int(-3000, 3000),
        fn(offsets, first) { #(offsets, first) },
      ),
      fn(c, generated) { #(c, generated) },
    ),
    fn(pair) {
      let #(c, #(offsets, first)) = pair
      let start = 1_000_000
      let deadlines = list.map(offsets, fn(offset) { start + offset })
      let served =
        tick(
          c.settings,
          start + first,
          start,
          start + 2 * c.settings.poll_seconds * 1000,
          0,
          deadlines,
        )
      let within =
        list.count(deadlines, fn(when) {
          when <= start + c.settings.poll_seconds * 1000
        })
      proptest.bump("accounts_" <> int.to_string(list.length(deadlines)))
      // Every account due within one period is served at least once.
      assert served >= within
      Nil
    },
  )
}

fn accounts() -> qcheck.Generator(#(List(#(Int, Bool)), Int, Bool)) {
  use offsets <- qcheck.bind(qcheck.generic_list(
    qcheck.map2(
      qcheck.bounded_int(-5000, 5000),
      qcheck.bool(),
      fn(offset, polling) { #(1_000_000 + offset, polling) },
    ),
    qcheck.bounded_int(0, 6),
  ))
  use last_enumerated <- qcheck.bind(qcheck.bounded_int(995_000, 1_005_000))
  use enumerating <- qcheck.bind(qcheck.bool())
  qcheck.return(#(offsets, last_enumerated, enumerating))
}
