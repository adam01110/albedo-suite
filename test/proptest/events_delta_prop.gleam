//// The suite's live event encoders (observation/events.gleam): the
//// `ToolWithImages` variant must encode exactly as the plain `Tool` event when
//// it carries no images, images must publish the reference the history route
//// serves, and `CostedUsage` must be `Usage` plus one estimate, so a client
//// that understands neither still reads the same event.

import albedo/observation/events as view
import albedo/usage/usage
import albedo_model as types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import proptest
import qcheck

const sessions = ["s-1", "session/with space", "é"]

pub type Entry {
  Entry(
    session: String,
    sequence: Int,
    call: types.ToolCall,
    body: String,
    progress: String,
    position: Int,
    failed: Bool,
  )
}

pub type Published {
  Published(
    field: String,
    mime: String,
    width: Int,
    height: Int,
    bytes: Int,
    url: String,
    reference_bytes: Int,
  )
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn call() -> qcheck.Generator(types.ToolCall) {
  qcheck.tuple2(
    pick(["c1", "call-2", "tool/3"]),
    pick(["bash", "read", "imagegen.run"]),
  )
  |> qcheck.map(fn(pair) {
    let #(id, name) = pair
    types.ToolCall(id, name, "{\"path\":\"a.txt\"}")
  })
}

fn image() -> qcheck.Generator(types.Image) {
  use mime, width, height, bytes <- qcheck.map4(
    pick(["image/png", "image/jpeg", "image/webp"]),
    qcheck.bounded_int(1, 512),
    qcheck.bounded_int(1, 512),
    qcheck.bounded_int(1, 65_536),
  )
  let assert Ok(value) =
    types.image(mime, "iVBORw0KGgo=", width, height, bytes)
  value
}

fn images() -> qcheck.Generator(List(types.Image)) {
  qcheck.list_from(image())
}

fn position() -> qcheck.Generator(Int) {
  qcheck.from_weighted_generators(#(8, qcheck.bounded_int(1, 500)), [
    #(2, pick([0, 1, 9_007_199_254_740_991])),
  ])
}

fn entry() -> qcheck.Generator(Entry) {
  use #(session, sequence), #(call, body), #(progress, position), failed <- qcheck.map4(
    qcheck.tuple2(pick(sessions), qcheck.bounded_int(0, 100_000)),
    qcheck.tuple2(call(), pick(["", "ok", "{\"lines\":3}", "done"])),
    qcheck.tuple2(pick(["p-1", "progress/2"]), position()),
    qcheck.bool(),
  )
  Entry(session, sequence, call, body, progress, position, failed)
}

fn tool_count() -> qcheck.Generator(Option(Int)) {
  qcheck.option_from(
    qcheck.from_weighted_generators(#(8, qcheck.bounded_int(0, 50)), [
      #(2, pick([0, 1, 10_000])),
    ]),
  )
}

fn publish(entry: Entry, values: List(types.Image), counted: Option(Int)) -> String {
  view.ToolWithImages(
    entry.call,
    entry.body,
    None,
    entry.progress,
    entry.position,
    values,
    entry.failed,
    counted,
  )
  |> view.encode(entry.session, entry.sequence, _)
  |> json.to_string
}

// Properties.

fn same_as_tool(entry: Entry) -> Nil {
  let plain =
    view.Tool(
      entry.call,
      entry.body,
      None,
      entry.progress,
      entry.position,
      entry.failed,
    )
    |> view.encode(entry.session, entry.sequence, _)
    |> json.to_string
  proptest.bump("plain_pair")
  assert plain == publish(entry, [], None)
}

fn tool_calls_field(entry: Entry) -> Nil {
  let counted = publish(entry, [], Some(2))
  let absent = publish(entry, [], None)
  proptest.bump("tool_calls_echo")
  assert string.contains(counted, "\"session_tool_calls\":2,")
  assert string.contains(absent, "\"session_tool_calls\":null,")
  // The counter is the only difference between the two publications.
  assert counted
    == string.replace(
      absent,
      "\"session_tool_calls\":null,",
      "\"session_tool_calls\":2,",
    )
  // The live event names the transcript entry the history route serves.
  assert string.contains(
    absent,
    "\"entry_id\":\"" <> int.to_string(entry.position) <> "\",",
  )
}

