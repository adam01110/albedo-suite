//// Lazy MCP idle expiry against a per-server model: fake stdio servers with
//// a zero timeout, their own timeouts and the session default, driven through
//// generated loads, calls, a killed transport and idle waits. The manager
//// reads the monotonic clock directly and has no tick message, so every
//// time-dependent expectation is a bound measured around the request:
//// certainly expired, certainly connected, or undetermined, and the coverage
//// counters report how often each held. Load history ordering is checked
//// separately because `first_at` counts whole seconds.

import albedo/composition/mcp_owner_support
import albedo/lifecycle/host_install
import albedo/storage/core_store
import albedo_clock
import albedo_ext_mcp/lazy
import albedo_ext_mcp/loads
import albedo_sdk/capabilities
import albedo_sdk/extension
import albedo_sdk/page
import albedo_sdk/storage
import albedo_sdk/store
import albedo_sdk/worktree
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck

const short_name = "short"

const long_name = "long"

const keep_name = "keep"

const unused_name = "unused"

const disabled_name = "disabled"

/// One generated scenario: the timeouts in use, the servers to load and in
/// which order, whether the stateful server's transport is killed, the calls
/// made while everyone is fresh, and whether the expired server is redialled
/// by a load or by a call.
pub type Case {
  Case(
    short_ms: Int,
    long_ms: Int,
    loads: List(String),
    kill_keep: Bool,
    calls: List(String),
    redial_by_load: Bool,
  )
}

