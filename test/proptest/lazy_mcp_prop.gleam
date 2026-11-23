//// The lazy MCP manager against a three-state model per server (not loaded,
//// connected, dropped), driven by generated histories of loads, calls,
//// transport kills and listings over two fake stdio servers, a disabled one
//// and an unknown name. Servers never fall idle here (timeout zero), so the
//// model needs no clock. The sidebar must list loaded servers in the order
//// of their first load.

import albedo/composition/mcp_owner_support
import albedo/lifecycle/host_install
import albedo/storage/core_store
import albedo_ext_mcp/lazy
import albedo_ext_mcp/loads
import albedo_sdk/capabilities
import albedo_sdk/extension
import albedo_sdk/storage
import albedo_sdk/store
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import proptest
import qcheck

pub type Op {
  Load(name: String)
  Call(server: String, fail: Bool)
  Kill(server: String)
  Listing
  Sidebar
}

pub type State {
  NotLoaded
  Connected
  Dropped
}

type Model {
  Model(servers: Dict(String, State), inits: Dict(String, Int), calls: Dict(String, Int), first_loads: List(String))
}

const live = ["a", "b"]

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn op() -> qcheck.Generator(Op) {
  qcheck.from_weighted_generators(#(5, pick(["a", "b", "b", "a", "off", "nope"]) |> qcheck.map(Load)), [
    #(4, qcheck.map2(pick(live), qcheck.from_weighted_generators(#(4, qcheck.return(False)), [#(1, qcheck.return(True))]), Call)),
    #(2, pick(live) |> qcheck.map(Kill)),
    #(2, qcheck.return(Listing)),
    #(1, qcheck.return(Sidebar)),
  ])
}

fn get(d: Dict(String, a), key: String, default: a) -> a {
  dict.get(d, key) |> result.unwrap(default)
}

fn bump(d: Dict(String, Int), key: String) -> Dict(String, Int) {
  dict.insert(d, key, get(d, key, 0) + 1)
}

