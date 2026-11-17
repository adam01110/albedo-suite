//// Catalog interpretation and selection over the native revision-cached index.

import albedo/harness/sdk/extension
import albedo_bytes/term
import albedo_model as types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

// These tuples are the persisted index ABI. Decode untrusted scalar metadata
// before returning an answer; do not copy or re-encode the whole catalog.
pub type IndexedModel =
  // Id, context limit, output limit, input modalities, reasoning efforts, display name.
  #(String, Dynamic, Dynamic, List(String), List(String), String)

pub type Provider =
  // Host, API URL, environment variables, sorted model ids.
  #(String, Dynamic, List(String), List(String))

pub type Candidate =
  #(String, IndexedModel)

pub type LookupError {
  MissingModel
  Unavailable(reason: String)
}

pub fn select(
  candidates: List(Candidate),
  providers: Dict(String, Provider),
  host: String,
) -> Result(extension.ModelInfo, LookupError) {
  let matched = case host {
    "" -> Error(Nil)
    "chatgpt.com" -> list.find(candidates, fn(entry) { entry.0 == "openai" })
    _ ->
      list.find(candidates, fn(entry) {
        // A candidate's provider must exist in the same cached index.
        let assert Ok(provider) = dict.get(providers, entry.0)
        provider.0 == host
      })
  }
  case matched {
    Ok(entry) ->
      attributed(entry, providers, case host {
        "chatgpt.com" -> "provider identity"
        _ -> "provider endpoint"
      })
    Error(_) -> unattributed(candidates)
  }
}

pub fn select_provider(
  candidates: List(Candidate),
  providers: Dict(String, Provider),
  provider: String,
) -> Result(extension.ModelInfo, LookupError) {
  use entry <- result.try(
    list.find(candidates, fn(entry) { entry.0 == provider })
    |> result.replace_error(MissingModel),
  )
  attributed(entry, providers, "provider name")
}

fn attributed(
  entry: Candidate,
  providers: Dict(String, Provider),
  matched: String,
) -> Result(extension.ModelInfo, LookupError) {
  use provider <- result.try(
    dict.get(providers, entry.0)
    |> result.replace_error(Unavailable("models catalog lookup failed")),
  )
  use api <- result.try(
    decode.run(provider.1, decode.optional(decode.string))
    |> result.replace_error(Unavailable(
      "models catalog provider API is invalid",
    )),
  )
  let model = entry.1
  Ok(
    extension.ModelInfo(
      ..extension.blank_model(model.0, entry.0),
      display_name: nonempty(model.5),
      context_tokens: positive_limit(model.1),
      max_output_tokens: positive_limit(model.2),
      input_modalities: model.3,
      endpoint: api,
      environment: provider.2,
      source: matched,
      efforts: types.parse_efforts(model.4),
    ),
  )
}