/// What the test knows about one server: whether it ever loaded, how many
/// client processes it started, the bounds around the request that last used
/// it, and whether its transport was killed.
type Server {
  Server(
    name: String,
    timeout: Int,
    loaded: Bool,
    connects: Int,
    used: Option(#(Int, Int)),
    killed: Bool,
  )
}

/// Whether a server must be connected, must not be, or the measurement is too
/// close to its deadline to decide.
type Reach {
  Broken
  Closed
  Undetermined
}

/// What a use must do to its server's transport.
type Expect {
  /// Certainly connected: no new client, one dispatch.
  Refresh
  /// Certainly idle: one new client, one dispatch.
  Redial
  /// Transport dropped: refused before dispatch, no new client.
  Refuse
  /// Too close to the deadline: a dispatch and at most one new client.
  Eager
}

type Use {
  Call
  Load
}

pub fn main() -> Nil {
  host_install.install()
  let home =
    "/tmp/albedo-proptest-mcp-idle-" <> int.to_string(proptest.unique())
  proptest.putenv("ALBEDO_HOME", home)
  proptest.remove_tree(home)
  let _ = make_dir(home)
  let assert Ok(ledger) =
    store.start(home <> "/preferences.db", "", core_store.tables())
  let scope = storage.host(ledger)
  let assert Ok(Nil) =
    storage.query(scope, fn(db) {
      storage.exec(db, "CREATE TABLE sessions(id TEXT PRIMARY KEY);")
    })
  let assert Ok(Nil) = loads.initialise(scope)
  proptest.check(
    "lazy MCP idle expiry follows a per-server model",
    20,
    case_generator(),
    fn(scenario) { run_case(home, scope, scenario) },
  )
  proptest.check(
    "MCP load history follows record, reset and forget",
    15,
    qcheck.generic_list(history_op(), qcheck.bounded_int(1, 12)),
    fn(ops) { history(scope, ops) },
  )
  proptest.check(
    "MCP load history keeps each server's first place",
    3,
    qcheck.generic_list(
      qcheck.generic_string(
        qcheck.alphanumeric_ascii_codepoint(),
        qcheck.bounded_int(1, 6),
      ),
      qcheck.bounded_int(2, 3),
    ),
    fn(names) { first_places(scope, names) },
  )
  store.close(ledger)
  proptest.remove_tree(home)
  Nil
}

// The idle property.

fn case_generator() -> qcheck.Generator(Case) {
  qcheck.map2(
    qcheck.tuple2(qcheck.bounded_int(250, 400), qcheck.bounded_int(1200, 1600)),
    qcheck.tuple4(
      qcheck.generic_list(role(), qcheck.bounded_int(1, 3)),
      qcheck.bool(),
      qcheck.generic_list(role(), qcheck.bounded_int(0, 3)),
      qcheck.bool(),
    ),
    fn(times, flags) {
      let #(short_ms, long_ms) = times
      let #(order, kill_keep, calls, redial_by_load) = flags
      let order = list.unique(order)
      let loads = case list.contains(order, short_name) {
        True -> order
        False -> list.append(order, [short_name])
      }
      Case(
        short_ms: short_ms,
        long_ms: long_ms,
        loads: loads,
        kill_keep: kill_keep && list.contains(loads, keep_name),
        calls: list.filter(calls, fn(name) { list.contains(loads, name) }),
        redial_by_load: redial_by_load,
      )
    },
  )
}

fn role() -> qcheck.Generator(String) {
  pick([short_name, short_name, long_name, keep_name])
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn run_case(home: String, scope: storage.Storage, scenario: Case) -> Nil {
  let session = "idle-" <> int.to_string(proptest.unique())
  let assert Ok(Nil) =
    storage.query(scope, fn(db) {
      storage.exec(db, "INSERT INTO sessions(id) VALUES('" <> session <> "');")
    })
  let controls =
    [short_name, long_name, keep_name, unused_name, disabled_name]
    |> list.map(fn(name) {
      let dir = home <> "/" <> session <> "-" <> name
      let _ = make_dir(dir)
      #(name, dir)
    })
    |> dict.from_list
  let runtime = mcp_owner_support.start_runtime()
  let assert Ok(#(manager, _)) =
    lazy.prepare(
      config(scenario, controls),
      preferences,
      scope,
      session,
      extension.preparation_owner(runtime.pid),
    )
  let assert Ok(Nil) =
    mcp_owner_support.on_runtime(runtime, fn() { lazy.adopt(manager) })
  let source = lazy.Managed(manager)
  let blank = fn(name, timeout) {
    #(name, Server(name, timeout, False, 0, None, False))
  }
  let initial =
    [
      blank(short_name, scenario.short_ms),
      blank(long_name, scenario.long_ms),
      blank(keep_name, 0),
      blank(unused_name, 0),
    ]
    |> dict.from_list
  // Preparation contacts nothing, loads nothing and lists no disabled server.
  observe(source, initial, controls)
  assert definitions(source) == "[]"
  let assert Error(_) = lazy.load(source, unused_name <> "-nope")
  let assert Error(_) = lazy.load(source, disabled_name)
  // Loads in the generated order: each starts exactly one client.
  let loaded =
    list.fold(scenario.loads, initial, fn(servers, name) {
      use_server(source, servers, controls, name, Load)
    })
  observe(source, loaded, controls)
  assert sort_rows(sidebar(scope, session)) == expected_rows(scenario.loads)
  let definitions_before = definitions(source)
  // Calls on fresh servers never start another client.
  let called =
    list.fold(scenario.calls, loaded, fn(servers, name) {
      use_server(source, servers, controls, name, Call)
    })
  // A killed transport is refused until an explicit load redials it, and a
  // zero timeout keeps the drop from becoming idle cleanup.
  let dropped = case scenario.kill_keep {
    True -> {
      let killed = kill(source, controls, called, keep_name)
      observe(source, killed, controls)
      let refused = use_server(source, killed, controls, keep_name, Call)
      use_server(source, refused, controls, keep_name, Load)
    }
    False -> called
  }
  // Two short waits with a call between them: the call refreshes the last
  // use, so the server outlives its own timeout without a new client.
  process.sleep(scenario.short_ms * 2 / 5)
  let refreshed = use_server(source, dropped, controls, short_name, Call)
  process.sleep(scenario.short_ms * 2 / 5)
  observe(source, refreshed, controls)
  // Past the short timeout but not the long one: exactly the short server is
  // closed, its schemas and its history stay, and no listing redials.
  process.sleep(scenario.short_ms + 120)
  // The manager's own deadline wake-up ends the transport, before any request
  // from here could tick it.
  await_dead(
    server_pid(get(controls, short_name, "")),
    100,
    "idle cleanup did not close the transport at its deadline",
  )
  proptest.bump("deadline_wakeup")
  observe(source, refreshed, controls)
  assert definitions(source) == definitions_before
  assert sort_rows(sidebar(scope, session)) == expected_rows(scenario.loads)
  // Redial after expiry: one new client, one dispatch, no replay.
  let redialled = case scenario.redial_by_load {
    True -> use_server(source, refreshed, controls, short_name, Load)
    False -> use_server(source, refreshed, controls, short_name, Call)
  }
  observe(source, redialled, controls)
  // Closing the session stops every server it still holds.
  let live =
    [short_name, long_name, keep_name]
    |> list.filter(fn(name) {
      let assert Ok(server) = dict.get(redialled, name)
      server.loaded && !server.killed
    })
    |> list.map(fn(name) { server_pid(get(controls, name, "")) })
  lazy.close(manager)
  list.each(live, fn(pid) {
    await_dead(pid, 100, "a closed session left an MCP server running")
  })
  mcp_owner_support.kill_wait(runtime.pid)
}

/// Whether `server` must be connected at an observation whose request was
/// sent at `sent` and answered at `answered`. Loads and calls stamp the
/// manager's last use inside the request, so `sent` is a lower bound for it
/// and the reply's arrival an upper one.
fn reach(server: Server, sent: Int, answered: Int) -> Reach {
  case server.loaded, server.killed, server.timeout, server.used {
    False, _, _, _ -> Closed
    _, True, _, _ -> Closed
    _, _, 0, _ -> Broken
    _, _, timeout, Some(#(lower, upper)) ->
      case sent - upper >= timeout {
        True -> Closed
        False ->
          case answered - lower < timeout {
            True -> Broken
            False -> Undetermined
          }
      }
    _, _, _, None -> Undetermined
  }
}

/// Configured servers' state as JSON: loaded (schemas kept) and connected.
fn listing(source: lazy.Source) -> Dict(String, #(Bool, Bool)) {
  let assert Ok(listed) =
    json.parse(
      lazy.servers(source),
      decode.list({
        use name <- decode.field("name", decode.string)
        use loaded <- decode.field("loaded", decode.bool)
        use connected <- decode.field("connected", decode.bool)
        decode.success(#(name, #(loaded, connected)))
      }),
    )
  dict.from_list(listed)
}

/// Reads the manager's view once and compares it with the model, including
/// the transport process each decided state implies: a connected server's
/// process runs, and idle cleanup or a kill ends it.
fn observe(
  source: lazy.Source,
  servers: Dict(String, Server),
  controls: Dict(String, String),
) -> Nil {
  let sent = albedo_clock.monotonic_ms()
  let listed = listing(source)
  let answered = albedo_clock.monotonic_ms()
  dict.each(servers, fn(name, server) {
    let #(loaded, connected) =
      dict.get(listed, name) |> result.unwrap(#(False, False))
    assert loaded == server.loaded
    let pid = case server.loaded {
      True -> server_pid(get(controls, name, ""))
      False -> ""
    }
    case reach(server, sent, answered) {
      Broken -> {
        proptest.bump("certain_connected")
        assert connected
        assert alive(pid)
      }
      Closed -> {
        proptest.bump("certain_closed")
        assert !connected
        // Closed by idle cleanup or by a kill: either way its process ends,
        // though a closed stdio port lets the server exit on its own time.
        await_dead(pid, 100, "a closed MCP transport outlived its close")
      }
      // Too close to the deadline to decide: only the flags above hold.
      Undetermined -> proptest.bump("undetermined")
    }
  })
  // The disabled server never appears.
  assert dict.get(listed, disabled_name) == Error(Nil)
}

/// Runs one call or load and checks the transport accounting. The expectation
/// comes from the same measured bounds, and the fake server's seen log is the
/// oracle: handshakes are client starts and `tools/call` lines are dispatches.
fn use_server(
  source: lazy.Source,
  servers: Dict(String, Server),
  controls: Dict(String, String),
  name: String,
  action: Use,
) -> Dict(String, Server) {
  let assert Ok(server) = dict.get(servers, name)
  let control = get(controls, name, "")
  let before_init = seen(control, "initialize")
  let before_call = seen(control, "tools/call")
  assert before_init == server.connects
  // The advertised name is read before the measured window opens so an
  // interleaved definitions request cannot tick the manager inside it.
  let tool = case action {
    Call -> advertised(source, name)
    Load -> ""
  }
  let sent = albedo_clock.monotonic_ms()
  let answer = case action {
    Call -> lazy.call(source, tool, "{\"message\":\"hi\"}")
    Load -> lazy.load(source, name)
  }
  // The manager stamps the last use after it replies, so one more serialized
  // request establishes the upper bound: its touch has run by this reply.
  let _ = listing(source)
  let answered = albedo_clock.monotonic_ms()
  let after_init = seen(control, "initialize")
  let after_call = seen(control, "tools/call")
  let dispatched = case action {
    Call -> 1
    Load -> 0
  }
  let expect = server_expectation(server, reach(server, sent, answered), action)
  case expect {
    Refresh -> {
      proptest.bump("use_refresh")
      let assert Ok(_) = answer
      assert after_init == before_init
      assert after_call == before_call + dispatched
      dict.insert(
        servers,
        name,
        Server(..server, loaded: True, used: Some(#(sent, answered))),
      )
    }
    Redial -> {
      proptest.bump("use_redial")
      let assert Ok(_) = answer
      assert after_init == before_init + 1
      assert after_call == before_call + dispatched
      dict.insert(
        servers,
        name,
        Server(
          ..server,
          loaded: True,
          connects: after_init,
          used: Some(#(sent, answered)),
          killed: False,
        ),
      )
    }
    Refuse -> {
      proptest.bump("use_refused")
      let assert Error(reason) = answer
      assert string.contains(reason, "mcp.load")
      assert after_init == before_init
      assert after_call == before_call
      servers
    }
    Eager -> {
      proptest.bump("use_eager")
      let assert Ok(_) = answer
      assert after_init - before_init <= 1
      assert after_call == before_call + dispatched
      dict.insert(
        servers,
        name,
        Server(
          ..server,
          loaded: True,
          connects: after_init,
          used: Some(#(sent, answered)),
          killed: False,
        ),
      )
    }
  }
}

fn server_expectation(server: Server, reach: Reach, action: Use) -> Expect {
  case reach, server.killed, action {
    Broken, _, _ -> Refresh
    // An explicit load redials a dropped transport; a call is refused.
    Closed, True, Load -> Redial
    Closed, True, Call -> Refuse
    // Idle cleanup keeps the schemas, so any use reconnects.
    Closed, False, _ ->
      case server.loaded {
        True -> Redial
        False -> Eager
      }
    Undetermined, _, _ -> Eager
  }
}

fn kill(
  source: lazy.Source,
  controls: Dict(String, String),
  servers: Dict(String, Server),
  name: String,
) -> Dict(String, Server) {
  proptest.bump("kill")
  let assert Ok(server) = dict.get(servers, name)
  let pid = server_pid(get(controls, name, ""))
  let _ = os_cmd(charlist("kill -9 " <> pid))
  await_dead(pid, 100, "a killed MCP server outlived its kill")
  // An unexpected death reaches the manager with the port's exit, after the
  // OS process ends, so wait for that record before the model calls it dead.
  await_disconnected(source, name, albedo_clock.monotonic_ms() + 5000)
  dict.insert(servers, name, Server(..server, killed: True))
}

/// Waits until the manager reports `name` disconnected, or fails: a dropped
/// transport is recorded when its client observes the port's exit.
fn await_disconnected(source: lazy.Source, name: String, deadline: Int) -> Nil {
  let connected =
    dict.get(listing(source), name) |> result.map(fn(state) { state.1 })
  case connected {
    Ok(True) -> {
      assert albedo_clock.monotonic_ms() < deadline
        as "the manager recorded a dropped MCP transport"
      process.sleep(10)
      await_disconnected(source, name, deadline)
    }
    _ -> Nil
  }
}

fn config(scenario: Case, controls: Dict(String, String)) -> String {
  let servers =
    json.object([
      #(
        short_name,
        fixture(get(controls, short_name, ""), True, [
          #("idleTimeoutMs", json.int(scenario.short_ms)),
        ]),
      ),
      #(long_name, fixture(get(controls, long_name, ""), True, [])),
      #(
        keep_name,
        fixture(get(controls, keep_name, ""), True, [
          #("idleTimeoutMs", json.int(0)),
        ]),
      ),
      #(unused_name, fixture(get(controls, unused_name, ""), True, [])),
      #(disabled_name, fixture(get(controls, disabled_name, ""), False, [])),
    ])
  json.object([
    #("servers", servers),
    #("retryMs", json.int(30_000)),
    #("idleTimeoutMs", json.int(scenario.long_ms)),
  ])
  |> json.to_string
}

fn fixture(
  control: String,
  enabled: Bool,
  fields: List(#(String, json.Json)),
) -> json.Json {
  let #(python, script) = fake_server()
  json.object([
    #("type", json.string("stdio")),
    #("command", json.string(python)),
    #("args", json.array([script], json.string)),
    #("env", json.object([#("FAKE_MCP_CONTROL", json.string(control))])),
    #("startupTimeoutMs", json.int(30_000)),
    #("callTimeoutMs", json.int(30_000)),
    #("enabled", json.bool(enabled)),
    ..fields
  ])
}

fn preferences() -> Result(capabilities.Preferences, String) {
  Ok(capabilities.unscoped())
}

fn get(d: Dict(String, a), key: String, default: a) -> a {
  dict.get(d, key) |> result.unwrap(default)
}

fn at(values: List(a), index: Int) -> a {
  case list.drop(values, index) |> list.first {
    Ok(value) -> value
    Error(Nil) -> panic as "index out of range"
  }
}

/// The advertised name of `server`'s tool, from the loaded schemas.
fn advertised(source: lazy.Source, server: String) -> String {
  let assert Ok(found) =
    json.parse(
      lazy.definitions(source),
      decode.list({
        use name <- decode.field("name", decode.string)
        use owner <- decode.field("server", decode.string)
        decode.success(#(name, owner))
      }),
    )
  case list.find(found, fn(entry) { entry.1 == server }) {
    Ok(entry) -> entry.0
    Error(Nil) ->
      panic as { "loaded server " <> server <> " advertises no tool" }
  }
}

fn definitions(source: lazy.Source) -> String {
  lazy.definitions(source)
}

// Load history.

type HistoryOp {
  Note(session: Int, name: String, loaded: Bool)
  Reopen(session: Int)
  Forget(session: Int)
}

fn history_op() -> qcheck.Generator(HistoryOp) {
  qcheck.from_weighted_generators(
    #(6, qcheck.map3(session(), name(), qcheck.bool(), Note)),
    [
      #(2, qcheck.map(session(), Reopen)),
      #(1, qcheck.map(session(), Forget)),
    ],
  )
}

fn session() -> qcheck.Generator(Int) {
  qcheck.bounded_int(0, 1)
}

fn name() -> qcheck.Generator(String) {
  qcheck.map(
    qcheck.generic_string(
      qcheck.lowercase_ascii_codepoint(),
      qcheck.bounded_int(1, 4),
    ),
    fn(text) { string.replace(text, "/", "_") },
  )
}

/// Record, reset and forget over two sessions, compared with an independent
/// model of each session's rows. Rows are compared as multisets because
/// `first_at` counts whole seconds, so rows recorded in one second tie.
fn history(scope: storage.Storage, ops: List(HistoryOp)) -> Nil {
  let sessions = [
    "h0-" <> int.to_string(proptest.unique()),
    "h1-" <> int.to_string(proptest.unique()),
  ]
  list.each(sessions, fn(session) {
    let assert Ok(Nil) =
      storage.query(scope, fn(db) {
        storage.exec(
          db,
          "INSERT INTO sessions(id) VALUES('" <> session <> "');",
        )
      })
  })
  let start: Dict(Int, List(#(String, Bool))) =
    dict.from_list([#(0, []), #(1, [])])
  list.fold(ops, start, fn(model, op) {
    let index = case op {
      Note(session, _, _) -> session
      Reopen(session) -> session
      Forget(session) -> session
    }
    let target = at(sessions, index)
    let applied = case op {
      Note(_, name, loaded) -> loads.record(scope, target, name, loaded)
      Reopen(_) -> loads.reset(scope, target)
      Forget(_) -> storage.query(scope, fn(db) { loads.forget(db, target) })
    }
    let assert Ok(Nil) = applied
    let rows = dict.get(model, index) |> result.unwrap([])
    let rows = case op {
      Note(_, name, loaded) ->
        case list.key_find(rows, name) {
          Ok(_) ->
            list.map(rows, fn(row) {
              case row.0 == name {
                True -> #(name, loaded)
                False -> row
              }
            })
          Error(_) -> list.append(rows, [#(name, loaded)])
        }
      Reopen(_) -> list.map(rows, fn(row) { #(row.0, False) })
      Forget(_) -> []
    }
    let model = dict.insert(model, index, rows)
    list.each([0, 1], fn(other) {
      let found =
        loads.list(scope, at(sessions, other))
        |> result.unwrap([])
        |> list.map(fn(row) { #(row.server, row.loaded) })
      let expected = dict.get(model, other) |> result.unwrap([])
      assert row_set(found) == row_set(expected)
    })
    model
  })
  Nil
}

/// Each server keeps the place its first load gave it: rows recorded a second
/// apart stay in insertion order across later records and a reset, even when
/// name order differs.
fn first_places(scope: storage.Storage, names: List(String)) -> Nil {
  let names =
    list.unique(
      list.map(names, fn(name) { "p" <> string.replace(name, "/", "_") }),
    )
  let session = "p-" <> int.to_string(proptest.unique())
  let assert Ok(Nil) =
    storage.query(scope, fn(db) {
      storage.exec(db, "INSERT INTO sessions(id) VALUES('" <> session <> "');")
    })
  list.each(names, fn(name) {
    let assert Ok(Nil) = loads.record(scope, session, name, True)
    process.sleep(1100)
  })
  // Later records and a reset keep the first places and update the flags.
  list.each(list.reverse(names), fn(name) {
    let assert Ok(Nil) = loads.record(scope, session, name, False)
  })
  let assert Ok(Nil) = loads.reset(scope, session)
  let found =
    loads.list(scope, session)
    |> result.unwrap([])
    |> list.map(fn(row) { #(row.server, row.loaded) })
  assert found == list.map(names, fn(name) { #(name, False) })
  proptest.bump("first_places_" <> int.to_string(list.length(names)))
  Nil
}

/// The session's sidebar rows: name, badge and tone.
fn sidebar(
  scope: storage.Storage,
  session: String,
) -> List(#(String, String, page.Tone)) {
  let assert Ok(glance) =
    loads.sidebar(extension.Sidebar(session, "", worktree.no_origins(), scope))
  assert glance.title == "mcp"
  list.map(glance.rows, fn(row) { #(row.text, row.badge, row.tone) })
}

/// The rows in name order, so a second boundary cannot reorder them.
fn sort_rows(
  rows: List(#(String, String, page.Tone)),
) -> List(#(String, String, page.Tone)) {
  list.sort(rows, fn(left, right) { string.compare(left.0, right.0) })
}

/// The row multiset in name order.
fn row_set(rows: List(#(String, Bool))) -> List(#(String, Bool)) {
  list.sort(rows, fn(left, right) { string.compare(left.0, right.0) })
}

/// Every loaded server's active row, in name order.
fn expected_rows(loaded: List(String)) -> List(#(String, String, page.Tone)) {
  loaded
  |> list.unique
  |> list.sort(string.compare)
  |> list.map(fn(name) { #(name, "loaded", page.Active) })
}

// Fixtures.

fn seen(control: String, method: String) -> Int {
  read(control <> "/seen")
  |> result.unwrap("")
  |> string.split("\n")
  |> list.filter(fn(line) { line == method })
  |> list.length
}

fn server_pid(control: String) -> String {
  let assert Ok(pid) = read(control <> "/pid")
  string.trim(pid)
}

/// Waits up to `tries` tenths of a second for OS process `pid` to exit; a
/// server that never started has no process at all.
fn await_dead(pid: String, tries: Int, reason: String) -> Nil {
  case alive(pid), tries {
    False, _ -> Nil
    True, 0 -> panic as reason
    True, _ -> {
      process.sleep(100)
      await_dead(pid, tries - 1, reason)
    }
  }
}

fn alive(pid: String) -> Bool {
  case pid == "" {
    // `/proc//stat` would read `/proc/stat`, which is never a server process.
    True -> False
    False ->
      case read("/proc/" <> pid <> "/stat") {
        Error(Nil) -> False
        // A zombie has exited.
        Ok(stat) -> !string.contains(stat, ") Z ")
      }
  }
}

fn read(path: String) -> Result(String, Nil) {
  read_file(path)
  |> result.replace_error(Nil)
  |> result.try(fn(bytes) { bit_to_string(bytes) })
}

fn bit_to_string(bytes: BitArray) -> Result(String, Nil) {
  case is_utf8(bytes) {
    True -> Ok(coerce(bytes))
    False -> Error(Nil)
  }
}

fn is_utf8(bytes: BitArray) -> Bool {
  decode.run(utf8_check(bytes), decode.bit_array) |> result.is_ok
}

@external(erlang, "albedo_mcp_ownership_test_support", "fake_server")
fn fake_server() -> #(String, String)

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "file", "make_dir")
fn make_dir(path: String) -> Dynamic

@external(erlang, "os", "cmd")
fn os_cmd(command: List(Int)) -> List(Int)

@external(erlang, "unicode", "characters_to_binary")
fn utf8_check(bytes: BitArray) -> Dynamic

@external(erlang, "unicode", "characters_to_list")
fn charlist(text: String) -> List(Int)

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> b
