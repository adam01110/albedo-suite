//// Lazy MCP lifecycle against the fake stdio server: preparation contacts
//// nothing, loads start one client, calls are never replayed, unload,
//// idle cleanup, catalogue drift, dropped transports, adoption and owner
//// death. Replaces the suite's former Erlang native tests.

import albedo/harness/extensions/mcp/lazy
import albedo/harness/extensions/mcp/loads
import albedo/harness/host_install
import albedo/harness/sdk/extension
import albedo/harness/sdk/page
import albedo/harness/sdk/storage
import albedo/harness/sdk/store
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import harness/mcp_owner_support

pub fn main() -> Nil {
  host_install.install()
  let home = "/tmp/albedo-suite-lazy-mcp-" <> int.to_string(unique())
  let _ = make_dir(home)
  set_env("ALBEDO_HOME", home)
  write(
    home <> "/capabilities.json",
    "{\"global\":{\"mcp\":{\"blocked\":false}}}",
  )
  let assert Ok(ledger) =
    store.start(
      home <> "/preferences.db",
      "CREATE TABLE session_selection(session TEXT,kind TEXT,preference_key TEXT,enabled INTEGER)",
    )
  let scope = storage.host(ledger)
  let assert Ok(Nil) =
    storage.query(scope, fn(db) {
      storage.exec(
        db,
        "CREATE TABLE sessions(id TEXT PRIMARY KEY);INSERT INTO sessions(id) VALUES('session');",
      )
    })
  let assert Ok(Nil) = loads.initialise(scope)
  descriptions_are_validated(scope)
  startup_contacts_nothing_and_loads_once(home, scope)
  idle_cleanup_reconnects_and_refuses_drift(home, scope)
  owner_death_ends_the_manager(home, scope)
  store.close(ledger)
  let _ = del_dir_r(home)
  io.println(
    "Lazy MCP: validation, startup, adoption, single load, no replay, unload, sidebar, idle, drift, dropped transport and owner death passed",
  )
}

