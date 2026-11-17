//// The models.dev catalog cache: the bounded fetch through
//// `sdk/cached_fetch`, and the parsed catalog pinned once per file revision.
//// Lookups, listing, and the fetch's acceptance check are in `catalogue` and
//// `catalog`.

import albedo/harness/extensions/models/catalog.{
  type Candidate, type IndexedModel, type Provider,
}
import albedo/harness/sdk/cached_fetch
import albedo/harness/sdk/settings_store
import albedo_bytes/term_codec
import albedo_file
import albedo_file/revision.{type Revision, Revision} as file_revision
import albedo_process/pinned
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/atom
import gleam/option.{type Option, None, Some}
import gleam/result

const max_bytes = 33_554_432

const refresh_key = "albedo_models_refresh"

/// Every error the shared fetch reports on this cache's behalf keeps this
/// catalog's name.
const what = "models catalog"

/// The index format saved beside the catalog. Version 3 files, written as
/// an Erlang map, are still read.
const index_version = 4

/// A model id's candidates and the providers they name.
pub type Parsed =
  #(Dict(String, List(Candidate)), Dict(String, Provider))

/// The parse of one catalog revision. Index entries name their provider
/// instead of embedding it: embedded provider maps are shared on the heap
/// but expand to over a gigabyte when copied.
type Entry {
  Entry(revision: Revision, parsed: Parsed, prices: Option(Prices))
}

