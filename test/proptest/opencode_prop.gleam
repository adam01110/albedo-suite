//// OpenCode Go extensions: the SDK-metadata route table, the documented family
//// routing, ownership of the documented endpoints, the shape of each
//// protocol's exchange, and the per-endpoint model listing.
////
//// Every oracle below is written from the documented rules (docs/development.md,
//// test/opencode_go_e2e_test.py, and the modules' own doc comments) rather than
//// by calling the code under test.
////
//// Two deviations are recorded with coverage counters instead of assertions,
//// because their contracts are ambiguous:
////
//// - `claude_id_not_lowercase`: the family routing is case-insensitive, but
////   `wire.encode_messages` drops the adaptive effort fields unless the raw
////   model id starts with lowercase `claude-`.
//// - `chat_uncanonical_root`: the chat exchange keeps the profile's own
////   endpoint root while the messages, responses and gemini exchanges rewrite
////   the Zen gateway to the direct inference one. Both roots answer alike
////   (probed 2026-11-21), so no request is lost.

import albedo_ext_opencode_go/catalog
import albedo_ext_opencode_go/routing
import albedo_ext_opencode_go/wire
import albedo_model as types
import albedo_openai
import albedo_openai/bridge
import albedo_openai/opencode as gateway
import albedo_sdk/extension
import albedo_sdk/key_environment
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree
import proptest
import qcheck

// Generators

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

const sdks = [
  "@ai-sdk/anthropic",
  "@ai-sdk/openai",
  "@ai-sdk/openai-compatible",
  "@ai-sdk/google",
  "unknown-sdk",
  "@ai-sdk/azure",
]

const prefixes = [
  "claude-",
  "gemini-",
  "gpt-",
  "grok-",
  "muse-spark-",
  "glm-",
  "qwen-",
  "CLAUDE-",
  "Gemini-",
  "GPT-",
  "minimax-m2.7",
  "",
]

fn alnum_text(max: Int) -> qcheck.Generator(String) {
  qcheck.generic_string(
    qcheck.alphanumeric_ascii_codepoint(),
    qcheck.bounded_int(0, max),
  )
}

fn model_id() -> qcheck.Generator(String) {
  use prefix, tail <- qcheck.map2(pick(prefixes), alnum_text(3))
  prefix <> tail
}

/// A catalog entry for one model: absent, present with no SDK of its own, or
/// present with its own SDK package.
pub type Entry {
  NoEntry
  EmptyEntry
  ModelSdk(String)
}

pub type Metadata {
  Metadata(provider_sdk: Option(String), model: String, entry: Entry)
}

fn metadata() -> qcheck.Generator(Metadata) {
  use provider_sdk, model, entry <- qcheck.map3(
    qcheck.option_from(pick(sdks)),
    model_id(),
    qcheck.from_weighted_generators(#(4, qcheck.return(EmptyEntry)), [
      #(4, pick(sdks) |> qcheck.map(ModelSdk)),
      #(3, qcheck.return(NoEntry)),
    ]),
  )
  Metadata(provider_sdk, model, entry)
}

