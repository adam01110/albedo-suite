//// Session cost pricing (albedo_session_cost.erl) against an independent
//// model of the documented rules, plus metamorphic relations that need no
//// model: grouping, row order, request multiplicity and additivity.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck

pub type Rate {
  /// A catalog rate as models.dev spells it, integer or float.
  Num(Float)
  Whole(Int)
  /// A rate the pricer must refuse: negative or not a number.
  Bad
}

pub type Cost {
  Cost(
    rates: List(#(String, Rate)),
    /// Context tiers by distinct size: applied when input exceeds the size.
    tiers: List(#(Int, List(#(String, Rate)))),
    over_200k: Option(List(#(String, Rate))),
  )
}

pub type Row {
  Row(
    session: String,
    profile: String,
    model: String,
    input: Option(Int),
    cached: Option(Int),
    created: Option(Int),
    w5: Option(Int),
    w1: Option(Int),
    output: Option(Int),
    ok: Bool,
    count: Int,
  )
}

pub type Case {
  Case(catalog: List(#(#(String, String), Cost)), rows: List(Row))
}

@external(erlang, "albedo_session_cost", "estimate_rows")
fn estimate_rows(prices: Dict(#(String, String), Dynamic), rows: List(List(Dynamic))) -> Option(Float)

@external(erlang, "albedo_session_cost", "estimate_grouped")
fn estimate_grouped(prices: Dict(#(String, String), Dynamic), rows: List(List(Dynamic))) -> List(#(String, Option(Float)))

// Generators.

const rate_keys = ["input", "output", "cache_read", "cache_write"]

fn rate() -> qcheck.Generator(Rate) {
  qcheck.from_weighted_generators(#(12, qcheck.bounded_int(0, 30) |> qcheck.map(Whole)), [
    #(6, qcheck.bounded_float(0.0, 20.0) |> qcheck.map(Num)),
    #(1, qcheck.return(Bad)),
  ])
}

fn rates() -> qcheck.Generator(List(#(String, Rate))) {
  // Each key is present with probability 9/10.
  qcheck.fixed_length_list_from(qcheck.tuple2(qcheck.bounded_int(0, 9), rate()), 4)
  |> qcheck.map(fn(found) {
    list.zip(rate_keys, found)
    |> list.filter_map(fn(entry) {
      let #(key, #(roll, value)) = entry
      case roll {
        0 -> Error(Nil)
        _ -> Ok(#(key, value))
      }
    })
  })
}

const tier_sizes = [100, 1000, 128_000, 200_000, 250_000]

fn cost() -> qcheck.Generator(Cost) {
  use base, tiers, over <- qcheck.map3(
    rates(),
    qcheck.fixed_length_list_from(qcheck.tuple2(qcheck.bounded_int(0, 3), rates()), 5),
    qcheck.option_from(rates()),
  )
  let tiers =
    list.zip(tier_sizes, tiers)
    |> list.filter_map(fn(entry) {
      let #(size, #(roll, rates)) = entry
      case roll {
        0 -> Ok(#(size, rates))
        _ -> Error(Nil)
      }
    })
  Cost(base, tiers, over)
}

const providers = ["p1", "p2"]

const models = ["m1", "m2", "M1"]

pub fn catalog() -> qcheck.Generator(List(#(#(String, String), Cost))) {
  let keys =
    list.flat_map(providers, fn(provider) {
      list.map(models, fn(model) { #(provider, model) })
    })
  use entries <- qcheck.map(
    qcheck.fixed_length_list_from(qcheck.tuple2(qcheck.bounded_int(0, 2), cost()), list.length(keys)),
  )
  list.zip(keys, entries)
  |> list.filter_map(fn(entry) {
    let #(key, #(roll, cost)) = entry
    case roll {
      0 -> Error(Nil)
      _ -> Ok(#(key, cost))
    }
  })
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

/// Token counts concentrated at the pricer's thresholds.
fn tokens() -> qcheck.Generator(Int) {
  qcheck.from_weighted_generators(#(3, qcheck.bounded_int(0, 2000)), [
    #(2, pick([0, 1, 99, 100, 101, 999, 1000, 1001, 128_000, 128_001])),
    #(2, pick([199_999, 200_000, 200_001, 250_000, 250_001, 1_000_000])),
    #(1, qcheck.bounded_int(0, 2_000_000)),
  ])
}

fn maybe(generator: qcheck.Generator(Int), missing: Int) -> qcheck.Generator(Option(Int)) {
  qcheck.from_weighted_generators(#(10 - missing, generator |> qcheck.map(Some)), [
    #(missing, qcheck.return(None)),
  ])
}

pub fn row() -> qcheck.Generator(Row) {
  use #(session, profile, model), #(input, cached_share, created_share), #(write_shape, output, ok, count) <- qcheck.map3(
    qcheck.tuple3(pick(["a", "b", "c"]), pick(["p1", "p1", "p2", "p2", "zz"]), pick(["m1", "m1", "m2", "m2", "M1", "m3"])),
    qcheck.tuple3(maybe(tokens(), 1), qcheck.bounded_int(0, 12), qcheck.bounded_int(0, 12)),
    qcheck.tuple4(qcheck.bounded_int(0, 19), maybe(tokens(), 1), qcheck.bool(), qcheck.bounded_int(1, 3)),
  )
  let total = option.unwrap(input, 1000)
  // Shares above ten overshoot the input, which the pricer clamps.
  let share = fn(n) {
    case n {
      0 -> None
      _ -> Some(total * n / 10)
    }
  }
  let cached = share(cached_share)
  let created = share(created_share)
  let c = option.unwrap(created, 0)
  // Cache-write splits: none, all 5m, all 1h, a split, or inconsistent.
  let #(w5, w1) = case write_shape {
    0 | 1 | 2 | 3 -> #(None, None)
    4 -> #(Some(c), Some(0))
    5 -> #(Some(0), Some(c))
    6 | 7 -> #(Some(c / 3), Some(c - c / 3))
    8 -> #(Some(c + 1), None)
    9 -> #(Some(0), Some(0))
    _ -> #(None, None)
  }
  Row(session, profile, model, input, cached, created, w5, w1, output, ok, count)
}

fn case_generator() -> qcheck.Generator(Case) {
  qcheck.map2(catalog(), qcheck.generic_list(row(), qcheck.bounded_int(0, 8)), Case)
}

// Conversions to the pricer's terms.

fn rate_value(rate: Rate) -> Dynamic {
  case rate {
    Num(value) -> dynamic.float(value)
    Whole(value) -> dynamic.int(value)
    Bad -> dynamic.string("free")
  }
}

fn rate_map(rates: List(#(String, Rate)), extra: List(#(Dynamic, Dynamic))) -> Dynamic {
  list.map(rates, fn(entry) { #(dynamic.string(entry.0), rate_value(entry.1)) })
  |> list.append(extra)
  |> dynamic.properties
}

pub fn prices(catalog: List(#(#(String, String), Cost))) -> Dict(#(String, String), Dynamic) {
  list.map(catalog, fn(entry) {
    let #(key, Cost(base, tiers, over)) = entry
    let tier_list =
      list.map(tiers, fn(tier) {
        rate_map(tier.1, [
          #(
            dynamic.string("tier"),
            dynamic.properties([
              #(dynamic.string("type"), dynamic.string("context")),
              #(dynamic.string("size"), dynamic.int(tier.0)),
            ]),
          ),
        ])
      })
    let extra = case tiers {
      [] -> []
      _ -> [#(dynamic.string("tiers"), dynamic.list(tier_list))]
    }
    let extra = case over {
      None -> extra
      Some(rates) -> [#(dynamic.string("context_over_200k"), rate_map(rates, [])), ..extra]
    }
    #(key, rate_map(base, extra))
  })
  |> dict.from_list
}

fn count_value(value: Option(Int)) -> Dynamic {
  case value {
    Some(n) -> dynamic.int(n)
    None -> proptest.undefined()
  }
}

/// A ledger row as the cost query selects it, optionally led by its session.
pub fn row_terms(row: Row, with_session: Bool) -> List(Dynamic) {
  let terms = [
    dynamic.string(row.profile),
    proptest.undefined(),
    dynamic.string(row.model),
    count_value(row.input),
    count_value(row.cached),
    count_value(row.created),
    count_value(row.w5),
    count_value(row.w1),
    count_value(row.output),
    dynamic.string(case row.ok {
      True -> "ok"
      False -> "error"
    }),
    dynamic.int(row.count),
  ]
  case with_session {
    True -> [dynamic.string(row.session), ..terms]
    False -> terms
  }
}

// The model, written from the pricer's documented rules.

fn rate_of(rates: List(#(String, Rate)), key: String) -> Result(Option(Float), Nil) {
  case list.key_find(rates, key) {
    Error(Nil) -> Ok(None)
    Ok(Num(value)) -> Ok(Some(value))
    Ok(Whole(value)) -> Ok(Some(int.to_float(value)))
    Ok(Bad) -> Error(Nil)
  }
}

/// Later lists override earlier ones key by key.
fn overlay(base: List(#(String, Rate)), top: List(#(String, Rate))) -> List(#(String, Rate)) {
  list.fold(top, base, fn(acc, entry) { list.key_set(acc, entry.0, entry.1) })
}

fn effective(cost: Cost, input: Int) -> List(#(String, Rate)) {
  let below =
    list.filter(cost.tiers, fn(tier) { input > tier.0 })
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.last
  case below, input > 200_000, cost.over_200k {
    Ok(tier), _, _ -> {
      proptest.bump("tier")
      overlay(cost.rates, tier.1)
    }
    Error(Nil), True, Some(over) -> {
      proptest.bump("over_200k")
      overlay(cost.rates, over)
    }
    _, _, _ -> cost.rates
  }
}

/// The catalog entry for a profile and model: the profile's own entry,
/// matched exactly or case-insensitively when that is unambiguous, else the
/// one price every provider listing the model agrees on.
fn lookup(catalog: List(#(#(String, String), Cost)), profile: String, model: String) -> Result(Cost, Nil) {
  let lower = string.lowercase(model)
  // Erlang term equality treats 2 and 2.0 alike, so the model does too.
  let distinct = fn(entries: List(#(#(String, String), Cost))) {
    list.map(entries, fn(entry) { numeric(entry.1) }) |> list.unique
  }
  case list.key_find(catalog, #(profile, lower)) {
    Ok(cost) -> Ok(cost)
    Error(Nil) -> {
      let own =
        list.filter(catalog, fn(entry) {
          { entry.0 }.0 == profile && string.lowercase({ entry.0 }.1) == lower
        })
      case distinct(own) {
        [cost] -> Ok(cost)
        _ -> {
          proptest.bump("fallback")
          case
            distinct(
              list.filter(catalog, fn(entry) { string.lowercase({ entry.0 }.1) == lower }),
            )
          {
            [cost] -> Ok(cost)
            _ -> Error(Nil)
          }
        }
      }
    }
  }
}

fn numeric(cost: Cost) -> Cost {
  let rates = fn(rates: List(#(String, Rate))) {
    list.map(rates, fn(entry) {
      case entry.1 {
        Whole(n) -> #(entry.0, Num(int.to_float(n)))
        _ -> entry
      }
    })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  }
  Cost(
    rates(cost.rates),
    list.map(cost.tiers, fn(tier) { #(tier.0, rates(tier.1)) }),
    option.map(cost.over_200k, rates),
  )
}

fn charge(rates: List(#(String, Rate)), key: String, tokens: Int) -> Result(Float, Nil) {
  case tokens {
    0 -> Ok(0.0)
    _ ->
      case rate_of(rates, key) {
        Ok(Some(rate)) -> Ok(int.to_float(tokens) *. rate)
        _ -> Error(Nil)
      }
  }
}

pub fn model_row(catalog: List(#(#(String, String), Cost)), row: Row) -> Result(Float, Nil) {
  case row.ok, row.input, row.output {
    False, None, None -> {
      proptest.bump("unmetered_failure")
      Ok(0.0)
    }
    _, Some(input), Some(output) if input >= 0 && output >= 0 -> {
      use cost <- result.try(lookup(catalog, row.profile, row.model))
      let rates = effective(cost, input)
      let cached = option.unwrap(row.cached, 0)
      let created = option.unwrap(row.created, 0)
      let w5 = option.unwrap(row.w5, 0)
      let w1 = option.unwrap(row.w1, 0)
      let fresh = int.max(0, input - cached - created)
      use write <- result.try(case w5 + w1 {
        0 -> charge(rates, "cache_write", created)
        split if split == created -> {
          proptest.bump("split_write")
          use five <- result.try(charge(rates, "cache_write", w5))
          use hour <- result.map(charge(rates, "input", w1))
          five +. 2.0 *. hour
        }
        _ -> Error(Nil)
      })
      use fresh_cost <- result.try(charge(rates, "input", fresh))
      use read_cost <- result.try(charge(rates, "cache_read", cached))
      use output_cost <- result.map(charge(rates, "output", output))
      int.to_float(row.count) *. { fresh_cost +. read_cost +. write +. output_cost } /. 1_000_000.0
    }
    _, _, _ -> Error(Nil)
  }
}

pub fn model_total(catalog: List(#(#(String, String), Cost)), rows: List(Row)) -> Option(Float) {
  list.try_fold(rows, 0.0, fn(total, row) {
    model_row(catalog, row) |> result.map(float.add(total, _))
  })
  |> option.from_result
}

pub fn close(a: Option(Float), b: Option(Float)) -> Bool {
  case a, b {
    None, None -> True
    Some(x), Some(y) ->
      float.absolute_value(x -. y) <=. 1.0e-9 *. float.max(1.0, float.max(float.absolute_value(x), float.absolute_value(y)))
    _, _ -> False
  }
}

fn show(value: Option(Float)) -> String {
  case value {
    None -> "unknown"
    Some(x) -> float.to_string(x)
  }
}

fn sessions(rows: List(Row)) -> List(String) {
  list.map(rows, fn(row) { row.session }) |> list.unique |> list.sort(string.compare)
}

pub fn main() -> Nil {
  proptest.check("grouped estimate matches the pricing model", 100, case_generator(), fn(c) {
    let found =
      estimate_grouped(prices(c.catalog), list.map(c.rows, row_terms(_, True)))
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    assert list.map(found, fn(entry) { entry.0 }) == sessions(c.rows)
    list.each(found, fn(entry) {
      let expected = model_total(c.catalog, list.filter(c.rows, fn(row) { row.session == entry.0 }))
      proptest.bump(case expected {
        None -> "unknown_session"
        Some(_) -> "priced_session"
      })
      case close(entry.1, expected) {
        True -> Nil
        False -> panic as { "session " <> entry.0 <> ": pricer " <> show(entry.1) <> ", model " <> show(expected) }
      }
    })
  })

  proptest.check("estimate ignores row order", 100, qcheck.tuple2(case_generator(), qcheck.uniform_int()), fn(input) {
    let #(c, salt) = input
    let shuffled =
      list.index_map(c.rows, fn(row, i) { #(int.bitwise_exclusive_or(i * 7919, salt) % 1009, row) })
      |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
      |> list.map(fn(entry) { entry.1 })
    let p = prices(c.catalog)
    assert close(
      estimate_rows(p, list.map(c.rows, row_terms(_, False))),
      estimate_rows(p, list.map(shuffled, row_terms(_, False))),
    )
  })

  proptest.check("a row counted k times prices as k single rows", 100, case_generator(), fn(c) {
    let expanded =
      list.flat_map(c.rows, fn(row) { list.repeat(Row(..row, count: 1), row.count) })
    let p = prices(c.catalog)
    assert close(
      estimate_rows(p, list.map(c.rows, row_terms(_, False))),
      estimate_rows(p, list.map(expanded, row_terms(_, False))),
    )
  })

  proptest.check("estimates add across a split of the rows", 100, qcheck.tuple2(case_generator(), qcheck.bounded_int(0, 8)), fn(input) {
    let #(c, at) = input
    let #(left, right) = list.split(c.rows, at)
    let p = prices(c.catalog)
    let price = fn(rows) { estimate_rows(p, list.map(rows, row_terms(_, False))) }
    let summed = case price(left), price(right) {
      Some(a), Some(b) -> Some(a +. b)
      _, _ -> None
    }
    assert close(price(c.rows), summed)
  })
}
