import albedo/harness/extensions/zed/stream as zed_stream
import albedo/harness/extensions/zed/wire
import albedo/openai_api
import albedo/openai_api/replay
import albedo/openai_api/request as encoder
import albedo/openai_api/sse
import albedo/openai_api/stream as albedo_stream
import albedo/openai_api/types
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam/string_tree
import gleeunit/should

fn field(body: String, path: List(String)) -> String {
  let assert Ok(value) = json.parse(body, decode.at(path, decode.string))
  value
}

fn encoded(model: String, choice: types.ToolChoice) -> String {
  let request = openai_api.request(model, [types.User("hello")])
  let request =
    types.Request(
      ..request,
      max_output_tokens: Some(512),
      tools: [
        types.Tool(
          "python",
          "execute",
          json.object([#("type", json.string("object"))]),
          False,
        ),
      ],
      options: types.Options(
        ..request.options,
        effort: Some("high"),
        tool_choice: Some(choice),
      ),
    )
  let assert Ok(exchange) =
    wire.encode(
      case model {
        "claude-" <> _ -> "anthropic"
        "gpt-" <> _ -> "open_ai"
        _ -> "google"
      },
      "https://cloud.zed.dev",
      "test-jwt",
      "session",
      request,
    )
  string_tree.to_string(exchange.body)
}

fn encoding() {
  let claude = encoded("claude-sonnet-4-6", types.NamedTool("python"))
  field(claude, ["provider"]) |> should.equal("anthropic")
  field(claude, ["provider_request", "tool_choice", "type"])
  |> should.equal("tool")
  field(claude, ["provider_request", "tool_choice", "name"])
  |> should.equal("python")
  field(claude, ["provider_request", "output_config", "effort"])
  |> should.equal("high")
  let no = encoded("claude-sonnet-4-6", types.NoTool)
  field(no, ["provider_request", "tool_choice", "type"]) |> should.equal("none")
  let any = encoded("claude-sonnet-4-6", types.AnyTool)
  field(any, ["provider_request", "tool_choice", "type"]) |> should.equal("any")
  let gpt = encoded("gpt-5.4", types.AnyTool)
  field(gpt, ["provider"]) |> should.equal("open_ai")
  field(gpt, ["provider_request", "reasoning", "effort"])
  |> should.equal("high")
  field(gpt, ["provider_request", "tool_choice"]) |> should.equal("required")
  let gemini = encoded("gemini-3.1-pro-preview", types.NoTool)
  field(gemini, ["provider"]) |> should.equal("google")
  field(gemini, ["provider_request", "model"])
  |> should.equal("models/gemini-3.1-pro-preview")
  field(gemini, [
    "provider_request",
    "generationConfig",
    "thinkingConfig",
    "thinkingLevel",
  ])
  |> should.equal("HIGH")
  field(gemini, [
    "provider_request",
    "toolConfig",
    "functionCallingConfig",
    "mode",
  ])
  |> should.equal("NONE")
}

/// A conversation every native family has to encode: text turns, an image, a
/// replayed assistant tool call, its result, and a closing turn.
fn sample(model: String, choice: types.ToolChoice) -> types.Request {
  let assert Ok(image) = types.image("image/png", "aGVsbG8=", 2, 3, 5)
  let call = types.ToolCall("call-1", "python", "{\"code\":\"x\"}")
  let assert Ok(replay) =
    json.parse(
      json.to_string(replay.message(json.string("calling"), "", None, [call])),
      types.replay_decoder(types.ChatCompletions),
    )
  types.Request(
    model,
    Some("answer briefly"),
    [
      types.User("hello"),
      types.UserImage("look", [image]),
      types.Replay(replay),
      types.ToolOutput("call-1", "tool said", []),
      types.User("bye"),
    ],
    [
      types.Tool(
        "python",
        "execute",
        json.object([#("type", json.string("object"))]),
        False,
      ),
    ],
    Some(512),
    types.Options(
      ..types.defaults,
      temperature: Some(0.2),
      tool_choice: Some(choice),
      effort: Some("high"),
      format: Some(types.JsonObject),
    ),
  )
}

fn provider_body(
  provider: String,
  model: String,
  choice: types.ToolChoice,
) -> String {
  let assert Ok(exchange) =
    wire.encode(
      provider,
      "https://cloud.zed.dev",
      "test-jwt",
      "session",
      sample(model, choice),
    )
  string_tree.to_string(exchange.body)
}

/// One step into a provider request: an object key or a list index.
type Seg {
  Key(String)
  Index(Int)
}

fn reach(
  value: decode.Dynamic,
  segments: List(Seg),
) -> Result(decode.Dynamic, Nil) {
  case segments {
    [] -> Ok(value)
    [Key(key), ..rest] ->
      case decode.run(value, decode.at([key], decode.dynamic)) {
        Ok(next) -> reach(next, rest)
        Error(_) -> Error(Nil)
      }
    [Index(index), ..rest] ->
      case decode.run(value, decode.at([index], decode.dynamic)) {
        Ok(next) -> reach(next, rest)
        Error(_) -> Error(Nil)
      }
  }
}

/// Whether the `provider_request` has a value at `segments`.
fn has(body: String, segments: List(Seg)) -> Bool {
  case json.parse(body, decode.at(["provider_request"], decode.dynamic)) {
    Ok(value) -> result.is_ok(reach(value, segments))
    Error(_) -> False
  }
}

/// One step into a bare request body, without a provider envelope.
fn body_field(
  body: String,
  segments: List(Seg),
  decoder: decode.Decoder(a),
) -> a {
  let assert Ok(value) = json.parse(body, decode.dynamic)
  let assert Ok(value) = reach(value, segments)
  let assert Ok(decoded) = decode.run(value, decoder)
  decoded
}

fn codex_body(body: String, segments: List(Seg)) -> String {
  body_field(body, segments, decode.string)
}

fn codex_bool(body: String, segments: List(Seg)) -> Bool {
  body_field(body, segments, decode.bool)
}

fn sent(body: String, segments: List(Seg), decoder: decode.Decoder(a)) -> a {
  let assert Ok(value) =
    json.parse(body, decode.at(["provider_request"], decode.dynamic))
  let assert Ok(value) = reach(value, segments)
  let assert Ok(decoded) = decode.run(value, decoder)
  decoded
}

fn sent_text(body: String, segments: List(Seg)) -> String {
  sent(body, segments, decode.string)
}

fn sent_int(body: String, segments: List(Seg)) -> Int {
  sent(body, segments, decode.int)
}

fn sent_bool(body: String, segments: List(Seg)) -> Bool {
  sent(body, segments, decode.bool)
}

fn contains(body: String, fragment: String) -> Nil {
  string.contains(body, fragment) |> should.be_true
}

/// Zed's cloud parses a Responses input item as a `type`-tagged object, so a
/// dropped discriminator is a 400 before any provider sees the request.
fn assert_responses_items_typed(body: String) -> Nil {
  let items =
    decode.at(["provider_request", "input"], decode.list(decode.dynamic))
  let assert Ok(items) = json.parse(body, items)
  list.length(items) |> should.equal(6)
  // The suite's own Responses item decoder requires the `type` discriminator.
  json.parse(
    body,
    decode.at(
      ["provider_request", "input"],
      decode.list(types.replay_decoder(types.Responses)),
    ),
  )
  |> should.be_ok
  let assert Ok(kinds) =
    json.parse(
      body,
      decode.at(
        ["provider_request", "input"],
        decode.list(decode.at(["type"], decode.string)),
      ),
    )
  kinds
  |> should.equal([
    "message", "message", "message", "function_call", "function_call_output",
    "message",
  ])
}

/// The built-in tools declare strict with optional parameters, which strict
/// mode cannot express; the encoder must not claim it.
fn optional_schema() -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("additionalProperties", json.bool(False)),
    #("required", json.array(["code"], json.string)),
    #(
      "properties",
      json.object([
        #("code", json.object([#("type", json.string("string"))])),
        #("timeout_ms", json.object([#("type", json.string("integer"))])),
      ]),
    ),
  ])
}

