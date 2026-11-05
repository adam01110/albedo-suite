import albedo/openai_api/types.{
  type Error, type Input, type Protocol, type ProviderPolicy, type Request,
  type Tool, Assistant, ChatCompletions, Codex, InvalidRequest, OpenAI, Replay,
  Responses, ToolOutput, User, UserImage,
}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam/string_tree.{type StringTree}

/// Encode to iodata; the request is never flattened. Each input's small
/// fragments are coalesced as it is encoded (see `flatten`).
pub fn encode(
  protocol: Protocol,
  request: Request,
) -> Result(StringTree, Error) {
  encode_with_policy(protocol, OpenAI, request)
}

pub fn encode_with_policy(
  protocol: Protocol,
  policy: ProviderPolicy,
  request: Request,
) -> Result(StringTree, Error) {
  use _ <- result.try(validate(request))
  let #(instructions, developer) = layout(protocol, policy, request)
  let reasoning = echoes_reasoning(protocol, request.input)
  let include_reasoning = includes_reasoning(protocol, request)
  use input <- result.try(encode_inputs(protocol, reasoning, request.input, []))
  let input = case developer {
    Some(context) -> [message(Responses, "developer", context), ..input]
    None -> input
  }
  let fields = [
    #("model", json.string(request.model)),
    #("stream", json.bool(True)),
  ]
  let fields = case protocol {
    Responses -> {
      let max_tokens = case policy {
        OpenAI
        | types.OpenCodeGo(_, _)
        | types.OpenCodeZen(_, _, _)
        | types.Mistral(_)
        | types.GitHubCopilot(_) -> request.max_output_tokens
        Codex(_, _) -> None
      }
      [
        #("input", json.preprocessed_array(input)),
        #("store", json.bool(False)),
        ..fields
      ]
      // Encrypted reasoning is requested only when it will be replayed, as
      // the provider charges for it either way.
      |> optional(
        "include",
        case include_reasoning {
          True -> Some(["reasoning.encrypted_content"])
          False -> None
        },
        json.array(_, json.string),
      )
      |> optional("instructions", instructions, json.string)
      |> optional("max_output_tokens", max_tokens, json.int)
    }
    ChatCompletions -> {
      let messages = case instructions {
        None -> input
        Some(text) -> [message(ChatCompletions, "system", text), ..input]
      }
      let messages = #("messages", json.preprocessed_array(messages))
      case policy {
        // Mistral sends usage in its last chunk unasked.
        types.Mistral(session_id) ->
          [messages, #("n", json.int(1)), ..fields]
          |> optional("max_tokens", request.max_output_tokens, json.int)
          |> optional(
            "prompt_cache_key",
            when(request.options.cache, session_id),
            json.string,
          )
        _ ->
          [
            messages,
            #("n", json.int(1)),
            #(
              "stream_options",
              json.object([#("include_usage", json.bool(True))]),
            ),
            ..fields
          ]
          |> optional(
            "max_completion_tokens",
            request.max_output_tokens,
            json.int,
          )
      }
    }
  }
  let fields = case request.tools {
    [] -> fields
    tools -> [
      #("tools", json.array(tools, encode_tool(protocol, policy, _))),
      ..fields
    ]
  }
  let options = request.options
  let tools = request.tools != []
  let fields = case policy, protocol {
    // The ChatGPT reasoning backend fixes sampling; only what it accepts
    // overrides its defaults.
    Codex(_, session_id), Responses -> [
      #(
        "tool_choice",
        option.map(options.tool_choice, tool_choice(protocol, _))
          |> option.unwrap(json.string("auto")),
      ),
      #(
        "parallel_tool_calls",
        json.bool(option.unwrap(options.parallel_tool_calls, True)),
      ),
      #(
        "text",
        json.object(
          [#("verbosity", json.string("low"))]
          |> optional("format", options.format, response_format(protocol, _)),
        ),
      ),
      #(
        "reasoning",
        json.object([
          #("effort", json.string(option.unwrap(options.effort, "medium"))),
          #("summary", json.string("auto")),
        ]),
      ),
      #("prompt_cache_key", json.string(session_id)),
      ..fields
    ]
    _, _ -> {
      let fields =
        fields
        |> sampling(options)
        |> optional("tool_choice", options.tool_choice, tool_choice(protocol, _))
        |> optional(
          "parallel_tool_calls",
          when_tools(tools, options.parallel_tool_calls),
          json.bool,
        )
      case protocol {
        Responses ->
          fields
          |> optional("reasoning", reasoning_config(options.effort), fn(config) {
            json.object(config)
          })
          |> optional("text", options.format, fn(format) {
            json.object([#("format", response_format(protocol, format))])
          })
        ChatCompletions ->
          fields
          |> optional(
            "stop",
            case options.stop {
              [] -> None
              stop -> Some(stop)
            },
            json.array(_, json.string),
          )
          |> optional("reasoning_effort", options.effort, json.string)
          |> optional("response_format", options.format, response_format(
            protocol,
            _,
          ))
      }
    }
  }
  let fields = case policy {
    OpenAI | Codex(_, _) ->
      optional(fields, "service_tier", options.service_tier, json.string)
    types.OpenCodeGo(_, _)
    | types.OpenCodeZen(_, _, _)
    | types.Mistral(_)
    | types.GitHubCopilot(_) -> fields
  }
  Ok(json.to_string_tree(json.object(fields)))
}

/// The instructions a request sends, and the developer message that opens
/// its input. Codex caches by prefix in the order instructions, tools, input,
/// so there the workspace's context moves from the instructions to that
/// message, as Codex CLI sends AGENTS.md: what every session shares (the base
/// prompt, tool docs and tool schemas) then leads the prompt in one piece.
/// Other servers get the instructions whole, since not every Responses server
/// takes a developer message.
fn layout(
  protocol: Protocol,
  policy: ProviderPolicy,
  request: Request,
) -> #(Option(String), Option(String)) {
  case protocol, policy, types.split_instructions(request) {
    Responses, Codex(_, _), Some(#(shared, context)) -> #(
      Some(shared),
      Some(string.trim_start(context)),
    )
    _, _, _ -> #(request.instructions, None)
  }
}