fn reference_decoder() -> decode.Decoder(#(String, String, Int)) {
  use url <- decode.field("url", decode.string)
  use field <- decode.field("field", decode.string)
  use bytes <- decode.field("bytes", decode.int)
  decode.success(#(url, field, bytes))
}

fn published_decoder() -> decode.Decoder(List(Published)) {
  use values <- decode.field(
    "data",
    decode.field(
      "images",
    decode.list({
      use mime <- decode.field("mime_type", decode.string)
      use width <- decode.field("width", decode.int)
      use height <- decode.field("height", decode.int)
      use bytes <- decode.field("original_bytes", decode.int)
      use #(url, field, reference_bytes) <- decode.field(
        "reference",
        reference_decoder(),
      )
        decode.success(
          Published(field, mime, width, height, bytes, url, reference_bytes),
        )
      }),
      decode.success,
    ),
  )
  decode.success(values)
}

fn image_fields(input: #(Entry, List(types.Image), Option(Int))) -> Nil {
  let #(entry, values, counted) = input
  let assert Ok(raw) =
    json.parse(publish(entry, values, counted), decode.dynamic)
  let assert Ok(published) = decode.run(raw, published_decoder())
  proptest.bump(case values {
    [] -> "no_images"
    _ -> "images"
  })
  assert list.length(published) == list.length(values)
  let expected = list.index_map(values, fn(value, index) {
    let #(mime, width, height, bytes) = types.image_meta(value)
    let field = "image-" <> int.to_string(index)
    // The reference names the field the history route serves for this entry.
    Published(
      field,
      mime,
      width,
      height,
      bytes,
      "/sessions/"
      <> entry.session
      <> "/history/"
      <> int.to_string(entry.position)
      <> "/"
      <> field,
      bytes,
    )
  })
  assert published == expected
}

fn metadata() -> qcheck.Generator(Option(usage.Metadata)) {
  qcheck.option_from({
    use prompt, completion, cached, recorded <- qcheck.map4(
      qcheck.bounded_int(0, 100_000),
      qcheck.bounded_int(0, 10_000),
      qcheck.option_from(qcheck.bounded_int(0, 50_000)),
      qcheck.bounded_int(0, 1_000_000),
    )
    usage.Metadata(
      "model-x",
      recorded,
      Some(usage.Tokens(prompt, completion, cached, None, None, None, None)),
      None,
      None,
      None,
      None,
    )
  })
}

fn cost() -> qcheck.Generator(Option(types.Cost)) {
  qcheck.option_from(
    qcheck.bounded_float(0.0, 10.0)
      |> qcheck.map(fn(value) { types.Cost(Some(value), None, None) }),
  )
}

fn estimate() -> qcheck.Generator(Option(Float)) {
  qcheck.option_from(
    qcheck.from_weighted_generators(#(6, qcheck.bounded_float(0.0, 100.0)), [
      #(2, pick([0.0, 0.000001, 1.5, 12_345.678])),
    ]),
  )
}

fn cost_is_only_addition(
  input: #(Option(usage.Metadata), Option(types.Cost), Option(Float)),
) -> Nil {
  let #(metadata, spent, estimate) = input
  let plain = json.to_string(view.usage(metadata, spent))
  let costed = json.to_string(view.costed_usage(metadata, spent, estimate))
  // The estimate is one field in front of the usage event, and a missing
  // estimate is still the field, null rather than absent.
  let field = case estimate {
    None -> "\"session_cost_usd\":null,"
    Some(value) ->
      "\"session_cost_usd\":" <> json.to_string(json.float(value)) <> ","
  }
  proptest.bump(case estimate {
    None -> "no_estimate"
    Some(_) -> "estimate"
  })
  assert costed
    == "{" <> field <> string.slice(plain, 1, string.length(plain))
}

pub fn main() -> Nil {
  proptest.check(
    "tool event with no images equals the plain tool event",
    100,
    entry(),
    same_as_tool,
  )
  proptest.check(
    "tool event echoes the ledger counter and entry id",
    100,
    entry(),
    tool_calls_field,
  )
  proptest.check(
    "tool images publish the history reference",
    40,
    qcheck.map3(entry(), images(), tool_count(), fn(entry, values, counted) {
    #(entry, values, counted)
  }),
    image_fields,
  )
  proptest.check(
    "costed usage adds one estimate to the usage event",
    100,
    qcheck.map3(metadata(), cost(), estimate(), fn(metadata, cost, estimate) {
    #(metadata, cost, estimate)
  }),
    cost_is_only_addition,
  )
}
