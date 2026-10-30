import albedo/harness/extensions/zed/stream as zed_stream
import albedo/harness/extensions/zed/wire
import albedo/openai_api
import albedo/openai_api/sse
import albedo/openai_api/stream as albedo_stream
import albedo/openai_api/types
import gleam/bit_array
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
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
    should.be_true(usage.output_tokens >= 5)
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
    should.be_true(usage.output_tokens >= 5)
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
    should.be_true(usage.output_tokens >= 5)
    list.length(turn.output) |> should.equal(1)
  }
}

pub fn main() {
  native_protocols()
  encoding()
  reduction()
  framing()
  io.println(
    "Zed encoder, thinking/usage/status reducer and bounded NDJSON cases passed",
  )
}
