//// Which provider profile and model a new child or peer runs on.
////
//// Listing a profile's models can ask its endpoint over the network (the
//// generic openai extension reads `<endpoint>/models`), so callers resolve a
//// choice in their own process before they ask the registry: the registry
//// answers every request in the daemon, and an endpoint that never answers
//// once held it for seconds per spawn, failing every request meanwhile.

import albedo/clock
import albedo/daemon/configuration
import albedo/daemon/conversation
import albedo/daemon/session_provider
import albedo/harness/model_lists
import albedo/harness/runtime
import albedo/text_scalars
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

/// A profile and the model to run on it, or why there is none.
pub type Choice =
  Result(#(configuration.Provider, String), String)

/// One lookup's view: every profile's endpoint, read once, and the time by
/// which every list it asks for must have answered.
type Lookup {
  Lookup(
    host: runtime.Runtime,
    endpoints: dict.Dict(String, Option(String)),
    deadline: Int,
  )
}

/// A lookup waits for lists at most one first fetch from its start, however
/// many profiles it asks and however late each ask begins.
fn lookup(host: runtime.Runtime, home: String) -> Lookup {
  Lookup(
    host,
    session_provider.profile_endpoints(home),
    clock.monotonic_ms() + model_lists.first_wait_ms(),
  )
}

/// `requested` is "provider/model", a bare model, or "" for the parent's. A
/// bare model stays on the parent's provider when it lists it, and otherwise
/// moves to the one other provider that does. Other profiles are listed only
/// when the parent's provider may not list it (see `moved`).
pub fn resolve(
  host: runtime.Runtime,
  home: String,
  parent: conversation.Info,
  requested: String,
) -> Choice {
  resolve_with(lookup(host, home), home, parent, requested)
}

fn resolve_with(
  lookup: Lookup,
  home: String,
  parent: conversation.Info,
  requested: String,
) -> Choice {
  use saved <- result.try(configuration.profiles(home))
  use _ <- result.try(
    list.try_each(saved, fn(profile) {
      case profile {
        Error(#(name, reason)) ->
          case string.starts_with(requested, name <> "/") {
            True -> Error(reason)
            False -> Ok(Nil)
          }
        Ok(_) -> Ok(Nil)
      }
    }),
  )
  let profiles = result.values(saved)
  let qualified =
    list.find_map(profiles, fn(profile) {
      let prefix = profile.name <> "/"
      case string.starts_with(requested, prefix) {
        True ->
          Ok(#(
            profile,
            text_scalars.drop(requested, text_scalars.length(prefix)),
          ))
        False -> Error(Nil)
      }
    })
  case qualified {
    Ok(#(profile, model)) ->
      case
        profile.name == parent_provider(home, parent)
        && model == parent.model
        || offers(lookup, profile, model)
      {
        True -> Ok(#(profile, model))
        False -> Error("model is not available from provider " <> profile.name)
      }
    Error(_) -> {
      use current <- result.try(current(home, parent))
      let model = case requested {
        "" -> parent.model
        _ -> requested
      }
      let others =
        list.filter(profiles, fn(profile) { profile.name != current.name })
      case moved(lookup, current, others, model) {
        Ok([profile]) -> Ok(#(profile, model))
        Error(Nil) | Ok([]) -> Ok(#(current, model))
        Ok(_) ->
          Error(
            "model is available from multiple providers; use provider/model",
          )
      }
    }
  }
}

/// The parent's profile. A legacy session has none recorded until its client
/// is configured, and runs on the flat config's.
fn current(
  home: String,
  parent: conversation.Info,
) -> Result(configuration.Provider, String) {
  case parent.provider {
    "" -> configuration.legacy(home)
    name -> configuration.named(home, name)
  }
}

fn parent_provider(home: String, parent: conversation.Info) -> String {
  case current(home, parent) {
    Ok(provider) -> provider.name
    Error(_) -> parent.provider
  }
}

/// Resolve a switch like a spawn, but refuse unknown bare ids too.
pub fn resolve_switch(
  host: runtime.Runtime,
  home: String,
  info: conversation.Info,
  requested: String,
) -> Choice {
  let lookup = lookup(host, home)
  use #(provider, model) <- result.try(resolve_with(
    lookup,
    home,
    info,
    requested,
  ))
  case offers(lookup, provider, model) {
    True -> Ok(#(provider, model))
    False -> Error("model is not available from any provider")
  }
}

/// What a session may hand a child, each as "provider/model": its own model,
/// its own provider's models, then every other provider's.
pub fn available(
  host: runtime.Runtime,
  home: String,
  info: conversation.Info,
) -> List(String) {
  let profiles = configuration.providers(home) |> result.unwrap([])
  let lookup = lookup(host, home)
  let listings =
    concurrently(
      lookup,
      profiles,
      fn(profile) { listed(lookup, profile) },
      [],
      fn(_) { False },
    )
    |> list.zip(profiles, _)
  let provider = parent_provider(home, info)
  let #(same, other) =
    list.partition(listings, fn(listing) { { listing.0 }.name == provider })
  let qualified = fn(listing: #(configuration.Provider, List(String))) {
    list.map(listing.1, fn(model) { { listing.0 }.name <> "/" <> model })
  }
  let current = case same {
    [] -> []
    _ -> [provider <> "/" <> info.model]
  }
  list.unique(list.append(
    current,
    list.flat_map(list.append(same, other), qualified),
  ))
}

/// `Error(Nil)` when `current` offers `model`, else the `others` that do, in
/// profile order. `current` is asked first when its list is at hand; one that
/// must be fetched is asked together with the others, so a slow endpoint and
/// stalled ones cost one wait, not two. Its answer is still awaited before
/// the others count.
fn moved(
  lookup: Lookup,
  current: configuration.Provider,
  others: List(configuration.Provider),
  model: String,
) -> Result(List(configuration.Provider), Nil) {
  let ask = fn(profile) { offers(lookup, profile, model) }
  let asked = case current.model == model || ready(lookup, current) {
    True ->
      case ask(current) {
        True -> [True]
        False -> [
          False,
          ..concurrently(lookup, others, ask, False, fn(_) { False })
        ]
      }
    False ->
      concurrently(lookup, [current, ..others], ask, False, fn(received) {
        dict.get(received, 0) == Ok(True)
      })
  }
  case asked {
    [True, ..] -> Error(Nil)
    [_, ..rest] ->
      list.zip(others, rest)
      |> list.filter_map(fn(answer) {
        case answer.1 {
          True -> Ok(answer.0)
          False -> Error(Nil)
        }
      })
      |> Ok
    [] -> Error(Nil)
  }
}

/// `work` on every item at once, in item order; `fallback` for one that has not
/// answered by the lookup's deadline, or by the time the answers so far are
/// `enough`. The answers are collected in a process of their own, so ones that
/// land after the caller stops listening never reach its mailbox.
fn concurrently(
  lookup: Lookup,
  items: List(a),
  work: fn(a) -> b,
  fallback: b,
  enough: fn(dict.Dict(Int, b)) -> Bool,
) -> List(b) {
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    let answers = process.new_subject()
    list.index_map(items, fn(item, index) {
      process.spawn_unlinked(fn() {
        process.send(answers, #(index, work(item)))
      })
    })
    let received =
      collect(answers, list.length(items), lookup.deadline, enough, dict.new())
    process.send(reply, received)
  })
  let received =
    process.receive(
      reply,
      int.max(0, lookup.deadline - clock.monotonic_ms()) + 1000,
    )
    |> result.unwrap(dict.new())
  list.index_map(items, fn(_, index) {
    dict.get(received, index) |> result.unwrap(fallback)
  })
}

fn collect(
  answers: process.Subject(#(Int, b)),
  remaining: Int,
  deadline: Int,
  enough: fn(dict.Dict(Int, b)) -> Bool,
  received: dict.Dict(Int, b),
) -> dict.Dict(Int, b) {
  case remaining == 0 || enough(received) {
    True -> received
    False ->
      case
        process.receive(answers, int.max(0, deadline - clock.monotonic_ms()))
      {
        Ok(#(index, value)) ->
          collect(
            answers,
            remaining - 1,
            deadline,
            enough,
            dict.insert(received, index, value),
          )
        Error(Nil) -> received
      }
  }
}

fn offers(
  lookup: Lookup,
  provider: configuration.Provider,
  model: String,
) -> Bool {
  provider.model == model || list.contains(listed(lookup, provider), model)
}

/// Whether listing `provider`'s models answers without waiting on a fetch.
fn ready(lookup: Lookup, provider: configuration.Provider) -> Bool {
  runtime.model_names_ready(
    lookup.host,
    provider.extension,
    endpoint(lookup, provider),
  )
}

fn listed(lookup: Lookup, provider: configuration.Provider) -> List(String) {
  list.unique([
    provider.model,
    ..runtime.model_names(
      lookup.host,
      provider.extension,
      endpoint(lookup, provider),
    )
  ])
}

/// A generic extension (openai) serves many gateways; the profile's endpoint
/// names which catalog provider's models it lists.
fn endpoint(
  lookup: Lookup,
  provider: configuration.Provider,
) -> Option(String) {
  dict.get(lookup.endpoints, provider.name)
  |> option.from_result
  |> option.flatten
}
