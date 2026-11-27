//// The files extension's routes driven as the host drives them: generated
//// JSON arguments through the route the extension declares, a temporary store
//// for uploaded images, and a scripted albedo-fff stdio worker on PATH for
//// files.fff. Oracles come from the routes' documented contracts, not from
//// their code: an argument decoder that names the fields it could not read,
//// before/index preconditions with their own messages, upload lookup by
//// transcript position or by the newest upload, and the worker protocol's
//// value, error, mismatch, and bound answers.

import albedo/history/conversation
import albedo/storage/core_store
import albedo_ext_files
import albedo_model as types
import albedo_sdk/extension
import albedo_sdk/host
import albedo_sdk/location
import albedo_sdk/session_info
import albedo_sdk/storage
import albedo_sdk/store
import albedo_sqlite
import files_route_context as routes
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck

// ---------------------------------------------------------------- the route

fn files_route() -> routes.Handle {
  let extension.Extension(
    name: _,
    description: _,
    requires: _,
    plugins: plugins,
    initialise: _,
    tables: _,
    uses: _,
  ) = albedo_ext_files.extension()
  let found =
    list.flat_map(plugins, fn(plugin) {
      case plugin {
        extension.ToolPlugin(_, _, _, declared) -> declared
        _ -> []
      }
    })
  let assert [#("files", route)] = found
  route
}

/// A fresh session row, so each case starts from an empty transcript.
fn new_session(ledger: store.Store) -> String {
  let id = "s" <> int.to_string(proptest.unique())
  let assert Ok(Nil) =
    storage.query(storage.host(ledger), fn(db) {
      albedo_sqlite.exec(
        "INSERT INTO sessions(id,cwd,model,protocol) VALUES('"
          <> id
          <> "','/tmp','test-model','test-protocol')",
        on: db,
      )
    })
  id
}

/// The transcript sequence of the row the last commit appended.
fn latest_seq(ledger: store.Store, session: String) -> Int {
  let assert Ok(maximum) =
    storage.query(storage.host(ledger), fn(db) {
      albedo_sqlite.first(
        albedo_sqlite.rows(
          "SELECT MAX(seq) FROM transcript WHERE session='" <> session <> "'",
          on: db,
          with: [],
          expecting: decode.field(0, decode.int, decode.success),
        ),
        missing: "transcript maximum",
      )
    })
  maximum
}

// ---------------------------------------------------------------- generators

@external(erlang, "unicode", "characters_to_binary")
fn from_codepoints(codepoints: List(Int)) -> String

/// Text that can hold any UTF-8 the kernel passes through, including the
/// characters a JSON encoder must escape.
fn text() -> qcheck.Generator(String) {
  use length <- qcheck.bind(qcheck.bounded_int(0, 12))
  use codepoints <- qcheck.bind(qcheck.fixed_length_list_from(
    qcheck.from_weighted_generators(#(6, qcheck.bounded_int(97, 122)), [
      #(1, qcheck.bounded_int(32, 126)),
      #(1, qcheck.bounded_int(0x3B1, 0x3C9)),
      #(
        1,
        qcheck.from_generators(qcheck.return(34), [
          qcheck.return(92),
          qcheck.return(10),
        ]),
      ),
    ]),
    length,
  ))
  qcheck.return(from_codepoints(codepoints))
}

fn encode(raw: String) -> String {
  bit_array.base64_encode(bit_array.from_string(raw), True)
}

/// A nonempty payload: an image must carry bytes.
fn image_text() -> qcheck.Generator(String) {
  qcheck.map(text(), fn(value) {
    case value {
      "" -> "x"
      _ -> value
    }
  })
}

fn upload_image(raw: String) -> types.Image {
  let assert Ok(image) =
    types.image("image/png", encode(raw), 1, 1, string.byte_size(raw))
  image
}

/// A transcript row a case commits: prose, or a user row with pictures.
pub type Row {
  Note(String)
  Upload(List(String))
}

fn row() -> qcheck.Generator(Row) {
  qcheck.from_weighted_generators(#(4, qcheck.map(text(), Note)), [
    #(
      4,
      qcheck.map(
        qcheck.generic_list(image_text(), qcheck.bounded_int(1, 3)),
        Upload,
      ),
    ),
  ])
}

