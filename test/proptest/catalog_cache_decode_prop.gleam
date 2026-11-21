//// Property tests for the models.dev catalog cache's saved index: the index
//// written beside a catalog must decode to exactly the parse it came from,
//// with and without the suite's price element, and prices must agree with a
//// recomputation from the catalog JSON. Expected prices and provider ids come
//// from the generated catalog, not from the module under test.

import albedo_bytes/term_codec
import albedo_file
import albedo_models_dev/catalog_cache
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import proptest
import qcheck

/// A cost object as `price_index` keeps it: keyed `(provider, model key)`, and
/// only when the catalog gives the model an object `cost`.
type Model {
  Model(
    key: String,
    id: String,
    context: Int,
    output: Int,
    price: Option(String),
  )
}

type ProviderInfo {
  ProviderInfo(
    name: String,
    api: String,
    env: List(String),
    models: List(Model),
  )
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn model_gen() -> qcheck.Generator(Model) {
  use key, id, context, output, price <- qcheck.map5(
    qcheck.from_weighted_generators(#(6, pick(["gpt-5", "claude-5", "m1"])), [
      #(2, pick(["openai/gpt-5", "a/b/c", "same"])),
      #(1, pick(["", "gemini-3"])),
    ]),
    qcheck.from_weighted_generators(#(5, qcheck.return("")), [
      #(3, pick(["gpt-5", "alias-5", "same"])),
    ]),
    qcheck.from_weighted_generators(#(6, pick([0, 200_000, 1_000_000])), [
      #(1, pick([-1])),
    ]),
    qcheck.from_weighted_generators(#(6, pick([8192, 32_000])), [
      #(1, pick([0, -5])),
    ]),
    qcheck.from_weighted_generators(#(6, qcheck.return(None)), [
      #(2, qcheck.return(Some("1.5"))),
      #(1, qcheck.return(Some("0"))),
    ]),
  )
  Model(key:, id:, context:, output:, price:)
}

/// One provider's body: an api URL, environment names, and its models. The
/// name is assigned by position so two providers never collide in the JSON
/// object, which would silently drop one of them.
fn provider_body_gen() -> qcheck.Generator(#(String, List(String), List(Model))) {
  let envs: List(List(String)) = [[], ["P_KEY"]]
  qcheck.map3(
    pick(["https://p.example/v1", ""]),
    pick(envs),
    qcheck.generic_list(model_gen(), qcheck.bounded_int(0, 3)),
    fn(api, env, models) { #(api, env, collapse(models)) },
  )
}

/// A JSON object holds one value per key, so a repeated model key names only
/// the last model written for it. Collapse the generated models the same way
/// before building either the catalog or the expectation.
fn collapse(models: List(Model)) -> List(Model) {
  list.fold(models, dict.new(), fn(by_key, model) {
    dict.insert(by_key, model.key, model)
  })
  |> dict.values
}

fn provider_name(index: Int) -> String {
  "p" <> int.to_string(index)
}

fn catalog_gen() -> qcheck.Generator(List(ProviderInfo)) {
  qcheck.generic_list(provider_body_gen(), qcheck.bounded_int(1, 3))
  |> qcheck.map(fn(bodies) {
    list.index_map(bodies, fn(body, index) {
      let #(api, env, models) = body
      ProviderInfo(name: provider_name(index), api:, env:, models:)
    })
  })
}

fn model_json(model: Model) -> #(String, json.Json) {
  let fields = [
    #("id", json.string(model.id)),
    #("name", json.string(model.id)),
    #(
      "limit",
      json.object([
        #("context", json.int(model.context)),
        #("output", json.int(model.output)),
      ]),
    ),
    #(
      "modalities",
      json.object([#("input", json.array(["text"], json.string))]),
    ),
  ]
  let fields = case model.price {
    None -> fields
    Some(price) -> [
      #("cost", json.object([#("input", json.string(price))])),
      ..fields
    ]
  }
  #(model.key, json.object(fields))
}

fn provider_json(provider: ProviderInfo) -> #(String, json.Json) {
  #(
    provider.name,
    json.object([
      #("api", json.string(provider.api)),
      #("env", json.array(provider.env, json.string)),
      #("models", json.object(list.map(provider.models, model_json))),
    ]),
  )
}

fn body_of(providers: List(ProviderInfo)) -> String {
  json.object(list.map(providers, provider_json)) |> json.to_string
}

