//// Project-scoped, agent-maintained notes; never a source of mandatory instructions.
////
//// The files live on the daemon's disk (files.gleam), and the kernel's
//// `memory` object reaches them through the route below wherever it runs.
//// A workspace writes only its own memory and reads its whole link group.

import albedo_clock
import albedo_ext_memory/files
import albedo_file
import albedo_sdk/extension
import albedo_sdk/host
import albedo_sdk/links
import albedo_sdk/rpc
import albedo_sdk/transfer
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "memory",
    "Durable project memory and dated journal entries.",
    [],
    [
      extension.TransferPlugin(transfer_adapter()),
      extension.ToolPlugin(
        "Project memory is nonbinding recall, not instructions. The startup block is a topic index, not full notes. "
          <> "Before project work, retrieve relevant facts with memory.search(query, limit=20) (SQLite FTS5) "
          <> "or memory.grep(term, limit=20); memory.read(max_chars=16000) reads current workspace memory with an explicit output bound. "
          <> "Search includes linked workspaces and journals; verify facts that may have changed. "
          <> "memory.append(text)/save(text)/journal(text) write only this workspace (a worktree's own is its origin's); never store secrets. "
          <> "Required rules belong in AGENTS.md. Calls are synchronous and also awaitable.",
        [],
        ["memory"],
        [],
      ),
      // A session in a workspace whose link group grew hears what its next
      // snapshot will hold for the workspaces that joined.
      extension.LinkedSummaryPlugin(linked_summary),
      extension.ManagedPlugin(fn(preparation) {
        let extension.Preparation(storage: scope, origins:, workspace:, ..) =
          preparation
        let own = links.origin(scope, origins, workspace)
        use context <- result.try(load(links.group(scope, origins, own)))
        Ok(
          extension.Managed(..extension.empty(), context: context, routes: [
            #("memory", fn(context: host.Context, method, args) {
              let group = links.group(context.storage, context.origins, own)
              handle(own, group, method, args)
            }),
          ]),
        )
      }),
    ],
    extension.no_initialise,
    tables: [],
    uses: [],
  )
}

fn linked_summary(workspaces: List(String)) -> String {
  case files.linked(workspaces) {
    "" -> ""
    memory -> "Their memory, as a new session's snapshot holds it:\n" <> memory
  }
}

fn handle(
  own: String,
  group: List(String),
  method: String,
  args: decode.Dynamic,
) -> Result(json.Json, #(String, String)) {
  rpc.serve(
    method,
    args,
    fn(method, args) {
      let text = fn(field) {
        rpc.args(
          args,
          decode.field(field, decode.string, decode.success),
          "expected " <> field,
        )
      }
      case method {
        "memory.read" -> read(own) |> result.map(json.string)
        "memory.save" -> text("text") |> result.try(save(own, _)) |> path
        "memory.append" -> text("text") |> result.try(append(own, _)) |> path
        "memory.journal" -> {
          use date <- result.try(text("date"))
          use entry <- result.try(text("text"))
          journal(own, date, entry) |> path
        }
        "memory.documents" -> {
          let #(found, truncated) = documents(group)
          Ok(
            json.object([
              #(
                "documents",
                json.array(found, fn(document) {
                  let #(workspace, relative, content) = document
                  json.object([
                    #("workspace", json.string(workspace)),
                    #("path", json.string(relative)),
                    #("text", json.string(content)),
                  ])
                }),
              ),
              #("truncated", json.bool(truncated)),
              #("own", json.string(own)),
            ]),
          )
        }
        _ -> Error("unknown memory operation")
      }
    },
    fn(message) { #("invalid", message) },
  )
}

fn path(written: Result(String, String)) -> Result(json.Json, String) {
  result.map(written, json.string)
}

fn load(group: List(String)) -> Result(String, String) {
  files.load(group)
}

fn read(workspace: String) -> Result(String, String) {
  files.read(workspace)
}

fn save(workspace: String, text: String) -> Result(String, String) {
  files.save(workspace, text)
}

fn append(workspace: String, text: String) -> Result(String, String) {
  files.append(workspace, text)
}

fn journal(
  workspace: String,
  date: String,
  text: String,
) -> Result(String, String) {
  files.journal(workspace, date, text)
}

fn documents(group: List(String)) -> #(List(#(String, String, String)), Bool) {
  files.documents(group)
}

/// Reads this workspace's memory only, without checking its working directory.
pub fn export_snapshot(workspace: String) -> Result(files.Snapshot, String) {
  files.export_snapshot(workspace)
}

/// Imports once per origin, transfer, source workspace and target file.
pub fn import_snapshot(
  target: String,
  origin: String,
  transfer_id: String,
  snapshot: files.Snapshot,
) -> Result(Nil, String) {
  files.import_snapshot(
    target,
    origin,
    transfer_id,
    snapshot,
    albedo_clock.system_seconds(),
  )
}

/// The moved workspace's memory files, named `memory/<relative path>`, merged
/// into the destination workspace's memory at activation.
fn transfer_adapter() -> transfer.Adapter {
  let files = fn(scope: transfer.Scope) {
    use snapshot <- result.map(export_snapshot(scope.workspace))
    list.map(snapshot.files, fn(file) {
      transfer.Contents("memory/" <> file.0, bit_array.from_string(file.1))
    })
  }
  transfer.Adapter(
    ..transfer.declare("memory", [], []),
    files: files,
    install: install,
  )
}

/// Imports the staged files as the origin workspace's snapshot. A retry of
/// the same transfer skips what an earlier attempt committed.
fn install(
  scope: transfer.Scope,
  origin: transfer.Origin,
  staged: List(transfer.Staged),
) -> Result(List(String), String) {
  use files <- result.try(
    list.try_map(staged, fn(file) {
      use relative <- result.try(case file.name {
        "memory/" <> relative -> Ok(relative)
        name -> Error("not a memory file: " <> name)
      })
      use bytes <- result.try(
        albedo_file.read(file.path)
        |> result.replace_error("cannot read staged " <> file.name),
      )
      bit_array.to_string(bytes)
      |> result.map(fn(text) { #(relative, text) })
      |> result.replace_error("staged " <> file.name <> " is not UTF-8")
    }),
  )
  case files {
    [] -> Ok([])
    _ ->
      import_snapshot(
        scope.workspace,
        origin.daemon,
        origin.transfer,
        files.Snapshot(origin.workspace, files),
      )
      |> result.replace([])
  }
}