fn validate(request: Request) -> Result(Nil, Error) {
  case string.is_empty(string.trim(request.model)), request.max_output_tokens {
    True, _ -> Error(InvalidRequest("model must not be empty"))
    _, Some(n) if n <= 0 ->
      Error(InvalidRequest("max_output_tokens must be positive"))
    _, _ -> validate_tools(request.tools)
  }
}

fn validate_tools(tools: List(Tool)) -> Result(Nil, Error) {
  list.try_fold(tools, set.new(), fn(seen, tool) {
    case string.is_empty(tool.name), set.contains(seen, tool.name) {
      True, _ -> Error(InvalidRequest("tool name must not be empty"))
      _, True -> Error(InvalidRequest("duplicate tool name: " <> tool.name))
      _, _ -> Ok(set.insert(seen, tool.name))
    }
  })
  |> result.replace(Nil)
}

/// Zed sends no reasoning object for an effort of `none`, and asks for a
/// streamed summary whenever it does reason.
fn reasoning_config(effort: Option(String)) -> Option(List(#(String, Json))) {
  case effort {
    Some("none") | None -> None
    Some(effort) ->
      Some([
        #("effort", json.string(effort)),
        #("summary", json.string("auto")),
      ])
  }
}

/// Whether this request pays for encrypted reasoning: it reasons, or it
/// replays a reasoning item the provider issued.
fn includes_reasoning(protocol: Protocol, request: Request) -> Bool {
  case request.options.effort {
    Some("none") | None -> replays_reasoning(protocol, request.input)
    Some(_) -> True
  }
}

fn replays_reasoning(protocol: Protocol, inputs: List(Input)) -> Bool {
  protocol == Responses
  && list.any(inputs, fn(input) {
    case input {
      Replay(item) ->
        types.replay_protocol(item) == Responses
        && types.replay_has(item, "encrypted_content")
      _ -> False
    }
  })
}

/// DeepSeek's thinking mode refuses a tools request whose assistant messages
/// lack `reasoning_content`, even one that never reasoned, so once the history
/// carries the field every assistant message does.
fn echoes_reasoning(protocol: Protocol, inputs: List(Input)) -> Bool {
  protocol == ChatCompletions
  && list.any(inputs, fn(input) {
    case input {
      Replay(item) -> types.replay_has(item, "reasoning_content")
      _ -> False
    }
  })
}

fn encode_inputs(
  protocol: Protocol,
  reasoning: Bool,
  inputs: List(Input),
  encoded: List(Json),
) -> Result(List(Json), Error) {
  case protocol, inputs {
    _, [] -> Ok(list.reverse(encoded))
    // Chat Completions tool messages carry text only, and nothing may come
    // between an assistant's tool calls and their results. The images of a
    // whole run of results follow it in one user message, labelled per call.
    ChatCompletions, [ToolOutput(..), ..] -> {
      let #(encoded, images, rest) = chat_tool_run(inputs, encoded, [])
      let encoded = case images {
        [] -> encoded
        _ -> [
          flatten(
            json.object([
              #("role", json.string("user")),
              #("content", json.preprocessed_array(list.reverse(images))),
            ]),
          ),
          ..encoded
        ]
      }
      encode_inputs(protocol, reasoning, rest, encoded)
    }
    _, [input, ..rest] -> {
      use json <- result.try(encode_input(protocol, reasoning, input))
      encode_inputs(protocol, reasoning, rest, [flatten(json), ..encoded])
    }
  }
}

fn chat_tool_run(
  inputs: List(Input),
  encoded: List(Json),
  images: List(Json),
) -> #(List(Json), List(Json), List(Input)) {
  case inputs {
    [ToolOutput(id, text, attached), ..rest] -> {
      let tool = chat_tool_message(id, text, attached)
      let images = case attached {
        [] -> images
        _ ->
          list.fold(
            attached,
            [
              text_part(ChatCompletions, "Images from tool call " <> id <> ":"),
              ..images
            ],
            fn(parts, image) { [image_part(ChatCompletions, image), ..parts] },
          )
      }
      chat_tool_run(rest, [flatten(tool), ..encoded], images)
    }
    rest -> #(encoded, images, rest)
  }
}

