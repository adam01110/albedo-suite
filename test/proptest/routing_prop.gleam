//// Property tests for OpenCode Go routing: which endpoints an `opencode-go`
//// profile owns after base-URL normalisation, and which wire route the catalog
//// metadata names for a model. The expected answers come from small
//// independent models of the documented rules (an empty endpoint is the
//// default one, trailing slashes are not part of a base URL, and only a
//// catalog entry for the model itself may inherit the provider's default SDK),
//// not from the module under test.

import albedo_env
import albedo_ext_opencode_go/routing
import albedo_ext_opencode_go/wire
import gleam/bit_array
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import proptest
import qcheck

const default_base_url = "https://opencode.ai/inference/go/v1"

const zen_base_url = "https://opencode.ai/zen/go/v1"

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

/// A base URL from its parts, so the interesting shapes (missing scheme,
/// missing host, odd ports, empty and multi-segment paths, trailing slashes)
/// all occur.
fn url_gen() -> qcheck.Generator(String) {
  let parts =
    qcheck.tuple4(
      qcheck.from_weighted_generators(#(8, pick(["https://"])), [
        #(1, pick(["http://"])),
        #(1, pick(["HTTPS://"])),
        #(1, qcheck.return("")),
      ]),
      qcheck.from_weighted_generators(#(8, pick(["opencode.ai"])), [
        #(1, pick(["example.com", "localhost", "127.0.0.1"])),
        #(1, qcheck.return("")),
      ]),
      qcheck.from_weighted_generators(#(8, qcheck.return("")), [
        #(1, pick([":443", ":8080", ":0"])),
      ]),
      qcheck.generic_list(
        qcheck.from_weighted_generators(#(4, pick(["inference", "go", "v1"])), [
          #(1, pick(["zen", "v2", "v1/", "a b", ".."])),
          #(1, qcheck.return("")),
        ]),
        qcheck.bounded_int(0, 4),
      ),
    )
  let built =
    qcheck.tuple2(parts, qcheck.bounded_int(0, 3))
    |> qcheck.map(fn(input) {
      let #(#(scheme, host, port, segments), slashes) = input
      let path = case segments {
        [] -> ""
        _ -> "/" <> string.join(segments, "/")
      }
      scheme <> host <> port <> path <> string.repeat("/", slashes)
    })
  qcheck.from_generators(qcheck.return(""), [built])
}

/// Trailing slashes are not part of a base URL.
fn strip(url: String) -> String {
  case string.ends_with(url, "/") && url != "/" {
    True -> strip(string.drop_end(url, 1))
    False ->
      case url {
        "/" -> ""
        _ -> url
      }
  }
}

/// The documented resolution: an empty endpoint names the default one,
/// unless the environment configures another, and every other endpoint is
/// taken without its trailing slashes.
fn resolved(url: String) -> String {
  case url {
    "" ->
      case strip(albedo_env.get("OPENCODE_GO_BASE_URL")) {
        "" -> default_base_url
        configured -> configured
      }
    _ -> strip(url)
  }
}

/// A saved profile: its name and the endpoint it names.
fn profile_gen() -> qcheck.Generator(#(String, String, String)) {
  qcheck.map3(
    pick(["work", "personal"]),
    qcheck.from_weighted_generators(#(12, pick(["opencode-go"])), [
      #(2, pick(["openai"])),
    ]),
    url_gen(),
    fn(name, provider, endpoint) { #(name, provider, endpoint) },
  )
}

