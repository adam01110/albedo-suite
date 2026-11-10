//// Albedo requests into Amazon Bedrock's Anthropic-shaped Messages route.
//// The body and headers are the same on bedrock-runtime and bedrock-mantle;
//// only the host differs, so one encoder covers both. Replay keeps the signed
//// thinking blocks Claude recorded, so a thinking-enabled turn continues with
//// the blocks the provider issued.

import albedo/harness/extensions/bedrock/sigv4.{type Credentials}
import albedo/harness/extensions/claude/schema
import albedo/harness/extensions/claude/wire.{blocks_detail}
import albedo/openai_api
import albedo/openai_api/replay
import albedo/openai_api/types.{
  type Error, type Input, type Request, Assistant, InvalidRequest, Replay,
  ToolOutput, User, UserImage,
}
import gleam/bool
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}
import gleam/uri

pub type Auth {
  Bearer(key: String)
  SigV4(credentials: Credentials)
}

type Message {
  Message(role: String, blocks: List(Json))
}

pub fn encode(
  auth: Auth,
  base_url: String,
  now: Int,
  request: Request,
) -> Result(openai_api.Exchange, Error) {
  use <- bool.guard(
    !string.contains(string.lowercase(request.model), "claude"),
    Error(InvalidRequest(
      "this Bedrock profile serves Claude models through the Anthropic Messages route; configure an anthropic.claude* model id",
    )),
  )
  use #(host, region, service) <- result.try(target(base_url))
  use body_tree <- result.try(encode_body(request))
  let body = string_tree.to_string(body_tree)
  let auth_headers = case auth {
    Bearer(key) -> [#("x-api-key", key)]
    SigV4(credentials) ->
      sigv4.headers(credentials, region, service, host, now, body)
  }
  Ok(openai_api.Exchange(
    "https://" <> host <> "/anthropic/v1/messages",
    list.flatten([
      auth_headers,
      [
        #("anthropic-version", "2023-06-01"),
        #("accept", "text/event-stream"),
      ],
    ]),
    body_tree,
    120_000,
    None,
    8 * 1024 * 1024,
    True,
  ))
}

/// Encodes `request` into a portable Anthropic Messages JSON body. A replayed
/// turn from the same model carries the signed thinking blocks the reducer
/// recorded; any other turn carries text and tool calls. Shared by Bedrock,
/// OpenCode Go and Copilot, whose `/messages` routes differ only in
/// authentication.
pub fn encode_body(request: Request) -> Result(StringTree, Error) {
  encode_with_marks(request, None)
}

/// `encode_body` with the prefixes a provider can serve from its prompt cache
/// marked, so a repeated history reads instead of paying for the write: the
/// last tool, the system prompt (or the start every session shares and the
/// rest after it), and the last input. `ttl_seconds` is the lease the route
/// honours; a request that asks for no cache write carries no marks.
pub fn encode_body_cached(
  request: Request,
  ttl_seconds: Int,
) -> Result(StringTree, Error) {
  case request.options.cache {
    True -> encode_with_marks(request, Some(ttl_seconds))
    False -> encode_with_marks(request, None)
  }
}

/// What `encode_body_cached` marks, in the order the body carries them, as the
/// request ledger records it: exactly the `cache_control` breakpoints sent.
pub fn cache_marks(
  request: Request,
  ttl_seconds: Int,
) -> List(types.CacheMark) {
  use <- bool.guard(!request.options.cache, [])
  let tools = case request.tools {
    [] -> []
    _ -> [types.CacheMark(types.ToolsSpan, ttl_seconds)]
  }
  let shared = case types.split_instructions(request) {
    Some(_) -> [types.CacheMark(types.SharedSystemSpan, ttl_seconds)]
    None -> []
  }
  let system = case request.instructions {
    Some(text) if text != "" -> [types.CacheMark(types.SystemSpan, ttl_seconds)]
    _ -> []
  }
  let tail = case list.last(request.input) {
    // A replayed assistant turn is history to read, not a breakpoint to write.
    Ok(Replay(_)) | Error(Nil) -> []
    Ok(_) -> [
      types.CacheMark(
        types.InputSpan(list.length(request.input) - 1),
        ttl_seconds,
      ),
    ]
  }
  list.flatten([tools, shared, system, tail])
}

fn encode_with_marks(
  request: Request,
  ttl: Option(Int),
) -> Result(StringTree, Error) {
  use <- bool.guard(
    request.model == "",
    Error(InvalidRequest("invalid Bedrock model")),
  )
  use max_tokens <- result.try(types.required_output_limit(
    request,
    "Anthropic Messages",
  ))
  use messages <- result.try(
    list.try_fold(
      mark_last(request.input, fn(input, last) { #(input, last) }),
      [],
      fn(acc, pair) {
        add(request.model, acc, pair.0, case pair.1 {
          True -> ttl
          False -> None
        })
      },
    ),
  )
  let messages =
    messages
    |> list.reverse
    |> list.map(fn(message) {
      json.object([
        #("role", json.string(message.role)),
        #("content", json.preprocessed_array(message.blocks)),
      ])
    })
  let fields = [
    #("model", json.string(request.model)),
    #("messages", json.preprocessed_array(messages)),
    #("max_tokens", json.int(max_tokens)),
    #("stream", json.bool(True)),
  ]
  let fields = case system_field(request, ttl) {
    Some(system) -> [#("system", system), ..fields]
    None -> fields
  }
  let fields = case request.tools {
    [] -> fields
    tools -> [
      #(
        "tools",
        json.preprocessed_array(
          mark_last(tools, fn(tool, last) {
            tool_block(tool, case last {
              True -> ttl
              False -> None
            })
          }),
        ),
      ),
      ..fields
    ]
  }
  let fields = case request.options.tool_choice {
    Some(types.NoTool) -> [tool_choice("none", None), ..fields]
    Some(types.AnyTool) -> [tool_choice("any", None), ..fields]
    Some(types.NamedTool(name)) -> [tool_choice("tool", Some(name)), ..fields]
    _ -> fields
  }
  // Thinking is requested only with an effort, and a model whose catalog entry
  // does not support thinking is never offered one.
  let fields = case request.options.effort {
    Some(effort) -> [
      #(
        "thinking",
        json.object([
          #("type", json.string("adaptive")),
          #("display", json.string("summarized")),
        ]),
      ),
      #("output_config", json.object([#("effort", json.string(effort))])),
      ..fields
    ]
    None -> fields
  }
  Ok(json.to_string_tree(json.object(fields)))
}

/// `(host, region, service)` from a configured `baseUrl`. The SigV4
/// service name follows each endpoint's own IAM action namespace
/// (`bedrock:*` vs `bedrock-mantle:*`); mantle's has not been verified.
pub fn target(base_url: String) -> Result(#(String, String, String), Error) {
  let invalid =
    InvalidRequest(
      "baseUrl must be an HTTPS bedrock-runtime or bedrock-mantle AWS host with no credentials, port, query, fragment or path",
    )
  use parsed <- result.try(uri.parse(base_url) |> result.replace_error(invalid))
  use <- bool.guard(
    parsed.scheme != Some("https")
      || parsed.userinfo != None
      || parsed.port != None
      || parsed.query != None
      || parsed.fragment != None
      || { parsed.path != "" && parsed.path != "/" },
    Error(invalid),
  )
  use host <- result.try(option.to_result(parsed.host, invalid))
  use #(service, region, suffix) <- result.try(case string.split(host, ".") {
    ["bedrock-runtime", region, ..suffix] ->
      Ok(#("bedrock", region, string.join(suffix, ".")))
    ["bedrock-mantle", region, ..suffix] ->
      Ok(#("bedrock-mantle", region, string.join(suffix, ".")))
    _ -> Error(invalid)
  })
  let valid_region =
    region != ""
    && list.all(string.to_graphemes(region), fn(c) {
      string.contains("abcdefghijklmnopqrstuvwxyz0123456789-", c)
    })
  let valid_suffix = case suffix {
    "amazonaws.com"
    | "api.aws"
    | "amazonaws.com.cn"
    | "api.amazonwebservices.com.cn"
    | "c2s.ic.gov"
    | "sc2s.sgov.gov"
    | "cloud.adc-e.uk"
    | "csp.hci.ic.gov" -> True
    _ -> False
  }
  use <- bool.guard(!valid_region || !valid_suffix, Error(invalid))
  Ok(#(host, region, service))
}

fn add(
  model: String,
  acc: List(Message),
  input: Input,
  mark: Option(Int),
) -> Result(List(Message), Error) {
  case input {
    User(text) -> Ok(push(acc, "user", [text_block(text, mark)]))
    Assistant(text) -> Ok(push(acc, "assistant", [text_block(text, mark)]))
    UserImage(text, images) -> {
      let count = list.length(images)
      let image_blocks =
        list.index_map(images, fn(image, index) {
          image_block(image, case mark {
            Some(seconds) if index == count - 1 -> Some(seconds)
            _ -> None
          })
        })
      let blocks = case text {
        "" -> image_blocks
        _ -> [text_block(text, None), ..image_blocks]
      }
      Ok(push(acc, "user", blocks))
    }
    ToolOutput(id, output, images) ->
      Ok(push(acc, "user", [tool_result_block(id, output, images, mark)]))
    Replay(item) -> {
      use <- bool.guard(
        types.replay_protocol(item) == types.Responses,
        Error(InvalidRequest("cannot replay output across protocols")),
      )
      use message <- result.try(
        types.inspect_item(item, replay.message_decoder(detail_decoder()))
        |> result.replace_error(InvalidRequest(
          "replayed assistant message is not portable",
        )),
      )
      let blocks = case message.details {
        // The blocks the reducer recorded, in the order Claude sent them, with
        // the signature that lets the provider verify its own thinking.
        [Recorded(original, blocks), ..] if original == model -> blocks
        _ -> portable_blocks(message)
      }
      Ok(push(acc, "assistant", blocks))
    }
  }
}

type Recorded {
  Recorded(model: String, blocks: List(Json))
}

fn detail_decoder() -> decode.Decoder(Option(Recorded)) {
  use kind <- decode.field("type", decode.string)
  use model <- decode.optional_field("model", "", decode.string)
  use blocks <- decode.optional_field("blocks", [], decode.list(decode.dynamic))
  decode.success(case kind == blocks_detail {
    True -> Some(Recorded(model, list.map(blocks, types.encode_value)))
    False -> None
  })
}

fn portable_blocks(message: replay.Message(Recorded)) -> List(Json) {
  list.append(
    case message.text {
      "" -> []
      text -> [text_block(text, None)]
    },
    list.map(message.calls, fn(call) {
      tool_use_block(call.id, call.name, call.arguments)
    }),
  )
}

/// Adjacent turns of one role merge: Anthropic rejects back-to-back messages
/// of the same role, and a run of tool results arrives as separate inputs.
fn push(acc: List(Message), role: String, blocks: List(Json)) -> List(Message) {
  case blocks, acc {
    [], _ -> acc
    _, [Message(last, previous), ..rest] if last == role -> [
      Message(role, list.append(previous, blocks)),
      ..rest
    ]
    _, _ -> [Message(role, blocks), ..acc]
  }
}

/// A text block, carrying a cache breakpoint when `mark` names its lease.
fn text_block(text: String, mark: Option(Int)) -> Json {
  json.object([
    #("type", json.string("text")),
    #("text", json.string(text)),
    ..cache_field(mark)
  ])
}

/// The `system` field: one string, or, when the request marks its cache, the
/// blocks whose breakpoints `cache_marks` reports.
fn system_field(request: Request, ttl: Option(Int)) -> Option(Json) {
  case ttl, request.instructions {
    Some(seconds), Some(text) if text != "" ->
      Some(
        json.preprocessed_array(case types.split_instructions(request) {
          Some(#(shared, rest)) -> [
            text_block(shared, Some(seconds)),
            text_block(rest, Some(seconds)),
          ]
          None -> [text_block(text, Some(seconds))]
        }),
      )
    _, Some(text) if text != "" -> Some(json.string(text))
    _, _ -> None
  }
}

/// Anthropic's cache breakpoint. Without a lease the route's own default
/// applies, which is the five minutes every Messages route accepts; an hour
/// is sent only where a route honours it.
fn cache_field(mark: Option(Int)) -> List(#(String, Json)) {
  case mark {
    None -> []
    Some(seconds) -> [
      #(
        "cache_control",
        json.object(case seconds >= 3600 {
          True -> [
            #("type", json.string("ephemeral")),
            #("ttl", json.string("1h")),
          ]
          False -> [#("type", json.string("ephemeral"))]
        }),
      ),
    ]
  }
}

/// Maps a list, telling the mapper when it is holding the final item.
fn mark_last(items: List(a), mapper: fn(a, Bool) -> b) -> List(b) {
  case items {
    [] -> []
    [last] -> [mapper(last, True)]
    [first, ..rest] -> [mapper(first, False), ..mark_last(rest, mapper)]
  }
}

fn image_block(image: types.Image, mark: Option(Int)) -> Json {
  let #(mime_type, _, _, _) = types.image_meta(image)
  json.object([
    #("type", json.string("image")),
    #(
      "source",
      json.object([
        #("type", json.string("base64")),
        #("media_type", json.string(mime_type)),
        #("data", types.base64_string(types.image_data(image))),
      ]),
    ),
    ..cache_field(mark)
  ])
}

fn tool_use_block(id: String, name: String, arguments: String) -> Json {
  let input =
    json.parse(arguments, decode.dynamic)
    |> result.map(types.encode_value)
    |> result.unwrap(json.object([]))
  json.object([
    #("type", json.string("tool_use")),
    #("id", json.string(id)),
    #("name", json.string(name)),
    #("input", input),
  ])
}

fn tool_result_block(
  id: String,
  output: String,
  images: List(types.Image),
  mark: Option(Int),
) -> Json {
  let content = case output, images {
    "", [] -> [text_block("", None)]
    _, _ -> [
      text_block(output, None),
      ..list.map(images, fn(image) { image_block(image, None) })
    ]
  }
  json.object([
    #("type", json.string("tool_result")),
    #("tool_use_id", json.string(id)),
    #("content", json.preprocessed_array(content)),
    ..cache_field(mark)
  ])
}

fn tool_block(tool: types.Tool, mark: Option(Int)) -> Json {
  json.object([
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #("input_schema", schema.normalize(tool.parameters)),
    ..cache_field(mark)
  ])
}

fn tool_choice(kind: String, name: Option(String)) -> #(String, Json) {
  let fields = [#("type", json.string(kind))]
  let fields = case name {
    Some(name) -> [#("name", json.string(name)), ..fields]
    None -> fields
  }
  #("tool_choice", json.object(fields))
}