fn commit_row(ledger: store.Store, session: String, row: Row) -> Int {
  let inputs = case row {
    Note(body) -> [types.User(body)]
    Upload(images) -> [
      types.UserImage("picture", list.map(images, upload_image)),
    ]
  }
  let assert Ok(_) =
    conversation.commit(ledger, session, inputs, session_info.Idle)
  latest_seq(ledger, session)
}

// ---------------------------------------------------------------- answers

fn answer(
  route: routes.Handle,
  context: host.Context,
  method: String,
  args: json.Json,
) -> String {
  case routes.call(route, context, method, args) {
    Ok(value) -> "value:" <> json.to_string(value)
    Error(#(code, message)) -> "error:" <> code <> ":" <> message
  }
}

fn found_answer(raw: String) -> String {
  "value:" <> json.to_string(json.object([#("data", json.string(encode(raw)))]))
}

fn before_answer(seq: Int) -> String {
  "value:" <> json.to_string(json.object([#("before", json.int(seq))]))
}

const unavailable = "error:image_unavailable:uploaded image not found"

const invalid_types = "error:invalid:entry, index and before must be integers"

// ------------------------------------------------------- argument decoding

/// One JSON argument field as a caller can spell it.
pub type Field {
  Absent
  Null
  Integer(Int)
  Text(String)
  Decimal(Float)
  Truth
  Nested
}

fn field() -> qcheck.Generator(Field) {
  qcheck.from_weighted_generators(
    #(6, qcheck.map(qcheck.bounded_int(-3, 20), Integer)),
    [
      #(2, qcheck.return(Absent)),
      #(2, qcheck.return(Null)),
      #(
        2,
        qcheck.map(
          qcheck.bounded_int(-1_000_000_000_000, 1_000_000_000_000),
          Integer,
        ),
      ),
      #(1, qcheck.map(text(), Text)),
      #(1, qcheck.map(qcheck.bounded_float(-5.0, 5.0), Decimal)),
      #(1, qcheck.return(Truth)),
      #(1, qcheck.return(Nested)),
    ],
  )
}

fn field_json(field: Field) -> json.Json {
  case field {
    Absent | Null -> json.null()
    Integer(value) -> json.int(value)
    Text(value) -> json.string(value)
    Decimal(value) -> json.float(value)
    Truth -> json.bool(True)
    Nested -> json.object([#("x", json.int(1))])
  }
}

fn image_args(entry: Field, index: Field, before: Field) -> json.Json {
  let fields =
    list.filter_map(
      [#("entry", entry), #("index", index), #("before", before)],
      fn(pair) {
        case pair.1 {
          Absent -> Error(Nil)
          other -> Ok(#(pair.0, field_json(other)))
        }
      },
    )
  json.object(fields)
}

/// The transcript position a caller asked for, when it is readable.
fn position_field(field: Field) -> Result(Option(Int), Nil) {
  case field {
    Absent | Null -> Ok(None)
    Integer(value) -> Ok(Some(value))
    _ -> Error(Nil)
  }
}

/// A count argument: absent takes the documented default of zero, and
/// anything that is not an integer is unreadable.
fn count_field(field: Field) -> Result(Int, Nil) {
  case field {
    Absent -> Ok(0)
    Integer(value) -> Ok(value)
    _ -> Error(Nil)
  }
}

const entry_message =
  "error:invalid:entry must be a positive transcript position"

const index_message = "error:invalid:index must be nonnegative"

const before_message = "error:invalid:before must be nonnegative"

/// What the route owes a caller for these argument fields, in an empty
/// session, with a label for behavioural coverage: the decoder's message,
/// the first failed precondition, or a lookup that finds nothing.
fn expect_image(
  entry: Field,
  index: Field,
  before: Field,
) -> #(String, String) {
  case position_field(entry), count_field(index), count_field(before) {
    Ok(position), Ok(index), Ok(before) ->
      case position, index, before {
        Some(position), _, _ if position < 1 -> #("invalid_entry", entry_message)
        _, index, _ if index < 0 -> #("invalid_index", index_message)
        _, _, before if before < 0 -> #("invalid_before", before_message)
        _, _, _ -> #("lookup", unavailable)
      }
    _, _, _ -> #("invalid_types", invalid_types)
  }
}

fn argument_properties(ledger: store.Store, route: routes.Handle) -> Nil {
  let session = new_session(ledger)
  let context = routes.context(ledger, session, "/tmp")
  proptest.check(
    "files.image answers generated arguments with the documented error",
    40,
    qcheck.map3(field(), field(), field(), fn(entry, index, before) {
      #(entry, index, before)
    }),
    fn(input) {
      let #(entry, index, before) = input
      let #(label, expected) = expect_image(entry, index, before)
      proptest.bump(label)
      let actual =
        answer(route, context, "files.image", image_args(entry, index, before))
      case actual == expected {
        True -> Nil
        False ->
          panic as {
            "entry="
            <> field_text(entry)
            <> " index="
            <> field_text(index)
            <> " before="
            <> field_text(before)
            <> " gave "
            <> actual
            <> ", expected "
            <> expected
          }
      }
    },
  )
}

fn field_text(field: Field) -> String {
  case field {
    Absent -> "absent"
    Null -> "null"
    Integer(value) -> "int " <> int.to_string(value)
    Text(value) -> "text " <> string.inspect(value)
    Decimal(value) -> "float " <> string.inspect(value)
    Truth -> "bool"
    Nested -> "object"
  }
}

// ------------------------------------------------------- uploaded images

fn image_properties(ledger: store.Store, route: routes.Handle) -> Nil {
  proptest.check(
    "files.image resolves each committed upload by position and index",
    20,
    qcheck.generic_list(row(), qcheck.bounded_int(1, 4)),
    fn(generated) {
      let session = new_session(ledger)
      let context = routes.context(ledger, session, "/tmp")
      let rows =
        list.map(generated, fn(kind) {
          #(commit_row(ledger, session, kind), kind)
        })
      list.each(rows, fn(entry) {
        let #(seq, kind) = entry
        case kind {
          Note(_) -> {
            proptest.bump("position_prose")
            assert answer(
                route,
                context,
                "files.image",
                json.object([#("entry", json.int(seq)), #("index", json.int(0))]),
              )
              == unavailable
          }
          Upload(images) -> {
            let _ =
              list.index_map(images, fn(raw, index) {
                proptest.bump("position_found")
                assert answer(
                    route,
                    context,
                    "files.image",
                    json.object([
                      #("entry", json.int(seq)),
                      #("index", json.int(index)),
                    ]),
                  )
                  == found_answer(raw)
              })
            proptest.bump("position_past_end")
            assert answer(
                route,
                context,
                "files.image",
                json.object([
                  #("entry", json.int(seq)),
                  #("index", json.int(list.length(images))),
                ]),
              )
              == unavailable
          }
        }
      })
      // A query with no position reads the newest upload in the transcript.
      let newest: Option(#(Int, List(String))) =
        list.fold(rows, None, fn(found, entry) {
          case entry.1 {
            Upload(images) -> Some(#(entry.0, images))
            Note(_) -> found
          }
        })
      case newest {
        None -> {
          proptest.bump("newest_missing")
          assert answer(route, context, "files.image", json.object([]))
            == unavailable
        }
        Some(#(_, images)) -> {
          let _ =
            list.index_map(images, fn(raw, index) {
              proptest.bump("newest_found")
              assert answer(
                  route,
                  context,
                  "files.image",
                  json.object([#("index", json.int(index))]),
                )
                == found_answer(raw)
            })
          proptest.bump("newest_past_end")
          assert answer(
              route,
              context,
              "files.image",
              json.object([#("index", json.int(list.length(images)))]),
            )
            == unavailable
        }
      }
      Nil
    },
  )
}

// ------------------------------------------------------- upload paging

/// The numbers from `count` down to one.
fn numbers(count: Int) -> List(Int) {
  case count {
    0 -> []
    _ -> [count, ..numbers(count - 1)]
  }
}

/// One page holds 64 candidate rows, so a transcript whose first page holds
/// only prose that mentions `user_image` must answer with the position to
/// resume from, and the resume must find the uploads the page skipped. An index
/// selects among the images of the newest row that holds any, not across rows.
fn paging_properties(ledger: store.Store, route: routes.Handle) -> Nil {
  let session = new_session(ledger)
  let context = routes.context(ledger, session, "/tmp")
  let older = commit_row(ledger, session, Upload(["older-image"]))
  let newer = commit_row(ledger, session, Upload(["newer-one", "newer-two"]))
  let prose =
    list.map(numbers(64), fn(index) {
      commit_row(
        ledger,
        session,
        Note("user_image prose " <> int.to_string(index)),
      )
    })
  let assert [first_candidate, ..] = prose
  assert answer(route, context, "files.image", json.object([]))
    == before_answer(first_candidate)
  let resumed = json.object([#("before", json.int(first_candidate))])
  assert answer(route, context, "files.image", resumed)
    == found_answer("newer-one")
  assert answer(
      route,
      context,
      "files.image",
      json.object([
        #("before", json.int(first_candidate)),
        #("index", json.int(1)),
      ]),
    )
    == found_answer("newer-two")
  assert answer(
      route,
      context,
      "files.image",
      json.object([
        #("before", json.int(first_candidate)),
        #("index", json.int(2)),
      ]),
    )
    == unavailable
  // Resuming before the newer upload reaches the older one.
  assert answer(
      route,
      context,
      "files.image",
      json.object([#("before", json.int(newer))]),
    )
    == found_answer("older-image")
  let _ = older
  Nil
}

// ------------------------------------------------------- the FFF worker

@external(erlang, "file", "make_dir")
fn make_dir(path: String) -> Dynamic

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> Dynamic

@external(erlang, "file", "change_mode")
fn change_mode(path: String, mode: Int) -> Dynamic

@external(erlang, "proptest_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "files_fff_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "files_fff_ffi", "same_json")
fn same_json(left: String, right: String) -> Bool

@external(erlang, "albedo_fff", "search")
fn fff_search(
  key: String,
  argv: List(String),
  auth: Option(String),
  args: Dynamic,
) -> Result(String, String)

/// A stdio worker that logs each request line and answers with the current
/// reply file, then exits when the exit file names a code.
fn worker_script(log: String, reply: String, exit_file: String) -> String {
  let assert Ok(python) = proptest.executable("python3")
  string.join(
    [
      "#!" <> python,
      "import sys",
      "LOG = \"" <> log <> "\"",
      "REPLY = \"" <> reply <> "\"",
      "EXIT = \"" <> exit_file <> "\"",
      "out = open(LOG, \"ab\", buffering=0)",
      "for line in sys.stdin.buffer:",
      "    out.write(line if line.endswith(b\"\\n\") else line + b\"\\n\")",
      "    try:",
      "        data = open(REPLY, \"rb\").read()",
      "    except FileNotFoundError:",
      "        data = b\"\"",
      "    if data:",
      "        sys.stdout.buffer.write(data)",
      "        sys.stdout.buffer.flush()",
      "    try:",
      "        code = int(open(EXIT).read().strip())",
      "    except (FileNotFoundError, ValueError):",
      "        code = None",
      "    if code is not None:",
      "        sys.exit(code)",
      "",
    ],
    "\n",
  )
}

fn install_worker(
  dir: String,
  log: String,
  reply: String,
  exit_file: String,
) -> Nil {
  let path = dir <> "/albedo-fff"
  proptest.write_file(
    path,
    bit_array.from_string(worker_script(log, reply, exit_file)),
    0,
  )
  let _ = change_mode(path, 0o755)
  Nil
}

fn set_reply(path: String, text: String) -> Nil {
  proptest.write_file(path, bit_array.from_string(text), 0)
  Nil
}

fn last_line(content: String) -> String {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
  |> list.last
  |> result.unwrap("")
}

fn line_count(content: String) -> Int {
  content
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
  |> list.length
}

fn response(value: json.Json) -> String {
  json.to_string(
    json.object([
      #("protocol", json.int(1)),
      #("ok", json.bool(True)),
      #("value", value),
    ]),
  )
  <> "\n"
}

/// Argument fields a caller can send the search route.
fn fff_args() -> qcheck.Generator(List(#(String, json.Json))) {
  use op <- qcheck.bind(qcheck.option_from(text()))
  use query <- qcheck.bind(qcheck.option_from(text()))
  use path <- qcheck.bind(qcheck.option_from(text()))
  qcheck.return(
    list.filter_map([#("op", op), #("query", query), #("path", path)], fn(pair) {
      case pair.1 {
        None -> Error(Nil)
        Some(value) -> Ok(#(pair.0, json.string(value)))
      }
    }),
  )
}

fn value() -> qcheck.Generator(json.Json) {
  qcheck.from_weighted_generators(
    #(4, qcheck.map(qcheck.bounded_int(-1000, 1000), json.int)),
    [
      #(4, qcheck.map(text(), json.string)),
      #(1, qcheck.return(json.bool(True))),
      #(1, qcheck.return(json.null())),
    ],
  )
}

fn fff_properties(
  ledger: store.Store,
  route: routes.Handle,
  home: String,
) -> Nil {
  let dir = home <> "/worker"
  let _ = make_dir(dir)
  let log = home <> "/requests"
  let reply = home <> "/reply"
  let exit_file = home <> "/exit"
  install_worker(dir, log, reply, exit_file)
  let old_path = getenv("PATH") |> result.unwrap("")
  proptest.putenv("PATH", dir <> ":" <> old_path)
  let context = routes.context(ledger, "fff-session", "/tmp")

  proptest.check(
    "files.fff answers with the worker's value and forwards the arguments",
    25,
    qcheck.map2(fff_args(), value(), fn(args, value) { #(args, value) }),
    fn(input) {
      let #(args, value) = input
      set_reply(reply, response(value))
      let before = case read_file(log) {
        Ok(content) -> line_count(content)
        Error(_) -> 0
      }
      let assert Ok(returned) =
        routes.call(route, context, "files.fff", json.object(args))
      proptest.bump("value")
      assert same_json(json.to_string(returned), json.to_string(value))
      let assert Ok(logged) = read_file(log)
      assert line_count(logged) == before + 1
      assert same_json(
        last_line(logged),
        json.to_string(json.object([#("protocol", json.int(1)), ..args])),
      )
    },
  )

  proptest.check(
    "files.fff reports the worker's error message",
    20,
    text(),
    fn(message) {
      set_reply(
        reply,
        json.to_string(
          json.object([
            #("protocol", json.int(1)),
            #("ok", json.bool(False)),
            #("error", json.string(message)),
          ]),
        )
          <> "\n",
      )
      proptest.bump("worker_error")
      assert answer(
          route,
          context,
          "files.fff",
          json.object([#("op", json.string("find"))]),
        )
        == "error:fff:" <> message
    },
  )

  proptest.check(
    "files.fff refuses a worker answer that is not protocol 1",
    15,
    qcheck.from_generators(
      qcheck.map(qcheck.bounded_int(2, 9), fn(protocol) {
        json.object([
          #("protocol", json.int(protocol)),
          #("ok", json.bool(True)),
        ])
      }),
      [
        qcheck.map(qcheck.bounded_int(2, 9), fn(protocol) {
          json.object([
            #("protocol", json.int(protocol)),
            #("ok", json.bool(True)),
            #("value", json.int(1)),
          ])
        }),
        qcheck.return(json.object([#("ok", json.bool(True))])),
      ],
    ),
    fn(payload) {
      set_reply(reply, json.to_string(payload) <> "\n")
      proptest.bump("protocol_mismatch")
      assert answer(
          route,
          context,
          "files.fff",
          json.object([#("op", json.string("find"))]),
        )
        == "error:fff:FFF protocol mismatch"
    },
  )

  proptest.check(
    "files.fff refuses a worker answer that is not JSON",
    5,
    text(),
    fn(garbage) {
      set_reply(reply, garbage <> "\n")
      proptest.bump("invalid_json")
      assert answer(
          route,
          context,
          "files.fff",
          json.object([#("op", json.string("find"))]),
        )
        == "error:fff:FFF worker returned invalid JSON"
    },
  )

  proptest.check(
    "files.fff bounds a request before it reaches the worker",
    1,
    qcheck.return(Nil),
    fn(_) {
      let before = case read_file(log) {
        Ok(content) -> line_count(content)
        Error(_) -> 0
      }
      let huge = string.repeat("x", 1_048_577)
      proptest.bump("oversize")
      assert answer(
          route,
          context,
          "files.fff",
          json.object([#("query", json.string(huge))]),
        )
        == "error:fff:FFF request exceeds 1 MiB bound"
      let assert Ok(logged) = read_file(log)
      assert line_count(logged) == before
    },
  )

  proptest.check(
    "albedo_fff refuses arguments that are not an object",
    15,
    value(),
    fn(value) {
      let assert Ok(dynamic) = json.parse(json.to_string(value), decode.dynamic)
      proptest.bump("not_an_object")
      assert fff_search("local", [], None, dynamic)
        == Error("invalid FFF arguments")
    },
  )

  proptest.check(
    "albedo_fff forwards arguments without the routing target",
    15,
    fff_args(),
    fn(pairs) {
      set_reply(
        reply,
        response(json.object([#("paths", json.array([], json.string))])),
      )
      let args =
        json.object([#("_fff_target", json.string("some-target")), ..pairs])
      let assert Ok(dynamic) = json.parse(json.to_string(args), decode.dynamic)
      let assert Ok(_) = fff_search("local", [], None, dynamic)
      let assert Ok(logged) = read_file(log)
      proptest.bump("target_stripped")
      assert same_json(
        last_line(logged),
        json.to_string(json.object([#("protocol", json.int(1)), ..pairs])),
      )
    },
  )
  Nil
}

// ------------------------------------------------------- search targets

/// A workspace on another host searches there, and a local workspace searches
/// locally unless the kernel names the host it moved to. The target the route
/// must name is the location's own ssh spelling, which `sdk/location` already
/// property-tests; a host that cannot be reached answers with the target
/// spelled out, so the message shows which target the route resolved.
fn remote_properties(ledger: store.Store, route: routes.Handle) -> Nil {
  proptest.check(
    "files.fff names the target it resolves from the workspace",
    1,
    qcheck.return([
      #("proptest.invalid:/work", None),
      #("someone@proptest.invalid:/work", None),
      #("/tmp", Some("proptest.invalid")),
    ]),
    fn(cases) {
      list.each(cases, fn(entry) {
        let #(workspace, override) = entry
        let context = routes.context(ledger, "target-session", workspace)
        let args = case override {
          Some(target) -> json.object([#("_fff_target", json.string(target))])
          None -> json.object([#("op", json.string("paths"))])
        }
        let expected = case override, location.parse(workspace) {
          Some(target), _ -> target
          None, Ok(at) -> location.ssh_target(at) |> result.unwrap("")
          None, Error(_) -> ""
        }
        proptest.bump("target_" <> workspace)
        let answer = answer(route, context, "files.fff", args)
        case
          string.starts_with(answer, "error:fff:")
          && string.contains(answer, expected)
        {
          True -> Nil
          False ->
            panic as {
              "workspace "
              <> workspace
              <> " gave "
              <> answer
              <> ", expected the target "
              <> expected
            }
        }
      })
    },
  )
}

/// Arguments the kernel can pass but no route can read, and methods the
/// extension does not serve: each route must answer with its documented
/// error rather than crash, and never reach the worker.
fn shape_properties(ledger: store.Store, route: routes.Handle) -> Nil {
  let context = routes.context(ledger, new_session(ledger), "/tmp")
  proptest.check(
    "files routes refuse arguments that are not an object",
    15,
    value(),
    fn(garbage) {
      proptest.bump("not_an_object")
      assert answer(route, context, "files.image", garbage)
        == "error:invalid:entry, index and before must be integers"
      // The search route carries one code for everything its worker call
      // answers, so only the message says what was unreadable.
      assert routes.call(route, context, "files.fff", garbage)
        == Error(#("fff", "invalid FFF host"))
    },
  )
  proptest.check(
    "files routes refuse an operation they do not serve",
    10,
    text(),
    fn(method) {
      let method = "files.unknown " <> method
      proptest.bump("unknown_method")
      assert answer(route, context, method, json.object([]))
        == "error:unavailable:unknown files operation"
    },
  )
  Nil
}

pub fn main() -> Nil {
  let home = "/tmp/albedo-proptest-files-" <> int.to_string(proptest.unique())
  let _ = make_dir(home)
  let assert Ok(ledger) =
    store.start(home <> "/files.db", fn(_) { Ok(Nil) }, core_store.tables())
  let assert Ok(Nil) = conversation.initialise(ledger)
  let route = files_route()
  argument_properties(ledger, route)
  shape_properties(ledger, route)
  image_properties(ledger, route)
  paging_properties(ledger, route)
  fff_properties(ledger, route, home)
  remote_properties(ledger, route)
  store.close(ledger)
  let _ = del_dir_r(home)
  Nil
}