pub fn main() -> Nil {
  host_install.install()
  let home = "/tmp/albedo-proptest-mcp-" <> int.to_string(proptest.unique())
  proptest.putenv("ALBEDO_HOME", home)
  let _ = del_dir_r(home)
  let _ = make_dir(home)
  let assert Ok(ledger) = store.start(home <> "/preferences.db", "", core_store.tables())
  let scope = storage.host(ledger)
  let assert Ok(Nil) =
    storage.query(scope, fn(db) { storage.exec(db, "CREATE TABLE sessions(id TEXT PRIMARY KEY);") })
  let assert Ok(Nil) = loads.initialise(scope)
  proptest.check("lazy manager follows the lifecycle model", 10, qcheck.generic_list(op(), qcheck.bounded_int(1, 20)), fn(ops) {
    let session = "s" <> int.to_string(proptest.unique())
    let assert Ok(Nil) =
      storage.query(scope, fn(db) { storage.exec(db, "INSERT INTO sessions(id) VALUES('" <> session <> "');") })
    let controls = list.map(live, fn(name) {
      let dir = home <> "/" <> session <> "-" <> name
      let _ = make_dir(dir)
      #(name, dir)
    }) |> dict.from_list
    let servers =
      json.object([
        #("a", fixture(get(controls, "a", ""), True)),
        #("b", fixture(get(controls, "b", ""), True)),
        #("off", fixture(home <> "/unused", False)),
      ])
    let config =
      json.object([#("servers", servers), #("retryMs", json.int(30_000)), #("idleTimeoutMs", json.int(0))])
      |> json.to_string
    let runtime = mcp_owner_support.start_runtime()
    let assert Ok(#(manager, _)) =
      lazy.prepare(config, preferences, scope, session, extension.preparation_owner(runtime.pid))
    let assert Ok(Nil) = mcp_owner_support.on_runtime(runtime, fn() { lazy.adopt(manager) })
    let source = lazy.Managed(manager)
    let initial = Model(dict.from_list([#("a", NotLoaded), #("b", NotLoaded)]), dict.new(), dict.new(), [])
    let final =
      list.fold(ops, initial, fn(model, op) {
        let after = step(source, scope, session, controls, model, op)
        // Counters the fake servers keep must match the model after every op.
        list.each(live, fn(name) {
          assert seen(get(controls, name, ""), "initialize") == get(after.inits, name, 0)
          assert seen(get(controls, name, ""), "tools/call") == get(after.calls, name, 0)
        })
        after
      })
    let _ = final
    lazy.close(manager)
    mcp_owner_support.kill_wait(runtime.pid)
  })
  store.close(ledger)
  let _ = del_dir_r(home)
  Nil
}

fn step(source: lazy.Source, scope: storage.Storage, session: String, controls: Dict(String, String), model: Model, op: Op) -> Model {
  case op {
    Load(name) -> {
      let answer = lazy.load(source, name)
      case get(model.servers, name, NotLoaded), list.contains(live, name) {
        _, False -> {
          proptest.bump("load_refused")
          let assert Error(_) = answer
          model
        }
        Connected, True -> {
          proptest.bump("load_reuse")
          let assert Ok(_) = answer
          model
        }
        state, True -> {
          proptest.bump(case state {
            Dropped -> "load_redial"
            _ -> "load_first"
          })
          let assert Ok(_) = answer
          let first = case list.contains(model.first_loads, name) {
            True -> model.first_loads
            False -> list.append(model.first_loads, [name])
          }
          Model(..model, servers: dict.insert(model.servers, name, Connected), inits: bump(model.inits, name), first_loads: first)
        }
      }
    }
    Call(server, fail) -> {
      let message = case fail {
        True -> "fail"
        False -> "hi"
      }
      let tool = advertised(source, server)
      case get(model.servers, server, NotLoaded), tool {
        NotLoaded, _ -> {
          proptest.bump("call_unloaded")
          assert tool == Error(Nil)
          model
        }
        Dropped, Ok(tool) -> {
          proptest.bump("call_dropped")
          let assert Error(reason) = lazy.call(source, tool, "{\"message\":\"" <> message <> "\"}")
          assert string.contains(reason, "mcp.load")
          model
        }
        Connected, Ok(tool) -> {
          let answer = lazy.call(source, tool, "{\"message\":\"" <> message <> "\"}")
          case fail {
            True -> {
              proptest.bump("call_failed")
              let assert Error(reason) = answer
              assert string.contains(reason, "outcome unknown")
            }
            False -> {
              proptest.bump("call_ok")
              let assert Ok(echoed) = answer
              assert string.contains(echoed, message)
            }
          }
          Model(..model, calls: bump(model.calls, server))
        }
        _, Error(Nil) -> panic as { "loaded server " <> server <> " advertises no tool" }
      }
    }
    Kill(server) ->
      case get(model.servers, server, NotLoaded) {
        Connected -> {
          proptest.bump("kill")
          let pid = server_pid(get(controls, server, ""))
          kill(pid)
          await_dead(pid, 50)
          // An unexpected death reaches the manager with the port's exit, after
          // the OS process ends, so wait for that record before the model
          // calls it dropped; a load before it would reuse the dead client.
          await_disconnected(source, server, 500)
          Model(..model, servers: dict.insert(model.servers, server, Dropped))
        }
        _ -> model
      }
    Listing -> {
      let expected =
        ["a", "b"]
        |> list.map(fn(name) {
          case get(model.servers, name, NotLoaded) {
            NotLoaded -> #(name, False, False)
            Connected -> #(name, True, True)
            Dropped -> #(name, True, False)
          }
        })
      assert listing(source) == expected
      model
    }
    Sidebar -> {
      proptest.bump("sidebar_" <> int.to_string(list.length(model.first_loads)))
      let assert Ok(found) = loads.list(scope, session)
      let found = list.map(found, fn(load) { #(load.server, load.loaded) })
      let expected = list.map(model.first_loads, fn(name) { #(name, True) })
      case found == expected {
        True -> Nil
        False -> panic as { "sidebar " <> string.inspect(found) <> ", first loads " <> string.inspect(expected) }
      }
      model
    }
  }
}

/// The advertised name of `server`'s echo tool, if its schemas are loaded.
fn advertised(source: lazy.Source, server: String) -> Result(String, Nil) {
  let assert Ok(found) =
    json.parse(
      lazy.definitions(source),
      decode.list({
        use name <- decode.field("name", decode.string)
        use owner <- decode.field("server", decode.string)
        decode.success(#(name, owner))
      }),
    )
  list.find(found, fn(entry) { entry.1 == server }) |> result.map(fn(entry) { entry.0 })
}

fn listing(source: lazy.Source) -> List(#(String, Bool, Bool)) {
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

fn fixture(control: String, enabled: Bool) -> json.Json {
  let #(python, script) = fake_server()
  json.object([
    #("type", json.string("stdio")),
    #("command", json.string(python)),
    #("args", json.array([script], json.string)),
    #("env", json.object([#("FAKE_MCP_CONTROL", json.string(control))])),
    #("startupTimeoutMs", json.int(5000)),
    #("callTimeoutMs", json.int(5000)),
    #("enabled", json.bool(enabled)),
  ])
}

fn preferences() -> Result(capabilities.Preferences, String) {
  Ok(capabilities.unscoped())
}

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

/// Waits until the manager reports `name` disconnected, polling every 10 ms.
fn await_disconnected(source: lazy.Source, name: String, tries: Int) -> Nil {
  let connected = list.contains(listing(source), #(name, True, True))
  case connected, tries {
    False, _ -> Nil
    True, 0 -> panic as "the manager never recorded a dropped MCP transport"
    True, _ -> {
      process.sleep(10)
      await_disconnected(source, name, tries - 1)
    }
  }
}

fn alive(pid: String) -> Bool {
  case read("/proc/" <> pid <> "/stat") {
    Error(Nil) -> False
    Ok(stat) -> !string.contains(stat, ") Z ")
  }
}

fn kill(pid: String) -> Nil {
  let _ = os_cmd(charlist("kill -9 " <> pid))
  Nil
}

fn read(path: String) -> Result(String, Nil) {
  case read_file(path) {
    Ok(bytes) -> Ok(coerce(bytes))
    Error(_) -> Error(Nil)
  }
}

@external(erlang, "albedo_suite_test_support", "fake_mcp_server")
fn fake_server() -> #(String, String)

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "file", "make_dir")
fn make_dir(path: String) -> Dynamic

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> Dynamic

@external(erlang, "os", "cmd")
fn os_cmd(command: List(Int)) -> List(Int)

@external(erlang, "unicode", "characters_to_list")
fn charlist(text: String) -> List(Int)

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> b