/// Each model's models.dev `cost` object, JSON-decoded, by provider id and
/// model id. A model without one is absent: its price is unknown.
pub type Prices =
  Dict(#(String, String), Dynamic)

fn entries() -> pinned.Pinned(Entry) {
  pinned.new("albedo/harness/extensions/models/catalog_cache")
}

/// Starts a background fetch when the cache is missing or stale.
pub fn refresh(
  catalog: String,
  url: String,
  max_age_ms: Int,
  accept: fn(BitArray) -> Result(String, String),
) -> Nil {
  cached_fetch.refresh(
    catalog,
    url,
    max_age_ms,
    refresh_key,
    what,
    accepted(accept),
    after_write,
  )
}

/// Fetches the catalog now and reports why it failed.
pub fn reload(
  catalog: String,
  url: String,
  accept: fn(BitArray) -> Result(String, String),
) -> Result(Nil, String) {
  cached_fetch.reload(catalog, url, what, accepted(accept), after_write)
}

fn accepted(
  accept: fn(BitArray) -> Result(String, String),
) -> fn(BitArray) -> Result(BitArray, String) {
  fn(body) { accept(body) |> result.map(bit_array.from_string) }
}

/// Once a catalog is replaced, its parse and saved index are stale. Both
/// heal on the next parse, but dropping them keeps the next lookup from
/// trusting the old revision first.
fn after_write(catalog: String) -> Nil {
  pinned.erase(entries(), catalog)
  albedo_file.delete(index_path(catalog))
}

/// The parsed catalog of the file's current revision.
pub fn catalog(catalog: String) -> Result(Parsed, String) {
  current(catalog) |> result.map(fn(entry) { entry.parsed })
}

/// The price index of the file's current revision, kept with its parse.
/// Empty when the catalog is missing or unreadable. An index saved without
/// prices, by upstream or an earlier suite, is completed from the catalog
/// once per revision.
pub fn prices(catalog: String) -> Prices {
  let priced = {
    use entry <- result.try(current(catalog))
    case entry.prices {
      Some(prices) -> Ok(prices)
      None -> reprice(catalog, entry.revision)
    }
  }
  result.unwrap(priced, dict.new())
}

fn current(catalog: String) -> Result(Entry, String) {
  case file_revision.read(catalog) {
    Ok(file_revision.Regular(revision)) if revision.size <= max_bytes ->
      case pinned.get(entries(), catalog) {
        Ok(entry) if entry.revision == revision -> Ok(entry)
        _ -> load(catalog, revision)
      }
    Ok(_) -> Error("models catalog is too large")
    Error(Nil) -> Error("no models catalog is cached")
  }
}

/// Parsing 4 MiB per request would be wasteful, so a file revision is parsed
/// once. Sessions start turns together, so a missing revision is parsed by
/// one caller while the rest wait on the lock and then read its result.
fn load(catalog: String, revision: Revision) -> Result(Entry, String) {
  let held =
    albedo_file.with_lock(catalog, albedo_file.Forever, fn() {
      case pinned.get(entries(), catalog) {
        Ok(entry) if entry.revision == revision -> Ok(entry)
        _ -> {
          use Nil <- result.try(
            cached_fetch.isolated(what, fn() { from_index(catalog, revision) }),
          )
          pinned.get(entries(), catalog)
          |> result.replace_error(what <> " could not be read")
        }
      }
    })
  result.unwrap(held, Error(what <> " could not be read"))
}

/// Reads the catalog's prices beside an index that has none, then saves and
/// pins them with that index. An unreadable catalog has no prices.
fn reprice(catalog: String, revision: Revision) -> Result(Prices, String) {
  let held =
    albedo_file.with_lock(catalog, albedo_file.Forever, fn() {
      case pinned.get(entries(), catalog) {
        Ok(Entry(revision: pinned_revision, parsed:, prices: None))
          if pinned_revision == revision
        -> {
          use prices <- result.map(
            cached_fetch.isolated(what, fn() {
              settings_store.read_json(catalog)
              |> result.map(price_index)
              |> result.unwrap(dict.new())
              |> Ok
            }),
          )
          save_index(catalog, revision, parsed, prices)
          pinned.put(entries(), catalog, Entry(revision, parsed, Some(prices)))
          prices
        }
        Ok(Entry(revision: pinned_revision, prices: Some(prices), ..))
          if pinned_revision == revision
        -> Ok(prices)
        _ -> Error(what <> " changed while reading prices")
      }
    })
  result.unwrap(held, Error(what <> " could not be read"))
}

/// The reduced index of the current revision, saved beside the catalog,
/// loads straight into its final shape. Decoding the JSON takes several
/// times more memory than the index it produces. A missing or stale index is
/// rebuilt.
fn from_index(catalog: String, revision: Revision) -> Result(Nil, String) {
  let saved = {
    use bytes <- result.try(albedo_file.read(index_path(catalog)))
    use term <- result.try(term_codec.decode_safe(bytes))
    decode.run(term, saved_index(revision)) |> result.replace_error(Nil)
  }
  case saved {
    Ok(#(parsed, prices)) -> {
      pinned.put(entries(), catalog, Entry(revision, parsed, prices))
      Ok(Nil)
    }
    Error(Nil) -> parse(catalog, revision)
  }
}

fn index_path(catalog: String) -> String {
  catalog <> ".index"
}

fn parse(catalog: String, revision: Revision) -> Result(Nil, String) {
  case settings_store.read_json(catalog) {
    Ok(decoded) -> {
      use prepared <- result.map(catalog.prepare(decoded))
      let parsed = #(prepared.index, prepared.providers)
      let prices = price_index(decoded)
      let current = retrim(catalog, prepared.replacement, revision)
      save_index(catalog, current, parsed, prices)
      pinned.put(entries(), catalog, Entry(current, parsed, Some(prices)))
    }
    Error(reason) ->
      case reason == atom.create("invalid") {
        True -> Error("models catalog is not valid JSON")
        False -> Error("models catalog could not be read")
      }
  }
}

/// Best effort: without an index the next start parses the catalog again.
/// The suite appends the price index as a fifth element, which upstream's
/// reader of the same version ignores.
fn save_index(
  catalog: String,
  revision: Revision,
  parsed: Parsed,
  prices: Prices,
) -> Nil {
  let saved = #(
    index_version,
    #(revision.size, revision.modified),
    parsed.0,
    parsed.1,
    prices,
  )
  let _ =
    albedo_file.write_private(
      index_path(catalog),
      term_codec.encode_compressed(saved, 1),
    )
  Nil
}

