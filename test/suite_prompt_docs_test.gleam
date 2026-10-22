import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extension/prompt_docs
import albedo/harness/extensions/agents/extension as agents
import albedo/harness/extensions/browser/extension as browser
import albedo/harness/extensions/mail/extension as mail
import albedo/harness/extensions/paperclips/extension as paperclips
import albedo/harness/extensions/python/extension as python
import albedo/harness/extensions/remote/extension as remote
import albedo/harness/extensions/schedule/extension as schedule
import albedo/harness/host
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/string

fn item(name: String, text: String) -> extension.Prepared {
  extension.Prepared(
    name,
    extension.Managed(..extension.empty(), instructions: text),
  )
}

pub fn main() -> Nil {
  let actual =
    [
      python.extension(),
      agents.extension(),
      remote.extension(),
      browser.extension(),
      mail.extension(),
      schedule.extension(),
      paperclips.extension(),
    ]
    |> list.flat_map(fn(ext) {
      list.map(extension.declared(ext), fn(value) {
        extension.Prepared(ext.name, value)
      })
    })
  let before =
    actual
    |> list.map(fn(item) { item.value.instructions })
    |> string.join("\n")
    |> string.byte_size
  let after = actual |> prompt_docs.instructions |> string.byte_size
  assert after < before
  io.println(
    "Optional reference bytes: "
    <> int.to_string(before)
    <> " -> "
    <> int.to_string(after),
  )

  let original = string.repeat("FULL_AGENTS_REFERENCE ", 100)
  let items = [
    item("python", "core rules"),
    item("agents", original),
    item("custom", "custom instructions"),
  ]
  assert prompt_docs.available(items)
  let compact = prompt_docs.instructions(items)
  assert string.contains(compact, "core rules")
  assert string.contains(compact, "custom instructions")
  assert string.contains(compact, "agents.models()")
  assert string.contains(compact, "api_docs.read")
  assert !string.contains(compact, original)
  assert string.byte_size(compact) < string.byte_size(original)
  assert compact == prompt_docs.instructions(items)

  let assert Ok(ledger) = store.start(":memory:", "")
  let context = host.Context(ledger, "test", [])
  let #(_, call) = prompt_docs.route(items)
  let assert Ok(args) =
    json.parse("\"invalid native arguments\"", decode.dynamic)
  // Host arguments are native decoded maps, not JSON text.
  let assert Ok(native) =
    json.parse(
      json.to_string(json.object([#("topic", json.string("agents"))])),
      decode_dynamic(),
    )
  let assert Ok(full) = call(context, "api_docs.read", native)
  assert json.to_string(full) == json.to_string(json.string(original))
  assert prompt_docs.instructions(items) == compact
  let assert Ok(topics) = call(context, "api_docs.catalog", args)
  assert json.to_string(topics) == "[\"python\",\"agents\",\"custom\"]"
  let assert Error(#("invalid", _)) = call(context, "api_docs.read", args)
  let assert Ok(missing) =
    json.parse("{\"topic\":\"disabled\"}", decode_dynamic())
  let assert Error(#("unavailable", _)) =
    call(context, "api_docs.read", missing)
  let assert Error(#("invalid", _)) = call(context, "api_docs.unknown", args)

  let without_python = [item("agents", original)]
  assert !prompt_docs.available(without_python)
  assert prompt_docs.instructions(without_python) == original
  list.each(["api_docs", "albedo_plugins.api_docs"], fn(module) {
    let collision =
      extension.Prepared(
        "custom",
        extension.Managed(..extension.empty(), python_modules: [module]),
      )
    let conflicted = list.append(items, [collision])
    assert !prompt_docs.available(conflicted)
    assert string.contains(prompt_docs.instructions(conflicted), original)
  })
  let collision =
    extension.Prepared(
      "custom",
      extension.Managed(..extension.empty(), routes: [prompt_docs.route(items)]),
    )
  assert !prompt_docs.available(list.append(items, [collision]))
  store.close(ledger)
  io.println(
    "Prompt docs: projection, exact retrieval, stable prefix, disabled and collision cases passed",
  )
}

fn decode_dynamic() -> decode.Decoder(dynamic.Dynamic) {
  decode.dynamic
}