fn chat_tool_message(
  id: String,
  text: String,
  images: List(types.Image),
) -> Json {
  json.object([
    #("role", json.string("tool")),
    #("tool_call_id", json.string(id)),
    #("content", json.string(tool_text(text, images))),
  ])
}

/// Some providers reject an empty tool result even when images accompany it.
fn tool_text(text: String, images: List(types.Image)) -> String {
  case text, images {
    "", [_, ..] -> "(see attached image)"
    _, _ -> text
  }
}

fn encode_input(
  protocol: Protocol,
  reasoning: Bool,
  input: Input,
) -> Result(Json, Error) {
  case input {
    User(text) -> Ok(message(protocol, "user", text))
    UserImage(text, images) -> Ok(image_message(protocol, text, images))
    Assistant(text) if reasoning ->
      Ok(
        json.object([
          #("role", json.string("assistant")),
          #("content", json.string(text)),
          #("reasoning_content", json.string("")),
        ]),
      )
    Assistant(text) -> Ok(message(protocol, "assistant", text))
    ToolOutput(id, text, images) ->
      Ok(case protocol {
        Responses ->
          json.object([
            #("type", json.string("function_call_output")),
            #("call_id", json.string(id)),
            #("output", case images {
              [] -> json.string(text)
              _ -> {
                let parts = list.map(images, image_part(Responses, _))
                json.preprocessed_array(case text {
                  "" -> parts
                  _ -> [text_part(Responses, text), ..parts]
                })
              }
            }),
          ])
        ChatCompletions -> chat_tool_message(id, text, images)
      })
    Replay(item) ->
      case types.replay_protocol(item) == protocol {
        True if reasoning ->
          Ok(case types.replay_has(item, "reasoning_content") {
            True -> types.replay_json(item)
            False ->
              types.replay_json_with(item, "reasoning_content", json.string(""))
          })
        True -> Ok(types.replay_json(item))
        False -> Error(InvalidRequest("cannot replay output across protocols"))
      }
  }
}

/// Responses input is a list of typed items: every one carries `type`, and a
/// message's text is a typed content part rather than a bare string.
fn message(protocol: Protocol, role: String, content: String) -> Json {
  case protocol {
    Responses ->
      json.object([
        #("type", json.string("message")),
        #("role", json.string(role)),
        #("content", json.preprocessed_array([message_part(role, content)])),
      ])
    ChatCompletions ->
      json.object([
        #("role", json.string(role)),
        #("content", json.string(content)),
      ])
  }
}

/// A replayed assistant turn is output text, as the provider written it; every
/// other role is input text.
fn message_part(role: String, text: String) -> Json {
  case role {
    "assistant" ->
      json.object([
        #("type", json.string("output_text")),
        #("text", json.string(text)),
        #("annotations", json.array([], json.string)),
      ])
    _ ->
      json.object([
        #("type", json.string("input_text")),
        #("text", json.string(text)),
      ])
  }
}

