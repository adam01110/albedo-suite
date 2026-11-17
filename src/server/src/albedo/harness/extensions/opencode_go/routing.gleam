//// Suite routing for OpenCode Go: the wire route a model's catalog SDK
//// metadata names, and the endpoints an `opencode-go` profile owns.

import albedo/harness/sdk/credentials
import albedo_env
import albedo_file
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

const store = "opencode-go"

const default_base_url = "https://opencode.ai/inference/go/v1"

/// The route the catalog's SDK package names for `model`: `messages`,
/// `responses`, `chat_completions`, `gemini`, or "" for none. Per-model SDK
/// metadata takes precedence over the provider's default SDK. Only a catalog
/// entry for `model` itself may inherit that default: an absent entry keeps
/// the documented family routing instead of a provider-wide SDK.
pub fn metadata_route(home: String, model: String) -> String {
  let npm = {
    use body <- result.try(albedo_file.read(home <> "/models.json"))
    use body <- result.try(bit_array.to_string(body))
    json.parse(body, decode.at([store], npm_decoder(model)))
    |> result.replace_error(Nil)
  }
  case result.unwrap(npm, "") {
    "@ai-sdk/anthropic" -> "messages"
    "@ai-sdk/openai" -> "responses"
    "@ai-sdk/openai-compatible" -> "chat_completions"
    "@ai-sdk/google" -> "gemini"
    _ -> ""
  }
}

fn npm_decoder(model: String) -> decode.Decoder(String) {
  use default <- decode.optional_field("npm", "", decode.string)
  use models <- decode.optional_field(
    "models",
    dict.new(),
    decode.dict(decode.string, decode.dynamic),
  )
  decode.success(case dict.get(models, model) {
    Error(_) -> ""
    Ok(entry) ->
      decode.run(entry, decode.at(["provider", "npm"], decode.string))
      |> result.unwrap(default)
  })
}

/// The documented OpenCode Go endpoints, or one an `opencode-go` profile
/// names.
pub fn owns_endpoint(home: String, endpoint: String) -> Bool {
  let endpoint = resolve_base_url(endpoint)
  endpoint == default_base_url
  || endpoint == "https://opencode.ai/zen/go/v1"
  || list.any(credentials.profiles(home).entries, fn(profile) {
    profile.provider == store && resolve_base_url(profile.endpoint) == endpoint
  })
}

fn resolve_base_url(url: String) -> String {
  case url, trim_slashes(albedo_env.get("OPENCODE_GO_BASE_URL")) {
    "", "" -> default_base_url
    "", configured -> configured
    url, _ -> trim_slashes(url)
  }
}

fn trim_slashes(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> trim_slashes(string.drop_end(url, 1))
    False -> url
  }
}
