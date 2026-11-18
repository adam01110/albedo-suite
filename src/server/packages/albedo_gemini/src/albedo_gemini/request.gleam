//// Portable Gemini `generateContent` bodies with text, images and tool calls.
//// Replay sends the model's own parts back with the thought signatures it
//// issued, and no signature where it issued none. Routes own their URL,
//// authentication and headers.

import albedo_model.{
  type Error, type Input, type Request, Assistant, InvalidRequest, Replay,
  ToolOutput, User, UserImage,
} as types
import albedo_model/replay
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

/// The detail type a replayed Vertex turn carries its model parts under.
const parts_detail = "vertex.parts"

/// Models that take tool-result media as sibling parts of the function
/// response; every other model nests it under `functionResponse.parts`, as
/// Google documents for Gemini 3 and later.
const sibling_media_models = [
  "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite",
]

type Content {
  Content(role: String, parts: List(Json))
}

type History {
  History(contents: List(Content), calls: Dict(String, String))
}

/// Encodes `request` into a portable Gemini `generateContent` JSON body.
pub fn encode_body(request: Request) -> Result(StringTree, Error) {
  use contents <- result.try(contents_json(request))
  let config = generation_config(request)
  let fields = [
    #("contents", json.preprocessed_array(contents)),
    #("generationConfig", config),
  ]
  let fields = list.append(system_field(request), fields)
  let fields = case tools_json(request) {
    Some(tools) -> [
      #("tools", tools),
      #("toolConfig", tool_config(request.options.tool_choice)),
      ..fields
    ]
    None -> fields
  }
  Ok(json.to_string_tree(json.object(fields)))
}