fn image_message(
  protocol: Protocol,
  text: String,
  images: List(types.Image),
) -> Json {
  // An empty text part is rejected by some endpoints, and frame archives
  // attach images with no text by design.
  let images = list.map(images, image_part(protocol, _))
  let parts = case text {
    "" -> images
    _ -> [text_part(protocol, text), ..images]
  }
  json.object(case protocol {
    Responses -> [
      #("type", json.string("message")),
      #("role", json.string("user")),
      #("content", json.preprocessed_array(parts)),
    ]
    ChatCompletions -> [
      #("role", json.string("user")),
      #("content", json.preprocessed_array(parts)),
    ]
  })
}

fn text_part(protocol: Protocol, text: String) -> Json {
  let kind = case protocol {
    Responses -> "input_text"
    ChatCompletions -> "text"
  }
  json.object([#("type", json.string(kind)), #("text", json.string(text))])
}

fn image_part(protocol: Protocol, image: types.Image) -> Json {
  let #(mime_type, _, _, _) = types.image_meta(image)
  let url = data_url(mime_type, types.image_data(image))
  case protocol {
    Responses ->
      json.object([
        #("type", json.string("input_image")),
        #("detail", json.string("auto")),
        #("image_url", url),
      ])
    ChatCompletions ->
      json.object([
        #("type", json.string("image_url")),
        #("image_url", json.object([#("url", url)])),
      ])
  }
}

/// The exact provider-facing tool schema array used by `encode`.
/// Context inspection can reuse this without rebuilding request policy.
pub fn encode_tools(protocol: Protocol, tools: List(Tool)) -> Json {
  json.array(tools, encode_tool(protocol, OpenAI, _))
}

fn encode_tool(protocol: Protocol, policy: ProviderPolicy, tool: Tool) -> Json {
  let fields = [
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #("parameters", tool.parameters),
    #("strict", case policy {
      Codex(_, _) -> json.null()
      // Copilot validates a strict schema literally, and albedo's tools declare
      // optional properties (`python`'s `timeout_ms`), which strict mode forbids
      // next to a `required` list. Ask for non-strict arguments until the tool
      // schemas are strict-valid themselves.
      types.GitHubCopilot(_) -> json.bool(False)
      OpenAI
      | types.OpenCodeGo(_, _)
      | types.OpenCodeZen(_, _, _)
      | types.Mistral(_) ->
        json.bool(tool.strict && strict_schema(tool.parameters))
    }),
  ]
  json.object(case protocol {
    Responses -> [#("type", json.string("function")), ..fields]
    ChatCompletions -> [
      #("type", json.string("function")),
      #("function", json.object(fields)),
    ]
  })
}

/// OpenAI's strict mode requires every object level to close
/// `additionalProperties` and to list all of its properties as required. A
/// schema that cannot make that claim is sent as non-strict: the provider
/// rejects such a request outright rather than ignoring the claim.
fn strict_schema(parameters: Json) -> Bool {
  let assert Ok(value) = json.parse(json.to_string(parameters), decode.dynamic)
  schema_value(value)
}

fn schema_value(value: Dynamic) -> Bool {
  case as_dict(value) {
    Ok(fields) -> schema_object(fields)
    Error(_) ->
      case as_list(value) {
        Ok(items) -> list.all(items, schema_value)
        Error(_) -> True
      }
  }
}

fn schema_object(fields: Dict(String, Dynamic)) -> Bool {
  let properties = map_field(fields, "properties")
  let required = strings_field(fields, "required") |> set.from_list
  let object = declares(fields, "object") || !dict.is_empty(properties)
  let closed = is_false_field(fields, "additionalProperties")
  let complete = list.all(dict.keys(properties), set.contains(required, _))
  // Every schema-bearing keyword, so an object that hides behind one of them
  // still has to close additionalProperties and require its properties.
  let children =
    list.flatten([
      dict.values(properties),
      dict.values(map_field(fields, "patternProperties")),
      dict.values(map_field(fields, "dependentSchemas")),
      list_field(fields, "anyOf"),
      list_field(fields, "oneOf"),
      list_field(fields, "allOf"),
      list_field(fields, "prefixItems"),
      child_field(fields, "items"),
      child_field(fields, "additionalProperties"),
      child_field(fields, "not"),
      child_field(fields, "if"),
      child_field(fields, "then"),
      child_field(fields, "else"),
      dict.values(map_field(fields, "$defs")),
      dict.values(map_field(fields, "definitions")),
    ])
  { !object || { closed && complete } } && list.all(children, schema_value)
}

fn as_dict(value: Dynamic) -> Result(Dict(String, Dynamic), Nil) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.replace_error(Nil)
}

