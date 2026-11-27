//// Property tests for the lazy MCP manager's call path (albedo-suite): call
//// arguments survive the trip to the server unchanged, concurrent callers each
//// get exactly one reply of their own, idle cleanup never closes a transport
//// with a call in flight, and a reconnect whose catalogue drifted is refused
//// before dispatch. The fake server records every request it receives, so the
//// oracle is what the server got, never the manager's own view.

import albedo/composition/mcp_owner_support
import albedo/lifecycle/host_install
import albedo/storage/core_store
import albedo_clock
import albedo_ext_mcp/lazy
import albedo_ext_mcp/loads
import albedo_sdk/capabilities
import albedo_sdk/extension
import albedo_sdk/storage
import albedo_sdk/store
import albedo_sqlite
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import proptest
import qcheck

const server_name = "rec"

pub fn main() -> Nil {
  host_install.install()
  let home =
    "/tmp/albedo-proptest-mcp-call-" <> int.to_string(proptest.unique())
  proptest.putenv("ALBEDO_HOME", home)
  proptest.remove_tree(home)
  let _ = make_dir(home)
  let assert Ok(ledger) =
    store.start(home <> "/preferences.db", fn(_) { Ok(Nil) }, core_store.tables())
  let scope = storage.host(ledger)
  let assert Ok(Nil) =
    storage.query(scope, fn(db) {
      albedo_sqlite.exec("CREATE TABLE sessions(id TEXT PRIMARY KEY);", on: db)
    })
  let assert Ok(Nil) = storage.query(scope, loads.initialise_schema)
  arguments_property(home, scope)
  concurrency_property(home, scope)
  queued_calls_property(home, scope)
  dead_caller_property(home, scope)
  reconnect_ownership_property(home, scope)
  idle_in_flight_property(home, scope)
  reads_do_not_keep_alive_property(home, scope)
  drift_property(home, scope)
  store.close(ledger)
  proptest.remove_tree(home)
  Nil
}

// The manager under test, with one fake recording server.

type Fixture {
  Fixture(
    manager: lazy.Lazy,
    source: lazy.Source,
    runtime: mcp_owner_support.Runtime,
    control: String,
  )
}