/// The fields of a Gemini `countTokens` request, which every route that
/// counts takes: the request's contents, system instruction and tools, and
/// not its generation settings. A route wraps them as its endpoint asks, in
/// a `generateContentRequest` or beside the model.
pub fn count_fields(request: Request) -> Result(List(#(String, Json)), Error) {
  use contents <- result.map(contents_json(request))
  [
    [#("contents", json.preprocessed_array(contents))],
    system_field(request),
    case tools_json(request) {
      Some(tools) -> [#("tools", tools)]
      None -> []
    },
  ]
  |> list.flatten
}

fn contents_json(request: Request) -> Result(List(Json), Error) {
  use history <- result.map(
    list.try_fold(request.input, History([], dict.new()), fn(h, i) {
      add(request.model, h, i)
    }),
  )
  history.contents
  |> list.reverse
  |> list.map(fn(content) {
    json.object([
      #("role", json.string(content.role)),
      #("parts", json.preprocessed_array(content.parts)),
    ])
  })
}

fn system_field(request: Request) -> List(#(String, Json)) {
  case request.instructions {
    Some(text) if text != "" -> [
      #(
        "systemInstruction",
        json.object([
          #("role", json.string("user")),
          #("parts", json.preprocessed_array([text_part(text)])),
        ]),
      ),
    ]
    _ -> []
  }
}

fn tools_json(request: Request) -> Option(Json) {
  case request.tools {
    [] -> None
    tools ->
      Some(
        json.preprocessed_array([
          json.object([
            #(
              "functionDeclarations",
              json.array(tools, fn(tool) {
                json.object([
                  #("name", json.string(tool.name)),
                  #("description", json.string(tool.description)),
                  #("parametersJsonSchema", tool.parameters),
                ])
              }),
            ),
          ]),
        ]),
      )
  }
}

fn generation_config(request: Request) -> Json {
  let thinking =
    thinking_config(
      request.model,
      request.options.effort,
      request.max_output_tokens,
    )
  let fields = case thinking {
    [] -> []
    fields -> [#("thinkingConfig", json.object(fields))]
  }
  let fields = case request.max_output_tokens {
    Some(n) -> [#("maxOutputTokens", json.int(n)), ..fields]
    None -> fields
  }
  let fields = case request.options.temperature {
    Some(t) -> [#("temperature", json.float(t)), ..fields]
    None -> fields
  }
  let fields = case request.options.top_p {
    Some(p) -> [#("topP", json.float(p)), ..fields]
    None -> fields
  }
  let fields = case request.options.stop {
    [] -> fields
    stops -> [#("stopSequences", json.array(stops, json.string)), ..fields]
  }
  let fields =
    list.append(fields, case request.options.format {
      None -> []
      Some(types.JsonObject) -> [
        #("responseMimeType", json.string("application/json")),
      ]
      Some(types.JsonSchema(_, schema, _)) -> [
        #("responseMimeType", json.string("application/json")),
        #("responseJsonSchema", schema),
      ]
    })
  json.object(fields)
}

type Thinking {
  Budget(low: Int, medium: Int, high: Int, disable: Bool)
  Levels(efforts: List(types.Effort))
}

/// Google's documented thinking controls for each Gemini family, kept here
/// rather than importing a provider's catalog. Only known families and their
/// version suffixes match, and a model none matches gets no thinking control.
/// A budgeted model takes every effort as a budget, none and minimal turning
/// thinking off where the model allows it; a model with named levels gets the
/// nearest one it lists.
fn thinking_config(
  model: String,
  effort: Option(types.Effort),
  limit: Option(Int),
) -> List(#(String, Json)) {
  let model = string.lowercase(model)
  let levels = Levels([types.Minimal, types.Low, types.Medium, types.High])
  let pro_levels = Levels([types.Low, types.Medium, types.High])
  let flash = Budget(1024, 8192, 24_576, True)
  let policy =
    list.find(
      [
        #("gemini-2.5-pro", Budget(1024, 8192, 32_768, False)),
        #("gemini-2.5-flash-lite", flash),
        #("gemini-2.5-flash", flash),
        #("gemini-3-pro", Levels([types.Low, types.High])),
        #("gemini-3-flash", levels),
        #("gemini-3.1-pro", pro_levels),
        #("gemini-3.1-flash-lite", levels),
        #("gemini-3.5-flash-lite", levels),
        #("gemini-3.5-flash", levels),
        #("gemini-3.6-flash", levels),
        #("gemini-3.7-flash", pro_levels),
        #("gemini-3.8-flash", pro_levels),
        #("gemini-4-argon", pro_levels),
        #("gemini-4-argon-contributor", pro_levels),
      ],
      fn(entry) {
        model == entry.0
        || model == entry.0 <> "-001"
        || model == entry.0 <> "-preview"
        || string.starts_with(model, entry.0 <> "-preview-")
      },
    )
  let thoughts = [#("includeThoughts", json.bool(True))]
  case policy, effort {
    Error(_), _ -> []
    Ok(_), None -> thoughts
    Ok(#(_, Budget(low, medium, high, disable))), Some(effort) -> {
      let budget = case effort {
        types.NoReasoning | types.Minimal if disable -> 0
        types.NoReasoning | types.Minimal | types.Low -> low
        types.Medium -> medium
        types.High | types.XHigh | types.Max -> high
      }
      [#("thinkingBudget", json.int(answer_room(budget, limit))), ..thoughts]
    }
    Ok(#(_, Levels(efforts))), Some(effort) ->
      case types.nearest_effort(effort, efforts) {
        Some(level) -> [
          #(
            "thinkingLevel",
            json.string(string.uppercase(types.effort_name(level))),
          ),
          ..thoughts
        ]
        None -> thoughts
      }
  }
}

/// A thinking budget that leaves `limit`, which counts thinking too, room for
/// an answer: at most the limit less 1024, though never under the 128 a
/// thinking model needs to think at all.
fn answer_room(budget: Int, limit: Option(Int)) -> Int {
  case limit {
    Some(limit) -> int.min(budget, int.max(limit - 1024, 128))
    None -> budget
  }
}

fn tool_config(tool_choice: Option(types.ToolChoice)) -> Json {
  let mode = case tool_choice {
    Some(types.NoTool) -> "NONE"
    Some(types.AnyTool) | Some(types.NamedTool(_)) -> "ANY"
    _ -> "AUTO"
  }
  let fields = [#("mode", json.string(mode))]
  let fields = case tool_choice {
    Some(types.NamedTool(name)) -> [
      #("allowedFunctionNames", json.array([name], json.string)),
      ..fields
    ]
    _ -> fields
  }
  json.object([#("functionCallingConfig", json.object(fields))])
}

fn add(
  model: String,
  history: History,
  input: Input,
) -> Result(History, Error) {
  case input {
    User(text) -> Ok(push(history, "user", [text_part(text)]))
    UserImage(text, images) -> {
      let image_parts = list.map(images, inline_part)
      let parts = case text {
        "" -> image_parts
        _ -> [text_part(text), ..image_parts]
      }
      Ok(push(history, "user", parts))
    }
    Assistant(text) -> Ok(push(history, "model", [text_part(text)]))
    ToolOutput(id, output, images) -> {
      use name <- result.try(
        dict.get(history.calls, id)
        |> result.replace_error(InvalidRequest(
          "tool output " <> id <> " has no preceding call",
        )),
      )
      let text = case output, images {
        "", [_, ..] -> "(see attached image)"
        _, _ -> output
      }
      let sibling = sibling_media(model)
      let response =
        json.object([
          #(
            "functionResponse",
            json.object([
              #("name", json.string(name)),
              #("id", json.string(id)),
              #("response", json.object([#("output", json.string(text))])),
              ..case sibling {
                True -> []
                False -> [
                  #(
                    "parts",
                    json.preprocessed_array(list.map(images, inline_part)),
                  ),
                ]
              }
            ]),
          ),
        ])
      let history = push(history, "user", [response])
      Ok(case sibling, images {
        True, [_, ..] ->
          push(history, "user", [
            text_part("Tool result image:"),
            ..list.map(images, inline_part)
          ])
        _, _ -> history
      })
    }
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
      let calls =
        list.fold(message.calls, history.calls, fn(calls, call) {
          dict.insert(calls, call.id, call.name)
        })
      Ok(push(
        History(..history, calls: calls),
        "model",
        portable_parts(message),
      ))
    }
  }
}

type Recorded {
  Recorded(parts: List(Json))
}

fn detail_decoder() -> decode.Decoder(Option(Recorded)) {
  use kind <- decode.field("type", decode.string)
  use parts <- decode.optional_field("parts", [], decode.list(decode.dynamic))
  decode.success(case kind == parts_detail {
    True -> Some(Recorded(list.map(parts, types.encode_value)))
    False -> None
  })
}

/// The model's own parts when the reducer recorded them, otherwise text and
/// tool calls. A call replayed without a recorded signature carries none.
fn portable_parts(message: replay.Message(Recorded)) -> List(Json) {
  case message.details {
    [Recorded(parts), ..] if parts != [] -> parts
    _ -> {
      let text = case message.text {
        "" -> []
        text -> [text_part(text)]
      }
      let calls =
        list.map(message.calls, fn(call) {
          json.object([
            #(
              "functionCall",
              json.object([
                #("name", json.string(call.name)),
                #("args", arguments(call.arguments)),
                #("id", json.string(call.id)),
              ]),
            ),
          ])
        })
      list.append(text, calls)
    }
  }
}

fn sibling_media(model: String) -> Bool {
  list.contains(sibling_media_models, string.lowercase(model))
}

fn arguments(encoded: String) -> Json {
  json.parse(encoded, decode.dynamic)
  |> result.map(types.encode_value)
  |> result.unwrap(json.object([]))
}

/// Adjacent turns of one role merge: Gemini expects a run of tool results
/// in one turn, and repeated roles are otherwise rejected.
fn push(history: History, role: String, parts: List(Json)) -> History {
  case parts, history.contents {
    [], _ -> history
    _, [Content(last, previous), ..rest] if last == role ->
      History(..history, contents: [
        Content(role, list.append(previous, parts)),
        ..rest
      ])
    _, contents ->
      History(..history, contents: [Content(role, parts), ..contents])
  }
}

fn text_part(text: String) -> Json {
  json.object([#("text", json.string(text))])
}

fn inline_part(image: types.Image) -> Json {
  let #(mime_type, _, _, _) = types.image_meta(image)
  json.object([
    #(
      "inlineData",
      json.object([
        #("mimeType", json.string(mime_type)),
        #("data", types.base64_string(types.image_data(image))),
      ]),
    ),
  ])
}
