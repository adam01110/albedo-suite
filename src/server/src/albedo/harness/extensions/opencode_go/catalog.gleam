//// OpenCode Go catalog: model context limits, modalities, reasoning effort,
//// and live /models entitlement discovery.

import albedo/harness/extension
import albedo/harness/extensions/models/extension as models
import albedo/harness/extensions/opencode_go/accounts
import albedo/harness/model_lists
import albedo/harness/settings
import albedo/openai_api/catalog as model_catalog
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const default_base_url = "https://opencode.ai/inference/go/v1"

pub fn catalog() -> extension.ModelCatalog {
  extension.ModelCatalog(lookup, list_models, None)
}

fn lookup(id: String, at: Option(String)) -> Option(extension.ModelInfo) {
  let is_opencode_go_endpoint = case at {
    None -> True
    Some(url) -> owns_endpoint(settings.home(), url)
  }
  use <- bool.guard(!is_opencode_go_endpoint, None)

  let target_endpoint = option.unwrap(at, default_base_url)
  let listed = model_lists.saved("opencode-go", list_key(at))
  let base =
    extension.ModelInfo(
      ..extension.blank_model(id, "opencode-go"),
      endpoint: Some(target_endpoint),
      environment: ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"],
      source: "OpenCode Go catalog",
    )
  case models.lookup_provider("opencode-go", id) {
    Some(found) -> {
      use <- bool.guard(
        at == None
          && models.lookup_provider("anthropic", id) != None
          && result.is_error(listed),
        None,
      )
      Some(
        extension.ModelInfo(
          ..found,
          provider: "opencode-go",
          endpoint: Some(target_endpoint),
          environment: ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"],
        ),
      )
    }
    None -> {
      use <- bool.guard(!list.contains(result.unwrap(listed, []), id), None)
      Some(models.complete_model(base, Some(target_endpoint)))
    }
  }
}

@external(erlang, "albedo_opencode_go", "owns_endpoint")
fn owns_endpoint(home: String, endpoint: String) -> Bool

fn list_models(
  provider: String,
  endpoint: Option(String),
) -> extension.Listing {
  case provider {
    "opencode-go" -> {
      let home = settings.home()
      extension.Remote(
        list_key(endpoint),
        fn() { models(home, option.unwrap(endpoint, "")) },
        models.list("opencode-go", None),
      )
    }
    _ -> extension.Unlisted
  }
}

/// Lists are kept per endpoint; no endpoint means the default one.
fn list_key(endpoint: Option(String)) -> String {
  string.remove_suffix(option.unwrap(endpoint, default_base_url), "/")
}

fn models(home: String, endpoint: String) -> Result(List(String), String) {
  use #(url, key) <- result.try(accounts.discovery(home, endpoint))
  // Lists are cached per endpoint, so fetch the requested one, keyless when
  // discovery only found another endpoint's key.
  let #(url, key) = case
    endpoint == "" || model_catalog.root(url) == model_catalog.root(endpoint)
  {
    True -> #(url, key)
    False -> #(endpoint, "")
  }
  use #(status, body) <- result.try(model_catalog.fetch(
    url,
    key,
    "albedo/1.0",
    10_000,
  ))
  case status {
    200 -> model_catalog.ids(body, is_chat_model)
    _ -> Error("endpoint returned HTTP " <> int.to_string(status))
  }
}

// Exclude image generation, TTS, audio, realtime, and speech routes.
fn is_chat_model(id: String) -> Bool {
  id != "auto"
  && !list.any(["audio", "tts", "realtime", "image", "asr"], fn(marker) {
    string.contains(id, marker)
  })
}
