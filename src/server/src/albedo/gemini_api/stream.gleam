//// Gemini `streamGenerateContent` SSE chunks reduced to albedo events and a
//// chat-shaped replay message. The message keeps the model's own parts, with
//// each thought signature it issued, so a replay sends the signature back
//// unmodified.

import albedo/openai_api/decoding
import albedo/openai_api/fields
import albedo/openai_api/replay
import albedo/openai_api/stream as reducer
import albedo/openai_api/types
import gleam/bit_array
import gleam/crypto
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string

type Block {
  Text(text: List(String), thought: Bool, signature: Option(String))
  Call(call: types.ToolCall, signature: Option(String))
}

/// The detail type a replayed Vertex turn carries its model parts under.
const parts_detail = "vertex.parts"

type State {
  State(
    blocks: List(Block),
    call_ids: Set(String),
    usage: Option(types.Usage),
    finish: Option(String),
  )
}

type Chunk {
  Chunk(
    parts: List(Part),
    finish: Option(String),
    usage: Option(types.Usage),
    blocked: Option(String),
  )
}

type Part {
  Part(
    text: String,
    thought: Bool,
    call: Option(#(String, String, String)),
    signature: Option(String),
  )
}

pub fn reducer() -> reducer.Reducer {
  reducer.wrap(State([], set.new(), None, None), step, finish)
}

fn step(
  state: State,
  data: String,
) -> Result(#(State, List(types.Event), Option(types.Turn)), types.Error) {
  use #(state, events) <- result.map(feed(state, data))
  #(state, events, None)
}

fn feed(
  state: State,
  data: String,
) -> Result(#(State, List(types.Event)), types.Error) {
  use value <- result.try(
    json.parse(data, decode.dynamic)
    |> result.map_error(fn(error) {
      types.InvalidEvent("invalid Vertex JSON: " <> decoding.json_error(error))
    }),
  )
  case text_chunk(value) {
    Ok(chunk) -> apply(state, chunk)
    Error(Nil) -> decode_chunk(state, value)
  }
}

fn decode_chunk(
  state: State,
  value: dynamic.Dynamic,
) -> Result(#(State, List(types.Event)), types.Error) {
  use error <- result.try(
    decode.run(
      value,
      object({
        use error <- decode.optional_field(
          "error",
          None,
          present(
            object({
              use message <- decode.optional_field("message", "", decode.string)
              use status <- decode.optional_field("status", "", decode.string)
              decode.success(case message, status {
                "", "" -> "unknown Vertex stream error"
                "", status -> status
                message, _ -> message
              })
            }),
          ),
        )
        decode.success(error)
      }),
    )
    |> result.map_error(fn(_) {
      types.InvalidEvent("invalid Vertex stream error")
    }),
  )
  case error {
    Some(message) -> Error(types.ProviderError(message))
    None -> {
      use chunk <- result.try(
        decode.run(value, chunk_decoder())
        |> result.map_error(fn(_) {
          types.InvalidEvent("invalid Vertex stream chunk")
        }),
      )
      apply(state, chunk)
    }
  }
}

fn apply(
  state: State,
  chunk: Chunk,
) -> Result(#(State, List(types.Event)), types.Error) {
  case chunk.blocked {
    Some(reason) ->
      Error(types.ProviderError("request blocked by Google (" <> reason <> ")"))
    None -> {
      let #(state, events) =
        list.fold(chunk.parts, #(state, []), fn(acc, part) {
          let #(state, new) = add(acc.0, part)
          #(
            state,
            list.fold(new, acc.1, fn(events, event) { [event, ..events] }),
          )
        })
      Ok(#(
        State(
          ..state,
          usage: option.or(chunk.usage, state.usage),
          finish: option.or(chunk.finish, state.finish),
        ),
        list.reverse(events),
      ))
    }
  }
}

fn add(state: State, part: Part) -> #(State, List(types.Event)) {
  case part {
    Part(call: Some(#(id, name, arguments)), signature: signature, ..) -> {
      let index = set.size(state.call_ids)
      let id = case id == "" || set.contains(state.call_ids, id) {
        True -> call_id()
        False -> id
      }
      #(
        State(
          ..state,
          blocks: [
            Call(types.ToolCall(id, name, arguments), signature),
            ..state.blocks
          ],
          call_ids: set.insert(state.call_ids, id),
        ),
        [types.ArgumentsDelta(index, name, arguments)],
      )
    }
    Part(text: "", signature: None, ..) -> #(state, [])
    Part(text: text, thought: thought, signature: signature, ..) -> {
      let blocks = case state.blocks, signature {
        [Text(previous, was_thought, None), ..rest], None
          if was_thought == thought
        -> [Text([text, ..previous], thought, None), ..rest]
        _, _ -> [Text([text], thought, signature), ..state.blocks]
      }
      #(State(..state, blocks: blocks), case text, thought {
        "", _ -> []
        _, True -> [types.ThinkingDelta(text)]
        _, False -> [types.TextDelta(0, 0, text)]
      })
    }
  }
}