fn descriptions_are_validated(scope: storage.Storage) -> Nil {
  let runtime = mcp_owner_support.start_runtime()
  let owner = extension.preparation_owner(runtime.pid)
  list.each(["null", "42", "\"" <> string.repeat("x", 1025) <> "\""], fn(bad) {
    let assert Ok(value) = json.parse(bad, decode.dynamic)
    let assert Error(Nil) =
      lazy.description(
        dynamic.properties([#(dynamic.string("description"), value)]),
      )
    let config =
      "{\"retryMs\":30000,\"servers\":{\"a\":{\"type\":\"http\",\"url\":\"https://example.invalid/mcp\",\"description\":"
      <> bad
      <> "}}}"
    let assert Error(_) = lazy.prepare(config, scope, "session", owner)
  })
  let assert Ok(#(empty, context)) =
    lazy.prepare("{\"retryMs\":30000,\"servers\":{}}", scope, "session", owner)
  assert context == ""
  lazy.close(empty)
  mcp_owner_support.kill_wait(runtime.pid)
}

fn startup_contacts_nothing_and_loads_once(
  home: String,
  scope: storage.Storage,
) -> Nil {
  let control = home <> "/a"
  let _ = make_dir(control)
  let servers = [
    #(
      "a",
      server(
        Ok(control),
        "Load for API docs. \"quoted\"\n</extension-context>",
        True,
      ),
    ),
    #("b", server(Error(Nil), "", True)),
    #("blocked", server(Error(Nil), "", True)),
    #("disabled", server(Error(Nil), "", False)),
  ]
  let runtime = mcp_owner_support.start_runtime()
  let assert Ok(#(manager, context)) =
    lazy.prepare(
      config(servers, 0),
      scope,
      "session",
      extension.preparation_owner(runtime.pid),
    )
  let source = lazy.Managed(manager)

  // Preparation reads no credentials and starts nothing.
  assert read(control <> "/pid") == Error(Nil)
  let assert [_, catalog] = string.split(context, "\n")
  let assert Ok(listed) =
    json.parse(
      catalog,
      decode.list({
        use name <- decode.field("name", decode.string)
        use description <- decode.field("description", decode.string)
        decode.success(#(name, description))
      }),
    )
  assert listed
    == [
      #("a", "Load for API docs. \"quoted\"\n</extension-context>"),
      #("b", ""),
    ]
  assert !string.contains(context, "fake_mcp_server")

  // Only the runtime adopts it.
  let assert Error(_) = lazy.adopt(manager)
  let assert Ok(Nil) =
    mcp_owner_support.on_runtime(runtime, fn() { lazy.adopt(manager) })
  assert lazy.definitions(source) == "[]"
  assert state(source) == [#("a", False, False), #("b", False, False)]
  let assert Error(_) = lazy.load(source, "disabled")
  let assert Error(_) = lazy.load(source, "blocked")
  assert read(control <> "/pid") == Error(Nil)

  // Concurrent first loads start one client.
  let answers = process.new_subject()
  list.each([1, 2, 3, 4, 5, 6, 7, 8], fn(_) {
    process.spawn_unlinked(fn() {
      process.send(answers, lazy.load(source, "a"))
    })
  })
  let loaded =
    list.map([1, 2, 3, 4, 5, 6, 7, 8], fn(_) {
      let assert Ok(answer) = process.receive(answers, 15_000)
      answer
    })
    |> list.unique
  let assert [Ok(definitions)] = loaded
  assert seen(control, "initialize") == 1
  assert sidebar(scope) == [#("a", "loaded", page.Active)]
  let assert Ok([tool]) =
    json.parse(definitions, decode.list(decode.at(["name"], decode.string)))
  assert state(source) == [#("a", True, True), #("b", False, False)]

  // A failed call is reported, never replayed.
  let assert Ok(echoed) = lazy.call(source, tool, "{\"message\":\"hi\"}")
  assert string.contains(echoed, "hi")
  let assert Error(unknown) = lazy.call(source, tool, "{\"message\":\"fail\"}")
  assert string.contains(unknown, "outcome unknown")
  assert seen(control, "tools/call") == 2
  assert seen(control, "initialize") == 1

  // Unload discards the catalogue; a new load starts a new client.
  let assert Ok(Nil) = lazy.unload(source, "a")
  assert sidebar(scope) == [#("a", "unloaded", page.Plain)]
  let assert Error(_) = lazy.call(source, tool, "{\"message\":\"hi\"}")
  assert seen(control, "tools/call") == 2
  assert state(source) == [#("a", False, False), #("b", False, False)]
  let assert Ok(_) = lazy.load(source, "a")
  assert seen(control, "initialize") == 2
  assert sidebar(scope) == [#("a", "loaded", page.Active)]

  // An unexpected transport death needs an explicit unload and load.
  let pid = server_pid(control)
  kill(pid)
  await_dead(pid, 50)
  assert state(source) == [#("a", True, False), #("b", False, False)]
  let assert Error(dropped) = lazy.load(source, "a")
  assert string.contains(dropped, "unload and load")
  let assert Ok(Nil) = lazy.unload(source, "a")
  let assert Ok(_) = lazy.load(source, "a")
  assert seen(control, "initialize") == 3

  // Close ends the manager and its client.
  let pid = server_pid(control)
  let watched = process.monitor(lazy.manager(manager))
  lazy.close(manager)
  let _ = mcp_owner_support.down(watched)
  await_dead(pid, 100)
  lazy.close(manager)
  mcp_owner_support.kill_wait(runtime.pid)
}

fn idle_cleanup_reconnects_and_refuses_drift(
  home: String,
  scope: storage.Storage,
) -> Nil {
  let control = home <> "/idle"
  let _ = make_dir(control)
  let runtime = mcp_owner_support.start_runtime()
  // A new manager starts empty, so earlier loads are history.
  assert sidebar(scope) == [#("a", "loaded", page.Active)]
  let assert Ok(#(manager, _)) =
    lazy.prepare(
      config([#("a", server(Ok(control), "", True))], 300),
      scope,
      "session",
      extension.preparation_owner(runtime.pid),
    )
  let assert Ok(Nil) =
    mcp_owner_support.on_runtime(runtime, fn() { lazy.adopt(manager) })
  assert sidebar(scope) == [#("a", "unloaded", page.Plain)]
  let source = lazy.Managed(manager)
  let assert Ok(definitions) = lazy.load(source, "a")
  let assert Ok([tool]) =
    json.parse(definitions, decode.list(decode.at(["name"], decode.string)))
  let pid = server_pid(control)
  await_dead(pid, 100)
  // Idle cleanup keeps the schemas; an explicit call reconnects.
  assert state(source) == [#("a", True, False)]
  let assert Ok(_) = lazy.call(source, tool, "{\"message\":\"again\"}")
  assert seen(control, "initialize") == 2
  // A catalogue that changed while idle refuses the first call unrun.
  await_dead(server_pid(control), 100)
  write(
    control <> "/tools",
    "[{\"name\":\"other\",\"inputSchema\":{\"type\":\"object\"}}]",
  )
  let assert Error(changed) = lazy.call(source, tool, "{\"message\":\"x\"}")
  assert string.contains(changed, "catalogue changed")
  assert seen(control, "tools/call") == 1
  let assert Error(_) = lazy.call(source, tool, "{\"message\":\"x\"}")
  assert seen(control, "tools/call") == 1
  lazy.close(manager)
  mcp_owner_support.kill_wait(runtime.pid)
}

/// A preparer that dies before adoption ends the manager, and the runtime's
/// death ends an adopted one.
fn owner_death_ends_the_manager(home: String, scope: storage.Storage) -> Nil {
  let config = config([#("a", server(Error(Nil), "", True))], 0)
  let runtime = mcp_owner_support.start_runtime()
  let prepared = process.new_subject()
  let preparer =
    process.spawn_unlinked(fn() {
      process.send(
        prepared,
        lazy.prepare(
          config,
          scope,
          "session",
          extension.preparation_owner(runtime.pid),
        ),
      )
      process.sleep_forever()
    })
  let assert Ok(Ok(#(orphan, _))) = process.receive(prepared, 15_000)
  let watched = process.monitor(lazy.manager(orphan))
  mcp_owner_support.kill_wait(preparer)
  let _ = mcp_owner_support.down(watched)

  let assert Ok(#(adopted, _)) =
    lazy.prepare(
      config,
      scope,
      "session",
      extension.preparation_owner(runtime.pid),
    )
  let assert Ok(Nil) =
    mcp_owner_support.on_runtime(runtime, fn() { lazy.adopt(adopted) })
  let watched = process.monitor(lazy.manager(adopted))
  mcp_owner_support.kill_wait(runtime.pid)
  let _ = mcp_owner_support.down(watched)
  let _ = home
  Nil
}

// Fixtures.

fn server(
  control: Result(String, Nil),
  description: String,
  enabled: Bool,
) -> json.Json {
  let #(python, script) = fake_server()
  let env = case control {
    Ok(dir) -> [#("FAKE_MCP_CONTROL", json.string(dir))]
    Error(Nil) -> []
  }
  json.object([
    #("type", json.string("stdio")),
    #("command", json.string(python)),
    #("args", json.array([script], json.string)),
    #("env", json.object(env)),
    #("description", json.string(description)),
    #("enabled", json.bool(enabled)),
    #("startupTimeoutMs", json.int(5000)),
    #("callTimeoutMs", json.int(5000)),
  ])
}

fn config(servers: List(#(String, json.Json)), idle: Int) -> String {
  json.object([
    #("servers", json.object(servers)),
    #("retryMs", json.int(30_000)),
    #("idleTimeoutMs", json.int(idle)),
  ])
  |> json.to_string
}

/// The session's sidebar rows: name, badge and tone.
fn sidebar(scope: storage.Storage) -> List(#(String, String, page.Tone)) {
  let assert Ok(glance) = loads.sidebar(scope, "session", "")
  assert glance.title == "mcp"
  list.map(glance.rows, fn(row) { #(row.text, row.badge, row.tone) })
}

/// Each configured server's name, loaded and connected flags.
fn state(source: lazy.Source) -> List(#(String, Bool, Bool)) {
  let assert Ok(listed) =
    json.parse(
      lazy.servers(source),
      decode.list({
        use name <- decode.field("name", decode.string)
        use loaded <- decode.field("loaded", decode.bool)
        use connected <- decode.field("connected", decode.bool)
        decode.success(#(name, loaded, connected))
      }),
    )
  listed
}

/// How often the fake server under `control` received `method`.
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

/// Waits up to `tries` tenths of a second for OS process `pid` to exit.
fn await_dead(pid: String, tries: Int) -> Nil {
  case alive(pid), tries {
    False, _ -> Nil
    True, 0 -> panic as "the fake MCP server outlived its client"
    True, _ -> {
      process.sleep(100)
      await_dead(pid, tries - 1)
    }
  }
}

fn alive(pid: String) -> Bool {
  case read("/proc/" <> pid <> "/stat") {
    Error(Nil) -> False
    // A zombie has exited.
    Ok(stat) -> !string.contains(stat, ") Z ")
  }
}

fn kill(pid: String) -> Nil {
  let _ = os_cmd(charlist("kill -9 " <> pid))
  Nil
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

fn write(path: String, contents: String) -> Nil {
  let _ = write_file(path, contents)
  Nil
}

fn set_env(name: String, value: String) -> Nil {
  let _ = putenv(charlist(name), charlist(value))
  Nil
}

@external(erlang, "albedo_mcp_ownership_test_support", "fake_server")
fn fake_server() -> #(String, String)

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "file", "write_file")
fn write_file(path: String, contents: String) -> Dynamic

@external(erlang, "file", "make_dir")
fn make_dir(path: String) -> Dynamic

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> Dynamic

@external(erlang, "os", "putenv")
fn putenv(name: List(Int), value: List(Int)) -> Bool

@external(erlang, "os", "cmd")
fn os_cmd(command: List(Int)) -> List(Int)

@external(erlang, "unicode", "characters_to_list")
fn charlist(text: String) -> List(Int)

@external(erlang, "unicode", "characters_to_binary")
fn utf8_check(bytes: BitArray) -> Dynamic

fn is_utf8(bytes: BitArray) -> Bool {
  decode.run(utf8_check(bytes), decode.bit_array) |> result.is_ok
}

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> b

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int
