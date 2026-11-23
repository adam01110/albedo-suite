//// Project memory on the daemon's disk: one directory per workspace under
//// $ALBEDO_HOME/memories, `memory.md` plus `journal/<date>.md`. The kernel
//// reaches it through the memory host route wherever the kernel runs, so a
//// remote session's memory lives here too. Writes to one workspace are
//// serialized through a lock on its directory. Reads span a workspace's link group.
//// See README.md for snapshot transfer, receipts, and recovery.

import albedo_bytes/digest
import albedo_bytes/term_codec
import albedo_file
import albedo_file/info as file_info
import albedo_sdk/settings
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/order
import gleam/result
import gleam/set
import gleam/string

const max_file = 1_048_576

/// Characters of the topic index a session opens with, across workspaces.
const index_budget = 1600

/// Paragraphs the index lists per workspace, newest first.
const index_topics = 12

/// Characters of each paragraph's first line the index shows.
const topic_chars = 120

/// Bytes one documents answer carries.
const documents_budget = 16_777_216

/// A source workspace label and its relative UTF-8 memory and journal files.
pub type Snapshot {
  Snapshot(workspace: String, files: List(#(String, String)))
}

type Info {
  Missing
  Found(regular: Bool, size: Int)
  InfoFailed(reason: String)
}

type ReadError {
  ReadError(missing: Bool, reason: String)
}

type ListError {
  ListError(missing: Bool, reason: String)
}

/// A file's `.imports` receipt: the committed sources, or an import whose
/// payload replacement may not have happened yet. Each source pairs a hashed
/// origin, transfer, and workspace identity with the imported bytes' digest.
@internal
pub type Receipt {
  Done(sources: List(#(BitArray, BitArray)))
  Pending(
    sources: List(#(BitArray, BitArray)),
    before: BitArray,
    after: BitArray,
  )
}

fn root(workspace: String) -> String {
  join([settings.home(), "memories", slug(workspace)])
}

/// Every character other than an ASCII letter or digit becomes `-`.
fn slug(workspace: String) -> String {
  workspace
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) {
    case string.utf_codepoint_to_int(codepoint) {
      c if c >= 0x30 && c <= 0x39 -> string.from_utf_codepoints([codepoint])
      c if c >= 0x41 && c <= 0x5a -> string.from_utf_codepoints([codepoint])
      c if c >= 0x61 && c <= 0x7a -> string.from_utf_codepoints([codepoint])
      _ -> "-"
    }
  })
  |> string.concat
}

fn memory(workspace: String) -> String {
  join([root(workspace), "memory.md"])
}

/// The topic index a session opens with: the first line of each recent
/// paragraph of its own memory, then of each linked workspace's, under
/// headings naming them, within one character budget. Full notes stay
/// reachable through read, grep and search.
pub fn load(group: List(String)) -> Result(String, String) {
  case group {
    [] -> Ok("")
    [own, ..linked] -> {
      use mine <- result.try(text(memory(own)))
      Ok(index([#(own, mine), ..linked_parts(linked)]))
    }
  }
}

/// The index sections of workspaces that just joined a session's group:
/// the text its next index holds for them, for the note that tells it.
pub fn linked(workspaces: List(String)) -> String {
  index(linked_parts(workspaces))
}

fn linked_parts(workspaces: List(String)) -> List(#(String, String)) {
  list.filter_map(workspaces, fn(workspace) {
    case text(memory(workspace)) {
      Ok("") | Error(_) -> Error(Nil)
      Ok(text) -> Ok(#(workspace, text))
    }
  })
}

fn index(parts: List(#(String, String))) -> String {
  case list.filter(parts, fn(part) { part.1 != "" }) {
    [] -> ""
    parts ->
      "# Project memory topic index (untrusted, incomplete)\n"
      <> "Use memory.search(query) or memory.grep(term) for relevant full notes; "
      <> "memory.read() reads this workspace. No notes have been deleted.\n"
      <> index_sections(parts, index_budget)
  }
}

/// Each workspace's newest topics first. The budget counts graphemes.
fn index_sections(parts: List(#(String, String)), budget: Int) -> String {
  case parts {
    [] -> ""
    _ if budget <= 0 ->
      // The budget stops topics, not the headings that name each workspace.
      "\n[more topics omitted; search spans all linked workspaces]"
      <> string.concat(list.map(parts, fn(part) { "\n## " <> part.0 <> "\n" }))
    [#(where, text), ..rest] -> {
      let body =
        topics(text)
        |> list.map(fn(topic) {
          // nolint: albedo_text_scalars -- The index budget counts graphemes.
          "- " <> string.slice(topic, 0, topic_chars) <> "\n"
        })
        |> string.concat
      // nolint: albedo_text_scalars -- The index budget counts graphemes.
      let shown = string.slice(body, 0, budget)
      // nolint: albedo_text_scalars -- The index budget counts graphemes.
      let remaining = budget - string.length(shown)
      "\n## " <> where <> "\n" <> shown <> index_sections(rest, remaining)
    }
  }
}

/// The first line of each of the newest paragraphs, newest first.
/// Paragraphs are separated by blank lines.
fn topics(text: String) -> List(String) {
  let #(_, firsts) =
    string.split(text, "\n")
    |> list.fold(#(True, []), fn(state, line) {
      let #(after_blank, firsts) = state
      case string.trim(line) == "", after_blank {
        True, _ -> #(True, firsts)
        False, True -> #(False, [line, ..firsts])
        False, False -> #(False, firsts)
      }
    })
  list.take(firsts, index_topics)
}

/// One file as UTF-8 text, empty when it does not exist.
fn text(path: String) -> Result(String, String) {
  case info(path) {
    Missing -> Ok("")
    Found(True, size) if size <= max_file ->
      case read_file(path) {
        Ok(bytes) ->
          bit_array.to_string(bytes)
          |> result.replace_error(basename(path) <> " is not UTF-8")
        Error(ReadError(_, reason)) -> Error(reason)
      }
    Found(..) ->
      Error(basename(path) <> " must be a regular UTF-8 file of at most 1 MiB")
    InfoFailed(reason) -> Error(reason)
  }
}

fn basename(path: String) -> String {
  case string.split(path, "/") |> list.last {
    Ok(name) -> name
    Error(Nil) -> path
  }
}

pub fn read(workspace: String) -> Result(String, String) {
  text(memory(workspace))
}

/// Replaces the curated memory atomically.
pub fn save(workspace: String, text: String) -> Result(String, String) {
  case string.byte_size(text) > max_file {
    True -> Error("memory.md cannot exceed 1 MiB")
    False -> {
      let path = memory(workspace)
      locked(workspace, fn() {
        use _ <- result.try(recover_import(path))
        write_atomically(path, <<text:utf8>>)
      })
    }
  }
}

pub fn append(workspace: String, note: String) -> Result(String, String) {
  let path = memory(workspace)
  locked(workspace, fn() {
    use _ <- result.try(recover_import(path))
    use before <- result.try(text(path))
    let entry = entry(string.byte_size(before), note)
    case string.byte_size(before) + string.byte_size(entry) > max_file {
      True -> Error("memory.md cannot exceed 1 MiB")
      False -> write(path, entry)
    }
  })
}

pub fn journal(
  workspace: String,
  date: String,
  note: String,
) -> Result(String, String) {
  case journal_date(date) {
    False -> Error("journal date must be YYYY-MM-DD")
    True -> {
      // The final newline PCRE's `$` lets through is not part of the day.
      let day = string.remove_suffix(date, "\n")
      let path = join([root(workspace), "journal", day <> ".md"])
      locked(workspace, fn() {
        use _ <- result.try(recover_import(path))
        let size = case info(path) {
          Found(_, size) -> size
          _ -> 0
        }
        let entry = entry(size, note)
        case size + string.byte_size(entry) > max_file {
          True -> Error("journal file cannot exceed 1 MiB")
          False -> write(path, entry)
        }
      })
    }
  }
}

/// `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` as PCRE reads it, where `$` also matches
/// before a final newline.
fn journal_date(date: String) -> Bool {
  date_shaped(date)
  || {
    string.ends_with(date, "\n")
    && date_shaped(string.remove_suffix(date, "\n"))
  }
}

/// Four digits, a dash, two digits, a dash, and two digits.
fn date_shaped(text: String) -> Bool {
  case <<text:utf8>> {
    <<y1, y2, y3, y4, 0x2d, m1, m2, 0x2d, d1, d2>> ->
      list.all([y1, y2, y3, y4, m1, m2, d1, d2], fn(byte) {
        byte >= 0x30 && byte <= 0x39
      })
    _ -> False
  }
}

/// A note on its own line, a blank line from the one before it.
fn entry(size: Int, note: String) -> String {
  let gap = case size > 0 {
    True -> "\n"
    False -> ""
  }
  gap <> trim_newlines(note) <> "\n"
}

/// Drops trailing newlines, including the newline of a final `\r\n`.
fn trim_newlines(text: String) -> String {
  case string.ends_with(text, "\n") {
    True -> trim_newlines(string.remove_suffix(text, "\n"))
    False -> text
  }
}

fn write(path: String, entry: String) -> Result(String, String) {
  append_file(path, <<entry:utf8>>) |> result.replace(path)
}

fn write_atomically(path: String, bytes: BitArray) -> Result(String, String) {
  atomic_write(path, bytes) |> result.replace(path)
}

fn locked(
  workspace: String,
  run: fn() -> Result(a, String),
) -> Result(a, String) {
  use _ <- result.try(ensure_path(join([root(workspace), "journal"])))
  with_lock(root(workspace), run)
}

/// Every memory and journal file of the given workspaces, for grep and
/// search: `#(workspace, relative, text)` and whether the byte budget cut the
/// list short. Unreadable files are left out.
pub fn documents(
  workspaces: List(String),
) -> #(List(#(String, String, String)), Bool) {
  documents_from(workspaces, documents_budget, [])
}

fn documents_from(
  workspaces: List(String),
  budget: Int,
  found: List(#(String, String, String)),
) -> #(List(#(String, String, String)), Bool) {
  case workspaces {
    [] -> #(list.reverse(found), False)
    [workspace, ..rest] -> {
      let root = root(workspace)
      case
        collect(workspace, root, ["memory.md", ..journals(root)], budget, found)
      {
        Error(found) -> #(list.reverse(found), True)
        Ok(#(left, found)) -> documents_from(rest, left, found)
      }
    }
  }
}

/// `Error` holds what was collected when the budget ran out.
fn collect(
  workspace: String,
  root: String,
  files: List(String),
  budget: Int,
  found: List(#(String, String, String)),
) -> Result(
  #(Int, List(#(String, String, String))),
  List(#(String, String, String)),
) {
  case files {
    [] -> Ok(#(budget, found))
    [relative, ..rest] ->
      case text(join([root, relative])) {
        Ok("") | Error(_) -> collect(workspace, root, rest, budget, found)
        Ok(text) ->
          case string.byte_size(text) > budget {
            True -> Error(found)
            False ->
              collect(workspace, root, rest, budget - string.byte_size(text), [
                #(workspace, relative, text),
                ..found
              ])
          }
      }
  }
}

/// This workspace's memory only, without following links. Export and import
/// never hold two workspace locks together.
pub fn export_snapshot(workspace: String) -> Result(Snapshot, String) {
  use files <- result.map(source_files(workspace))
  Snapshot(workspace, files)
}

fn source_files(workspace: String) -> Result(List(#(String, String)), String) {
  with_lock(root(workspace), fn() {
    case list_dir(join([root(workspace), "journal"])) {
      Error(ListError(True, _)) ->
        snapshot_files(workspace, ["memory.md"], documents_budget, [])
      Ok(names) -> {
        let days =
          names
          |> list.filter_map(fn(name) {
            case journal_file(name) {
              Ok(day) -> Ok(join(["journal", day]))
              Error(Nil) -> Error(Nil)
            }
          })
          |> list.sort(string.compare)
          |> list.unique
        snapshot_files(workspace, ["memory.md", ..days], documents_budget, [])
      }
      Error(ListError(False, reason)) -> Error(reason)
    }
  })
}

/// The journal day file a directory entry names: `<date>.md` itself, or the
/// file a `<date>.md.imports` receipt belongs to.
fn journal_file(name: String) -> Result(String, Nil) {
  case string.split_once(name, ".md") {
    Ok(#(date, "")) | Ok(#(date, ".imports")) ->
      case date_shaped(date) {
        True -> Ok(date <> ".md")
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn snapshot_files(
  workspace: String,
  files: List(String),
  budget: Int,
  found: List(#(String, String)),
) -> Result(List(#(String, String)), String) {
  case files {
    [] -> Ok(list.reverse(found))
    [relative, ..rest] -> {
      let path = join([root(workspace), relative])
      use _ <- result.try(recover_import(path))
      use text <- result.try(text(path))
      case text, string.byte_size(text) <= budget {
        "", _ if relative == "memory.md" ->
          snapshot_files(workspace, rest, budget, found)
        _, True ->
          snapshot_files(workspace, rest, budget - string.byte_size(text), [
            #(relative, text),
            ..found
          ])
        _, False -> Error("source memory and journal exceed 16 MiB")
      }
    }
  }
}

/// Imports once per origin, transfer, source workspace and target file.
/// `seconds` is the system time that dates the imported sections.
pub fn import_snapshot(
  target: String,
  origin: String,
  transfer: String,
  snapshot: Snapshot,
  seconds: Int,
) -> Result(Nil, String) {
  let Snapshot(source, files) = snapshot
  use _ <- result.try(validate_snapshot(files, documents_budget, set.new()))
  let key = term_digest(#(origin, transfer, source))
  let heading =
    "\n\n## imported from " <> source <> " on " <> utc_date(seconds) <> "\n\n"
  locked(target, fn() {
    use _ <- result.try(transfer_manifest(
      root(target),
      origin,
      transfer,
      source,
      files,
    ))
    import_files(root(target), key, heading, files)
  })
}

/// Binds the origin and transfer to this snapshot's source label and sorted
/// files, so reusing them with a changed snapshot fails before merging.
fn transfer_manifest(
  root: String,
  origin: String,
  transfer: String,
  source: String,
  files: List(#(String, String)),
) -> Result(String, String) {
  let key = term_digest(#(origin, transfer)) |> digest.hex
  let path = join([root, ".transfers", key])
  let sorted =
    list.sort(files, fn(left, right) {
      case string.compare(left.0, right.0) {
        order.Eq -> string.compare(left.1, right.1)
        other -> other
      }
    })
  let manifest = term_digest(#(source, sorted))
  case read_file(path) {
    Ok(bytes) if bytes == manifest -> Ok(path)
    Ok(_) -> Error("memory snapshot changed for an existing transfer")
    Error(ReadError(True, _)) -> {
      use _ <- result.try(ensure_dir(path))
      write_atomically(path, manifest)
    }
    Error(ReadError(False, reason)) -> Error(reason)
  }
}

fn validate_snapshot(
  files: List(#(String, String)),
  budget: Int,
  seen: set.Set(String),
) -> Result(Nil, String) {
  case files {
    [] -> Ok(Nil)
    [#(relative, text), ..rest] -> {
      let size = string.byte_size(text)
      let valid_path =
        relative == "memory.md"
        || case relative {
          "journal/" <> name ->
            string.ends_with(name, ".md")
            && date_shaped(string.remove_suffix(name, ".md"))
          _ -> False
        }
      let valid_text = bit_array.is_utf8(<<text:utf8>>)
      case
        valid_path
        && valid_text
        && size <= max_file
        && size <= budget
        && !set.contains(seen, relative)
      {
        True ->
          validate_snapshot(rest, budget - size, set.insert(seen, relative))
        False ->
          Error(
            "invalid memory snapshot path, text, duplicate, or size (1 MiB/file, 16 MiB total)",
          )
      }
    }
  }
}

/// `YYYY-MM-DD` of a system time in seconds, in UTC.
fn utc_date(seconds: Int) -> String {
  // Days since 1970-01-01 to a proleptic Gregorian date (Hinnant's algorithm).
  let days = int.floor_divide(seconds, 86_400) |> result.unwrap(0)
  let z = days + 719_468
  let era = int.floor_divide(z, 146_097) |> result.unwrap(0)
  let day_of_era = z - era * 146_097
  let year_of_era =
    {
      day_of_era
      - day_of_era
      / 1460
      + day_of_era
      / 36_524
      - day_of_era
      / 146_096
    }
    / 365
  let day_of_year =
    day_of_era - { 365 * year_of_era + year_of_era / 4 - year_of_era / 100 }
  let month_index = { 5 * day_of_year + 2 } / 153
  let day = day_of_year - { 153 * month_index + 2 } / 5 + 1
  let month = case month_index < 10 {
    True -> month_index + 3
    False -> month_index - 9
  }
  let year =
    year_of_era
    + era
    * 400
    + case month <= 2 {
      True -> 1
      False -> 0
    }
  pad(year, 4) <> "-" <> pad(month, 2) <> "-" <> pad(day, 2)
}

fn pad(value: Int, width: Int) -> String {
  string.pad_start(int.to_string(value), width, "0")
}

fn import_files(
  root: String,
  key: BitArray,
  heading: String,
  files: List(#(String, String)),
) -> Result(Nil, String) {
  case files {
    [] -> Ok(Nil)
    [#("memory.md", ""), ..rest] -> import_files(root, key, heading, rest)
    [#(relative, text), ..rest] -> {
      use _ <- result.try(
        import_file(join([root, relative]), key, heading, <<text:utf8>>),
      )
      import_files(root, key, heading, rest)
    }
  }
}

fn import_file(
  path: String,
  key: BitArray,
  heading: String,
  bytes: BitArray,
) -> Result(List(#(BitArray, BitArray)), String) {
  use sources <- result.try(recover_import(path))
  let digest = digest.sha256(bytes)
  case list.key_find(sources, key) {
    Ok(recorded) if recorded == digest -> Ok(sources)
    Ok(_) -> Error("memory transfer file changed for an existing receipt")
    Error(Nil) -> merge_import(path, sources, #(key, digest), heading, bytes)
  }
}

fn merge_import(
  path: String,
  sources: List(#(BitArray, BitArray)),
  source: #(BitArray, BitArray),
  heading: String,
  bytes: BitArray,
) -> Result(List(#(BitArray, BitArray)), String) {
  use before <- result.try(text(path))
  let before = <<before:utf8>>
  let after = case before {
    <<>> -> bytes
    _ -> bit_array.concat([before, <<heading:utf8>>, bytes])
  }
  case bit_array.byte_size(after) <= max_file {
    True -> {
      // A write-ahead receipt makes a payload rename and its provenance
      // recoverable as one operation. Never guess after an external edit or
      // a corrupt receipt.
      use _ <- result.try(receipt(
        path,
        Pending([source, ..sources], before, after),
      ))
      recover_import(path)
    }
    False -> Error("imported memory file cannot exceed 1 MiB")
  }
}

/// The committed sources of a file's receipt, finishing a pending import
/// first.
fn recover_import(path: String) -> Result(List(#(BitArray, BitArray)), String) {
  use receipt <- result.try(read_import(path))
  case receipt {
    Done(sources) -> Ok(sources)
    Pending(sources, before, after) ->
      finish_import(path, sources, before, after)
  }
}

fn read_import(path: String) -> Result(Receipt, String) {
  case read_file(path <> ".imports") {
    Error(ReadError(True, _)) -> Ok(Done([]))
    Error(ReadError(False, reason)) -> Error(reason)
    Ok(bytes) -> decode_receipt(bytes)
  }
}

fn finish_import(
  path: String,
  sources: List(#(BitArray, BitArray)),
  before: BitArray,
  after: BitArray,
) -> Result(List(#(BitArray, BitArray)), String) {
  use current <- result.try(text(path))
  let current = <<current:utf8>>
  case current == after, current == before {
    True, _ ->
      case info(path) {
        Missing -> apply_import(path, sources, after)
        Found(..) -> commit_import(path, sources)
        InfoFailed(reason) -> Error(reason)
      }
    False, True -> apply_import(path, sources, after)
    False, False ->
      Error(
        "memory changed outside the daemon during an import; receipt retained",
      )
  }
}

fn apply_import(
  path: String,
  sources: List(#(BitArray, BitArray)),
  after: BitArray,
) -> Result(List(#(BitArray, BitArray)), String) {
  use _ <- result.try(atomic_write(path, after))
  commit_import(path, sources)
}

fn commit_import(
  path: String,
  sources: List(#(BitArray, BitArray)),
) -> Result(List(#(BitArray, BitArray)), String) {
  receipt(path, Done(sources)) |> result.replace(sources)
}

fn receipt(path: String, state: Receipt) -> Result(Nil, String) {
  atomic_write(path <> ".imports", encode_receipt(state))
}

/// The parts joined as one path, each later part under the one before.
fn join(parts: List(String)) -> String {
  case parts {
    [] -> ""
    [first, ..rest] -> list.fold(rest, first, albedo_file.join)
  }
}

fn info(path: String) -> Info {
  case file_info.read(path) {
    Ok(found) -> Found(found.kind == file_info.Regular, found.size)
    Error(file_info.Missing) -> Missing
    Error(file_info.Unreadable(reason)) ->
      InfoFailed(albedo_file.describe(reason))
  }
}

@external(erlang, "albedo_ext_memory_ffi", "read")
fn read_file(path: String) -> Result(BitArray, ReadError)

@external(erlang, "albedo_ext_memory_ffi", "append")
fn append_file(path: String, bytes: BitArray) -> Result(Nil, String)

/// Replaces a file through a synced, exclusively created temporary file in
/// the same directory.
fn atomic_write(path: String, bytes: BitArray) -> Result(Nil, String) {
  albedo_file.replace(path, bytes, sync: True, mode: None)
  |> result.map_error(fn(error) { albedo_file.describe(error.reason) })
}

@external(erlang, "albedo_ext_memory_ffi", "ensure_path")
fn ensure_path(dir: String) -> Result(Nil, String)

@external(erlang, "albedo_ext_memory_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

fn list_dir(dir: String) -> Result(List(String), ListError) {
  file_info.list(dir)
  |> result.map_error(fn(error) {
    case error {
      file_info.Missing ->
        ListError(True, albedo_file.describe(file_info.reason(error)))
      file_info.Unreadable(reason) ->
        ListError(False, albedo_file.describe(reason))
    }
  })
}

@external(erlang, "albedo_ext_memory_ffi", "journals")
fn journals(root: String) -> List(String)

/// Serializes cooperating callers on one workspace root within the daemon.
/// The lock waits for its turn, so it is never refused; a caller's exit
/// releases it.
fn with_lock(
  root: String,
  run: fn() -> Result(a, String),
) -> Result(a, String) {
  albedo_file.with_lock(root, albedo_file.Forever, run)
  |> result.replace_error("memory workspace lock unavailable")
  |> result.flatten
}

/// The SHA-256 of a value's external term format, which import keys and
/// transfer digests have always used.
@internal
pub fn term_digest(term: a) -> BitArray {
  digest.sha256(term_codec.encode(term))
}

/// An import receipt in the external term format earlier daemons wrote:
/// `{1, {done, Sources}}` or `{1, {pending, Sources, Before, After}}`.
@internal
pub fn encode_receipt(state: Receipt) -> BitArray {
  term_codec.encode(#(1, state))
}

@internal
pub fn decode_receipt(bytes: BitArray) -> Result(Receipt, String) {
  let invalid = "invalid memory import receipt"
  let shape = {
    use term <- result.try(term_codec.decode_safe(bytes))
    use versioned <- result.try(term_codec.tuple(term))
    use state <- result.try(case versioned {
      [version, state] ->
        case decode.run(version, decode.int) {
          Ok(1) -> term_codec.tuple(state)
          _ -> Error(Nil)
        }
      _ -> Error(Nil)
    })
    case state {
      [tag, sources] ->
        case tag_name(tag), list_of(sources) {
          Ok("done"), Ok(sources) ->
            Ok(#(sources, fn(sources) { Done(sources) }))
          _, _ -> Error(Nil)
        }
      [tag, sources, before, after] ->
        case
          tag_name(tag),
          list_of(sources),
          term_codec.binary(before),
          term_codec.binary(after)
        {
          Ok("pending"), Ok(sources), Ok(before), Ok(after) ->
            Ok(#(sources, fn(sources) { Pending(sources, before, after) }))
          _, _, _, _ -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  }
  case shape {
    Error(Nil) -> Error(invalid)
    Ok(#(sources, receipt)) ->
      case list.try_map(sources, source) {
        Ok(sources) -> Ok(receipt(sources))
        Error(Nil) -> Error("invalid memory import sources")
      }
  }
}

fn tag_name(tag: Dynamic) -> Result(String, Nil) {
  decode.run(tag, atom.decoder())
  |> result.map(atom.to_string)
  |> result.replace_error(Nil)
}

fn list_of(value: Dynamic) -> Result(List(Dynamic), Nil) {
  decode.run(value, decode.list(decode.dynamic)) |> result.replace_error(Nil)
}

/// One `{Key, Digest}` pair of binaries.
fn source(value: Dynamic) -> Result(#(BitArray, BitArray), Nil) {
  case term_codec.tuple(value) {
    Ok([key, digest]) ->
      case term_codec.binary(key), term_codec.binary(digest) {
        Ok(key), Ok(digest) -> Ok(#(key, digest))
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}