fn profiles_gen() -> qcheck.Generator(List(#(String, String, String))) {
  qcheck.generic_list(profile_gen(), qcheck.bounded_int(0, 2))
  |> qcheck.map(fn(profiles) {
    // Profile names key a JSON object, so they must not repeat.
    list.index_map(profiles, fn(profile, index) {
      let #(_, provider, endpoint) = profile
      #("p" <> int.to_string(index), provider, endpoint)
    })
  })
}

fn profiles_json(profiles: List(#(String, String, String))) -> String {
  profiles
  |> list.map(fn(profile) {
    let #(name, provider, endpoint) = profile
    #(
      name,
      json.object([
        #("extension", json.string(provider)),
        #("baseUrl", json.string(endpoint)),
      ]),
    )
  })
  |> json.object
  |> fn(providers) { json.object([#("providers", providers)]) }
  |> json.to_string
}

/// Whether the documented endpoints or an `opencode-go` profile own `url`.
fn expected_owned(
  url: String,
  profiles: List(#(String, String, String)),
) -> Bool {
  let url = resolved(url)
  url == default_base_url
  || url == zen_base_url
  || list.any(profiles, fn(profile) {
    let #(_, provider, endpoint) = profile
    provider == "opencode-go" && resolved(endpoint) == url
  })
}

/// The route the documented SDK table gives a catalog `npm` package.
fn sdk_route(npm: String) -> String {
  case npm {
    "@ai-sdk/anthropic" -> "messages"
    "@ai-sdk/openai" -> "responses"
    "@ai-sdk/openai-compatible" -> "chat_completions"
    "@ai-sdk/google" -> "gemini"
    _ -> ""
  }
}

/// The documented family routing for a model id, which lowercases and trims
/// the id before matching families.
fn family_route(model: String) -> String {
  let id = string.lowercase(string.trim(model))
  case string.starts_with(id, "gemini-") {
    True -> "GeminiRoute"
    False ->
      case string.starts_with(id, "claude-") || id == "minimax-m2.7" {
        True -> "MessagesRoute"
        False ->
          case
            string.starts_with(id, "gpt-")
            || string.starts_with(id, "grok-")
            || string.starts_with(id, "muse-spark-")
          {
            True -> "ResponsesRoute"
            False -> "ChatRoute"
          }
      }
  }
}

fn route_name(route: wire.Route) -> String {
  case route {
    wire.ChatRoute -> "ChatRoute"
    wire.ResponsesRoute -> "ResponsesRoute"
    wire.MessagesRoute -> "MessagesRoute"
    wire.GeminiRoute -> "GeminiRoute"
  }
}

fn named_route(route: String) -> String {
  case route {
    "messages" -> "MessagesRoute"
    "responses" -> "ResponsesRoute"
    "chat_completions" -> "ChatRoute"
    "gemini" -> "GeminiRoute"
    _ -> "none"
  }
}

/// How a model's catalog entry names an SDK.
type Entry {
  /// The catalog does not name the model at all.
  Absent
  /// The entry names its own SDK package.
  Own(npm: String)
  /// The entry names no SDK, or one that is not a string.
  Plain
  /// The entry is not an object.
  Broken
}

fn entry_gen() -> qcheck.Generator(Entry) {
  qcheck.from_weighted_generators(#(5, qcheck.return(Plain)), [
    #(3, pick([Absent])),
    #(
      4,
      pick([
        Own("@ai-sdk/anthropic"),
        Own("@ai-sdk/openai"),
        Own("@ai-sdk/openai-compatible"),
        Own("@ai-sdk/google"),
        Own("unknown-sdk"),
      ]),
    ),
    #(1, qcheck.return(Broken)),
  ])
}

fn provider_npm_gen() -> qcheck.Generator(Option(String)) {
  qcheck.from_weighted_generators(#(5, qcheck.return(None)), [
    #(2, qcheck.return(Some("@ai-sdk/google"))),
    #(1, qcheck.return(Some("@ai-sdk/openai"))),
  ])
}

/// The route the catalog metadata must name: only a catalog entry for the
/// model itself may inherit the provider's default SDK, and an entry whose
/// own SDK is not a string is no entry of its own.
fn metadata_expectation(entry: Entry, provider_npm: Option(String)) -> String {
  case entry {
    Absent -> ""
    Plain -> sdk_route(option_default(provider_npm))
    Broken -> sdk_route(option_default(provider_npm))
    Own(npm) -> sdk_route(npm)
  }
}

fn option_default(value: Option(String)) -> String {
  case value {
    None -> ""
    Some(found) -> found
  }
}

fn entry_json(entry: Entry) -> json.Json {
  case entry {
    Absent -> json.null()
    Broken -> json.string("not an entry")
    Plain -> json.object([])
    Own(npm) ->
      json.object([#("provider", json.object([#("npm", json.string(npm))]))])
  }
}

fn models_json(
  model: String,
  entry: Entry,
  provider_npm: Option(String),
) -> String {
  let models = case entry {
    Absent -> json.object([])
    _ -> json.object([#(model, entry_json(entry))])
  }
  let store = case provider_npm {
    None ->
      json.object([#("name", json.string("OpenCode Go")), #("models", models)])
    Some(npm) ->
      json.object([
        #("name", json.string("OpenCode Go")),
        #("npm", json.string(npm)),
        #("models", models),
      ])
  }
  json.object([#("opencode-go", store)]) |> json.to_string
}

fn check(name: String, generator: qcheck.Generator(a), property: fn(a) -> Nil) {
  proptest.check(name, 100, generator, property)
}

pub fn main() -> Nil {
  let holes =
    "/tmp/proptest-opencode-go-routing-" <> int.to_string(proptest.unique())
  let _ = proptest.remove_tree(holes)
  let _ = albedo_env.unset("OPENCODE_GO_BASE_URL")

  check(
    "a normalised endpoint decides ownership",
    qcheck.tuple2(url_gen(), profiles_gen()),
    fn(input) {
      let #(url, profiles) = input
      // Profiles live in config.json, which the routing reads for the
      // endpoints a saved `opencode-go` profile names.
      let home = holes <> "/home-" <> int.to_string(proptest.unique())
      proptest.write_file(
        home <> "/config.json",
        bit_array.from_string(profiles_json(profiles)),
        1000,
      )
      let found = routing.owns_endpoint(home, url)
      let expected = expected_owned(url, profiles)
      proptest.bump(case profiles {
        [] -> "no_profiles"
        _ -> "profiles"
      })
      proptest.bump(case expected {
        True -> "owned"
        False -> "foreign"
      })
      case found == expected {
        True -> Nil
        False ->
          panic as {
            "endpoint "
            <> string.inspect(url)
            <> " resolved differently: "
            <> string.inspect(#(profiles, found, expected, resolved(url)))
          }
      }
    },
  )

  let home = holes <> "/home"
  check(
    "trailing slashes never change which endpoints a profile owns",
    qcheck.tuple2(url_gen(), qcheck.bounded_int(1, 3)),
    fn(input) {
      let #(url, more) = input
      // The empty endpoint is the default one; repeated slashes alone are not
      // a base URL at all, so only a non-empty endpoint is padded here.
      case url {
        "" -> Nil
        _ -> {
          let padded = url <> string.repeat("/", more)
          let found = routing.owns_endpoint(home, padded)
          let expected = routing.owns_endpoint(home, url)
          proptest.bump("slash_variant")
          case found == expected {
            True -> Nil
            False ->
              panic as {
                "one trailing slash changed ownership: "
                <> string.inspect(#(url, padded, found, expected))
              }
          }
        }
      }
    },
  )

  check(
    "the documented endpoints and their slash variants are owned",
    qcheck.bounded_int(0, 4),
    fn(slashes) {
      let suffix = string.repeat("/", slashes)
      assert routing.owns_endpoint(home, default_base_url <> suffix)
      assert routing.owns_endpoint(home, zen_base_url <> suffix)
      proptest.bump("documented_endpoint")
      // The empty endpoint names the default one when nothing is configured.
      assert albedo_env.get("OPENCODE_GO_BASE_URL") == ""
      assert routing.owns_endpoint(home, "")
      // A neighbouring path is not an owned endpoint.
      assert !routing.owns_endpoint(home, "https://opencode.ai/inference/go/v2")
      assert !routing.owns_endpoint(home, "https://opencode.ai/inference/go")
      Nil
    },
  )

  check(
    "a configured base URL replaces the default endpoint",
    url_gen(),
    fn(configured) {
      albedo_env.set("OPENCODE_GO_BASE_URL", configured)
      let found = routing.owns_endpoint(home, "")
      let expected = expected_owned("", [])
      proptest.bump(case expected {
        True -> "configured_owned"
        False -> "configured_foreign"
      })
      let _ = albedo_env.unset("OPENCODE_GO_BASE_URL")
      case found == expected {
        True -> Nil
        False ->
          panic as {
            "a configured base URL was not resolved: "
            <> string.inspect(#(configured, strip(configured), found))
          }
      }
    },
  )

  // The catalog's own SDK metadata: the provider's default SDK is inherited
  // only by an entry for the model itself.
  let catalog_home = holes <> "/catalog-home"
  check(
    "catalog metadata routes each model by its own entry",
    qcheck.tuple3(
      pick(["mistral-large", "gpt-5", "claude-5", "gemini-3", "muse-spark-1"]),
      entry_gen(),
      provider_npm_gen(),
    ),
    fn(input) {
      let #(model, entry, provider_npm) = input
      proptest.write_file(
        catalog_home <> "/models.json",
        bit_array.from_string(models_json(model, entry, provider_npm)),
        1000,
      )
      let found = routing.metadata_route(catalog_home, model)
      let expected = metadata_expectation(entry, provider_npm)
      proptest.bump("metadata_" <> found)
      case found == expected {
        True -> Nil
        False ->
          panic as {
            "catalog metadata routed "
            <> model
            <> " as "
            <> string.inspect(found)
            <> ", expected "
            <> string.inspect(expected)
            <> ": "
            <> string.inspect(#(entry, provider_npm))
          }
      }
    },
  )

  // Route source agreement: an id the catalog names takes its metadata route,
  // and an id differing only by case or surrounding whitespace is not named,
  // so the documented family routing answers. This measures how far the two
  // sources diverge on the same model.
  check(
    "route sources agree on ids the catalog names and diverge on case variants",
    qcheck.tuple2(
      pick(["mistral-large", "gpt-5", "claude-5", "gemini-3", "muse-spark-1"]),
      pick([
        "@ai-sdk/anthropic",
        "@ai-sdk/openai",
        "@ai-sdk/openai-compatible",
        "@ai-sdk/google",
        "unknown-sdk",
      ]),
    ),
    fn(input) {
      let #(model, npm) = input
      albedo_env.set("ALBEDO_HOME", catalog_home)
      proptest.write_file(
        catalog_home <> "/models.json",
        bit_array.from_string(models_json(model, Own(npm), None)),
        1000,
      )
      let expected = named_route(sdk_route(npm))
      let found = route_name(wire.route(model))
      proptest.bump("catalog_id_" <> found)
      case expected {
        "none" -> {
          // A catalog package the suite does not route keeps the family
          // routing rather than guessing a wire.
          proptest.bump("catalog_unknown_sdk")
          assert found == family_route(model)
        }
        _ -> {
          case found == expected {
            True -> Nil
            False ->
              panic as {
                "catalog metadata routed "
                <> model
                <> " as "
                <> found
                <> ", expected "
                <> expected
              }
          }
        }
      }
      let variant = " " <> string.uppercase(model) <> " "
      let variant_expected = family_route(model)
      let variant_route = route_name(wire.route(variant))
      proptest.bump("variant_family_routing")
      case variant_route == variant_expected {
        True -> Nil
        False ->
          panic as {
            "a case variant left the family routing: "
            <> string.inspect(#(model, variant, variant_route, variant_expected))
          }
      }
      case variant_route == found {
        True -> proptest.bump("case_agree")
        False -> proptest.bump("case_diverge")
      }
      let _ = albedo_env.unset("ALBEDO_HOME")
      Nil
    },
  )

  proptest.remove_tree(holes)
}