fn as_list(value: Dynamic) -> Result(List(Dynamic), Nil) {
  decode.run(value, decode.list(decode.dynamic)) |> result.replace_error(Nil)
}

fn map_field(
  fields: Dict(String, Dynamic),
  key: String,
) -> Dict(String, Dynamic) {
  dict.get(fields, key)
  |> result.try(as_dict)
  |> result.unwrap(dict.new())
}

fn list_field(fields: Dict(String, Dynamic), key: String) -> List(Dynamic) {
  dict.get(fields, key)
  |> result.try(as_list)
  |> result.unwrap([])
}

fn child_field(fields: Dict(String, Dynamic), key: String) -> List(Dynamic) {
  case dict.get(fields, key) {
    Ok(value) -> [value]
    Error(_) -> []
  }
}

fn strings_field(fields: Dict(String, Dynamic), key: String) -> List(String) {
  case dict.get(fields, key) {
    Ok(value) ->
      decode.run(value, decode.list(decode.string)) |> result.unwrap([])
    Error(_) -> []
  }
}

fn is_false_field(fields: Dict(String, Dynamic), key: String) -> Bool {
  case dict.get(fields, key) {
    Ok(value) -> decode.run(value, decode.bool) == Ok(False)
    Error(_) -> False
  }
}

/// Whether the schema names `kind`, either alone or in a list of types.
fn declares(fields: Dict(String, Dynamic), kind: String) -> Bool {
  case dict.get(fields, "type") {
    Error(_) -> False
    Ok(value) ->
      decode.run(value, decode.string) == Ok(kind)
      || case as_list(value) {
        Ok(types) ->
          list.any(types, fn(one) { decode.run(one, decode.string) == Ok(kind) })
        Error(_) -> False
      }
  }
}

fn when(condition: Bool, value: a) -> Option(a) {
  case condition {
    True -> Some(value)
    False -> None
  }
}

/// OpenAI rejects `parallel_tool_calls` on a request without tools.
fn when_tools(tools: Bool, value: Option(Bool)) -> Option(Bool) {
  case tools {
    True -> value
    False -> None
  }
}

fn sampling(
  fields: List(#(String, Json)),
  options: types.Options,
) -> List(#(String, Json)) {
  fields
  |> optional("temperature", options.temperature, json.float)
  |> optional("top_p", options.top_p, json.float)
}

fn tool_choice(protocol: Protocol, choice: types.ToolChoice) -> Json {
  case choice, protocol {
    types.AutoTool, _ -> json.string("auto")
    types.NoTool, _ -> json.string("none")
    types.AnyTool, _ -> json.string("required")
    types.NamedTool(name), Responses ->
      json.object([
        #("type", json.string("function")),
        #("name", json.string(name)),
      ])
    types.NamedTool(name), ChatCompletions ->
      json.object([
        #("type", json.string("function")),
        #("function", json.object([#("name", json.string(name))])),
      ])
  }
}

/// Chat Completions nests a schema under `json_schema`; Responses flattens it
/// into `text.format`.
fn response_format(protocol: Protocol, format: types.Format) -> Json {
  case format {
    types.JsonObject -> json.object([#("type", json.string("json_object"))])
    types.JsonSchema(name, schema, strict) -> {
      let fields = [
        #("name", json.string(name)),
        #("schema", schema),
        #("strict", json.bool(strict)),
      ]
      json.object(case protocol {
        Responses -> [#("type", json.string("json_schema")), ..fields]
        ChatCompletions -> [
          #("type", json.string("json_schema")),
          #("json_schema", json.object(fields)),
        ]
      })
    }
  }
}

fn optional(
  fields: List(#(String, Json)),
  key: String,
  value: Option(a),
  encode: fn(a) -> Json,
) -> List(#(String, Json)) {
  case value {
    None -> fields
    Some(value) -> [#(key, encode(value)), ..fields]
  }
}

/// One encoded input with its small fragments coalesced while only that
/// input's fragments are live. The request then crosses to the HTTP connection
/// process as a short list of binaries, large ones shared rather than copied.
@external(erlang, "albedo_openai_json", "flatten")
fn flatten(json: Json) -> Json

@external(erlang, "albedo_openai_json", "data_url")
fn data_url(mime_type: String, data: types.ImageData) -> Json
