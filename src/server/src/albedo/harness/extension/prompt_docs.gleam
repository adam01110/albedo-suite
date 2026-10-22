//// Project only optional API reference prose; preserve executable contributions.

import albedo/harness/extension
import albedo/harness/host
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub fn available(items: List(extension.Prepared)) -> Bool {
  let values = list.map(items, fn(item) { item.value })
  let modules = list.flat_map(values, fn(value) { value.python_modules })
  list.contains(list.map(items, fn(item) { item.extension }), "python")
  && !extension.duplicate_capabilities(
    list.append(values, [
      extension.Managed(
        ..extension.empty(),
        python_modules: ["api_docs"],
        routes: [
          route(items),
        ],
      ),
    ]),
  )
  && !list.contains(modules, "albedo_plugins.api_docs")
}

fn summary(name: String) -> String {
  case name {
    "agents" ->
      "agents: spawn, inspect and cancel child sessions. Before spawning, read api_docs.read(\"agents\") and await agents.models(); children share the workspace. Independent children start back to back; results arrive as mail, never poll/sleep."
    "remote" ->
      "remote: SSH tools via await remote.connect(host), not run(\"ssh\", ...). Before use read api_docs.read(\"remote\"); remote file/tool operations require await. Do not retry authentication or failed operations blindly."
    "browser" ->
      "browser: CDP browser automation. Before use read api_docs.read(\"browser\"); close browsers when finished."
    "mail" ->
      "mail: await mail.submit(to, body) sends inter-agent messages; incoming letters arrive automatically as <mail>. Before use read api_docs.read(\"mail\")."
    "schedule" ->
      "schedule: durable scheduled prompts and heartbeats. Before use read api_docs.read(\"schedule\")."
    "paperclips" ->
      "paperclips: vent reviewable workflow/tool problems without interrupting the user; not a substitute for urgent reporting. Before use read api_docs.read(\"paperclips\")."
    _ -> ""
  }
}

pub fn instructions(items: List(extension.Prepared)) -> String {
  let compact = available(items)
  let prefix = case compact {
    True ->
      "Optional API references are available in full through await api_docs.read(topic); await api_docs.catalog() lists active topics. Read the reference before first use or when uncertain. No capabilities are disabled.\n"
    False -> ""
  }
  prefix
  <> {
    items
    |> list.map(fn(item) {
      case
        compact
        && summary(item.extension) != ""
        && string.trim(item.value.instructions) != ""
      {
        True -> summary(item.extension)
        False -> item.value.instructions
      }
    })
    |> list.filter(fn(text) { string.trim(text) != "" })
    |> string.join("\n")
  }
}

pub fn route(items: List(extension.Prepared)) -> host.Route {
  let documented =
    list.filter(items, fn(item) { string.trim(item.value.instructions) != "" })
  let names = list.unique(list.map(documented, fn(item) { item.extension }))
  #("api_docs", fn(_, method, args) {
    case method {
      "api_docs.catalog" -> Ok(json.array(names, json.string))
      "api_docs.read" -> {
        use topic <- result.try(
          decode.run(args, decode.field("topic", decode.string, decode.success))
          |> result.replace_error(#("invalid", "expected topic (string)")),
        )
        case list.contains(names, topic) {
          True ->
            documented
            |> list.filter(fn(item) { item.extension == topic })
            |> list.map(fn(item) { item.value.instructions })
            |> string.join("\n")
            |> json.string
            |> Ok
          False ->
            Error(#("unavailable", "no active API documentation for " <> topic))
        }
      }
      _ -> Error(#("invalid", "unknown api_docs operation"))
    }
  })
}
