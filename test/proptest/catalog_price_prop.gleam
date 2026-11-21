//// The models.dev price index against a walk of the same JSON: every model
//// with an object `cost` is priced under its own provider and model id, and
//// nothing else is.

import albedo_models_dev/catalog_cache
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck

type Cost {
  CostObject(fields: List(#(String, json.Json)))
  CostText(text: String)
  CostList(numbers: List(Int))
  CostNull
}

type Models {
  ModelsOf(costs: List(Option(Cost)))
  ModelsText(text: String)
}

type Provider {
  ProviderOf(models: Models)
  ProviderText(text: String)
}

type Case {
  Case(providers: List(Provider))
}

fn field_value() -> qcheck.Generator(json.Json) {
  qcheck.from_weighted_generators(
    #(5, qcheck.map(qcheck.bounded_int(0, 1000), json.int)),
    [
      #(2, qcheck.map(qcheck.bounded_float(0.0, 100.0), json.float)),
      #(1, qcheck.return(json.null())),
      #(1, qcheck.map(qcheck.string(), json.string)),
    ],
  )
}

fn tier() -> qcheck.Generator(json.Json) {
  use size <- qcheck.bind(qcheck.bounded_int(0, 300_000))
  use input <- qcheck.bind(field_value())
  use output <- qcheck.bind(field_value())
  qcheck.return(
    json.object([
      #(
        "tier",
        json.object([
          #("type", json.string("context")),
          #("size", json.int(size)),
        ]),
      ),
      #("input", input),
      #("output", output),
    ]),
  )
}

fn cost() -> qcheck.Generator(Cost) {
  qcheck.from_weighted_generators(
    #(8, {
      use fields <- qcheck.bind(qcheck.generic_list(
        qcheck.map2(
          qcheck.from_weighted_generators(#(3, qcheck.return("input")), [
            #(2, qcheck.return("output")),
            #(2, qcheck.return("cache_read")),
            #(1, qcheck.return("cache_write")),
            #(1, qcheck.string()),
          ]),
          field_value(),
          fn(name, value) { #(name, value) },
        ),
        qcheck.bounded_int(0, 4),
      ))
      use tiers <- qcheck.bind(qcheck.generic_list(
        tier(),
        qcheck.bounded_int(0, 2),
      ))
      use over <- qcheck.bind(qcheck.option_from(field_value()))
      let fields = case tiers {
        [] -> fields
        tiers -> [#("tiers", json.array(tiers, fn(tier) { tier })), ..fields]
      }
      let fields = case over {
        Some(value) -> [
          #("context_over_200k", json.object([#("input", value)])),
          ..fields
        ]
        None -> fields
      }
      qcheck.return(CostObject(fields))
    }),
    [
      #(1, qcheck.map(qcheck.string(), CostText)),
      #(
        1,
        qcheck.map(
          qcheck.generic_list(
            qcheck.bounded_int(-10, 10),
            qcheck.bounded_int(0, 3),
          ),
          CostList,
        ),
      ),
      #(1, qcheck.return(CostNull)),
    ],
  )
}

fn models() -> qcheck.Generator(Models) {
  qcheck.from_weighted_generators(
    #(
      9,
      qcheck.map(
        qcheck.generic_list(
          qcheck.option_from(cost()),
          qcheck.bounded_int(0, 3),
        ),
        ModelsOf,
      ),
    ),
    [#(1, qcheck.map(qcheck.string(), ModelsText))],
  )
}

fn scenario() -> qcheck.Generator(Case) {
  qcheck.map(
    qcheck.generic_list(
      qcheck.from_weighted_generators(#(9, qcheck.map(models(), ProviderOf)), [
        #(1, qcheck.map(qcheck.string(), ProviderText)),
      ]),
      qcheck.bounded_int(0, 3),
    ),
    Case,
  )
}

fn cost_json(cost: Cost) -> json.Json {
  case cost {
    CostObject(fields) -> json.object(fields)
    CostText(text) -> json.string(text)
    CostList(numbers) -> json.array(numbers, json.int)
    CostNull -> json.null()
  }
}

