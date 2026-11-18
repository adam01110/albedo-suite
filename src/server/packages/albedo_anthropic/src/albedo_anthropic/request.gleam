//// Portable Anthropic Messages bodies with text, images and tool calls.
//// `encode_body` replays a same-model turn with the signed thinking blocks
//// Claude recorded; `fields` replays natively only under an explicit detail
//// tag. Routes own their URL, authentication and headers.

import albedo_anthropic/schema
import albedo_model.{
  type Error, type Input, type Request, Assistant, InvalidRequest, Replay,
  ToolOutput, User, UserImage,
} as types
import albedo_model/replay
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

type Message {
  Message(role: String, blocks: List(Json))
}

/// Encodes `request` into a portable Anthropic Messages JSON body. A replayed
/// turn from the same model carries the signed thinking blocks the reducer
/// recorded; any other turn carries text, images and tool calls.
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
  encode_with_marks(request, Some(ttl_seconds))
}

/// Shared adaptive-thinking fields for Messages providers.
pub fn adaptive_thinking_fields(effort: types.Effort) -> List(#(String, Json)) {
  [
    #(
      "thinking",
      json.object([
        #("type", json.string("adaptive")),
        #("display", json.string("summarized")),
      ]),
    ),
    #(
      "output_config",
      json.object([#("effort", json.string(types.effort_name(effort)))]),
    ),
  ]
}

/// The detail type `anthropic_api/stream` records Claude's blocks under; the
/// stream module imports this one, so the name is repeated here.
const blocks_detail = "claude.blocks"

fn encode_with_marks(
  request: Request,
  ttl: Option(Int),
) -> Result(StringTree, Error) {
  use fields <- result.map(fields(request, ttl, Some(blocks_detail)))
  let fields = case request.options.effort {
    Some(effort) -> list.append(adaptive_thinking_fields(effort), fields)
    None -> fields
  }
  json.to_string_tree(json.object(fields))
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

/// Standard Messages fields, before a provider adds its thinking policy.
/// Cache marks require both an enabled cache and a TTL. Native replay requires
/// the same model and the supplied detail tag; other replay remains portable.
pub fn fields(
  request: Request,
  ttl: Option(Int),
  detail_tag: Option(String),
) -> Result(List(#(String, Json)), Error) {
  use max_tokens <- result.try(types.required_output_limit(
    request,
    "Anthropic Messages",
  ))
  prompt_fields(request, ttl, detail_tag, [
    #("max_tokens", json.int(max_tokens)),
    #("stream", json.bool(True)),
  ])
}

/// The fields `/messages/count_tokens` takes: what the model reads, without
/// the output limit or streaming.
pub fn count_fields(
  request: Request,
  detail_tag: Option(String),
) -> Result(List(#(String, Json)), Error) {
  prompt_fields(request, None, detail_tag, [])
}

fn prompt_fields(
  request: Request,
  ttl: Option(Int),
  detail_tag: Option(String),
  generation: List(#(String, Json)),
) -> Result(List(#(String, Json)), Error) {
  let ttl = case request.options.cache {
    True -> ttl
    False -> None
  }
  use <- bool.guard(
    request.model == "",
    Error(InvalidRequest("invalid Anthropic Messages model")),
  )
  use messages <- result.try(
    list.try_fold(
      mark_last(request.input, fn(input, last) { #(input, last) }),
      [],
      fn(acc, pair) {
        add(
          acc,
          pair.0,
          case pair.1 {
            True -> ttl
            False -> None
          },
          request.model,
          detail_tag,
        )
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
    ..generation
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
  Ok(fields)
}

fn add(
  acc: List(Message),
  input: Input,
  mark: Option(Int),
  model: String,
  detail_tag: Option(String),
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
        types.inspect_item(
          item,
          replay.message_decoder(case detail_tag {
            Some(tag) -> native_detail(tag)
            None -> decode.success(None)
          }),
        )
        |> result.replace_error(InvalidRequest(
          "replayed assistant message is not portable",
        )),
      )
      let blocks = case
        native_blocks(
          message.details,
          model,
          message.text,
          message.calls,
          fn(name) { name },
        )
      {
        Some(blocks) -> blocks
        None ->
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
      Ok(push(acc, "assistant", blocks))
    }
  }
}

/// A replay detail's native blocks, as a Messages stream recorded them under
/// `tag`, with the model that wrote them; None for any other detail.
pub fn native_detail(
  tag: String,
) -> decode.Decoder(Option(#(String, List(Dynamic)))) {
  use kind <- decode.optional_field("type", "", decode.string)
  case kind == tag {
    True -> {
      use model <- decode.optional_field("model", "", decode.string)
      use blocks <- decode.optional_field(
        "blocks",
        [],
        decode.list(decode.dynamic),
      )
      decode.success(Some(#(model, blocks)))
    }
    False -> decode.success(None)
  }
}

/// The blocks to replay an assistant message with as it was sent: those of its
/// first native detail, when `model` wrote them and they still hold the
/// message's text and calls, named as `wire_name` sends them. None after a
/// model change or a transcript edit; the message is then replayed portably.
pub fn native_blocks(
  details: List(#(String, List(Dynamic))),
  model: String,
  text: String,
  calls: List(types.ToolCall),
  wire_name: fn(String) -> String,
) -> Option(List(Json)) {
  case details {
    [#(original, [_, ..] as blocks), ..] if original == model ->
      case native_matches(blocks, text, calls, wire_name) {
        True -> Some(list.map(blocks, types.encode_value))
        False -> None
      }
    _ -> None
  }
}

// A stream records text, calls, and signed or redacted thinking; the text and
// calls must still be the transcript's.
fn native_matches(
  blocks: List(Dynamic),
  text: String,
  calls: List(types.ToolCall),
  wire_name: fn(String) -> String,
) -> Bool {
  let decoder = {
    use kind <- decode.field("type", decode.string)
    case kind {
      "tool_use" -> {
        use id <- decode.field("id", decode.string)
        use name <- decode.field("name", decode.string)
        use input <- decode.field("input", decode.dynamic)
        case id != "" && name != "" {
          True -> decode.success(#("", Some(#(id, name, input))))
          False -> decode.failure(#("", None), "native call with an identity")
        }
      }
      "thinking" -> {
        use _ <- decode.field("thinking", decode.string)
        use signature <- decode.field("signature", decode.string)
        case signature != "" {
          True -> decode.success(#("", None))
          False -> decode.failure(#("", None), "signed thinking block")
        }
      }
      "redacted_thinking" -> {
        use data <- decode.field("data", decode.string)
        case data != "" {
          True -> decode.success(#("", None))
          False -> decode.failure(#("", None), "redacted thinking data")
        }
      }
      "text" -> {
        use text <- decode.field("text", decode.string)
        decode.success(#(text, None))
      }
      _ -> decode.failure(#("", None), "native Anthropic block")
    }
  }
  let native = list.try_map(blocks, decode.run(_, decoder))
  let portable =
    list.try_map(calls, fn(call) {
      use input <- result.map(json.parse(call.arguments, decode.dynamic))
      #(call.id, wire_name(call.name), input)
    })
  case native, portable {
    Ok(native), Ok(portable) -> {
      let #(texts, native_calls) = list.unzip(native)
      string.concat(texts) == text && option.values(native_calls) == portable
    }
    _, _ -> False
  }
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

/// Builds a native tool call with the supplied wire name unchanged.
pub fn tool_use_block(id: String, name: String, arguments: String) -> Json {
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
