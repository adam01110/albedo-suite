import albedo/harness/extension
import albedo/harness/location
import albedo/harness/rpc
import albedo/harness/ssh
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn extension() -> extension.Extension {
  let base =
    extension.python_module(
      "files",
      "Read, search, and exactly edit workspace files from Python.",
      "files",
      "files.read(path, start_line=, end_line=, limit=) returns complete numbered lines; limit counts lines, and a separate max_chars= budget (default 16000 characters) stops very large windows and says where to resume, files.ls(path, pattern=) lists one directory, files.write(path, content) creates or replaces a whole file, and files.edit(path, old, new) replaces one exact unique string, reporting every occurrence with line ranges when it is not unique; retry it with line_hint=<line>. These return immediately, and awaiting them also works. await files.find(pattern, path_or_paths, glob=, context=N, literal=, case_sensitive=, max_results=50, hidden=, ignored=) searches contents (a regex unless literal=True) with N surrounding lines. Search uses the mandatory FFF indexed engine; a missing root or dependency raises, and unsupported flags or regular expressions fail explicitly rather than falling back. Ignored files cannot be included. await files.paths(pattern) ranks fuzzy filename matches; wildcard patterns and glob= retain exact glob filtering. Results remain bounded by max_results; use a focused query instead of enumerating all paths. Search calls must be awaited. Prefer these over rg, grep, find, ls, cat, and sed through run().",
      ["python"],
    )
  extension.Extension(..base, plugins: [
    extension.ManagedPlugin(fn(_, _, workspace) {
      let target = case location.parse(workspace) {
        Ok(location.Remote(..) as at) ->
          location.ssh_target(at) |> option.from_result
        _ -> None
      }
      Ok(
        extension.Managed(..extension.empty(), routes: [
          #("files", fn(_, request) {
            rpc.serve(
              request,
              "invalid FFF request",
              fn(method, args) {
                case method {
                  "files.fff" -> search(target, args)
                  _ -> Error("unknown files method")
                }
              },
              fn(message) { #("fff", message) },
            )
          }),
        ]),
      )
    }),
    ..base.plugins
  ])
}

fn search(
  default_target: Option(String),
  args: Dynamic,
) -> Result(json.Json, String) {
  use target <- result.try(rpc.args(
    args,
    decode.optional_field(
      "_fff_target",
      default_target,
      decode.optional(decode.string),
      decode.success,
    ),
    "invalid FFF host",
  ))
  let connection = case target {
    None -> Ok(#("local", [], None))
    Some(target) -> {
      use host <- result.try(
        ssh.ready(target, 30_000) |> result.map_error(ssh.describe(target, _)),
      )
      Ok(#(host.target, host.commands.argv, host.commands.auth_sock))
    }
  }
  use #(key, argv, auth) <- result.try(connection)
  use value <- result.try(native_search(key, argv, auth, args))
  json.parse(value, decode.dynamic)
  |> result.map(types.encode_value)
  |> result.replace_error("FFF worker returned invalid JSON")
}

@external(erlang, "albedo_fff", "search")
fn native_search(
  key: String,
  argv: List(String),
  auth: Option(String),
  args: Dynamic,
) -> Result(String, String)