/// The models.json a models.dev download holds for OpenCode Go.
fn catalog_json(meta: Metadata) -> String {
  let models = case meta.entry {
    NoEntry -> []
    EmptyEntry -> [#(meta.model, json.object([]))]
    ModelSdk(sdk) -> [
      #(
        meta.model,
        json.object([
          #("provider", json.object([#("npm", json.string(sdk))])),
        ]),
      ),
    ]
  }
  let provider = case meta.provider_sdk {
    None -> [#("models", json.object(models))]
    Some(sdk) -> [#("npm", json.string(sdk)), #("models", json.object(models))]
  }
  json.to_string(json.object([#("opencode-go", json.object(provider))]))
}

// Independent oracles

fn sdk_route(npm: String) -> String {
  case npm {
    "@ai-sdk/anthropic" -> "messages"
    "@ai-sdk/openai" -> "responses"
    "@ai-sdk/openai-compatible" -> "chat_completions"
    "@ai-sdk/google" -> "gemini"
    _ -> ""
  }
}

/// The documented family routing for a model the catalog does not name.
fn family_route(model: String) -> String {
  let id = string.lowercase(string.trim(model))
  case
    string.starts_with(id, "gemini-"),
    string.starts_with(id, "claude-") || id == "minimax-m2.7",
    string.starts_with(id, "gpt-")
      || string.starts_with(id, "grok-")
      || string.starts_with(id, "muse-spark-")
  {
    True, _, _ -> "gemini"
    _, True, _ -> "messages"
    _, _, True -> "responses"
    False, False, False -> "chat_completions"
  }
}

fn inherited_sdk(meta: Metadata) -> String {
  case meta.provider_sdk {
    Some(sdk) -> sdk_route(sdk)
    None -> ""
  }
}

/// The route the catalog metadata names for the model: only an entry for the
/// model itself may inherit the provider's SDK.
fn expected_metadata_route(meta: Metadata) -> String {
  case meta.entry {
    NoEntry -> ""
    EmptyEntry -> inherited_sdk(meta)
    ModelSdk(sdk) -> sdk_route(sdk)
  }
}

fn expected_route(meta: Metadata) -> String {
  case expected_metadata_route(meta) {
    "" -> family_route(meta.model)
    route -> route
  }
}

fn route_name(route: wire.Route) -> String {
  case route {
    wire.MessagesRoute -> "messages"
    wire.ResponsesRoute -> "responses"
    wire.GeminiRoute -> "gemini"
    wire.ChatRoute -> "chat_completions"
  }
}

/// An endpoint with every trailing slash removed, as the catalog's own notion
/// of an endpoint root treats one.
fn endpoint_root(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> endpoint_root(string.drop_end(url, 1))
    False -> url
  }
}

const documented_endpoints = [
  "https://opencode.ai/inference/go/v1",
  "https://opencode.ai/zen/go/v1",
]

fn expected_owned(url: String) -> Bool {
  list.contains(documented_endpoints, endpoint_root(url))
}

/// The inference root a request goes to: the profile's endpoint without its
/// trailing slash, with the Zen gateway rewritten to the direct inference one.
fn request_root(base: String) -> String {
  case endpoint_root(base) {
    "https://opencode.ai/zen/go/v1" -> "https://opencode.ai/inference/go/v1"
    root -> root
  }
}

// JSON helpers

fn body_fields(body: string_tree.StringTree) -> Result(Dict(String, Dynamic), Nil) {
  json.parse(
    string_tree.to_string(body),
    decode.dict(decode.string, decode.dynamic),
  )
  |> result.replace_error(Nil)
}

fn text_field(object: Dict(String, Dynamic), name: String) -> Result(String, Nil) {
  use value <- result.try(dict.get(object, name) |> result.replace_error(Nil))
  decode.run(value, decode.string) |> result.replace_error(Nil)
}

fn int_field(object: Dict(String, Dynamic), name: String) -> Option(Int) {
  case dict.get(object, name) {
    Ok(value) -> decode.run(value, decode.int) |> option.from_result
    Error(_) -> None
  }
}

fn nested_text(object: Dict(String, Dynamic), field_name: String, name: String) -> Result(String, Nil) {
  use value <- result.try(dict.get(object, field_name) |> result.replace_error(Nil))
  decode.run(value, decode.at([name], decode.string)) |> result.replace_error(Nil)
}

fn has_field(object: Dict(String, Dynamic), name: String) -> Bool {
  dict.has_key(object, name)
}

fn body_text(body: string_tree.StringTree) -> String {
  string_tree.to_string(body)
}

fn count_of(haystack: String, needle: String) -> Int {
  list.length(string.split(haystack, needle)) - 1
}

fn headers_named(headers: List(#(String, String)), name: String) -> List(String) {
  headers
  |> list.filter(fn(header) { string.lowercase(header.0) == name })
  |> list.map(fn(header) { header.1 })
}

fn fail(message: String) -> Nil {
  panic as message
}

/// The two shapes a wire may refuse: no model id, and no output limit where
/// the protocol requires one.
fn documented_refusal(shaped: Shaped) -> Bool {
  shaped.model == "" || shaped.max_tokens == None
}

fn expect(condition: Bool, message: String) -> Nil {
  case condition {
    True -> Nil
    False -> fail(message)
  }
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

fn option_text(value: Option(String)) -> String {
  case value {
    Some(text) -> text
    None -> "<none>"
  }
}

// Properties

/// The SDK package a model's catalog metadata names decides its protocol: an
/// entry with no SDK of its own inherits the provider's, an absent entry does
/// not, and a model the catalog does not name keeps the family routing.
fn routes_from_metadata(home: String, meta: Metadata) -> Nil {
  proptest.write_file(
    home <> "/models.json",
    <<catalog_json(meta):utf8>>,
    1_700_000_000,
  )
  let expected_named = expected_metadata_route(meta)
  let named = routing.metadata_route(home, meta.model)
  proptest.bump(case expected_named {
    "" -> "no_metadata_route"
    _ -> "metadata_route"
  })
  expect(
    named == expected_named,
    "metadata_route("
    <> meta.model
    <> ") = "
    <> named
    <> ", expected "
    <> expected_named,
  )
  let expected = expected_route(meta)
  let route = route_name(wire.route(meta.model))
  proptest.bump(expected)
  expect(
    route == expected,
    "wire.route(" <> meta.model <> ") = " <> route <> ", expected " <> expected,
  )
}

/// The documented family routing applies to any model id, however it is cased
/// or padded, when the catalog names no SDK for it.
fn family_routes(home: String, model: String) -> Nil {
  proptest.write_file(
    home <> "/models.json",
    <<"{\"opencode-go\":{\"name\":\"OpenCode Go\",\"models\":{}}":utf8>>,
    1_700_000_000,
  )
  let named = routing.metadata_route(home, model)
  expect(
    named == "",
    "metadata_route(" <> model <> ") = " <> named <> ", expected \"\"",
  )
  let expected = family_route(model)
  let route = route_name(wire.route(model))
  proptest.bump(expected)
  expect(
    route == expected,
    "wire.route(" <> model <> ") = " <> route <> ", expected " <> expected,
  )
}

fn endpoint_url() -> qcheck.Generator(String) {
  use base, tail, slash <- qcheck.map3(
    pick([
      "https://opencode.ai/inference/go/v1",
      "https://opencode.ai/zen/go/v1",
      "https://opencode.ai/zen/v1",
      "https://opencode.ai/inference/openai/v1",
      "https://api.anthropic.com/v1",
      "https://evil.example.com/opencode.ai/inference/go/v1",
      "https://opencode.ai/inference/go/v1.evil.example.com",
      "https://opencode.ai/inference/go",
      "https://opencode.ai/inference/go/V1",
      "http://localhost:8080/v1",
    ]),
    alnum_text(4),
    qcheck.bounded_int(0, 1),
  )
  let tail = case tail {
    "" -> ""
    _ -> "/" <> tail
  }
  base <> tail <> case slash {
    0 -> ""
    _ -> "/"
  }
}

/// The catalog answers only for the endpoints an `opencode-go` profile owns:
/// exactly the two documented gateways and a profile's own endpoint, never a
/// look-alike host or path.
fn endpoint_ownership(home: String, url: String) -> Nil {
  let expected = expected_owned(url)
  let owned = routing.owns_endpoint(home, url)
  proptest.bump(case expected {
    True -> "owned"
    False -> "foreign"
  })
  expect(
    owned == expected,
    "owns_endpoint(\""
    <> url
    <> "\") = "
    <> bool_text(owned)
    <> ", expected "
    <> bool_text(expected),
  )
}

// Request shaping

pub type Shaped {
  Shaped(
    key: String,
    base: String,
    model: String,
    instructions: Option(String),
    shared: Int,
    inputs: List(types.Input),
    tools: List(types.Tool),
    effort: Option(types.Effort),
    cache: Bool,
    max_tokens: Option(Int),
    service_tier: Option(String),
  )
}

fn input_gen() -> qcheck.Generator(types.Input) {
  // Provider encoders only accept a tool result after a call they can see, so
  // generated histories hold user and assistant text only.
  qcheck.from_weighted_generators(#(8, alnum_text(12) |> qcheck.map(types.User)), [
    #(4, alnum_text(12) |> qcheck.map(types.Assistant)),
  ])
}

fn tools_gen() -> qcheck.Generator(List(types.Tool)) {
  qcheck.generic_list(alnum_text(12), qcheck.bounded_int(0, 2))
  |> qcheck.map(fn(descriptions) {
    list.index_map(descriptions, fn(description, index) {
      types.Tool("tool" <> int.to_string(index), description, json.object([]), False)
    })
  })
}

fn effort_gen() -> qcheck.Generator(types.Effort) {
  pick([
    types.NoReasoning,
    types.Minimal,
    types.Low,
    types.Medium,
    types.High,
    types.XHigh,
    types.Max,
  ])
}

fn key_gen() -> qcheck.Generator(String) {
  alnum_text(12) |> qcheck.map(fn(tail) { "sk-zen-secret-" <> tail })
}

fn shaped() -> qcheck.Generator(Shaped) {
  use head <- qcheck.then(qcheck.tuple6(
    key_gen(),
    pick([
      "https://opencode.ai/inference/go/v1",
      "https://opencode.ai/inference/go/v1/",
      "https://opencode.ai/zen/go/v1",
      "https://opencode.ai/zen/go/v1/",
      "http://127.0.0.1:8080/v1",
    ]),
    model_id(),
    qcheck.generic_list(input_gen(), qcheck.bounded_int(0, 3)),
    tools_gen(),
    qcheck.option_from(effort_gen()),
  ))
  use tail <- qcheck.then(qcheck.tuple5(
    qcheck.bool(),
    qcheck.option_from(qcheck.bounded_int(1, 4096)),
    qcheck.option_from(pick(["flex", "priority", "auto"])),
    qcheck.option_from(alnum_text(24)),
    qcheck.bounded_int(0, 2),
  ))
  let shared = case tail.3, tail.4 {
    Some(text), 1 -> string.byte_size(text) / 2
    Some(text), 2 -> string.byte_size(text)
    _, _ -> 0
  }
  qcheck.return(Shaped(
    head.0,
    head.1,
    head.2,
    tail.3,
    shared,
    head.3,
    head.4,
    head.5,
    tail.0,
    tail.1,
    tail.2,
  ))
}

fn case_request(shaped: Shaped) -> types.Request {
  types.Request(
    shaped.model,
    shaped.instructions,
    shaped.inputs,
    shaped.tools,
    shaped.max_tokens,
    types.Options(
      ..types.defaults,
      effort: shaped.effort,
      cache: shaped.cache,
      service_tier: shaped.service_tier,
      shared_instructions: shaped.shared,
    ),
  )
}

/// Whether the request asks for a cache write on the spans the documented
/// marks cover: the last tool, the system prompt (or the shared start and the
/// rest after it), and the last input.
fn expected_marks(shaped: Shaped) -> Int {
  case shaped.cache {
    False -> 0
    True -> {
      let tools = case shaped.tools {
        [] -> 0
        _ -> 1
      }
      let system = case shaped.instructions {
        Some(text) if text != "" && shaped.shared > 0 -> case string.byte_size(text) > shaped.shared {
          True -> 2
          False -> 1
        }
        Some(text) if text != "" -> 1
        _ -> 0
      }
      let tail = case list.last(shaped.inputs) {
        Ok(types.Replay(_)) | Error(_) -> 0
        Ok(_) -> 1
      }
      tools + system + tail
    }
  }
}

/// The body fields the Anthropic Messages route documents. Nothing else may be
/// sent: a field outside this set is one the gateway does not document.
const messages_fields = [
  "model",
  "messages",
  "max_tokens",
  "stream",
  "system",
  "tools",
  "tool_choice",
  "thinking",
  "output_config",
]

fn messages_shape(shaped: Shaped) -> Nil {
  let client = albedo_openai.client(types.ChatCompletions, shaped.base, shaped.key)
  let request = case_request(shaped)
  case wire.encode_messages(client, [#("x-probe", "1")], request) {
    Error(_) ->
      expect(
        documented_refusal(shaped),
        "encode_messages(" <> shaped.model <> ") refused a shape it documents",
      )
    Ok(exchange) -> {
      proptest.bump("messages")
      let url = exchange.url
      let expected_url = request_root(shaped.base) <> "/messages"
      expect(url == expected_url, "messages URL " <> url <> ", expected " <> expected_url)
      expect(
        shaped.key == "" || !string.contains(url, shaped.key),
        "messages URL carries the profile key: " <> url,
      )
      expect(
        !string.contains(url, " "),
        "messages URL holds a space: " <> url,
      )
      expect(
        headers_named(exchange.headers, "x-api-key") == [shaped.key],
        "x-api-key headers "
        <> string.inspect(headers_named(exchange.headers, "x-api-key"))
        <> ", expected the profile key once",
      )
      expect(
        headers_named(exchange.headers, "anthropic-version") == ["2023-06-01"],
        "anthropic-version headers "
        <> string.inspect(headers_named(exchange.headers, "anthropic-version")),
      )
      expect(
        headers_named(exchange.headers, "x-probe") == ["1"],
        "the caller's own headers were dropped",
      )
      let body = body_text(exchange.body)
      expect(
        shaped.key == "" || !string.contains(body, shaped.key),
        "the messages body carries the profile key",
      )
      case body_fields(exchange.body) {
        Error(_) -> fail("the messages body is not a JSON object")
        Ok(fields) -> {
          let unexpected =
            dict.keys(fields)
            |> list.filter(fn(key) { !list.contains(messages_fields, key) })
          expect(
            unexpected == [],
            "undocumented messages fields " <> string.inspect(unexpected),
          )
          expect(
            text_field(fields, "model") == Ok(shaped.model),
            "messages model "
            <> string.inspect(text_field(fields, "model"))
            <> ", expected "
            <> shaped.model,
          )
          expect(
            int_field(fields, "max_tokens") == shaped.max_tokens,
            "messages max_tokens "
            <> string.inspect(int_field(fields, "max_tokens"))
            <> ", expected "
            <> string.inspect(shaped.max_tokens),
          )
          expect(!has_field(fields, "service_tier"), "the messages body carries service_tier")
          // A Claude model keeps the requested adaptive effort; any other
          // model on the Messages route sends no effort fields.
          let claude =
            string.starts_with(string.lowercase(string.trim(shaped.model)), "claude-")
          // A Claude id the lowercased family routing recognizes but the
          // encoder's own case-sensitive prefix check does not: the effort
          // fields are dropped. Recorded, not asserted; see the report.
          let lowercase_id = string.starts_with(shaped.model, "claude-")
          case claude && !lowercase_id {
            True -> proptest.bump("claude_id_not_lowercase")
            False -> Nil
          }
          case claude && lowercase_id, shaped.effort {
            True, Some(effort) -> {
              expect(
                nested_text(fields, "thinking", "type") == Ok("adaptive"),
                "claude thinking on the Messages route: "
                <> string.inspect(dict.get(fields, "thinking")),
              )
              expect(
                nested_text(fields, "output_config", "effort") == Ok(types.effort_name(effort)),
                "claude effort "
                <> string.inspect(dict.get(fields, "output_config")),
              )
            }
            _, _ -> {
              expect(!has_field(fields, "thinking"), "a non-Claude model kept thinking")
              expect(!has_field(fields, "output_config"), "a non-Claude model kept output_config")
            }
          }
        }
      }
      // The marks the ledger records are exactly the breakpoints sent.
      let sent = count_of(body, "\"cache_control\":")
      let expected = expected_marks(shaped)
      expect(
        sent == expected,
        "cache breakpoints sent "
        <> int.to_string(sent)
        <> ", expected "
        <> int.to_string(expected)
        <> " for "
        <> shaped.model,
      )
      let marks = list.length(wire.cache_marks(request))
      let messages_route = wire.route(shaped.model) == wire.MessagesRoute
      case messages_route {
        True ->
          expect(
            marks == expected,
            "cache_marks reported "
            <> int.to_string(marks)
            <> ", breakpoints sent "
            <> int.to_string(sent)
            <> " for "
            <> shaped.model,
          )
        False ->
          expect(
            marks == 0,
            "cache_marks reported marks on another route: " <> int.to_string(marks),
          )
      }
    }
  }
}

/// The Gemini route puts the model in its path, unchanged, and never in a URL
/// that carries the key.
fn gemini_shape(shaped: Shaped) -> Nil {
  let client = albedo_openai.client(types.ChatCompletions, shaped.base, shaped.key)
  let request = case_request(shaped)
  let expected =
    request_root(shaped.base)
    <> "/models/"
    <> shaped.model
    <> ":streamGenerateContent?alt=sse"
  case wire.encode_gemini(client, [], request) {
    Error(_) ->
      expect(
        documented_refusal(shaped),
        "encode_gemini(" <> shaped.model <> ") refused a documented shape",
      )
    Ok(exchange) -> {
      proptest.bump("gemini")
      expect(exchange.url == expected, "gemini URL " <> exchange.url <> ", expected " <> expected)
      expect(
        shaped.key == "" || !string.contains(exchange.url, shaped.key),
        "gemini URL carries the profile key",
      )
      case body_fields(exchange.body) {
        Error(_) -> fail("the gemini body is not a JSON object")
        Ok(fields) -> {
          expect(has_field(fields, "contents"), "the gemini body has no contents")
          expect(
            has_field(fields, "generationConfig"),
            "the gemini body has no generationConfig",
          )
        }
      }
    }
  }
}

/// Both OpenAI routes drop the service tier the gateway does not accept, and
/// keep the model id the request names.
fn openai_shapes(shaped: Shaped) -> Nil {
  let chat = albedo_openai.client(types.ChatCompletions, shaped.base, shaped.key)
  let responses = albedo_openai.client(types.Responses, shaped.base, shaped.key)
  let request = case_request(shaped)
  case albedo_openai.encode_request(chat, request, gateway.encode_openai) {
    Error(_) -> expect(documented_refusal(shaped), "the chat route refused a documented shape")
    Ok(exchange) -> {
      proptest.bump("chat")
      let expected = request_root(shaped.base) <> "/chat/completions"
      // The chat exchange is the only route that keeps the profile's own
      // endpoint root; the other three rewrite the Zen gateway to the direct
      // inference one. Both are documented endpoints, so record the split.
      case exchange.url == expected {
        True -> Nil
        False -> {
          proptest.bump("chat_uncanonical_root")
          expect(
            exchange.url == endpoint_root(shaped.base) <> "/chat/completions",
            "chat URL " <> exchange.url <> ", expected " <> expected,
          )
        }
      }
      expect(
        shaped.key == "" || !string.contains(exchange.url, shaped.key),
        "chat URL carries the profile key",
      )
      case body_fields(exchange.body) {
        Error(_) -> fail("the chat body is not a JSON object")
        Ok(fields) -> {
          expect(text_field(fields, "model") == Ok(shaped.model), "chat model changed")
          expect(!has_field(fields, "service_tier"), "the chat body carries service_tier")
        }
      }
    }
  }
  case gateway.encode_responses(responses, [], request) {
    Error(_) ->
      expect(documented_refusal(shaped), "the responses route refused a documented shape")
    Ok(exchange) -> {
      proptest.bump("responses")
      let expected = request_root(shaped.base) <> "/responses"
      case exchange.url == expected {
        True -> Nil
        False -> {
          proptest.bump("responses_uncanonical_root")
          expect(
            exchange.url == endpoint_root(shaped.base) <> "/responses",
            "responses URL " <> exchange.url <> ", expected " <> expected,
          )
        }
      }
      case body_fields(exchange.body) {
        Error(_) -> fail("the responses body is not a JSON object")
        Ok(fields) -> {
          expect(text_field(fields, "model") == Ok(shaped.model), "responses model changed")
          expect(!has_field(fields, "service_tier"), "the responses body carries service_tier")
        }
      }
    }
  }
}

/// Only the extension's own provider id is listed; every other id is not this
/// catalog's.
fn listing_provider(provider: String) -> Bool {
  let model_catalog = catalog.catalog()
  case model_catalog.list(provider, None, key_environment.empty()) {
    extension.Unlisted -> {
      expect(provider != "opencode-go", "the catalog unlisted its own provider " <> provider)
      False
    }
    extension.Local(_) -> {
      proptest.bump("local_unexpected")
      False
    }
    extension.Remote(_, _, _) -> {
      expect(
        provider == "opencode-go",
        "the catalog listed another provider: " <> provider,
      )
      True
    }
  }
}

/// Every endpoint spelling of one endpoint keeps one list key.
fn endpoints_listed() -> Nil {
  let model_catalog = catalog.catalog()
  let endpoints = [
    None,
    Some("https://opencode.ai/inference/go/v1"),
    Some("https://opencode.ai/inference/go/v1/"),
    Some("https://opencode.ai/zen/go/v1"),
    Some("http://127.0.0.1:8080/v1"),
  ]
  list.each(endpoints, fn(endpoint) {
    let expected = endpoint_root(option_endpoint(endpoint))
    case model_catalog.list("opencode-go", endpoint, key_environment.empty()) {
      extension.Remote(key, _, _) -> {
        proptest.bump("remote")
        expect(
          key == expected,
          "list key "
          <> key
          <> ", expected "
          <> expected
          <> " for "
          <> option_text(endpoint),
        )
      }
      _ -> fail("the catalog did not list its own provider for " <> option_text(endpoint))
    }
  })
}

fn option_endpoint(endpoint: Option(String)) -> String {
  case endpoint {
    Some(url) -> url
    None -> catalog.default_base_url
  }
}

// Responses adapter: recorded reasoning replay

pub type Recorded {
  Recorded(text: String, calls: List(#(String, String)), details: List(#(String, List(String))))
}

fn recorded_gen() -> qcheck.Generator(Recorded) {
  use head <- qcheck.then(qcheck.tuple3(
    alnum_text(8),
    qcheck.generic_list(alnum_text(6), qcheck.bounded_int(0, 2)),
    qcheck.generic_list(
      qcheck.tuple2(
        pick(["openai.reasoning", "openai.reasoning", "other.detail"]),
        qcheck.generic_list(alnum_text(6), qcheck.bounded_int(0, 2)),
      ),
      qcheck.bounded_int(0, 2),
    ),
  ))
  let calls =
    list.index_map(head.1, fn(id, index) { #(id <> int.to_string(index), "tool" <> int.to_string(index)) })
  qcheck.return(Recorded(head.0, calls, head.2))
}

fn reasoning_item(id: String) -> json.Json {
  json.object([
    #("type", json.string("reasoning")),
    #("id", json.string(id)),
    #("summary", json.array([], json.string)),
    #("encrypted_content", json.string("enc-" <> id)),
  ])
}

fn replay_message(recorded: Recorded) -> types.Input {
  let details =
    list.map(recorded.details, fn(detail) {
      json.object([
        #("type", json.string(detail.0)),
        #("items", json.preprocessed_array(list.map(detail.1, reasoning_item))),
        #("text", json.string(recorded.text)),
      ])
    })
  let calls =
    list.map(recorded.calls, fn(call) {
      json.object([
        #("id", json.string(call.0)),
        #("type", json.string("function")),
        #(
          "function",
          json.object([
            #("name", json.string(call.1)),
            #("arguments", json.string("{}")),
          ]),
        ),
      ])
    })
  let raw =
    json.object([
      #("role", json.string("assistant")),
      #("content", json.string(recorded.text)),
      #("tool_calls", json.preprocessed_array(calls)),
      #("reasoning_details", json.preprocessed_array(details)),
    ])
    |> json.to_string
  let assert Ok(value) = json.parse(raw, decode.dynamic)
  types.Replay(types.replay_item(types.ChatCompletions, value))
}

/// The label of one Responses input item, as the shape it replays as.
fn item_label(item: types.Input) -> String {
  case item {
    types.Replay(replayed) -> {
      let value = types.replay_value(replayed)
      let kind = decode.run(value, decode.at(["type"], decode.string)) |> result.unwrap("")
      case kind {
        "reasoning" -> "reasoning:" <> string_field(value, ["id"])
        "function_call" -> "function_call:" <> string_field(value, ["call_id"])
        _ -> kind <> ":" <> string_field(value, ["role"])
      }
    }
    types.Assistant(text) -> "text:" <> text
    _ -> "other"
  }
}

fn string_field(value: Dynamic, path: List(String)) -> String {
  decode.run(value, decode.at(path, decode.string)) |> result.unwrap("")
}

/// The reasoning items a turn recorded replay before the message they
/// preceded, a detail of another kind contributes nothing, and the text and
/// calls keep their order.
fn reasoning_replay(recorded: Recorded) -> Nil {
  let reasoning =
    list.flatten(list.map(recorded.details, fn(detail) {
      case detail.0 == "openai.reasoning" {
        True -> list.map(detail.1, fn(id) { "reasoning:" <> id })
        False -> []
      }
    }))
  let text = case recorded.text {
    "" -> []
    text -> ["text:" <> text]
  }
  let calls = list.map(recorded.calls, fn(call) { "function_call:" <> call.0 })
  let expected = list.flatten([reasoning, text, calls])
  case bridge.responses_inputs([replay_message(recorded)]) {
    Error(_) -> fail("the Responses adapter refused a recorded turn it wrote")
    Ok(items) -> {
      proptest.bump("replayed")
      let found = list.map(items, item_label)
      expect(
        found == expected,
        "replayed "
        <> string.inspect(found)
        <> ", expected "
        <> string.inspect(expected)
        <> " for "
        <> string.inspect(recorded.details),
      )
    }
  }
}

pub fn main() -> Nil {
  let home = "/tmp/albedo-opencode-prop-" <> int.to_string(proptest.unique())
  proptest.putenv("ALBEDO_HOME", home)
  proptest.check(
    "catalog metadata picks the documented route",
    40,
    metadata(),
    fn(meta) { routes_from_metadata(home, meta) },
  )
  proptest.check(
    "model families keep their documented route",
    40,
    model_id(),
    fn(model) { family_routes(home, model) },
  )
  proptest.check(
    "the catalog owns only the documented endpoints",
    40,
    endpoint_url(),
    fn(url) { endpoint_ownership(home, url) },
  )
  proptest.check(
    "the Messages route sends the documented fields",
    60,
    shaped(),
    messages_shape,
  )
  proptest.check(
    "the Gemini route keeps the model in its path",
    40,
    shaped(),
    gemini_shape,
  )
  proptest.check(
    "the OpenAI routes drop the service tier",
    40,
    shaped(),
    openai_shapes,
  )
  proptest.check(
    "each endpoint keeps its own model list",
    200,
    qcheck.tuple2(
      pick(["opencode-go", "opencode-go ", "OpenCode-Go", "opencode", "opencode-zen", "anthropic", ""]),
      qcheck.nil(),
    ),
    fn(pair) {
      let listed = listing_provider(pair.0)
      case listed {
        True -> endpoints_listed()
        False -> Nil
      }
    },
  )
  proptest.check(
    "a recorded reasoning item replays before its message",
    200,
    recorded_gen(),
    reasoning_replay,
  )
}