fn models_json(models: Models) -> json.Json {
  case models {
    ModelsOf(costs) ->
      json.object(
        list.index_map(costs, fn(cost, index) {
          #("m" <> int.to_string(index), case cost {
            Some(cost) -> json.object([#("cost", cost_json(cost))])
            None -> json.object([#("name", json.string("unnamed"))])
          })
        }),
      )
    ModelsText(text) -> json.string(text)
  }
}

fn document(c: Case) -> json.Json {
  json.object(
    list.index_map(c.providers, fn(provider, index) {
      #("p" <> int.to_string(index), case provider {
        ProviderOf(models) -> json.object([#("models", models_json(models))])
        ProviderText(text) -> json.string(text)
      })
    }),
  )
}

/// The expected index: walked from the same generated values, not from the
/// production code. Each object `cost` is priced as it parses.
fn expected(c: Case) -> Dict(#(String, String), Dynamic) {
  list.index_fold(c.providers, dict.new(), fn(prices, provider, index) {
    case provider {
      ProviderText(_) -> prices
      ProviderOf(ModelsText(_)) -> prices
      ProviderOf(ModelsOf(costs)) -> {
        let name = "p" <> int.to_string(index)
        list.index_fold(costs, prices, fn(prices, cost, model) {
          case cost {
            Some(CostObject(_) as cost) ->
              case json.parse(json.to_string(cost_json(cost)), decode.dynamic) {
                Ok(value) ->
                  dict.insert(
                    prices,
                    #(name, "m" <> int.to_string(model)),
                    value,
                  )
                Error(_) -> panic as "generated JSON did not parse"
              }
            _ -> prices
          }
        })
      }
    }
  })
}

fn write(path: String, c: Case, mtime: Int) -> Nil {
  proptest.write_file(
    path,
    bit_array.from_string(json.to_string(document(c))),
    mtime,
  )
}

fn path() -> String {
  "/tmp/albedo-proptest-catalog-"
  <> int.to_string(proptest.unique())
  <> "/models.json"
}

pub fn main() -> Nil {
  proptest.check(
    "prices index every model with an object cost",
    60,
    scenario(),
    fn(c) {
      let path = path()
      write(path, c, 1000)
      let costs =
        list.flat_map(c.providers, fn(provider) {
          case provider {
            ProviderText(_) -> []
            ProviderOf(ModelsText(_)) -> []
            ProviderOf(ModelsOf(costs)) -> costs
          }
        })
      proptest.bump("priced_" <> int.to_string(list.length(costs)))
      let found = catalog_cache.prices(path)
      let wanted = expected(c)
      proptest.bump("pairs_" <> int.to_string(dict.size(wanted)))
      case found == wanted {
        True -> Nil
        False ->
          panic as {
            "price index differs: expected "
            <> int.to_string(dict.size(wanted))
            <> " pairs, found "
            <> int.to_string(dict.size(found))
            <> "; missing "
            <> string.inspect(list.take(
              list.filter(dict.keys(wanted), fn(key) {
                !dict.has_key(found, key)
              }),
              3,
            ))
            <> "; extra "
            <> string.inspect(list.take(
              list.filter(dict.keys(found), fn(key) {
                !dict.has_key(wanted, key)
              }),
              3,
            ))
            <> " for "
            <> json.to_string(document(c))
          }
      }
      // A second read is served from the cache and agrees.
      assert catalog_cache.prices(path) == wanted
      Nil
    },
  )

  proptest.check(
    "prices follow a rewritten catalog",
    40,
    qcheck.tuple2(scenario(), scenario()),
    fn(pair) {
      let #(first, second) = pair
      let path = path()
      write(path, first, 1000)
      let before = expected(first)
      assert catalog_cache.prices(path) == before
      write(path, second, 2000)
      let after = expected(second)
      proptest.bump(case before == after {
        True -> "same_prices"
        False -> "changed_prices"
      })
      case catalog_cache.prices(path) == after {
        True -> Nil
        False -> panic as "prices kept the replaced catalog's index"
      }
    },
  )

  proptest.check(
    "an unreadable catalog prices nothing",
    30,
    qcheck.string(),
    fn(text) {
      let path = path()
      proptest.write_file(path, bit_array.from_string(text), 1000)
      case json.parse(text, decode.dynamic) {
        Ok(_) -> Nil
        Error(_) -> {
          assert catalog_cache.prices(path) == dict.new()
          Nil
        }
      }
      assert catalog_cache.prices(path <> ".missing") == dict.new()
      proptest.bump(
        "read_"
        <> case result.is_ok(json.parse(text, decode.dynamic)) {
          True -> "json"
          False -> "not_json"
        },
      )
      Nil
    },
  )
}