fn closed_schema() -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("additionalProperties", json.bool(False)),
    #("required", json.array(["code"], json.string)),
    #(
      "properties",
      json.object([#("code", json.object([#("type", json.string("string"))]))]),
    ),
  ])
}

fn nested_optional_schema() -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("additionalProperties", json.bool(False)),
    #("required", json.array(["opts"], json.string)),
    #(
      "properties",
      json.object([
        #(
          "opts",
          json.object([
            #("type", json.string("object")),
            #("additionalProperties", json.bool(False)),
            #(
              "properties",
              json.object([
                #("a", json.object([#("type", json.string("string"))])),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

/// A closed, complete object that still needs `additionalProperties: false`:
/// strict mode cannot be claimed for it, and nothing else about it is wrong.
fn unclosed_schema() -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("required", json.array([], json.string)),
    #("properties", json.object([])),
  ])
}

/// An object with an optional property and no `additionalProperties`: either
/// violation is enough to make its parent's strict claim false.
fn open_object() -> json.Json {
  json.object([
    #("type", json.string("object")),
    #(
      "properties",
      json.object([
        #("optional", json.object([#("type", json.string("string"))])),
      ]),
    ),
  ])
}

fn closed_nested_object() -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("additionalProperties", json.bool(False)),
    #("required", json.array(["value"], json.string)),
    #(
      "properties",
      json.object([#("value", json.object([#("type", json.string("string"))]))]),
    ),
  ])
}

/// A closed, complete object with one keyword nested under `key`: the only
/// place a violation can hide. Every schema-bearing keyword is reached, so a
/// violation behind one of them cannot be claimed as strict.
fn nested_under(key: String, value: json.Json) -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("additionalProperties", json.bool(False)),
    #("required", json.array([], json.string)),
    #("properties", json.object([])),
    #(key, value),
  ])
}

fn single_tool_body(schema: json.Json) -> String {
  tools_body("open_ai", [types.Tool("nested", "execute", schema, True)])
}

