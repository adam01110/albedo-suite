//// The suite's models.dev price index (session cost): parsing, saved-index
//// reload, completion of an index saved without prices, and trimming that
//// keeps `cost`, provider `npm` and model `provider`.

import albedo_file/revision as file_revision
import albedo_models_dev/catalog_cache
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/io
import gleam/json
import gleam/string

const source =
  "{\"p\":{\"api\":\"https://p.example/v1\",\"npm\":\"@ai-sdk/openai\",\"models\":{\"m\":{\"id\":\"m\",\"provider\":{\"npm\":\"@ai-sdk/anthropic\"},\"cost\":{\"input\":1.5,\"output\":6,\"cache_read\":0.15},\"limit\":{\"context\":8000,\"output\":1000}},\"free\":{\"id\":\"free\",\"cost\":\"none\"},\"plain\":{\"id\":\"plain\"}}}}"

pub fn main() -> Nil {
  let directory = "/tmp/albedo-suite-prices-" <> int.to_string(unique())
  let assert Ok(cost) =
    json.parse(
      "{\"input\":1.5,\"output\":6,\"cache_read\":0.15}",
      decode.dynamic,
    )
  let expected = dict.from_list([#(#("p", "m"), cost)])

  // A parse indexes object costs only, and saves them in the index.
  let parsed = directory <> "/parsed.json"
  write(parsed, <<source:utf8>>)
  assert catalog_cache.prices(parsed) == expected
  let assert Ok(index) = read(parsed <> ".index")
  let assert Ok(saved) = decode.run(binary_to_term(index), saved_decoder())
  assert saved.0 == 4
  assert saved.1 == expected

  // An unparsable catalog of the same revision reloads prices from its index.
  let copied = directory <> "/copied.json"
  unparsable_twin(parsed, copied)
  write(copied <> ".index", index)
  assert catalog_cache.prices(copied) == expected

  // An index saved without prices, as upstream writes it, still serves
  // lookups and is completed from the catalog once.
  let unpriced = directory <> "/unpriced.json"
  write(unpriced, <<source:utf8>>)
  let assert Ok(file_revision.Regular(revision)) = file_revision.read(parsed)
  let assert Ok(Nil) = file_revision.set_modified(unpriced, revision.modified)
  let assert Ok(fields) =
    decode.run(binary_to_term(index), {
      use index <- decode.field(2, decode.dynamic)
      use providers <- decode.field(3, decode.dynamic)
      decode.success(#(index, providers))
    })
  write(
    unpriced <> ".index",
    term_to_binary(#(4, #(revision.size, revision.modified), fields.0, fields.1)),
  )
  let assert Ok(_) = catalog_cache.catalog(unpriced)
  assert catalog_cache.prices(unpriced) == expected
  let assert Ok(completed) = read(unpriced <> ".index")
  let assert Ok(saved) = decode.run(binary_to_term(completed), saved_decoder())
  assert saved.1 == expected

  // A legacy catalog is trimmed in place, keeping cost and SDK routing.
  let legacy = directory <> "/legacy.json"
  write(legacy, <<
    string.replace(source, "{\"api\"", "{\"name\":\"P\",\"api\""):utf8,
  >>)
  assert catalog_cache.prices(legacy) == expected
  let assert Ok(trimmed) = read(legacy)
  assert_trimmed(trimmed)

  let _ = del_dir_r(directory)
  io.println(
    "Catalog prices: parse, index reload, unpriced index completion and trimming passed",
  )
}

fn assert_trimmed(bytes: BitArray) -> Nil {
  let assert Ok(text) = json.parse_bits(bytes, decode.dynamic)
  let at = fn(path, decoder) { decode.run(text, decode.at(path, decoder)) }
  assert at(["p", "npm"], decode.string) == Ok("@ai-sdk/openai")
  assert at(["p", "models", "m", "provider", "npm"], decode.string)
    == Ok("@ai-sdk/anthropic")
  assert decode.run(
      text,
      decode.at(["p", "models", "m", "cost", "output"], decode.int),
    )
    == Ok(6)
  assert at(["p", "name"], decode.string) |> is_error
  Nil
}

fn is_error(value: Result(a, b)) -> Bool {
  case value {
    Ok(_) -> False
    Error(_) -> True
  }
}

/// Version and price index of a saved index.
fn saved_decoder() -> decode.Decoder(
  #(Int, dict.Dict(#(String, String), Dynamic)),
) {
  use version <- decode.field(0, decode.int)
  use prices <- decode.field(
    4,
    decode.dict(
      {
        use provider <- decode.field(0, decode.string)
        use model <- decode.field(1, decode.string)
        decode.success(#(provider, model))
      },
      decode.dynamic,
    ),
  )
  decode.success(#(version, prices))
}

/// `to` gets the same size and modification time as `from`, but bytes no
/// JSON parser accepts.
fn unparsable_twin(from: String, to: String) -> Nil {
  let assert Ok(file_revision.Regular(revision)) = file_revision.read(from)
  write(to, <<string.repeat("x", revision.size):utf8>>)
  let assert Ok(Nil) = file_revision.set_modified(to, revision.modified)
  Nil
}

fn write(path: String, bytes: BitArray) -> Nil {
  let _ = ensure_dir(path)
  let assert True =
    write_file(path, bytes) == atom.to_dynamic(atom.create("ok"))
  Nil
}

@external(erlang, "erlang", "term_to_binary")
fn term_to_binary(value: a) -> BitArray

@external(erlang, "erlang", "binary_to_term")
fn binary_to_term(bytes: BitArray) -> Dynamic

@external(erlang, "file", "read_file")
fn read(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "file", "write_file")
fn write_file(path: String, bytes: BitArray) -> Dynamic

@external(erlang, "filelib", "ensure_dir")
fn ensure_dir(path: String) -> Dynamic

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> Dynamic

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int