fn open_fixture(
  scope: storage.Storage,
  label: String,
  control: String,
  idle_ms: Int,
) -> Fixture {
  open_servers(scope, label, [#(server_name, control, idle_ms)])
}

fn open_servers(
  scope: storage.Storage,
  label: String,
  servers: List(#(String, String, Int)),
) -> Fixture {
  let session = label <> "-" <> int.to_string(proptest.unique())
  let assert Ok(Nil) =
    storage.query(scope, fn(db) {
      albedo_sqlite.exec("INSERT INTO sessions(id) VALUES('" <> session <> "');", on: db)
    })
  let runtime = mcp_owner_support.start_runtime()
  let configured =
    list.map(servers, fn(entry) {
      #(entry.0, server_fixture(entry.1, entry.2))
    })
  let default_idle = case servers {
    [first, ..] -> first.2
    [] -> 0
  }
  let config =
    json.object([
      #("servers", json.object(configured)),
      #("retryMs", json.int(30_000)),
      #("idleTimeoutMs", json.int(default_idle)),
    ])
    |> json.to_string
  let assert Ok(#(manager, _)) =
    lazy.prepare(
      config,
      preferences,
      scope,
      session,
      extension.preparation_owner(runtime.pid),
    )
  let assert Ok(Nil) =
    mcp_owner_support.on_runtime(runtime, fn() { lazy.adopt(manager) })
  let control = case servers {
    [first, ..] -> first.1
    [] -> ""
  }
  Fixture(manager, lazy.Managed(manager), runtime, control)
}

fn close_fixture(fixture: Fixture) -> Nil {
  lazy.close(fixture.manager)
  mcp_owner_support.kill_wait(fixture.runtime.pid)
}

/// The recording server: `test/fake_mcp_record.py`, run by the interpreter
/// the test support names, with `control` as its FAKE_MCP_CONTROL directory.
fn server_fixture(control: String, idle_ms: Int) -> Json {
  let #(python, _) = fake_server()
  json.object([
    #("type", json.string("stdio")),
    #("command", json.string(python)),
    #("args", json.array(["test/fake_mcp_record.py"], json.string)),
    #("env", json.object([#("FAKE_MCP_CONTROL", json.string(control))])),
    #("startupTimeoutMs", json.int(30_000)),
    #("callTimeoutMs", json.int(30_000)),
    #("idleTimeoutMs", json.int(idle_ms)),
    #("enabled", json.bool(True)),
  ])
}

fn preferences() -> Result(capabilities.Preferences, String) {
  Ok(capabilities.unscoped())
}

// Generated JSON arguments.

type Value {
  VNull
  VBool(Bool)
  VInt(Int)
  VFloat(Float)
  VString(String)
  VList(List(Value))
  VObject(List(#(String, Value)))
}

fn arguments() -> qcheck.Generator(List(#(String, Value))) {
  qcheck.from_weighted_generators(#(7, random_arguments()), [
    #(3, deep_arguments()),
  ])
}

fn random_arguments() -> qcheck.Generator(List(#(String, Value))) {
  qcheck.bind(qcheck.bounded_int(1, 3), fn(depth) {
    qcheck.map(
      qcheck.generic_list(
        qcheck.tuple2(argument_key(), value_at(depth)),
        qcheck.bounded_int(1, 3),
      ),
      unique_pairs,
    )
  })
}

/// Three levels of nesting, so every run reaches deeply nested values.
fn deep_arguments() -> qcheck.Generator(List(#(String, Value))) {
  qcheck.map(value_at(1), fn(inner) {
    [
      #("message", VString("deep")),
      #(
        "nested",
        VObject([
          #("inner", VList([inner, VObject([#("leaf", VNull)])])),
        ]),
      ),
    ]
  })
}

fn value_at(depth: Int) -> qcheck.Generator(Value) {
  case depth <= 0 {
    True -> scalar()
    False ->
      qcheck.from_weighted_generators(#(4, scalar()), [
        #(
          3,
          qcheck.map(
            qcheck.generic_list(value_at(depth - 1), qcheck.bounded_int(0, 3)),
            VList,
          ),
        ),
        #(
          4,
          qcheck.map(
            qcheck.generic_list(
              qcheck.tuple2(argument_key(), value_at(depth - 1)),
              qcheck.bounded_int(0, 3),
            ),
            fn(pairs) { VObject(unique_pairs(pairs)) },
          ),
        ),
      ])
  }
}

fn scalar() -> qcheck.Generator(Value) {
  qcheck.from_weighted_generators(
    #(6, qcheck.map(int_value(), VInt)),
    [
      #(4, qcheck.map(string_value(), VString)),
      #(1, qcheck.map(float_value(), VFloat)),
      #(1, qcheck.map(qcheck.bool(), VBool)),
      #(1, qcheck.return(VNull)),
    ],
  )
}

/// Integers around the double and 64-bit boundaries, plus ordinary ones.
fn int_value() -> qcheck.Generator(Int) {
  qcheck.from_generators(qcheck.bounded_int(-1000, 1000), [
    qcheck.return(0),
    qcheck.return(-1),
    qcheck.return(9_007_199_254_740_993),
    qcheck.return(9_223_372_036_854_775_807),
    qcheck.return(9_223_372_036_854_775_808),
    qcheck.return(-9_223_372_036_854_775_808),
    qcheck.return(123_456_789_012_345_678_901_234_567_890),
    qcheck.return(-123_456_789_012_345_678_901_234_567_890),
  ])
}

fn float_value() -> qcheck.Generator(Float) {
  qcheck.from_generators(qcheck.bounded_float(-1_000.0, 1_000.0), [
    qcheck.return(0.0),
    qcheck.return(1.5),
    qcheck.return(-2.25),
    qcheck.return(123_456.789),
    qcheck.return(1.0e300),
    qcheck.return(1.0e-300),
  ])
}

/// Text that JSON must escape or keep as multibyte UTF-8.
fn string_value() -> qcheck.Generator(String) {
  qcheck.from_generators(
    qcheck.generic_string(
      qcheck.uniform_codepoint(),
      qcheck.bounded_int(0, 8),
    ),
    [
      qcheck.return(""),
      qcheck.return("plain text"),
      qcheck.return("\"quoted\" \\ backslash / slash"),
      qcheck.return("\n\t\r\u{0008}\u{000C}"),
      qcheck.return("héllo wörld"),
      qcheck.return("日本語のテキスト"),
      qcheck.return("👩🏽‍💻 emoji"),
      qcheck.return("e\u{0301} combining"),
      qcheck.return("line\u{2028}separator"),
      qcheck.return("\u{10FFFF}"),
      qcheck.return(string.repeat("long", 100)),
    ],
  )
}

fn argument_key() -> qcheck.Generator(String) {
  qcheck.from_generators(
    qcheck.generic_string(
      qcheck.alphanumeric_ascii_codepoint(),
      qcheck.bounded_int(1, 6),
    ),
    [
      qcheck.return("message"),
      qcheck.return(""),
      qcheck.return("ключ"),
      qcheck.return("a b"),
      qcheck.return("nested"),
    ],
  )
}

fn unique_pairs(pairs: List(#(String, Value))) -> List(#(String, Value)) {
  list.fold(pairs, [], fn(acc: List(#(String, Value)), pair) {
    case list.any(acc, fn(existing) { existing.0 == pair.0 }) {
      True -> acc
      False -> list.append(acc, [pair])
    }
  })
}

fn value_json(value: Value) -> Json {
  case value {
    VNull -> json.null()
    VBool(flag) -> json.bool(flag)
    VInt(number) -> json.int(number)
    VFloat(number) -> json.float(number)
    VString(text) -> json.string(text)
    VList(items) -> json.array(items, value_json)
    VObject(pairs) ->
      json.object(list.map(pairs, fn(pair) { #(pair.0, value_json(pair.1)) }))
  }
}

fn arguments_text(pairs: List(#(String, Value))) -> String {
  json.object(list.map(pairs, fn(pair) { #(pair.0, value_json(pair.1)) }))
  |> json.to_string
}

// Property: arguments reach the server unchanged.

fn arguments_property(home: String, scope: storage.Storage) -> Nil {
  let control = home <> "/arguments"
  let _ = make_dir(control)
  let fixture = open_fixture(scope, "arguments", control, 0)
  let assert Ok(_definitions) = lazy.load(fixture.source, server_name)
  let tool = advertised(fixture.source)
  proptest.check(
    "MCP call arguments reach the server unchanged",
    20,
    arguments(),
    fn(pairs) {
      let text = arguments_text(pairs)
      let expected = parsed(text)
      let before = call_count(control)
      let assert Ok(result) = lazy.call(fixture.source, tool, text)
      // Exactly one dispatch, carrying the structure the caller sent.
      assert call_count(control) == before + 1
      let received =
        decode.run(parsed(last_call(control)), decode.at(["arguments"], decode.dynamic))
      assert received == Ok(expected)
      // The server's own view comes back through the result unchanged.
      assert parsed(result_text(result)) == expected
      proptest.bump("depth_" <> int.to_string(depth_of(pairs)))
      case list.any(pairs, fn(pair) { is_multibyte(pair.1) }) {
        True -> proptest.bump("multibyte")
        False -> Nil
      }
      case list.any(pairs, fn(pair) { is_big_int(pair.1) }) {
        True -> proptest.bump("big_int")
        False -> Nil
      }
      assert string.length(text) > 0
      Nil
    },
  )
  proptest.check(
    "invalid call arguments are refused before dispatch",
    2,
    invalid_arguments(),
    fn(text) {
      let before = call_count(control)
      let assert Error(reason) = lazy.call(fixture.source, tool, text)
      assert string.contains(reason, "before dispatch")
      assert call_count(control) == before
      proptest.bump("invalid_refused")
      Nil
    },
  )
  close_fixture(fixture)
}

/// Arguments that are not a JSON object's text.
fn invalid_arguments() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.return(""), [
    qcheck.return("not json"),
    qcheck.return("[]"),
    qcheck.return("[1,2,3]"),
    qcheck.return("5"),
    qcheck.return("null"),
    qcheck.return("\"text\""),
    qcheck.return("{"),
    qcheck.return("{\"a\":1} trailing"),
  ])
}


fn is_multibyte(value: Value) -> Bool {
  case value {
    VString(text) -> string.byte_size(text) > string.length(text)
    VList(items) -> list.any(items, is_multibyte)
    VObject(pairs) -> list.any(pairs, fn(pair) { is_multibyte(pair.1) })
    _ -> False
  }
}

fn is_big_int(value: Value) -> Bool {
  case value {
    VInt(number) -> number > 9_007_199_254_740_992 || number < -9_007_199_254_740_992
    VList(items) -> list.any(items, is_big_int)
    VObject(pairs) -> list.any(pairs, fn(pair) { is_big_int(pair.1) })
    _ -> False
  }
}

fn depth_of(pairs: List(#(String, Value))) -> Int {
  list.fold(list.map(pairs, fn(pair) { value_depth(pair.1) }), 0, int.max)
}

fn value_depth(value: Value) -> Int {
  case value {
    VList(items) -> 1 + list.fold(list.map(items, value_depth), 0, int.max)
    VObject(pairs) ->
      1 + list.fold(list.map(pairs, fn(pair) { value_depth(pair.1) }), 0, int.max)
    _ -> 0
  }
}

// Property: concurrent callers each get exactly one reply of their own.

fn indices(count: Int) -> List(Int) {
  indices_from(count - 1, [])
}

fn indices_from(value: Int, acc: List(Int)) -> List(Int) {
  case value < 0 {
    True -> acc
    False -> indices_from(value - 1, [value, ..acc])
  }
}

fn concurrency_property(home: String, scope: storage.Storage) -> Nil {
  let control = home <> "/concurrent"
  let _ = make_dir(control)
  let fixture = open_fixture(scope, "concurrent", control, 0)
  let assert Ok(_definitions) = lazy.load(fixture.source, server_name)
  let tool = advertised(fixture.source)
  let initial_connects = seen(control, "initialize")
  proptest.check(
    "concurrent MCP callers each get their own replies",
    8,
    qcheck.map2(
      qcheck.bounded_int(2, 5),
      qcheck.bounded_int(1, 3),
      fn(callers, calls) { #(callers, calls) },
    ),
    fn(shape) {
      let #(callers, calls) = shape
      let tag = int.to_string(proptest.unique())
      let expected =
        list.flat_map(indices(callers), fn(caller) {
          list.map(indices(calls), fn(index) {
            "c"
            <> int.to_string(caller)
            <> "i"
            <> int.to_string(index)
            <> "-"
            <> tag
          })
        })
      let results = process.new_subject()
      list.each(indices(callers), fn(caller) {
        process.spawn_unlinked(fn() {
          let replies =
            list.map(indices(calls), fn(index) {
              let message =
                "c"
                <> int.to_string(caller)
                <> "i"
                <> int.to_string(index)
                <> "-"
                <> tag
              lazy.call(
                fixture.source,
                tool,
                "{\"message\":\"" <> message <> "\"}",
              )
            })
          process.send(results, replies)
        })
      })
      // Every caller gets its own replies back exactly once, and no caller
      // sees another caller's message.
      list.each(indices(callers), fn(_) {
        let assert Ok(replies) = process.receive(results, 60_000)
        assert list.length(replies) == calls
        let messages =
          list.map(replies, fn(reply) {
            let assert Ok(text) = reply
            let assert Ok(message) =
              json.parse(
                result_text(text),
                decode.at(["message"], decode.string),
              )
            assert list.contains(expected, message)
            message
          })
        assert list.length(list.unique(messages)) == calls
      })
      // The server saw exactly one dispatch per request, none twice.
      let dispatched = case_tagged_messages(control, tag)
      assert list.sort(dispatched, string.compare)
        == list.sort(expected, string.compare)
      assert seen(control, "initialize") == initial_connects
      proptest.bump("callers_" <> int.to_string(callers))
      Nil
    },
  )
  close_fixture(fixture)
}

fn case_tagged_messages(control: String, tag: String) -> List(String) {
  case read(control <> "/calls") {
    Error(Nil) -> []
    Ok(text) ->
      text
      |> string.split("\n")
      |> list.filter(fn(line) { string.contains(line, "-" <> tag) })
      |> list.filter_map(fn(line) {
        case
          json.parse(line, decode.at(["arguments", "message"], decode.string))
        {
          Ok(message) -> Ok(message)
          Error(_) -> Error(Nil)
        }
      })
      |> list.filter(fn(message) { string.ends_with(message, "-" <> tag) })
  }
}

// Property: a queued call survives another server's idle expiry.

fn queued_calls_property(home: String, scope: storage.Storage) -> Nil {
  proptest.check(
    "a queued call survives another server's idle expiry",
    4,
    qcheck.map3(
      qcheck.bounded_int(120, 250),
      qcheck.bounded_int(300, 500),
      qcheck.bool(),
      fn(idle_b, slow_a, killed) { #(idle_b, slow_a, killed) },
    ),
    fn(shape) {
      let #(idle_b, slow_a, killed) = shape
      // A killed transport keeps a deadline far away, so the manager cannot
      // classify its death as idle cleanup while another call is in flight.
      let idle_b = case killed {
        True -> 5_000
        False -> idle_b
      }
      let control_a = home <> "/queued-a-" <> int.to_string(proptest.unique())
      let control_b = home <> "/queued-b-" <> int.to_string(proptest.unique())
      let _ = make_dir(control_a)
      let _ = make_dir(control_b)
      write(control_a <> "/slow", seconds(slow_a))
      let fixture =
        open_servers(scope, "queued", [
          #("a", control_a, 0),
          #("b", control_b, idle_b),
        ])
      let assert Ok(_) = lazy.load(fixture.source, "a")
      let assert Ok(_) = lazy.load(fixture.source, "b")
      let tool_a = advertised_for(fixture.source, "a")
      let tool_b = advertised_for(fixture.source, "b")
      let results = process.new_subject()
      process.spawn_unlinked(fn() {
        process.send(
          results,
          lazy.call(fixture.source, tool_a, "{\"message\":\"slow\"}"),
        )
      })
      // Wait until a's slow call reached its server, so b's deadline passes
      // while the manager is busy dispatching a.
      await_calls(control_a, 1, albedo_clock.monotonic_ms() + 5000)
      case killed {
        True -> {
          let pid = server_pid(control_b)
          kill(pid)
          await_dead(pid, 200, "a killed MCP server outlived its kill")
          await_disconnected_for(
            fixture.source,
            "b",
            albedo_clock.monotonic_ms() + 5000,
          )
        }
        False -> Nil
      }
      let b_answer = lazy.call(fixture.source, tool_b, "{\"message\":\"queued\"}")
      let assert Ok(a_answer) = process.receive(results, 60_000)
      let assert Ok(_) = a_answer
      case killed {
        True -> {
          proptest.bump("queued_after_kill")
          let assert Error(reason) = b_answer
          assert string.contains(reason, "mcp.load")
          assert call_count(control_b) == 0
          // An explicit load redials; the next call is the first dispatch.
          let assert Ok(_) = lazy.load(fixture.source, "b")
          let assert Ok(_) = lazy.call(fixture.source, tool_b, "{\"message\":\"after\"}")
          assert call_count(control_b) == 1
        }
        False -> {
          proptest.bump("queued_after_idle")
          let assert Ok(_) = b_answer
          assert call_count(control_b) == 1
        }
      }
      // a's own call dispatched once and was not retried or doubled.
      assert call_count(control_a) == 1
      assert seen(control_b, "initialize") == 2
      close_fixture(fixture)
      Nil
    },
  )
}

fn await_calls(control: String, target: Int, deadline: Int) -> Nil {
  case call_count(control) >= target {
    True -> Nil
    False -> {
      assert albedo_clock.monotonic_ms() < deadline
        as "the slow MCP call never reached its server"
      process.sleep(5)
      await_calls(control, target, deadline)
    }
  }
}

// Property: a queued request whose caller died is never executed.

fn dead_caller_property(home: String, scope: storage.Storage) -> Nil {
  proptest.check(
    "a queued call from a dead caller is never dispatched",
    3,
    qcheck.bounded_int(300, 500),
    fn(slow_a) {
      let control_a = home <> "/dead-a-" <> int.to_string(proptest.unique())
      let control_b = home <> "/dead-b-" <> int.to_string(proptest.unique())
      let _ = make_dir(control_a)
      let _ = make_dir(control_b)
      write(control_a <> "/slow", seconds(slow_a))
      let fixture =
        open_servers(scope, "dead", [
          #("a", control_a, 0),
          #("b", control_b, 0),
        ])
      let assert Ok(_) = lazy.load(fixture.source, "a")
      let assert Ok(_) = lazy.load(fixture.source, "b")
      let tool_a = advertised_for(fixture.source, "a")
      let tool_b = advertised_for(fixture.source, "b")
      let slow = process.new_subject()
      process.spawn_unlinked(fn() {
        process.send(
          slow,
          lazy.call(fixture.source, tool_a, "{\"message\":\"slow\"}"),
        )
      })
      await_calls(control_a, 1, albedo_clock.monotonic_ms() + 5000)
      // b's request queues behind a's call; its caller dies before it runs.
      let caller =
        process.spawn_unlinked(fn() {
          let _ = lazy.call(fixture.source, tool_b, "{\"message\":\"dead\"}")
        })
      process.sleep(30)
      mcp_owner_support.kill_wait(caller)
      let assert Ok(slow_answer) = process.receive(slow, 60_000)
      let assert Ok(_) = slow_answer
      // A serialized listing returns only after the queued request was
      // handled, so the server's log is complete when it is checked.
      let _ = lazy.definitions(fixture.source)
      // The dead caller's request never reached its server.
      assert call_count(control_b) == 0
      assert seen(control_b, "initialize") == 1
      proptest.bump("dead_caller_discarded")
      // The manager still serves live callers.
      let assert Ok(_) = lazy.call(fixture.source, tool_b, "{\"message\":\"alive\"}")
      assert call_count(control_b) == 1
      close_fixture(fixture)
      Nil
    },
  )
}

// Property: caller death during an idle reconnect prevents the dispatch.

fn reconnect_ownership_property(home: String, scope: storage.Storage) -> Nil {
  proptest.check(
    "caller death during an idle reconnect prevents the call",
    2,
    qcheck.bounded_int(300, 500),
    fn(delay_ms) {
      let control = home <> "/reconnect-" <> int.to_string(proptest.unique())
      let _ = make_dir(control)
      let fixture = open_fixture(scope, "reconnect", control, 120)
      let assert Ok(_) = lazy.load(fixture.source, server_name)
      let tool = advertised(fixture.source)
      let pid = server_pid(control)
      await_dead(pid, 200, "an idle MCP transport outlived its timeout")
      await_disconnected(fixture.source, albedo_clock.monotonic_ms() + 5000)
      // The reconnect's handshake takes long enough to kill the caller in it.
      write(control <> "/delay", seconds(delay_ms))
      let caller =
        process.spawn_unlinked(fn() {
          let _ = lazy.call(fixture.source, tool, "{\"message\":\"doomed\"}")
        })
      process.sleep(delay_ms / 3)
      mcp_owner_support.kill_wait(caller)
      // The reconnect still finishes and keeps its catalogue.
      await_initialize(control, 2, albedo_clock.monotonic_ms() + 5000)
      assert connected(fixture.source)
      assert call_count(control) == 0
      proptest.bump("reconnect_ownership")
      // A live caller then dispatches exactly once.
      let assert Ok(_) = lazy.call(fixture.source, tool, "{\"message\":\"alive\"}")
      assert call_count(control) == 1
      close_fixture(fixture)
      Nil
    },
  )
}

fn await_initialize(control: String, target: Int, deadline: Int) -> Nil {
  case seen(control, "initialize") >= target {
    True -> Nil
    False -> {
      assert albedo_clock.monotonic_ms() < deadline
        as "the idle reconnect never completed"
      process.sleep(10)
      await_initialize(control, target, deadline)
    }
  }
}

// Property: reading catalogues does not keep a connection alive.

fn reads_do_not_keep_alive_property(home: String, scope: storage.Storage) -> Nil {
  proptest.check(
    "reading catalogues does not keep a connection alive",
    3,
    qcheck.bounded_int(150, 250),
    fn(idle_ms) {
      let control = home <> "/reads-" <> int.to_string(proptest.unique())
      let _ = make_dir(control)
      let fixture = open_fixture(scope, "reads", control, idle_ms)
      let assert Ok(_) = lazy.load(fixture.source, server_name)
      let tool = advertised(fixture.source)
      let before = definitions(fixture.source)
      let pid = server_pid(control)
      // Read the catalogue and the listing across the whole timeout.
      let deadline = albedo_clock.monotonic_ms() + idle_ms * 3
      let reads = read_loop(fixture.source, before, 0, deadline)
      assert reads > 3
      assert definitions(fixture.source) == before
      // The reads ran well past the timeout, so the transport is already
      // gone: it closed at its own deadline rather than after the last read.
      assert !alive(pid) as "reads kept an idle MCP transport alive"
      await_dead(pid, 50, "reads kept an idle MCP transport alive")
      assert !connected(fixture.source)
      // The call still reconnects once and dispatches once.
      let assert Ok(_) = lazy.call(fixture.source, tool, "{\"message\":\"after\"}")
      assert call_count(control) == 1
      assert seen(control, "initialize") == 2
      proptest.bump("reads_" <> int.to_string(reads / 10 * 10))
      close_fixture(fixture)
      Nil
    },
  )
}

fn read_loop(
  source: lazy.Source,
  expected: List(Definition),
  reads: Int,
  deadline: Int,
) -> Int {
  case albedo_clock.monotonic_ms() >= deadline {
    True -> reads
    False -> {
      assert definitions(source) == expected
      process.sleep(15)
      read_loop(source, expected, reads + 1, deadline)
    }
  }
}

// Property: idle cleanup never closes a transport with a call in flight.

fn idle_in_flight_property(home: String, scope: storage.Storage) -> Nil {
  proptest.check(
    "idle cleanup never closes a transport with a call in flight",
    2,
    qcheck.map2(
      qcheck.bounded_int(120, 250),
      qcheck.bounded_int(400, 700),
      fn(idle_ms, slow_ms) { #(idle_ms, slow_ms) },
    ),
    fn(shape) {
      let #(idle_ms, slow_ms) = shape
      let control = home <> "/in-flight-" <> int.to_string(proptest.unique())
      let _ = make_dir(control)
      write(control <> "/slow", seconds(slow_ms))
      let fixture = open_fixture(scope, "inflight", control, idle_ms)
      let assert Ok(_definitions) = lazy.load(fixture.source, server_name)
      let tool = advertised(fixture.source)
      let pid = server_pid(control)
      // Sample the server process for the whole call: idle cleanup happening
      // mid-call would end it before the reply arrives.
      let samples = process.new_subject()
      let ready = process.new_subject()
      process.spawn_unlinked(fn() {
        let stop = process.new_subject()
        process.send(ready, stop)
        process.send(samples, sample(pid, [], stop))
      })
      let assert Ok(stop) = process.receive(ready, 5000)
      let started = albedo_clock.monotonic_ms()
      let answer = lazy.call(fixture.source, tool, "{\"message\":\"hi\"}")
      let elapsed = albedo_clock.monotonic_ms() - started
      process.send(stop, Nil)
      let assert Ok(collected) = process.receive(samples, 10_000)
      let assert Ok(_) = answer
      assert elapsed >= slow_ms
      assert list.length(collected) > 3
      assert list.all(collected, fn(alive_sample) { alive_sample })
      // The call refreshed the last use, so the transport is still up.
      assert connected(fixture.source)
      // Once idle past its own timeout it still closes.
      await_dead(pid, 200, "an idle MCP transport outlived its timeout")
      assert !connected(fixture.source)
      proptest.bump("in_flight_" <> int.to_string(idle_ms))
      close_fixture(fixture)
      Nil
    },
  )
}

fn sample(
  pid: String,
  collected: List(Bool),
  stop: process.Subject(Nil),
) -> List(Bool) {
  case process.receive(stop, 5) {
    Ok(Nil) -> list.reverse(collected)
    Error(Nil) -> sample(pid, [alive(pid), ..collected], stop)
  }
}

fn seconds(milliseconds: Int) -> String {
  int.to_string(milliseconds / 1000)
  <> "."
  <> pad3(milliseconds % 1000)
}

fn pad3(value: Int) -> String {
  let text = int.to_string(value)
  case string.length(text) {
    1 -> "00" <> text
    2 -> "0" <> text
    _ -> text
  }
}

// Property: a reconnect refuses a catalogue that drifted, before dispatch.

pub type Tool {
  Tool(name: String, description: String, schema: Json)
}

type Mutation {
  Same
  ChangeDescription(Int)
  ChangeSchema(Int)
  Rename(Int)
  Add
  Drop(Int)
  Reverse
  Replace
}

fn drift_case() -> qcheck.Generator(#(List(Tool), List(Tool))) {
  qcheck.map3(tool_list(), mutation(), tool_list(), fn(first, mutation, fresh) {
    #(first, apply_mutation(first, mutation, fresh))
  })
}

fn tool_list() -> qcheck.Generator(List(Tool)) {
  qcheck.bind(qcheck.bounded_int(1, 3), fn(size) {
    qcheck.map(
      qcheck.generic_list(tool(), qcheck.return(size)),
      fn(tools) { unique_names(tools, []) },
    )
  })
}

fn unique_names(tools: List(Tool), taken: List(String)) -> List(Tool) {
  case tools {
    [] -> []
    [tool, ..rest] -> {
      let name = fresh_name(tool.name, taken)
      [Tool(..tool, name: name), ..unique_names(rest, [name, ..taken])]
    }
  }
}

fn fresh_name(name: String, taken: List(String)) -> String {
  case list.contains(taken, name) {
    False -> name
    True -> fresh_name(name <> "_", taken)
  }
}

fn tool() -> qcheck.Generator(Tool) {
  qcheck.map3(tool_name(), description(), schema(), Tool)
}

fn tool_name() -> qcheck.Generator(String) {
  qcheck.from_generators(
    qcheck.generic_string(
      qcheck.alphanumeric_ascii_codepoint(),
      qcheck.bounded_int(1, 8),
    ),
    [
      qcheck.return("echo"),
      qcheck.return("search"),
      qcheck.return("list_items"),
      qcheck.return("über"),
    ],
  )
}

fn description() -> qcheck.Generator(String) {
  qcheck.from_generators(
    qcheck.generic_string(qcheck.codepoint(), qcheck.bounded_int(0, 12)),
    [
      qcheck.return(""),
      qcheck.return("Echo one message back"),
      qcheck.return("List the things ✓"),
      qcheck.return("line\nbreak"),
    ],
  )
}

fn schema() -> qcheck.Generator(Json) {
  qcheck.from_generators(
    qcheck.map(
      qcheck.generic_list(
        qcheck.tuple2(argument_key(), json_type()),
        qcheck.bounded_int(0, 2),
      ),
      fn(properties) {
        json.object([
          #("type", json.string("object")),
          #(
            "properties",
            json.object(unique_properties(properties)),
          ),
        ])
      },
    ),
    [
      qcheck.return(json.object([#("type", json.string("object"))])),
      qcheck.return(
        json.object([
          #("type", json.string("object")),
          #("required", json.array(["message"], json.string)),
          #(
            "properties",
            json.object([
              #("message", json.object([#("type", json.string("string"))])),
            ]),
          ),
        ]),
      ),
    ],
  )
}

fn unique_properties(
  properties: List(#(String, String)),
) -> List(#(String, Json)) {
  list.fold(properties, [], fn(acc: List(#(String, Json)), pair) {
    case list.any(acc, fn(existing) { existing.0 == pair.0 }) {
      True -> acc
      False ->
        list.append(acc, [
          #(pair.0, json.object([#("type", json.string(pair.1))])),
        ])
    }
  })
}

fn json_type() -> qcheck.Generator(String) {
  qcheck.from_generators(qcheck.return("string"), [
    qcheck.return("integer"),
    qcheck.return("boolean"),
    qcheck.return("array"),
  ])
}

fn mutation() -> qcheck.Generator(Mutation) {
  qcheck.from_weighted_generators(
    #(4, qcheck.return(Same)),
    [
      #(4, qcheck.map(qcheck.bounded_int(0, 3), ChangeDescription)),
      #(4, qcheck.map(qcheck.bounded_int(0, 3), ChangeSchema)),
      #(2, qcheck.map(qcheck.bounded_int(0, 3), Rename)),
      #(2, qcheck.return(Add)),
      #(2, qcheck.map(qcheck.bounded_int(0, 3), Drop)),
      #(1, qcheck.return(Reverse)),
      #(2, qcheck.return(Replace)),
    ],
  )
}

fn apply_mutation(
  tools: List(Tool),
  mutation: Mutation,
  fresh: List(Tool),
) -> List(Tool) {
  case mutation {
    Same -> tools
    Replace -> fresh
    Add -> list.append(tools, [Tool("added", "A new tool", json.object([]))])
    Reverse -> list.reverse(tools)
    ChangeDescription(index) ->
      update_at(tools, index, fn(tool) {
        Tool(..tool, description: tool.description <> " changed")
      })
    ChangeSchema(index) ->
      update_at(tools, index, fn(tool) {
        Tool(
          ..tool,
          schema: json.object([
            #("type", json.string("object")),
            #("additionalProperties", json.bool(True)),
          ]),
        )
      })
    Rename(index) ->
      update_at(tools, index, fn(tool) {
        Tool(..tool, name: tool.name <> "_renamed")
      })
    Drop(index) ->
      case list.length(tools) > 1 {
        True -> drop_at(tools, index)
        False -> list.append(tools, [Tool("fallback", "", json.object([]))])
      }
  }
}

fn update_at(tools: List(Tool), index: Int, update: fn(Tool) -> Tool) -> List(Tool) {
  let position = index % list.length(tools)
  tools
  |> list.index_map(fn(tool, at) { #(at, tool) })
  |> list.map(fn(entry) {
    case entry.0 == position {
      True -> update(entry.1)
      False -> entry.1
    }
  })
}

fn drop_at(tools: List(Tool), index: Int) -> List(Tool) {
  let position = index % list.length(tools)
  tools
  |> list.index_map(fn(tool, at) { #(at, tool) })
  |> list.filter_map(fn(entry) {
    case entry.0 == position {
      True -> Error(Nil)
      False -> Ok(entry.1)
    }
  })
}

fn tool_json(tool: Tool) -> Json {
  json.object([
    #("name", json.string(tool.name)),
    #("description", json.string(tool.description)),
    #("inputSchema", tool.schema),
  ])
}

fn tools_text(tools: List(Tool)) -> String {
  json.array(tools, tool_json) |> json.to_string
}

fn drift_property(home: String, scope: storage.Storage) -> Nil {
  proptest.check(
    "MCP reconnect refuses a drifted catalogue before dispatch",
    10,
    qcheck.map2(drift_case(), qcheck.bool(), fn(scenario, killed) {
      #(scenario, killed)
    }),
    fn(input) {
      let #(#(first, second), killed) = input
      let control = home <> "/drift-" <> int.to_string(proptest.unique())
      let _ = make_dir(control)
      write(control <> "/tools", tools_text(first))
      let fixture = open_fixture(scope, "drift", control, 150)
      let assert Ok(_definitions) = lazy.load(fixture.source, server_name)
      let before = definitions(fixture.source)
      let assert [oldest, ..] = before
      let pid = server_pid(control)
      // Reconnect either after idle cleanup, which keeps the schemas, or
      // after an unexpected transport death, which needs an explicit load.
      case killed {
        True -> {
          proptest.bump("drift_after_kill")
          kill(pid)
          await_dead(pid, 200, "a killed MCP server outlived its kill")
        }
        False -> {
          proptest.bump("drift_after_idle")
          await_dead(pid, 200, "an idle MCP transport outlived its timeout")
        }
      }
      await_disconnected(fixture.source, albedo_clock.monotonic_ms() + 5000)
      write(control <> "/tools", tools_text(second))
      let dispatched = call_count(control)
      let drifted = parsed(tools_text(first)) != parsed(tools_text(second))
      let answer = case killed {
        True -> lazy.load(fixture.source, server_name)
        False -> lazy.call(fixture.source, oldest.advertised, "{\"message\":\"hi\"}")
      }
      case drifted {
        True -> {
          proptest.bump("drift_refused")
          let assert Error(reason) = answer
          assert string.contains(reason, "catalogue changed")
          // Refused before dispatch, and the reconnect's catalogue adopted.
          assert call_count(control) == dispatched
          assert adopted(fixture.source) == expected(second)
          case definitions(fixture.source) {
            [] -> Nil
            [newest, ..] -> {
              let assert Ok(_) =
                lazy.call(fixture.source, newest.advertised, "{\"message\":\"hi\"}")
              assert call_count(control) == dispatched + 1
            }
          }
        }
        False -> {
          proptest.bump("drift_absent")
          let assert Ok(_) = answer
          assert definitions(fixture.source) == before
          // An idle reconnect dispatched the call itself; an explicit load
          // dispatches nothing, so a following call is the first.
          case killed {
            False -> Nil
            True -> {
              let assert Ok(_) =
                lazy.call(fixture.source, oldest.advertised, "{\"message\":\"hi\"}")
              Nil
            }
          }
          assert call_count(control) == dispatched + 1
        }
      }
      assert seen(control, "initialize") == 2
      close_fixture(fixture)
      Nil
    },
  )
}

/// The raw tool name and schema of every adopted definition, in order.
fn adopted(source: lazy.Source) -> List(#(String, Dynamic)) {
  list.map(definitions(source), fn(definition) {
    #(definition.tool, definition.parameters)
  })
}

fn expected(tools: List(Tool)) -> List(#(String, Dynamic)) {
  list.map(tools, fn(tool) { #(tool.name, parsed(json.to_string(tool.schema))) })
}

// The manager's own view.

pub type Definition {
  Definition(advertised: String, server: String, tool: String, parameters: Dynamic)
}

fn definitions(source: lazy.Source) -> List(Definition) {
  let assert Ok(found) =
    json.parse(
      lazy.definitions(source),
      decode.list({
        use name <- decode.field("name", decode.string)
        use server <- decode.field("server", decode.string)
        use tool <- decode.field("tool", decode.string)
        use parameters <- decode.field("parameters", decode.dynamic)
        decode.success(Definition(name, server, tool, parameters))
      }),
    )
  found
}

fn advertised(source: lazy.Source) -> String {
  advertised_for(source, server_name)
}

fn advertised_for(source: lazy.Source, server: String) -> String {
  let assert Ok(definition) =
    list.find(definitions(source), fn(definition) { definition.server == server })
  definition.advertised
}

/// Whether the manager reports the rec server connected.
fn connected(source: lazy.Source) -> Bool {
  connected_for(source, server_name)
}

fn connected_for(source: lazy.Source, server: String) -> Bool {
  let assert Ok(listed) =
    json.parse(
      lazy.servers(source),
      decode.list({
        use name <- decode.field("name", decode.string)
        use connected <- decode.field("connected", decode.bool)
        decode.success(#(name, connected))
      }),
    )
  case list.find(listed, fn(entry) { entry.0 == server }) {
    Ok(entry) -> entry.1
    Error(Nil) -> False
  }
}

/// Waits until the manager reports the transport disconnected.
fn await_disconnected(source: lazy.Source, deadline: Int) -> Nil {
  await_disconnected_for(source, server_name, deadline)
}

fn await_disconnected_for(source: lazy.Source, server: String, deadline: Int) -> Nil {
  case connected_for(source, server) {
    True -> {
      assert albedo_clock.monotonic_ms() < deadline
        as "the manager recorded a dropped MCP transport"
      process.sleep(10)
      await_disconnected_for(source, server, deadline)
    }
    False -> Nil
  }
}

fn result_text(result: String) -> String {
  let assert Ok([text]) =
    json.parse(
      result,
      decode.at(["content"], decode.list(decode.at(["text"], decode.string))),
    )
  text
}

// The recording server's files.

fn seen(control: String, method: String) -> Int {
  read(control <> "/seen")
  |> result.unwrap("")
  |> string.split("\n")
  |> list.filter(fn(line) { line == method })
  |> list.length
}

fn call_count(control: String) -> Int {
  call_lines(control) |> list.length
}

fn last_call(control: String) -> String {
  let assert Ok(line) = list.last(call_lines(control))
  line
}

fn call_lines(control: String) -> List(String) {
  read(control <> "/calls")
  |> result.unwrap("")
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
}

fn server_pid(control: String) -> String {
  let assert Ok(pid) = read(control <> "/pid")
  string.trim(pid)
}


fn kill(pid: String) -> Nil {
  let _ = os_cmd(charlist("kill -9 " <> pid))
  Nil
}

/// Waits up to `tries` tenths of a second for OS process `pid` to exit.
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
    True -> False
    False ->
      case read("/proc/" <> pid <> "/stat") {
        Error(Nil) -> False
        // A zombie has exited.
        Ok(stat) -> !string.contains(stat, ") Z ")
      }
  }
}

/// The text as JSON, for structural comparison with another parse.
fn parsed(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> b

@external(erlang, "albedo_suite_test_support", "fake_mcp_server")
fn fake_server() -> #(String, String)

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "file", "write_file")
fn write_file(path: String, contents: String) -> Dynamic

@external(erlang, "file", "make_dir")
fn make_dir(path: String) -> Dynamic

@external(erlang, "os", "cmd")
fn os_cmd(command: List(Int)) -> List(Int)

@external(erlang, "unicode", "characters_to_list")
fn charlist(text: String) -> List(Int)

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

@external(erlang, "unicode", "characters_to_binary")
fn utf8_check(bytes: BitArray) -> Dynamic

fn write(path: String, contents: String) -> Nil {
  let _ = write_file(path, contents)
  Nil
}