fn calls(blocks: List(Block)) -> List(types.ToolCall) {
  blocks
  |> list.filter_map(fn(block) {
    case block {
      Call(call, _) -> Ok(call)
      _ -> Error(Nil)
    }
  })
  |> list.reverse
}

fn finish(state: State) -> Result(types.Turn, types.Error) {
  let blocks = list.reverse(state.blocks)
  case state.finish {
    // Even a nonempty body can be truncated midway through a function call.
    None -> Error(types.UnexpectedEnd)
    Some(reason) -> {
      let finish = case reason {
        "STOP" ->
          case calls(state.blocks) {
            [] -> types.Complete
            _ -> types.ToolCalls
          }
        "MAX_TOKENS" -> types.LengthLimit
        "SAFETY"
        | "RECITATION"
        | "PROHIBITED_CONTENT"
        | "BLOCKLIST"
        | "SPII"
        | "IMAGE_SAFETY" -> types.ContentFiltered
        other -> types.OtherFinish(other)
      }
      // The loop executes any nonempty tool_calls regardless of finish.
      // Never publish calls from a limited, filtered or failed completion.
      let calls = case finish {
        types.ToolCalls -> calls(state.blocks)
        _ -> []
      }
      let joined = fn(pick) { blocks |> list.filter_map(pick) |> string.concat }
      let text =
        joined(fn(block) {
          case block {
            Text(chunks, False, _) -> Ok(flat(chunks))
            _ -> Error(Nil)
          }
        })
      let thinking =
        joined(fn(block) {
          case block {
            Text(chunks, True, _) -> Ok(flat(chunks))
            _ -> Error(Nil)
          }
        })
      use item <- result.map(
        json.parse(
          json.to_string(message(
            text,
            thinking,
            details(blocks, finish == types.ToolCalls),
            calls,
          )),
          types.replay_decoder(types.ChatCompletions),
        )
        |> result.map_error(fn(error) {
          types.InvalidEvent(
            "could not build the Vertex replay message: "
            <> decoding.json_error(error),
          )
        }),
      )
      let call_indices =
        list.index_map(calls, fn(call, index) { #(call.id, index) })
      types.Turn(None, [item], calls, state.usage, finish, None, call_indices)
    }
  }
}

fn message(
  text: String,
  thinking: String,
  details: Option(json.Json),
  calls: List(types.ToolCall),
) -> json.Json {
  let content = case text {
    "" -> json.null()
    text -> json.string(text)
  }
  replay.message(content, thinking, details, calls)
}

/// The model's own parts in arrival order, for a replay that returns each
/// thought signature exactly as it came.
fn details(blocks: List(Block), include_calls: Bool) -> Option(json.Json) {
  let parts =
    list.filter_map(blocks, fn(block) {
      case block {
        Call(_, _) if !include_calls -> Error(Nil)
        _ -> model_part(block)
      }
    })
  case parts {
    [] -> None
    parts ->
      Some(
        json.preprocessed_array([
          json.object([
            #("type", json.string(parts_detail)),
            #("parts", json.preprocessed_array(parts)),
          ]),
        ]),
      )
  }
}

fn model_part(block: Block) -> Result(json.Json, Nil) {
  case block {
    Text(chunks, thought, signature) ->
      text_model_part(chunks, thought, signature)
    Call(types.ToolCall(id, name, arguments), signature) ->
      Ok(
        json.object([
          #(
            "functionCall",
            json.object([
              #("name", json.string(name)),
              #(
                "args",
                json.parse(arguments, decode.dynamic)
                  |> result.map(types.encode_value)
                  |> result.unwrap(json.object([])),
              ),
              #("id", json.string(id)),
            ]),
          ),
          ..case signature {
            Some(signature) -> [#("thoughtSignature", json.string(signature))]
            None -> []
          }
        ]),
      )
  }
}

fn text_model_part(
  chunks: List(String),
  thought: Bool,
  signature: Option(String),
) -> Result(json.Json, Nil) {
  let text = flat(chunks)
  case text, signature {
    "", None -> Error(Nil)
    _, _ ->
      Ok(
        json.object([
          #("text", json.string(text)),
          ..list.append(
            case thought {
              True -> [#("thought", json.bool(True))]
              False -> []
            },
            case signature {
              Some(signature) -> [#("thoughtSignature", json.string(signature))]
              None -> []
            },
          )
        ]),
      )
  }
}

fn flat(chunks: List(String)) -> String {
  chunks |> list.reverse |> string.concat
}

fn call_id() -> String {
  "call_"
  <> {
    crypto.strong_random_bytes(9)
    |> bit_array.base16_encode
    |> string.lowercase
  }
}

// Validate object containers too: optional fields alone would accept a
// scalar/null container as if every field were absent.
fn object(decoder: decode.Decoder(a)) -> decode.Decoder(a) {
  use _ <- decode.then(decode.dict(decode.string, decode.dynamic))
  decoder
}

fn present(decoder: decode.Decoder(a)) -> decode.Decoder(Option(a)) {
  use value <- decode.then(decoder)
  decode.success(Some(value))
}

fn chunk_decoder() -> decode.Decoder(Chunk) {
  let candidate =
    object({
      use parts <- decode.optional_field(
        "content",
        [],
        object({
          use parts <- decode.optional_field(
            "parts",
            [],
            decode.list(part_decoder()),
          )
          decode.success(parts)
        }),
      )
      use finish <- decode.optional_field(
        "finishReason",
        None,
        present(decode.string),
      )
      decode.success(#(parts, finish))
    })
  object({
    use candidates <- decode.optional_field(
      "candidates",
      [],
      decode.list(candidate),
    )
    use usage <- decode.optional_field(
      "usageMetadata",
      None,
      present(usage_decoder()),
    )
    use blocked <- decode.optional_field(
      "promptFeedback",
      None,
      object({
        use reason <- decode.optional_field(
          "blockReason",
          None,
          present(decode.string),
        )
        decode.success(reason)
      }),
    )
    let #(parts, finish) = case candidates {
      [first, ..] -> first
      [] -> #([], None)
    }
    decode.success(Chunk(parts, finish, usage, blocked))
  })
}

/// What `chunk_decoder` reads from a chunk without an error, prompt
/// feedback, or function call and with at most one candidate, read with the
/// field readers. Error(Nil) for anything else, which the decoders then read.
fn text_chunk(value: dynamic.Dynamic) -> Result(Chunk, Nil) {
  use <- fields.require(
    fields.absent(value, "error") && fields.absent(value, "promptFeedback"),
  )
  use candidates <- result.try(fields.list_or_empty(value, "candidates"))
  use #(parts, finish) <- result.try(case candidates {
    [] -> Ok(#([], None))
    [candidate] -> text_candidate(candidate)
    _ -> Error(Nil)
  })
  use usage <- result.try(fields.present_object(value, "usageMetadata"))
  use usage <- result.map(case usage {
    Some(usage) -> read_usage(usage) |> result.map(Some)
    None -> Ok(None)
  })
  Chunk(parts, finish, usage, None)
}

fn text_candidate(
  candidate: dynamic.Dynamic,
) -> Result(#(List(Part), Option(String)), Nil) {
  use content <- result.try(fields.present_object(candidate, "content"))
  use parts <- result.try(case content {
    Some(content) ->
      fields.list_or_empty(content, "parts")
      |> result.try(list.try_map(_, text_part))
    None -> Ok([])
  })
  use finish <- result.map(fields.present_string(candidate, "finishReason"))
  #(parts, finish)
}

fn text_part(part: dynamic.Dynamic) -> Result(Part, Nil) {
  use <- fields.require(fields.absent(part, "functionCall"))
  use text <- result.try(fields.string_or(part, "text", ""))
  use thought <- result.try(fields.bool_or(part, "thought", False))
  use signature <- result.map(fields.present_string(part, "thoughtSignature"))
  Part(text, thought, None, signature)
}

fn read_usage(usage: dynamic.Dynamic) -> Result(types.Usage, Nil) {
  use prompt <- result.try(fields.int_or(usage, "promptTokenCount", 0))
  use candidates <- result.try(fields.int_or(usage, "candidatesTokenCount", 0))
  use cached <- result.try(fields.present_int(usage, "cachedContentTokenCount"))
  use thoughts <- result.map(fields.present_int(usage, "thoughtsTokenCount"))
  to_usage(prompt, candidates, cached, thoughts)
}

fn part_decoder() -> decode.Decoder(Part) {
  object({
    use text <- decode.optional_field("text", "", decode.string)
    use thought <- decode.optional_field("thought", False, decode.bool)
    use call <- decode.optional_field(
      "functionCall",
      None,
      present(
        object({
          use id <- decode.optional_field("id", "", decode.string)
          use name <- decode.field("name", decode.string)
          use args <- decode.optional_field("args", dynamic.properties([]), {
            use _ <- decode.then(decode.dict(decode.string, decode.dynamic))
            decode.dynamic
          })
          decode.success(#(id, name, json.to_string(types.encode_value(args))))
        }),
      ),
    )
    use signature <- decode.optional_field(
      "thoughtSignature",
      None,
      decode.optional(decode.string),
    )
    decode.success(Part(text, thought, call, signature))
  })
}

fn usage_decoder() -> decode.Decoder(types.Usage) {
  object({
    use prompt <- decode.optional_field("promptTokenCount", 0, decode.int)
    use candidates <- decode.optional_field(
      "candidatesTokenCount",
      0,
      decode.int,
    )
    use cached <- decode.optional_field(
      "cachedContentTokenCount",
      None,
      present(decode.int),
    )
    use thoughts <- decode.optional_field(
      "thoughtsTokenCount",
      None,
      present(decode.int),
    )
    decode.success(to_usage(prompt, candidates, cached, thoughts))
  })
}

fn to_usage(
  prompt: Int,
  candidates: Int,
  cached: Option(Int),
  thoughts: Option(Int),
) -> types.Usage {
  types.Usage(
    prompt,
    candidates + option.unwrap(thoughts, 0),
    cached,
    None,
    None,
    None,
    thoughts,
  )
}