/// Every object level counts: an unclosed object behind any applicator, list
/// item, reference or the top level itself must drop the strict claim.
fn strict_traversal() {
  let tools = [
    types.Tool("unclosed", "execute", unclosed_schema(), True),
  ]
  let gpt = tools_body("open_ai", tools)
  sent_bool(gpt, [Key("tools"), Index(0), Key("strict")]) |> should.equal(False)

  let list_keywords = ["anyOf", "oneOf", "allOf", "prefixItems"]
  list.each(list_keywords, fn(key) {
    let schema =
      nested_under(key, json.array([open_object()], fn(value) { value }))
    sent_bool(single_tool_body(schema), [Key("tools"), Index(0), Key("strict")])
    |> should.equal(False)
    let control =
      nested_under(
        key,
        json.array([closed_nested_object()], fn(value) { value }),
      )
    sent_bool(single_tool_body(control), [Key("tools"), Index(0), Key("strict")])
    |> should.equal(True)
  })

  // additionalProperties is traversed too, but a schema there already leaves its
  // parent unclosed, so only these keywords can hide the first violation.
  let schema_keywords = ["items", "not", "if", "then", "else"]
  list.each(schema_keywords, fn(key) {
    let schema = nested_under(key, open_object())
    sent_bool(single_tool_body(schema), [Key("tools"), Index(0), Key("strict")])
    |> should.equal(False)
    let control = nested_under(key, closed_nested_object())
    sent_bool(single_tool_body(control), [Key("tools"), Index(0), Key("strict")])
    |> should.equal(True)
  })

  let map_keywords = [
    "patternProperties",
    "dependentSchemas",
    "$defs",
    "definitions",
  ]
  list.each(map_keywords, fn(key) {
    let schema = nested_under(key, json.object([#("hidden", open_object())]))
    sent_bool(single_tool_body(schema), [Key("tools"), Index(0), Key("strict")])
    |> should.equal(False)
    let control =
      nested_under(key, json.object([#("hidden", closed_nested_object())]))
    sent_bool(single_tool_body(control), [Key("tools"), Index(0), Key("strict")])
    |> should.equal(True)
  })
}

/// The ChatGPT reasoning backend fixes sampling, tool choice and the token
/// limit; the encoder must send only what it accepts.
fn codex_policy() {
  let request =
    types.Request(
      "gpt-5.4",
      None,
      [types.User("hello")],
      [
        types.Tool("python", "execute", closed_nested_object(), True),
      ],
      Some(512),
      types.Options(
        ..types.defaults,
        temperature: Some(0.2),
        effort: Some("high"),
        format: Some(types.JsonObject),
      ),
    )
  let assert Ok(tree) =
    encoder.encode_with_policy(
      types.Responses,
      types.Codex("codex-account", "codex-session"),
      request,
    )
  let body = string_tree.to_string(tree)
  contains(body, "\"strict\":null")
  codex_body(body, [Key("tool_choice")]) |> should.equal("auto")
  codex_bool(body, [Key("parallel_tool_calls")]) |> should.equal(True)
  codex_body(body, [Key("text"), Key("verbosity")]) |> should.equal("low")
  codex_body(body, [Key("text"), Key("format"), Key("type")])
  |> should.equal("json_object")
  codex_body(body, [Key("reasoning"), Key("effort")]) |> should.equal("high")
  codex_body(body, [Key("reasoning"), Key("summary")]) |> should.equal("auto")
  codex_body(body, [Key("prompt_cache_key")]) |> should.equal("codex-session")
  // The backend owns the token budget and the sampling it refuses to take.
  string.contains(body, "max_output_tokens") |> should.be_false
  string.contains(body, "temperature") |> should.be_false
}

fn tools_body(provider: String, tools: List(types.Tool)) -> String {
  let request =
    types.Request(
      "gpt-5.4",
      None,
      [types.User("hi")],
      tools,
      None,
      types.defaults,
    )
  let assert Ok(exchange) =
    wire.encode(
      provider,
      "https://cloud.zed.dev",
      "test-jwt",
      "session",
      request,
    )
  string_tree.to_string(exchange.body)
}

fn tool_strictness() {
  let tools = [
    types.Tool("python", "execute", optional_schema(), True),
    types.Tool("closed", "execute", closed_schema(), True),
    types.Tool("nested", "execute", nested_optional_schema(), True),
    types.Tool("loose", "execute", closed_schema(), False),
  ]
  let gpt = tools_body("open_ai", tools)
  sent_bool(gpt, [Key("tools"), Index(0), Key("strict")]) |> should.equal(False)
  sent_bool(gpt, [Key("tools"), Index(1), Key("strict")]) |> should.equal(True)
  sent_bool(gpt, [Key("tools"), Index(2), Key("strict")]) |> should.equal(False)
  sent_bool(gpt, [Key("tools"), Index(3), Key("strict")]) |> should.equal(False)
  // The same claim travels on the Chat Completions route.
  let grok = tools_body("x_ai", tools)
  sent_bool(grok, [Key("tools"), Index(0), Key("function"), Key("strict")])
  |> should.equal(False)
  sent_bool(grok, [Key("tools"), Index(1), Key("function"), Key("strict")])
  |> should.equal(True)
}

fn provider_requests() {
  // Anthropic Messages: typed content blocks, adaptive thinking, effort.
  let claude = provider_body("anthropic", "claude-sonnet-4-6", types.AnyTool)
  sent_text(claude, [Key("model")]) |> should.equal("claude-sonnet-4-6")
  sent_int(claude, [Key("max_tokens")]) |> should.equal(512)
  sent_bool(claude, [Key("stream")]) |> should.equal(True)
  sent_text(claude, [Key("system")]) |> should.equal("answer briefly")
  sent_text(claude, [Key("messages"), Index(0), Key("role")])
  |> should.equal("user")
  sent_text(claude, [
    Key("messages"),
    Index(0),
    Key("content"),
    Index(0),
    Key("type"),
  ])
  |> should.equal("text")
  sent_text(claude, [
    Key("messages"),
    Index(0),
    Key("content"),
    Index(0),
    Key("text"),
  ])
  |> should.equal("hello")
  sent_text(claude, [
    Key("messages"),
    Index(0),
    Key("content"),
    Index(2),
    Key("type"),
  ])
  |> should.equal("image")
  sent_text(claude, [
    Key("messages"),
    Index(0),
    Key("content"),
    Index(2),
    Key("source"),
    Key("type"),
  ])
  |> should.equal("base64")
  sent_text(claude, [
    Key("messages"),
    Index(1),
    Key("content"),
    Index(1),
    Key("type"),
  ])
  |> should.equal("tool_use")
  sent_text(claude, [
    Key("messages"),
    Index(2),
    Key("content"),
    Index(0),
    Key("type"),
  ])
  |> should.equal("tool_result")
  sent_text(claude, [
    Key("messages"),
    Index(2),
    Key("content"),
    Index(0),
    Key("tool_use_id"),
  ])
  |> should.equal("call-1")
  sent_text(claude, [Key("tools"), Index(0), Key("name")])
  |> should.equal("python")
  sent_text(claude, [Key("tools"), Index(0), Key("input_schema"), Key("type")])
  |> should.equal("object")
  sent_text(claude, [Key("tool_choice"), Key("type")]) |> should.equal("any")
  sent_text(claude, [Key("thinking"), Key("type")]) |> should.equal("adaptive")
  sent_text(claude, [Key("thinking"), Key("display")])
  |> should.equal("summarized")
  sent_text(claude, [Key("output_config"), Key("effort")])
  |> should.equal("high")

  // OpenAI Responses: every input item carries `type`, and message text is a
  // typed content part.
  let gpt = provider_body("open_ai", "gpt-5.4", types.AnyTool)
  sent_text(gpt, [Key("model")]) |> should.equal("gpt-5.4")
  sent_bool(gpt, [Key("stream")]) |> should.equal(True)
  sent_bool(gpt, [Key("store")]) |> should.equal(False)
  sent_text(gpt, [Key("instructions")]) |> should.equal("answer briefly")
  sent_int(gpt, [Key("max_output_tokens")]) |> should.equal(512)
  sent_text(gpt, [Key("include"), Index(0)])
  |> should.equal("reasoning.encrypted_content")
  sent_text(gpt, [Key("reasoning"), Key("effort")]) |> should.equal("high")
  sent_text(gpt, [Key("text"), Key("format"), Key("type")])
  |> should.equal("json_object")
  sent_text(gpt, [Key("tools"), Index(0), Key("type")])
  |> should.equal("function")
  sent_text(gpt, [Key("tools"), Index(0), Key("name")])
  |> should.equal("python")
  sent_bool(gpt, [Key("tools"), Index(0), Key("strict")]) |> should.equal(False)
  sent_text(gpt, [Key("input"), Index(0), Key("type")])
  |> should.equal("message")
  sent_text(gpt, [Key("input"), Index(0), Key("role")]) |> should.equal("user")
  sent_text(gpt, [
    Key("input"),
    Index(0),
    Key("content"),
    Index(0),
    Key("type"),
  ])
  |> should.equal("input_text")
  sent_text(gpt, [
    Key("input"),
    Index(0),
    Key("content"),
    Index(0),
    Key("text"),
  ])
  |> should.equal("hello")
  sent_text(gpt, [
    Key("input"),
    Index(1),
    Key("content"),
    Index(1),
    Key("type"),
  ])
  |> should.equal("input_image")
  sent_text(gpt, [Key("input"), Index(2), Key("role")])
  |> should.equal("assistant")
  sent_text(gpt, [
    Key("input"),
    Index(2),
    Key("content"),
    Index(0),
    Key("type"),
  ])
  |> should.equal("output_text")
  sent_text(gpt, [Key("input"), Index(3), Key("type")])
  |> should.equal("function_call")
  sent_text(gpt, [Key("input"), Index(3), Key("call_id")])
  |> should.equal("call-1")
  sent_text(gpt, [Key("input"), Index(3), Key("name")])
  |> should.equal("python")
  sent_text(gpt, [Key("input"), Index(4), Key("type")])
  |> should.equal("function_call_output")
  sent_text(gpt, [Key("input"), Index(4), Key("call_id")])
  |> should.equal("call-1")
  sent_text(gpt, [Key("input"), Index(4), Key("output")])
  |> should.equal("tool said")
  // The exact item shapes Zed's own Responses client sends.
  contains(
    gpt,
    "{\"content\":[{\"text\":\"hello\",\"type\":\"input_text\"}],\"role\":\"user\",\"type\":\"message\"}",
  )
  contains(
    gpt,
    "{\"content\":[{\"annotations\":[],\"text\":\"calling\",\"type\":\"output_text\"}],\"role\":\"assistant\",\"type\":\"message\"}",
  )
  contains(
    gpt,
    "{\"arguments\":\"{\\\"code\\\":\\\"x\\\"}\",\"call_id\":\"call-1\",\"name\":\"python\",\"type\":\"function_call\"}",
  )
  assert_responses_items_typed(gpt)

  // Google GenerateContent: wrapped model name, parts, function responses.
  let gemini = provider_body("google", "gemini-3.1-pro-preview", types.AnyTool)
  sent_text(gemini, [Key("model")])
  |> should.equal("models/gemini-3.1-pro-preview")
  sent_text(gemini, [Key("contents"), Index(0), Key("role")])
  |> should.equal("user")
  sent_text(gemini, [
    Key("contents"),
    Index(0),
    Key("parts"),
    Index(0),
    Key("text"),
  ])
  |> should.equal("hello")
  sent_text(gemini, [
    Key("contents"),
    Index(0),
    Key("parts"),
    Index(2),
    Key("inlineData"),
    Key("mimeType"),
  ])
  |> should.equal("image/png")
  sent_text(gemini, [Key("contents"), Index(1), Key("role")])
  |> should.equal("model")
  sent_text(gemini, [
    Key("contents"),
    Index(1),
    Key("parts"),
    Index(1),
    Key("functionCall"),
    Key("name"),
  ])
  |> should.equal("python")
  sent_text(gemini, [
    Key("contents"),
    Index(2),
    Key("parts"),
    Index(0),
    Key("functionResponse"),
    Key("name"),
  ])
  |> should.equal("python")
  sent_text(gemini, [
    Key("contents"),
    Index(2),
    Key("parts"),
    Index(0),
    Key("functionResponse"),
    Key("response"),
    Key("output"),
  ])
  |> should.equal("tool said")
  sent_text(gemini, [
    Key("systemInstruction"),
    Key("parts"),
    Index(0),
    Key("text"),
  ])
  |> should.equal("answer briefly")
  sent_text(gemini, [
    Key("generationConfig"),
    Key("thinkingConfig"),
    Key("thinkingLevel"),
  ])
  |> should.equal("HIGH")
  sent_bool(gemini, [
    Key("generationConfig"),
    Key("thinkingConfig"),
    Key("includeThoughts"),
  ])
  |> should.equal(True)
  sent_int(gemini, [Key("generationConfig"), Key("maxOutputTokens")])
  |> should.equal(512)
  sent_text(gemini, [Key("generationConfig"), Key("responseMimeType")])
  |> should.equal("application/json")
  sent_text(gemini, [
    Key("tools"),
    Index(0),
    Key("functionDeclarations"),
    Index(0),
    Key("name"),
  ])
  |> should.equal("python")
  sent_text(gemini, [
    Key("tools"),
    Index(0),
    Key("functionDeclarations"),
    Index(0),
    Key("parametersJsonSchema"),
    Key("type"),
  ])
  |> should.equal("object")
  sent_text(gemini, [
    Key("toolConfig"),
    Key("functionCallingConfig"),
    Key("mode"),
  ])
  |> should.equal("ANY")

  // OpenAI Chat Completions: system message, function tools, tool results.
  let grok = provider_body("x_ai", "grok-4", types.NamedTool("python"))
  sent_text(grok, [Key("model")]) |> should.equal("grok-4")
  sent_bool(grok, [Key("stream")]) |> should.equal(True)
  sent_text(grok, [Key("messages"), Index(0), Key("role")])
  |> should.equal("system")
  sent_text(grok, [Key("messages"), Index(0), Key("content")])
  |> should.equal("answer briefly")
  sent_text(grok, [Key("messages"), Index(1), Key("role")])
  |> should.equal("user")
  sent_text(grok, [Key("messages"), Index(1), Key("content")])
  |> should.equal("hello")
  sent_text(grok, [Key("messages"), Index(3), Key("role")])
  |> should.equal("assistant")
  sent_text(grok, [
    Key("messages"),
    Index(3),
    Key("tool_calls"),
    Index(0),
    Key("id"),
  ])
  |> should.equal("call-1")
  sent_text(grok, [Key("messages"), Index(4), Key("role")])
  |> should.equal("tool")
  sent_text(grok, [Key("messages"), Index(4), Key("tool_call_id")])
  |> should.equal("call-1")
  sent_text(grok, [Key("messages"), Index(5), Key("content")])
  |> should.equal("bye")
  sent_int(grok, [Key("max_completion_tokens")]) |> should.equal(512)
  sent_bool(grok, [Key("stream_options"), Key("include_usage")])
  |> should.equal(True)
  sent_text(grok, [Key("tools"), Index(0), Key("type")])
  |> should.equal("function")
  sent_text(grok, [Key("tools"), Index(0), Key("function"), Key("name")])
  |> should.equal("python")
  sent_text(grok, [Key("tool_choice"), Key("type")]) |> should.equal("function")
  sent_text(grok, [Key("tool_choice"), Key("function"), Key("name")])
  |> should.equal("python")
  sent_text(grok, [Key("response_format"), Key("type")])
  |> should.equal("json_object")
}

fn feed(reducer: albedo_stream.Reducer, event: String) {
  let assert Ok(#(next, events, turn)) = reducer.feed(event)
  #(next, events, turn)
}

fn reduction() {
  let reducer = zed_stream.reducer("anthropic", "claude-sonnet-4-6", [])
  let #(reducer, _, _) = feed(reducer, "{\"status\":\"started\"}")
  let #(reducer, _, _) =
    feed(
      reducer,
      "{\"event\":{\"type\":\"message_start\",\"message\":{\"id\":\"zed-test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0,\"cache_read_input_tokens\":3}}}}",
    )
  let #(reducer, _, _) =
    feed(
      reducer,
      "{\"event\":{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}}",
    )
  let #(reducer, events, _) =
    feed(
      reducer,
      "{\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"consider\"}}}",
    )
  events |> should.equal([types.ThinkingDelta("consider")])
  let #(reducer, _, _) =
    feed(reducer, "{\"event\":{\"type\":\"content_block_stop\",\"index\":0}}")
  let #(reducer, _, _) =
    feed(
      reducer,
      "{\"event\":{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}}",
    )
  let #(reducer, _, turn) =
    feed(reducer, "{\"event\":{\"type\":\"message_stop\"}}")
  turn |> should.equal(None)
  reducer.finish() |> should.equal(Error(types.UnexpectedEnd))
  let #(_, _, turn) = feed(reducer, "{\"status\":\"stream_ended\"}")
  let assert Some(turn) = turn
  let assert Some(usage) = turn.usage
  usage.input_tokens |> should.equal(13)
  usage.output_tokens |> should.equal(7)
  usage.cached_input_tokens |> should.equal(Some(3))
  reducer.feed("{\"status\":{\"failed\":{\"message\":\"quota exhausted\"}}}")
  |> should.equal(Error(types.ProviderError("quota exhausted")))
  reducer.feed("not JSON") |> should.be_error
}

fn framing() {
  let parser = sse.new_ndjson(100)
  let assert Ok(#(parser, events)) =
    sse.feed(parser, <<"{\"event\":\"":utf8, 0xc3>>)
  events |> should.equal([])
  let assert Ok(#(parser, events)) = sse.feed(parser, <<0xa9, "\"}\r\n":utf8>>)
  events |> should.equal([sse.Event("", "{\"event\":\"é\"}")])
  let assert Ok(#(parser, _)) =
    sse.feed(parser, bit_array.from_string("{\"status\":\"stream_ended\"}"))
  sse.finish(parser)
  |> should.equal(Ok([sse.Event("", "{\"status\":\"stream_ended\"}")]))
  sse.feed(sse.new_ndjson(2), bit_array.from_string("123\n"))
  |> should.equal(Error(sse.EventTooLarge))
}

fn gemini_roundtrip(
  chunks: List(String),
  finish: String,
) -> #(types.Turn, String) {
  let reducer =
    list.fold(
      chunks,
      zed_stream.reducer("google", "gemini-3.1-pro-preview", []),
      fn(reducer, parts) {
        let #(next, _, _) =
          feed(
            reducer,
            "{\"event\":{\"candidates\":[{\"content\":{\"parts\":"
              <> parts
              <> "}}]}}",
          )
        next
      },
    )
  let #(reducer, _, _) =
    feed(
      reducer,
      "{\"event\":{\"candidates\":[{\"finishReason\":\"" <> finish <> "\"}]}}",
    )
  let #(_, _, turn) = feed(reducer, "{\"status\":\"stream_ended\"}")
  let assert Some(turn) = turn
  let body =
    request_body(
      "google",
      "gemini-3.1-pro-preview",
      [types.User("hello"), ..list.map(turn.output, types.Replay)],
      types.defaults,
    )
  #(turn, body)
}

fn gemini_many_calls() {
  let indices = int.range(255, -1, [], list.prepend)
  let parts =
    json.array(indices, fn(index) {
      json.object([
        #(
          "functionCall",
          json.object([
            #("id", json.string("duplicate")),
            #("name", json.string("tool-" <> int.to_string(index))),
            #("args", json.object([])),
          ]),
        ),
      ])
    })
    |> json.to_string
  let #(reducer, events, _) =
    feed(
      zed_stream.reducer("google", "gemini-3.1-pro-preview", []),
      "{\"event\":{\"candidates\":[{\"content\":{\"parts\":"
        <> parts
        <> "},\"finishReason\":\"STOP\"}]}}",
    )
  let calls =
    list.map(events, fn(event) {
      let assert types.ArgumentsDelta(index, name, _) = event
      #(index, name)
    })
  calls
  |> should.equal(
    list.map(indices, fn(index) { #(index, "tool-" <> int.to_string(index)) }),
  )
  let #(_, _, turn) = feed(reducer, "{\"status\":\"stream_ended\"}")
  let assert Some(turn) = turn
  list.length(turn.tool_calls) |> should.equal(256)
  let ids = list.map(turn.tool_calls, fn(call) { call.id })
  ids |> set.from_list |> set.size |> should.equal(256)
  list.first(ids) |> should.equal(Ok("duplicate"))
}

fn gemini_stream_replay() {
  let cases = [
    #(["[{\"text\":\"a\"}]", "[{\"text\":\"b\"}]"], "[{\"text\":\"ab\"}]", "ab"),
    #(
      [
        "[{\"text\":\"a\"}]",
        "[{\"text\":\"b\",\"thoughtSignature\":\"s\"}]",
        "[{\"text\":\"c\",\"thoughtSignature\":\"s\"}]",
        "[{\"text\":\"d\",\"thoughtSignature\":\"t\"}]",
        "[{\"text\":\"e\"}]",
      ],
      "[{\"text\":\"a\"},{\"text\":\"b\",\"thoughtSignature\":\"s\"},{\"text\":\"c\",\"thoughtSignature\":\"s\"},{\"text\":\"d\",\"thoughtSignature\":\"t\"},{\"text\":\"e\"}]",
      "abcde",
    ),
    #(
      ["[{\"text\":\"a\"}]", "[{\"text\":\"\",\"thoughtSignature\":\"s\"}]"],
      "[{\"text\":\"a\"},{\"text\":\"\",\"thoughtSignature\":\"s\"}]",
      "a",
    ),
    #(
      [
        "[{\"text\":\"a\",\"thought\":true}]",
        "[{\"text\":\"b\",\"thought\":true}]",
        "[{\"text\":\"c\",\"thought\":true,\"thoughtSignature\":\"s\"}]",
        "[{\"text\":\"d\",\"thought\":true,\"thoughtSignature\":\"s\"}]",
        "[{\"text\":\"e\",\"thought\":true,\"thoughtSignature\":\"t\"}]",
        "[{\"text\":\"answer\"}]",
      ],
      "[{\"text\":\"ab\",\"thought\":true},{\"text\":\"c\",\"thought\":true,\"thoughtSignature\":\"s\"},{\"text\":\"d\",\"thought\":true,\"thoughtSignature\":\"s\"},{\"text\":\"e\",\"thought\":true,\"thoughtSignature\":\"t\"},{\"text\":\"answer\"}]",
      "answer",
    ),
  ]
  list.each(cases, fn(example) {
    let #(turn, body) = gemini_roundtrip(example.0, "STOP")
    let assert [item] = turn.output
    types.inspect_item(item, decode.at(["content"], decode.string))
    |> should.equal(Ok(example.2))
    let assert Ok(expected) = json.parse(example.1, decode.dynamic)
    body_field(
      body,
      [Key("provider_request"), Key("contents"), Index(1), Key("parts")],
      decode.dynamic,
    )
    |> should.equal(expected)
  })
  let chunks = [
    "[{\"text\":\"partial\"},{\"functionCall\":{\"name\":\"python\",\"id\":\"call-1\",\"args\":{\"code\":\"x\"}},\"thoughtSignature\":\"call-signature\"}]",
  ]
  list.each(["MAX_TOKENS", "SAFETY"], fn(finish) {
    let #(turn, body) = gemini_roundtrip(chunks, finish)
    turn.tool_calls |> should.equal([])
    string.contains(body, "functionCall") |> should.be_false
    sent_text(body, [
      Key("contents"),
      Index(1),
      Key("parts"),
      Index(0),
      Key("text"),
    ])
    |> should.equal("partial")
  })
  let #(turn, body) = gemini_roundtrip(chunks, "STOP")
  list.length(turn.tool_calls) |> should.equal(1)
  sent_text(body, [
    Key("contents"),
    Index(1),
    Key("parts"),
    Index(1),
    Key("thoughtSignature"),
  ])
  |> should.equal("call-signature")
}

fn native_protocols() {
  {
    let reducer = zed_stream.reducer("open_ai", "gpt-5.4", [])
    let reducer =
      list.fold(
        [
          "{\"event\":{\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"r\",\"output_index\":0,\"summary_index\":0,\"delta\":\"gpt-thought\"}}",
          "{\"event\":{\"type\":\"response.completed\",\"response\":{\"id\":\"response-test\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"gpt-reply\",\"annotations\":[]}]}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"output_tokens_details\":{\"reasoning_tokens\":2}}}}}",
        ],
        reducer,
        fn(reducer, event) {
          let #(next, _, turn) = feed(reducer, event)
          turn |> should.equal(None)
          next
        },
      )
    let #(_, _, turn) = feed(reducer, "{\"status\":\"stream_ended\"}")
    let assert Some(turn) = turn
    let assert Some(usage) = turn.usage
    usage.input_tokens |> should.equal(10)
    usage.output_tokens |> should.equal(5)
    usage.reasoning_tokens |> should.equal(Some(2))
    list.length(turn.output) |> should.equal(1)
  }
  {
    let reducer = zed_stream.reducer("google", "gemini-3.1-pro-preview", [])
    let reducer =
      list.fold(
        [
          "{\"event\":{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"gemini-thought\",\"thought\":true},{\"text\":\"gemini-reply\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":5,\"thoughtsTokenCount\":2,\"totalTokenCount\":17}}}",
        ],
        reducer,
        fn(reducer, event) {
          let #(next, _, turn) = feed(reducer, event)
          turn |> should.equal(None)
          next
        },
      )
    let #(_, _, turn) = feed(reducer, "{\"status\":\"stream_ended\"}")
    let assert Some(turn) = turn
    let assert Some(usage) = turn.usage
    usage.input_tokens |> should.equal(10)
    // Thought tokens are output tokens here, and nothing else is added.
    usage.output_tokens |> should.equal(7)
    usage.reasoning_tokens |> should.equal(Some(2))
    list.length(turn.output) |> should.equal(1)
  }
  {
    let reducer = zed_stream.reducer("x_ai", "grok-4", [])
    let reducer =
      list.fold(
        [
          "{\"event\":{\"id\":\"grok-test\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"reasoning_content\":\"grok-thought\"},\"finish_reason\":null}]}}",
          "{\"event\":{\"id\":\"grok-test\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"grok-reply\"},\"finish_reason\":\"stop\"}]}}",
          "{\"event\":{\"id\":\"grok-test\",\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}}",
        ],
        reducer,
        fn(reducer, event) {
          let #(next, _, turn) = feed(reducer, event)
          turn |> should.equal(None)
          next
        },
      )
    let #(_, _, turn) = feed(reducer, "{\"status\":\"stream_ended\"}")
    let assert Some(turn) = turn
    let assert Some(usage) = turn.usage
    usage.input_tokens |> should.equal(10)
    usage.output_tokens |> should.equal(5)
    list.length(turn.output) |> should.equal(1)
  }
}

/// One provider detail block, as a reducer records it for replay.
fn detail(kind: String, fields: List(#(String, json.Json))) -> json.Json {
  json.object([#("type", json.string(kind)), ..fields])
}

/// A replayed assistant turn: text, one tool call, and the provider's own
/// recorded detail blocks.
fn replayed(text: String, details: List(json.Json)) -> types.Input {
  let call = types.ToolCall("call-1", "python", "{\"code\":\"x\"}")
  let assert Ok(item) =
    json.parse(
      json.to_string(
        replay.message(
          json.string(text),
          "",
          case details {
            [] -> None
            details -> Some(json.preprocessed_array(details))
          },
          [call],
        ),
      ),
      types.replay_decoder(types.ChatCompletions),
    )
  types.Replay(item)
}

fn request_body(
  provider: String,
  model: String,
  inputs: List(types.Input),
  options: types.Options,
) -> String {
  let request = types.Request(model, None, inputs, [], Some(512), options)
  let assert Ok(exchange) =
    wire.encode(
      provider,
      "https://cloud.zed.dev",
      "test-jwt",
      "session",
      request,
    )
  string_tree.to_string(exchange.body)
}

fn reasoning_options() -> types.Options {
  types.Options(..types.defaults, effort: Some("high"))
}

/// A thinking-enabled Claude turn continues with the signed blocks the
/// reducer recorded, in the order the model sent them.
fn anthropic_thinking_replay() {
  let blocks = [
    json.object([
      #("type", json.string("thinking")),
      #("thinking", json.string("consider")),
      #("signature", json.string("sig-1")),
    ]),
    json.object([
      #("type", json.string("text")),
      #("text", json.string("calling")),
    ]),
    json.object([
      #("type", json.string("tool_use")),
      #("id", json.string("call-1")),
      #("name", json.string("python")),
      #("input", json.object([])),
    ]),
  ]
  let body =
    request_body(
      "anthropic",
      "claude-sonnet-4-6",
      [
        types.User("hello"),
        replayed("calling", [
          detail("claude.blocks", [
            #("model", json.string("claude-sonnet-4-6")),
            #("blocks", json.preprocessed_array(blocks)),
          ]),
        ]),
        types.ToolOutput("call-1", "tool said", []),
      ],
      reasoning_options(),
    )
  let content = [Key("messages"), Index(1), Key("content")]
  sent_text(body, list.append(content, [Index(0), Key("type")]))
  |> should.equal("thinking")
  sent_text(body, list.append(content, [Index(0), Key("signature")]))
  |> should.equal("sig-1")
  sent_text(body, list.append(content, [Index(0), Key("thinking")]))
  |> should.equal("consider")
  sent_text(body, list.append(content, [Index(1), Key("type")]))
  |> should.equal("text")
  sent_text(body, list.append(content, [Index(2), Key("type")]))
  |> should.equal("tool_use")
}

/// A replayed Gemini call carries the signature the model issued, and no
/// signature at all when the model issued none.
fn gemini_signatures() {
  let unsigned =
    request_body(
      "google",
      "gemini-3.1-pro-preview",
      [types.User("hello"), replayed("calling", [])],
      types.defaults,
    )
  string.contains(unsigned, "thoughtSignature") |> should.be_false
  let signed =
    json.object([
      #(
        "functionCall",
        json.object([
          #("name", json.string("python")),
          #("args", json.object([#("code", json.string("x"))])),
          #("id", json.string("call-1")),
        ]),
      ),
      #("thoughtSignature", json.string("model-signature")),
    ])
  let with_signature =
    request_body(
      "google",
      "gemini-3.1-pro-preview",
      [
        types.User("hello"),
        replayed("calling", [
          detail("vertex.parts", [#("parts", json.preprocessed_array([signed]))]),
        ]),
      ],
      types.defaults,
    )
  sent_text(with_signature, [
    Key("contents"),
    Index(1),
    Key("parts"),
    Index(0),
    Key("thoughtSignature"),
  ])
  |> should.equal("model-signature")
}

/// Gemini takes tool-result media nested in the function response, except for
/// the 2.5 family, which takes it as sibling parts of the same turn.
fn gemini_tool_media() {
  let assert Ok(image) = types.image("image/png", "aGVsbG8=", 2, 3, 5)
  let inputs = [
    types.User("hello"),
    replayed("calling", []),
    types.ToolOutput("call-1", "tool said", [image]),
  ]
  let nested =
    request_body("google", "gemini-3.1-pro-preview", inputs, types.defaults)
  sent_text(nested, [
    Key("contents"),
    Index(2),
    Key("parts"),
    Index(0),
    Key("functionResponse"),
    Key("parts"),
    Index(0),
    Key("inlineData"),
    Key("mimeType"),
  ])
  |> should.equal("image/png")
  sent_text(nested, [
    Key("contents"),
    Index(2),
    Key("parts"),
    Index(0),
    Key("functionResponse"),
    Key("id"),
  ])
  |> should.equal("call-1")
  let sibling =
    request_body("google", "gemini-2.5-flash", inputs, types.defaults)
  has(sibling, [
    Key("contents"),
    Index(2),
    Key("parts"),
    Index(0),
    Key("functionResponse"),
    Key("parts"),
  ])
  |> should.be_false
  sent_text(sibling, [
    Key("contents"),
    Index(2),
    Key("parts"),
    Index(2),
    Key("inlineData"),
    Key("mimeType"),
  ])
  |> should.equal("image/png")
}

/// A hosted Gemini or effort the local table does not know forwards the
/// catalog's level instead of failing the request.
fn gemini_unknown_effort() {
  let body =
    request_body(
      "google",
      "gemini-9-hosted-preview",
      [types.User("hi")],
      reasoning_options(),
    )
  sent_text(body, [
    Key("generationConfig"),
    Key("thinkingConfig"),
    Key("thinkingLevel"),
  ])
  |> should.equal("HIGH")
}

/// Encrypted reasoning is requested only when it will be replayed, a summary
/// is asked for whenever the request reasons, and a recorded reasoning item
/// returns with the next request.
fn responses_reasoning() {
  let quiet =
    request_body("open_ai", "gpt-5.4", [types.User("hi")], types.defaults)
  has(quiet, [Key("include")]) |> should.be_false
  let reasoning =
    request_body("open_ai", "gpt-5.4", [types.User("hi")], reasoning_options())
  sent_text(reasoning, [Key("include"), Index(0)])
  |> should.equal("reasoning.encrypted_content")
  sent_text(reasoning, [Key("reasoning"), Key("summary")])
  |> should.equal("auto")
  let none =
    request_body(
      "open_ai",
      "gpt-5.4",
      [types.User("hi")],
      types.Options(..types.defaults, effort: Some("none")),
    )
  has(none, [Key("reasoning")]) |> should.be_false
  let item =
    json.object([
      #("type", json.string("reasoning")),
      #("id", json.string("rs-1")),
      #("encrypted_content", json.string("opaque")),
    ])
  let replayed_reasoning =
    request_body(
      "open_ai",
      "gpt-5.4",
      [
        types.User("hi"),
        replayed("calling", [
          detail("openai.reasoning", [
            #("items", json.preprocessed_array([item])),
          ]),
        ]),
      ],
      types.defaults,
    )
  sent_text(replayed_reasoning, [Key("input"), Index(1), Key("type")])
  |> should.equal("reasoning")
  sent_text(replayed_reasoning, [
    Key("input"),
    Index(1),
    Key("encrypted_content"),
  ])
  |> should.equal("opaque")
  sent_text(replayed_reasoning, [Key("input"), Index(2), Key("type")])
  |> should.equal("message")
  sent_text(replayed_reasoning, [Key("input"), Index(3), Key("type")])
  |> should.equal("function_call")
  // The replayed item is the reason the request pays for encrypted reasoning.
  sent_text(replayed_reasoning, [Key("include"), Index(0)])
  |> should.equal("reasoning.encrypted_content")
}

/// The status-message capability is presence-only, as the editor reads it.
fn capability_header() {
  zed_stream.supports_status_messages([
    #("X-Zed-Server-Supports-Status-Messages", "false"),
  ])
  |> should.be_true
  zed_stream.supports_status_messages([
    #("content-type", "application/x-ndjson"),
  ])
  |> should.be_false
}

fn wide_schema() {
  let names =
    int.range(512, 0, [], fn(names, index) { [int.to_string(index), ..names] })
  let schema = fn(required) {
    json.object([
      #("type", json.string("object")),
      #("additionalProperties", json.bool(False)),
      #("required", json.array(required, json.string)),
      #(
        "properties",
        json.object(
          list.map(names, fn(name) {
            #(name, json.object([#("type", json.string("string"))]))
          }),
        ),
      ),
    ])
  }
  sent_bool(single_tool_body(schema(list.reverse(names))), [
    Key("tools"),
    Index(0),
    Key("strict"),
  ])
  |> should.be_true
  sent_bool(single_tool_body(schema(list.drop(names, 1))), [
    Key("tools"),
    Index(0),
    Key("strict"),
  ])
  |> should.be_false
}

fn tool_image_order() {
  let assert Ok(first) = types.image("image/png", "YQ==", 1, 1, 1)
  let assert Ok(second) = types.image("image/png", "Yg==", 1, 1, 1)
  let assert Ok(third) = types.image("image/png", "Yw==", 1, 1, 1)
  let request =
    openai_api.request("test", [
      types.ToolOutput("one", "", [first, second]),
      types.ToolOutput("no-images", "plain", []),
      types.ToolOutput("two", "", [third]),
      types.User("next"),
    ])
  let assert Ok(body) = encoder.encode(types.ChatCompletions, request)
  let body = string_tree.to_string(body)
  codex_body(body, [Key("messages"), Index(0), Key("tool_call_id")])
  |> should.equal("one")
  codex_body(body, [Key("messages"), Index(1), Key("tool_call_id")])
  |> should.equal("no-images")
  codex_body(body, [Key("messages"), Index(2), Key("tool_call_id")])
  |> should.equal("two")
  let assert Ok(parts) =
    json.parse(body, decode.at(["messages"], decode.list(decode.dynamic)))
  list.length(parts) |> should.equal(5)
  let part = fn(index, key) {
    codex_body(body, [
      Key("messages"),
      Index(3),
      Key("content"),
      Index(index),
      Key(key),
    ])
  }
  part(0, "text") |> should.equal("Images from tool call one:")
  codex_body(body, [
    Key("messages"),
    Index(3),
    Key("content"),
    Index(1),
    Key("image_url"),
    Key("url"),
  ])
  |> should.equal("data:image/png;base64,YQ==")
  codex_body(body, [
    Key("messages"),
    Index(3),
    Key("content"),
    Index(2),
    Key("image_url"),
    Key("url"),
  ])
  |> should.equal("data:image/png;base64,Yg==")
  part(3, "text") |> should.equal("Images from tool call two:")
  codex_body(body, [
    Key("messages"),
    Index(3),
    Key("content"),
    Index(4),
    Key("image_url"),
    Key("url"),
  ])
  |> should.equal("data:image/png;base64,Yw==")
  codex_body(body, [Key("messages"), Index(4), Key("content")])
  |> should.equal("next")
}

pub fn main() {
  wide_schema()
  tool_image_order()
  gemini_stream_replay()
  gemini_many_calls()
  native_protocols()
  encoding()
  provider_requests()
  tool_strictness()
  anthropic_thinking_replay()
  gemini_signatures()
  gemini_tool_media()
  gemini_unknown_effort()
  responses_reasoning()
  capability_header()
  strict_traversal()
  codex_policy()
  reduction()
  framing()
  io.println(
    "Zed per-family provider requests, replayed thinking/signatures/reasoning, strict-schema traversal, Codex policy, thinking/usage/status reducer and bounded NDJSON cases passed",
  )
}