fn unattributed(
  candidates: List(Candidate),
) -> Result(extension.ModelInfo, LookupError) {
  let models = term.sort(candidates) |> list.map(fn(entry) { entry.1 })
  case models {
    [] -> Error(MissingModel)
    [first, ..] -> {
      let limits = list.map(models, fn(model) { #(model.1, model.2) })
      let matched = case term.unique_sorted(limits) {
        [_] -> "model id"
        _ ->
          "model id; smallest limits of "
          <> int.to_string(list.length(models))
          <> " providers"
      }
      Ok(
        extension.ModelInfo(
          ..extension.blank_model(first.0, ""),
          display_name: case
            models
            |> list.filter_map(fn(model) {
              nonempty(model.5) |> option.to_result(Nil)
            })
            |> list.unique
          {
            [name] -> Some(name)
            _ -> None
          },
          context_tokens: smallest(list.map(models, fn(model) { model.1 })),
          // The smallest window is the safe one to compact by, but another
          // provider's smaller output limit would cut this one's answers short.
          max_output_tokens: agreed(list.map(models, fn(model) { model.2 })),
          input_modalities: shared(list.map(models, fn(model) { model.3 })),
          source: matched,
          efforts: types.parse_efforts(
            shared(list.map(models, fn(model) { model.4 })),
          ),
        ),
      )
    }
  }
}

fn positive_limit(value: Dynamic) -> Option(Int) {
  case decode.run(value, decode.int) {
    Ok(limit) if limit > 0 -> Some(limit)
    _ -> None
  }
}

fn smallest(values: List(Dynamic)) -> Option(Int) {
  list.fold(values, None, fn(smallest, value) {
    case smallest, positive_limit(value) {
      None, known -> known
      Some(current), Some(known) -> Some(int.min(current, known))
      _, None -> smallest
    }
  })
}

/// The limit every candidate that reports one agrees on.
fn agreed(values: List(Dynamic)) -> Option(Int) {
  let known =
    list.filter_map(values, fn(value) {
      positive_limit(value) |> option.to_result(Nil)
    })
  case list.unique(known) {
    [limit] -> Some(limit)
    _ -> None
  }
}

// Empty lists mean unknown, so only candidates reporting capabilities constrain
// the intersection. Keep the first reporting candidate's order and duplicates.
fn shared(lists: List(List(String))) -> List(String) {
  case list.filter(lists, fn(items) { items != [] }) {
    [] -> []
    [first, ..rest] ->
      list.filter(first, fn(item) {
        list.all(rest, fn(items) { list.contains(items, item) })
      })
  }
}

pub fn list_provider(
  providers: Dict(String, Provider),
  provider: String,
  host: String,
) -> Result(List(String), String) {
  let selected = case host {
    "" -> dict.get(providers, provider)
    _ ->
      dict.values(providers)
      |> list.find(fn(metadata) { metadata.0 == host })
      |> result.lazy_or(fn() { dict.get(providers, provider) })
  }
  selected
  |> result.map(fn(metadata) { metadata.3 })
  |> result.replace_error("provider is not in the cached catalog")
}

// Preserve native tuple ordering, including duplicate aliases from one provider,
// and numeric equality in the index's raw limit pairs.

/// Projection built inside the native parse worker; only the reduced index is
/// published. A legacy catalog may also need a trimmed file replacement.
pub type Prepared {
  Prepared(
    providers: Dict(String, Provider),
    index: Dict(String, List(Candidate)),
    replacement: Option(String),
  )
}

/// Validate a fetched catalog and retain only metadata consumed by lookup.
/// Cached files have a separate, more permissive root-shape contract.
pub fn compact(body: BitArray) -> Result(String, Nil) {
  use providers <- result.try(
    json.parse_bits(body, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(Nil),
  )
  case
    list.any(dict.values(providers), fn(raw) {
      case object(raw) {
        Ok(fields) ->
          case dict.get(fields, "models") {
            Ok(models) -> result.is_ok(object(models))
            Error(_) -> False
          }
        Error(_) -> False
      }
    })
  {
    True -> Ok(trim(providers))
    False -> Error(Nil)
  }
}

/// Build the version-3 index without normalizing its raw API and limit values.
pub fn prepare(decoded: Dynamic) -> Result(Prepared, String) {
  use providers <- result.try(
    object(decoded)
    |> result.replace_error("models catalog is not a provider object"),
  )
  use projected <- result.try(
    dict.fold(providers, Ok(#(dict.new(), dict.new())), fn(acc, name, raw) {
      use acc <- result.try(acc)
      project_provider(name, raw, acc)
    })
    |> result.replace_error("models catalog could not be read"),
  )
  let legacy =
    list.any(dict.values(providers), fn(raw) {
      case object(raw) {
        Ok(fields) -> dict.has_key(fields, "name")
        Error(_) -> False
      }
    })
  Ok(
    Prepared(projected.0, projected.1, case legacy {
      True -> Some(trim(providers))
      False -> None
    }),
  )
}

fn project_provider(
  name: String,
  raw: Dynamic,
  acc: #(Dict(String, Provider), Dict(String, List(Candidate))),
) -> Result(#(Dict(String, Provider), Dict(String, List(Candidate))), Nil) {
  case object(raw) {
    Error(_) -> Ok(acc)
    Ok(fields) -> {
      let models = field_object(fields, "models") |> dict.to_list
      let ids =
        list.map(models, fn(entry) {
          let id = case object(entry.1) {
            Ok(model) -> text_field(model, "id")
            Error(_) -> ""
          }
          case id {
            "" -> entry.0
            _ -> id
          }
        })
        |> list.filter(fn(id) { id != "" })
        |> term.unique_sorted
      use index <- result.try(
        list.try_fold(models, acc.1, fn(index, entry) {
          use model <- result.try(project_model(entry.1))
          let candidate = #(name, model)
          let index = add(index, entry.0, candidate)
          case string.split(entry.0, "/") {
            [_] -> Ok(index)
            parts -> {
              let assert Ok(alias) = list.last(parts)
              Ok(add(index, alias, candidate))
            }
          }
        }),
      )
      let api = raw_field(fields, "api")
      Ok(#(
        dict.insert(acc.0, name, #(
          host(api),
          api,
          strings(raw_field(fields, "env")),
          ids,
        )),
        index,
      ))
    }
  }
}

fn project_model(raw: Dynamic) -> Result(IndexedModel, Nil) {
  case object(raw) {
    Error(_) -> Ok(#("", term.json_null(), term.json_null(), [], [], ""))
    Ok(fields) -> {
      let limits = field_object(fields, "limit")
      let inputs = field_object(fields, "modalities")
      use efforts <- result.try(model_efforts(fields))
      Ok(#(
        text_field(fields, "id"),
        raw_field(limits, "context"),
        raw_field(limits, "output"),
        strings(raw_field(inputs, "input")),
        efforts,
        text_field(fields, "name"),
      ))
    }
  }
}

fn model_efforts(fields: Dict(String, Dynamic)) -> Result(List(String), Nil) {
  let raw = case dict.get(fields, "reasoning_options") {
    Error(_) -> Ok([])
    Ok(raw) ->
      decode.run(raw, decode.list(decode.dynamic)) |> result.replace_error(Nil)
  }
  use entries <- result.try(raw)
  let decoder = {
    use kind <- decode.field("type", decode.string)
    use values <- decode.field("values", decode.list(decode.dynamic))
    decode.success(#(kind, values))
  }
  entries
  |> list.find_map(fn(entry) {
    case decode.run(entry, decoder) {
      Ok(#("effort", values)) ->
        Ok(
          list.filter_map(values, fn(value) {
            decode.run(value, decode.string) |> result.replace_error(Nil)
          }),
        )
      _ -> Error(Nil)
    }
  })
  |> result.unwrap([])
  |> Ok
}

fn add(
  index: Dict(String, List(Candidate)),
  key: String,
  candidate: Candidate,
) -> Dict(String, List(Candidate)) {
  dict.insert(index, key, [candidate, ..result.unwrap(dict.get(index, key), [])])
}

fn object(raw: Dynamic) -> Result(Dict(String, Dynamic), Nil) {
  decode.run(raw, decode.dict(decode.string, decode.dynamic))
  |> result.replace_error(Nil)
}

fn field_object(
  fields: Dict(String, Dynamic),
  name: String,
) -> Dict(String, Dynamic) {
  case dict.get(fields, name) {
    Ok(raw) -> object(raw) |> result.unwrap(dict.new())
    Error(_) -> dict.new()
  }
}

fn raw_field(fields: Dict(String, Dynamic), name: String) -> Dynamic {
  dict.get(fields, name) |> result.unwrap(term.json_null())
}

fn text_field(fields: Dict(String, Dynamic), name: String) -> String {
  decode.run(raw_field(fields, name), decode.string) |> result.unwrap("")
}

fn strings(raw: Dynamic) -> List(String) {
  decode.run(raw, decode.list(decode.dynamic))
  |> result.unwrap([])
  |> list.filter_map(fn(value) {
    decode.run(value, decode.string) |> result.replace_error(Nil)
  })
}

fn trim(providers: Dict(String, Dynamic)) -> String {
  providers
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    use fields <- result.try(object(entry.1))
    let models =
      field_object(fields, "models")
      |> dict.to_list
      |> list.filter_map(fn(entry) {
        use model <- result.try(object(entry.1))
        Ok(#(entry.0, trim_model(model)))
      })
    Ok(#(
      entry.0,
      json.object(
        // The provider's SDK package routes OpenCode Go protocols.
        list.append(retained(fields, ["api", "env", "npm"]), [
          #("models", json.object(models)),
        ]),
      ),
    ))
  })
  |> json.object
  |> json.to_string
}

fn trim_model(model: Dict(String, Dynamic)) -> json.Json {
  let nested =
    [#("limit", ["context", "output"]), #("modalities", ["input"])]
    |> list.filter_map(fn(container) {
      let fields = retained(field_object(model, container.0), container.1)
      case fields {
        [] -> Error(Nil)
        _ -> Ok(#(container.0, json.object(fields)))
      }
    })
  json.object(list.append(
    // A model's own SDK override and price serve protocol routing and
    // session cost.
    retained(model, ["id", "name", "provider", "cost", "reasoning_options"]),
    nested,
  ))
}

fn retained(
  fields: Dict(String, Dynamic),
  names: List(String),
) -> List(#(String, json.Json)) {
  list.filter_map(names, fn(name) {
    dict.get(fields, name)
    |> result.map(fn(value) { #(name, types.encode_value(value)) })
  })
}

/// Environment names for every provider at this host, including empty hosts.
pub fn env_for_host(
  providers: Dict(String, Provider),
  host: String,
) -> List(String) {
  dict.values(providers)
  |> list.filter(fn(provider) { provider.0 == host })
  |> list.flat_map(fn(provider) { provider.2 })
  |> term.unique_sorted
}

fn host(value: Dynamic) -> String {
  case decode.run(value, decode.string) {
    Ok(url) -> host_of(url)
    Error(_) -> ""
  }
}

/// The lowercase host of a URL, or `""` when it has none.
pub fn host_of(url: String) -> String {
  case uri.parse(url) {
    Ok(uri.Uri(host: Some(host), ..)) -> string.lowercase(host)
    _ -> ""
  }
}

fn nonempty(name: String) -> Option(String) {
  case string.trim(name) {
    "" -> None
    value -> Some(value)
  }
}