/// A catalog cached before trimming existed is trimmed in place on first
/// parse, keeping its mtime so the refresh schedule is unchanged. Answers
/// the revision the pinned entry must carry: the rewritten file's, or the
/// original's when the file is already trimmed or cannot be replaced.
fn retrim(
  catalog: String,
  replacement: option.Option(String),
  revision: Revision,
) -> Revision {
  case replacement {
    None -> revision
    Some(bytes) ->
      case
        cached_fetch.commit(
          catalog,
          bit_array.from_string(bytes),
          what,
          after_write,
        )
      {
        Ok(Nil) -> {
          let _ = file_revision.set_modified(catalog, revision.modified)
          case file_revision.read(catalog) {
            Ok(file_revision.Regular(rewritten)) -> rewritten
            _ -> revision
          }
        }
        Error(_) -> revision
      }
  }
}

/// A saved index of `revision`: `{4, Revision, Index, Providers}` with the
/// suite's optional `Prices` after them, or the earlier
/// `{3, Revision, #{index => Index, providers => Providers}}`.
fn saved_index(revision: Revision) -> Decoder(#(Parsed, Option(Prices))) {
  use version <- decode.field(0, decode.int)
  use size <- decode.subfield([1, 0], decode.int)
  use modified <- decode.subfield([1, 1], decode.int)
  case Revision(size:, modified:) == revision, version {
    True, 4 -> {
      use index <- decode.field(2, index_decoder())
      use providers <- decode.field(3, providers_decoder())
      use prices <- decode.optional_field(
        4,
        None,
        decode.map(prices_decoder(), Some),
      )
      decode.success(#(#(index, providers), prices))
    }
    True, 3 ->
      decode.at([2], {
        use index <- decode.field(atom.create("index"), index_decoder())
        use providers <- decode.field(
          atom.create("providers"),
          providers_decoder(),
        )
        decode.success(#(#(index, providers), None))
      })
    _, _ -> decode.failure(#(#(dict.new(), dict.new()), None), "current index")
  }
}

fn prices_decoder() -> Decoder(Prices) {
  decode.dict(
    {
      use provider <- decode.field(0, decode.string)
      use model <- decode.field(1, decode.string)
      decode.success(#(provider, model))
    },
    decode.dynamic,
  )
}

/// Every model's `cost` object, keyed as the catalog names provider and
/// model. Models without an object `cost` are left out.
fn price_index(decoded: Dynamic) -> Prices {
  let object = decode.dict(decode.string, decode.dynamic)
  let providers = decode.run(decoded, object) |> result.unwrap(dict.new())
  dict.fold(providers, dict.new(), fn(prices, provider, raw) {
    let models =
      decode.run(raw, decode.at(["models"], object))
      |> result.unwrap(dict.new())
    dict.fold(models, prices, fn(prices, model, raw) {
      case decode.run(raw, decode.at(["cost"], decode.dynamic)) {
        Ok(cost) ->
          case decode.run(cost, object) {
            Ok(_) -> dict.insert(prices, #(provider, model), cost)
            Error(_) -> prices
          }
        Error(_) -> prices
      }
    })
  })
}

fn index_decoder() -> Decoder(Dict(String, List(Candidate))) {
  decode.dict(decode.string, decode.list(candidate_decoder()))
}

fn providers_decoder() -> Decoder(Dict(String, Provider)) {
  decode.dict(decode.string, {
    use host <- decode.field(0, decode.string)
    use api <- decode.field(1, decode.dynamic)
    use environment <- decode.field(2, decode.list(decode.string))
    use models <- decode.field(3, decode.list(decode.string))
    decode.success(#(host, api, environment, models))
  })
}

fn candidate_decoder() -> Decoder(Candidate) {
  use provider <- decode.field(0, decode.string)
  use model <- decode.field(1, indexed_model_decoder())
  decode.success(#(provider, model))
}

fn indexed_model_decoder() -> Decoder(IndexedModel) {
  use id <- decode.field(0, decode.string)
  use context <- decode.field(1, decode.dynamic)
  use output <- decode.field(2, decode.dynamic)
  use inputs <- decode.field(3, decode.list(decode.string))
  use efforts <- decode.field(4, decode.list(decode.string))
  use name <- decode.field(5, decode.string)
  decode.success(#(id, context, output, inputs, efforts, name))
}
