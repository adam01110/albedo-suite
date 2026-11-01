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
import albedo/harness/runtime
import albedo/text_scalars
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A profile and the model to run on it, or why there is none.
pub type Choice =
  Result(#(configuration.Provider, String), String)

/// `requested` is "provider/model", a bare model, or "" for the parent's. A
/// bare model stays on the parent's provider when it lists it, and otherwise
/// moves to the one other provider that does. Only the profiles a decision
/// needs are listed.
pub fn resolve(
  host: runtime.Runtime,
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
        profile.name == parent.provider
        && model == parent.model
        || offers(host, home, profile, model)
      {
        True -> Ok(#(profile, model))
        False -> Error("model is not available from provider " <> profile.name)
      }
    Error(_) -> {
      use current <- result.try(configuration.named(home, parent.provider))
      let model = case requested {
        "" -> parent.model
        _ -> requested
      }
      case offers(host, home, current, model) {
        True -> Ok(#(current, model))
        False ->
          case other_offers(host, home, profiles, current, model) {
            [profile] -> Ok(#(profile, model))
            [] -> Ok(#(current, model))
            _ ->
              Error(
                "model is available from multiple providers; use provider/model",
              )
          }
      }
    }
  }
}

/// Resolve a switch like a spawn, but refuse unknown bare ids too.
pub fn resolve_switch(
  host: runtime.Runtime,
  home: String,
  info: conversation.Info,
  requested: String,
) -> Choice {
  use #(provider, model) <- result.try(resolve(host, home, info, requested))
  case offers(host, home, provider, model) {
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
  let listings =
    concurrently(profiles, fn(profile) { listed(host, home, profile) }, [])
    |> list.zip(profiles, _)
  let #(same, other) =
    list.partition(listings, fn(listing) { { listing.0 }.name == info.provider })
  let qualified = fn(listing: #(configuration.Provider, List(String))) {
    list.map(listing.1, fn(model) { { listing.0 }.name <> "/" <> model })
  }
  let current = case same {
    [] -> []
    _ -> [info.provider <> "/" <> info.model]
  }
  list.unique(list.append(
    current,
    list.flat_map(list.append(same, other), qualified),
  ))
}

/// The profiles other than `current` that offer `model`, in profile order. Each
/// is asked at once, so stalled endpoints cost one wait together.
fn other_offers(
  host: runtime.Runtime,
  home: String,
  profiles: List(configuration.Provider),
  current: configuration.Provider,
  model: String,
) -> List(configuration.Provider) {
  let others =
    list.filter(profiles, fn(profile) { profile.name != current.name })
  concurrently(
    others,
    fn(profile) { offers(host, home, profile, model) },
    False,
  )
  |> list.zip(others, _)
  |> list.filter_map(fn(asked) {
    case asked.1 {
      True -> Ok(asked.0)
      False -> Error(Nil)
    }
  })
}

/// How long one profile's endpoint may take before it counts as offering
/// nothing: its own fetch gives up sooner, this bounds a fetch that never does.
const listing_timeout_ms = 15_000

/// `work` on every item at once, in item order; `fallback` for one that has not
/// answered by the deadline.
fn concurrently(items: List(a), work: fn(a) -> b, fallback: b) -> List(b) {
  let answers = process.new_subject()
  list.index_map(items, fn(item, index) {
    process.spawn_unlinked(fn() { process.send(answers, #(index, work(item))) })
  })
  let deadline = clock.monotonic_ms() + listing_timeout_ms
  let received = collect(answers, list.length(items), deadline, dict.new())
  list.index_map(items, fn(_, index) {
    dict.get(received, index) |> result.unwrap(fallback)
  })
}

fn collect(
  answers: process.Subject(#(Int, b)),
  remaining: Int,
  deadline: Int,
  received: dict.Dict(Int, b),
) -> dict.Dict(Int, b) {
  case remaining {
    0 -> received
    _ ->
      case
        process.receive(answers, int.max(0, deadline - clock.monotonic_ms()))
      {
        Ok(#(index, value)) ->
          collect(
            answers,
            remaining - 1,
            deadline,
            dict.insert(received, index, value),
          )
        Error(Nil) -> received
      }
  }
}

fn offers(
  host: runtime.Runtime,
  home: String,
  provider: configuration.Provider,
  model: String,
) -> Bool {
  provider.model == model || list.contains(listed(host, home, provider), model)
}

fn listed(
  host: runtime.Runtime,
  home: String,
  provider: configuration.Provider,
) -> List(String) {
  // A generic extension (openai) serves many gateways; the profile's endpoint
  // names which catalog provider's models it lists.
  let endpoint = session_provider.profile_endpoint(home, provider.name)
  list.unique([
    provider.model,
    ..runtime.model_names(host, provider.extension, endpoint)
  ])
}
