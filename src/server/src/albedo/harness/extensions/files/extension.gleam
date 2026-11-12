import albedo/daemon/conversation
import albedo/daemon/images
import albedo/harness/extension
import albedo/harness/host
import albedo/harness/location
import albedo/harness/rpc
import albedo/harness/ssh
import albedo/openai_api/types
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "files",
    "Read, search, and exactly edit workspace files and read uploaded images from Python.",
    ["python"],
    [extension.ToolPlugin(instructions, [], ["files"], [#("files", route)])],
    extension.no_initialise,
  )
}

const instructions =
  "files.read(path, start_line=1, end_line=None, limit=None, max_chars=16000) returns numbered whole lines; limit counts lines, max_chars bounds characters, and a stopped read names where to resume. files.ls(path, pattern=) lists one directory. files.write(path, content) creates/replaces a file. files.edit(path, old, new, line_hint=None) replaces one unique match; ambiguity reports line ranges. files.edit(path, [(old,new), ...]) applies edits in order, all or none; prefer it to read/replace/write. await files.find(pattern, path, glob=, context=N, literal=False, case_sensitive=, max_results=50) searches contents by regex unless literal=True through the mandatory FFF index; path accepts one root or a list. Missing roots or dependencies raise; hidden=True, ignored=True and unsupported flags or regular expressions fail explicitly rather than falling back; empty results explain searched/skipped files. await files.paths(pattern) ranks fuzzy filename matches; wildcard patterns and glob= keep exact glob filtering. Results stay bounded by max_results; use a focused query instead of enumerating all paths. Both searches need await; use await parallel(...) for independent searches. Prefer these APIs over rg/grep/find/ls/cat/sed through run(). await files.image(index=0, entry=None) returns original uploaded bytes from the latest user message with images, or entry's transcript position; index is zero-based. FilesError reports unavailable uploads. Assign bytes before image-library use. This works remotely; do not read the daemon database or guess upload paths. Method docstrings give limits, errors and examples."

fn route(
  context: host.Context,
  method: String,
  args: Dynamic,
) -> Result(json.Json, #(String, String)) {
  case method {
    "files.fff" -> {
      let target = case location.parse(context.workspace) {
        Ok(location.Remote(..) as at) ->
          location.ssh_target(at) |> option.from_result
        _ -> None
      }
      search(target, args)
      |> result.map_error(fn(message) { #("fff", message) })
    }
    _ -> image(context, method, args)
  }
}

fn image(
  context: host.Context,
  method: String,
  args: Dynamic,
) -> Result(json.Json, #(String, String)) {
  case method {
    "files.image" -> {
      use #(position, index, before) <- result.try(
        rpc.args(
          args,
          {
            use position <- decode.optional_field(
              "entry",
              None,
              decode.optional(decode.int),
            )
            use index <- decode.optional_field("index", 0, decode.int)
            use before <- decode.optional_field("before", 0, decode.int)
            decode.success(#(position, index, before))
          },
          #("invalid", "entry, index and before must be integers"),
        ),
      )
      use _ <- result.try(case position, index, before {
        Some(position), _, _ if position < 1 ->
          Error(#("invalid", "entry must be a positive transcript position"))
        _, index, _ if index < 0 ->
          Error(#("invalid", "index must be nonnegative"))
        _, _, before if before < 0 ->
          Error(#("invalid", "before must be nonnegative"))
        _, _, _ -> Ok(Nil)
      })
      use lookup <- result.try(
        conversation.uploaded_image(
          context.store,
          context.session,
          position,
          index,
          before,
        )
        |> result.map_error(fn(message) { #("image_unavailable", message) }),
      )
      case lookup {
        conversation.ImageBefore(before) ->
          Ok(json.object([#("before", json.int(before))]))
        conversation.ImageFound(image) -> {
          use bytes <- result.try(
            images.bytes(context.store, image)
            |> result.replace_error(#(
              "image_unavailable",
              "uploaded image bytes not found",
            )),
          )
          Ok(
            json.object([
              #("data", json.string(bit_array.base64_encode(bytes, True))),
            ]),
          )
        }
      }
    }
    _ -> Error(#("unavailable", "unknown files operation"))
  }
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
      use remote <- result.try(
        ssh.ready(target, 30_000) |> result.map_error(ssh.describe(target, _)),
      )
      Ok(#(remote.target, remote.commands.argv, remote.commands.auth_sock))
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