/// The price index the catalog JSON names: one entry per model with an object
/// `cost`, keyed by the provider and the model's key in the catalog.
fn expected_prices(
  providers: List(ProviderInfo),
) -> List(#(#(String, String), String)) {
  list.flat_map(providers, fn(provider) {
    list.filter_map(provider.models, fn(model) {
      case model.price {
        Some(price) -> Ok(#(#(provider.name, model.key), price))
        None -> Error(Nil)
      }
    })
  })
  |> list.sort(fn(a, b) { string.compare(a.0.0, b.0.0) })
}

/// The ids a provider lists: each model's `id`, its catalog key when the id is
/// empty, unique and sorted.
fn expected_ids(provider: ProviderInfo) -> List(String) {
  provider.models
  |> list.filter_map(fn(model) {
    case model.id {
      "" ->
        case model.key {
          "" -> Error(Nil)
          key -> Ok(key)
        }
      id -> Ok(id)
    }
  })
  |> list.unique
  |> list.sort(string.compare)
}

fn same_prices(
  prices: Dict(#(String, String), Dynamic),
  expected: List(#(#(String, String), String)),
) -> Result(Nil, String) {
  case dict.size(prices) == list.length(expected) {
    False ->
      Error(
        "price index holds "
        <> int.to_string(dict.size(prices))
        <> " entries, expected "
        <> int.to_string(list.length(expected)),
      )
    True ->
      list.try_each(expected, fn(entry) {
        let #(key, price) = entry
        case dict.get(prices, key) {
          Error(_) -> Error("missing prices for " <> string.inspect(key))
          Ok(value) ->
            case decode.run(value, decode.at(["input"], decode.string)) {
              Ok(found) if found == price -> Ok(Nil)
              Ok(found) ->
                Error(
                  "prices for "
                  <> string.inspect(key)
                  <> " are "
                  <> found
                  <> ", expected "
                  <> price,
                )
              Error(_) ->
                Error(
                  "prices for " <> string.inspect(key) <> " are not an object",
                )
            }
        }
      })
  }
}

fn revision(size: Int, modified: Int) -> #(Int, Int) {
  #(size, modified)
}

fn write_catalog(path: String, body: String, modified: Int) -> Nil {
  proptest.write_file(path, bit_array.from_string(body), modified)
}

fn write_index(path: String, term: a, modified: Int) -> Nil {
  proptest.write_file(
    path <> ".index",
    term_codec.encode_compressed(term, 1),
    modified,
  )
}

pub fn main() -> Nil {
  let root = "/tmp/proptest-catalog-cache-" <> int.to_string(proptest.unique())
  let _ = proptest.remove_tree(root)
  let modified = 1_700_000_000

  proptest.check(
    "the saved index decodes to the parse it was written from",
    30,
    catalog_gen(),
    fn(providers) {
      let dir = root <> "/" <> int.to_string(proptest.unique())
      let body = body_of(providers)
      let prices = expected_prices(providers)
      proptest.bump(case prices {
        [] -> "no_prices"
        _ -> "prices"
      })

      // A fresh parse writes its index beside the catalog.
      let first = dir <> "/a/catalog.json"
      write_catalog(first, body, modified)
      let parsed = case catalog_cache.catalog(first) {
        Ok(parsed) -> parsed
        Error(why) -> panic as { "catalog did not parse: " <> why }
      }
      proptest.bump("parsed")
      list.each(providers, fn(provider) {
        let assert Ok(_) = dict.get(parsed.1, provider.name)
      })
      case same_prices(catalog_cache.prices(first), prices) {
        Ok(Nil) -> Nil
        Error(why) -> panic as { "a fresh parse priced wrong: " <> why }
      }
      // The provider metadata the parse keeps: ids, api, environment.
      list.each(providers, fn(provider) {
        let assert Ok(saved) = dict.get(parsed.1, provider.name)
        let #(_, api, env, ids) = saved
        assert ids == expected_ids(provider)
        assert env == provider.env
        let assert Ok(api) = decode.run(api, decode.string)
        assert api == provider.api
      })
      proptest.bump("provider_metadata")

      // The index the parse wrote, moved to another revision and read over a
      // catalog body that is not JSON at all: only a trusted index can answer,
      // so a decoder that silently gives up would be visible here.
      let index = case albedo_file.read(first <> ".index") {
        Ok(bytes) -> bytes
        Error(Nil) -> panic as "the parse saved no index"
      }
      let assert Ok(saved) = case term_codec.decode_safe(index) {
        Ok(term) -> Ok(term)
        Error(Nil) -> panic as "the saved index is not an external term"
      }
      let assert Ok(elements) = term_codec.tuple(saved)
      let assert [_, _, saved_index, saved_providers, saved_prices] = elements
      let body_size = bit_array.byte_size(bit_array.from_string(body))
      let copy = dir <> "/b/catalog.json"
      write_catalog(copy, "#", modified + 2)
      write_index(
        copy,
        #(
          4,
          revision(1, modified + 2),
          saved_index,
          saved_providers,
          saved_prices,
        ),
        modified + 2,
      )
      case catalog_cache.catalog(copy) {
        Ok(found) if found == parsed -> proptest.bump("saved_index_round_trip")
        Ok(_) ->
          panic as {
            "the saved index decoded to a different parse: "
            <> string.inspect(providers)
          }
        Error(_) ->
          panic as {
            "the saved index was not trusted, so the parse cache is lost: "
            <> string.inspect(providers)
          }
      }

      // The same saved index without its price element.
      let bare_copy = dir <> "/bb/catalog.json"
      write_catalog(bare_copy, "#", modified + 3)
      write_index(
        bare_copy,
        #(4, revision(1, modified + 3), saved_index, saved_providers),
        modified + 3,
      )
      case catalog_cache.catalog(bare_copy) {
        Ok(found) if found == parsed ->
          proptest.bump("saved_index_without_prices")
        Ok(_) ->
          panic as "the saved index without prices decoded to another parse"
        Error(_) -> panic as "the saved index without prices was refused"
      }

      // The saved index over its own catalog body: its prices must be the ones
      // the catalog JSON names.
      let repriced = dir <> "/c2/catalog.json"
      write_catalog(repriced, body, modified + 4)
      write_index(
        repriced,
        #(
          4,
          revision(body_size, modified + 4),
          saved_index,
          saved_providers,
          saved_prices,
        ),
        modified + 4,
      )
      case catalog_cache.catalog(repriced) == Ok(parsed) {
        True -> proptest.bump("saved_index_same_revision")
        False ->
          panic as "the saved index decoded to another parse beside its catalog"
      }
      case same_prices(catalog_cache.prices(repriced), prices) {
        Ok(Nil) -> proptest.bump("saved_prices")
        Error(why) -> panic as { "the saved price index is wrong: " <> why }
      }

      // The version-4 shape without the price element. The catalog body is not
      // JSON here, so only a trusted index can answer at all.
      let bare = dir <> "/c/catalog.json"
      write_catalog(bare, "#", modified)
      write_index(
        bare,
        #(4, revision(1, modified), parsed.0, parsed.1),
        modified,
      )
      case catalog_cache.catalog(bare) {
        Ok(found) if found == parsed -> proptest.bump("index_without_prices")
        Ok(_) -> panic as "an index without prices decoded to a different parse"
        Error(why) ->
          panic as {
            "an index without prices was refused, so the parse cache is lost: "
            <> why
          }
      }

      // The suite's own shape: the same index with a price element. Nothing is
      // written with a bare catalog body, so only the index can answer.
      let priced = dir <> "/d/catalog.json"
      write_catalog(priced, "#", modified)
      write_index(
        priced,
        #(4, revision(1, modified), parsed.0, parsed.1, dict.new()),
        modified,
      )
      case catalog_cache.catalog(priced) {
        Ok(found) if found == parsed -> proptest.bump("index_with_prices")
        Ok(_) -> panic as "an index with prices decoded to a different parse"
        Error(why) -> panic as { "an index with prices was refused: " <> why }
      }
      case dict.size(catalog_cache.prices(priced)) {
        0 -> proptest.bump("index_prices_empty")
        other ->
          panic as {
            "an empty price element decoded to " <> int.to_string(other)
          }
      }

      // A price element of the wrong type: the parse is the expensive part, so
      // the answer either keeps it or reports nothing at all.
      let broken = dir <> "/e/catalog.json"
      write_catalog(broken, "#", modified)
      write_index(
        broken,
        #(4, revision(1, modified), parsed.0, parsed.1, 42),
        modified,
      )
      case catalog_cache.catalog(broken) {
        Ok(_) -> proptest.bump("bad_prices_confined")
        Error(_) -> proptest.bump("bad_prices_discards_parse")
      }

      // A stale index: a different revision must not be trusted. The catalog
      // body is JSON again, so a reparse answers.
      let stale = dir <> "/f/catalog.json"
      write_catalog(stale, body, modified + 1)
      write_index(
        stale,
        #(4, revision(1, modified), parsed.0, parsed.1),
        modified,
      )
      case catalog_cache.catalog(stale) == Ok(parsed) {
        True -> proptest.bump("stale_index_reparsed")
        False -> panic as "a stale index answered for another revision"
      }
      Nil
    },
  )

  proptest.remove_tree(root)
}
