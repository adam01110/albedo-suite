//// Shared runner for the discovery property tests: case count and seed come
//// from PROPTEST_COUNT and PROPTEST_SEED, and each property prints the seed it
//// used plus behavioural coverage counters, so a run can be reproduced.

import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import qcheck

@external(erlang, "proptest_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "proptest_ffi", "bump")
pub fn bump(key: String) -> Nil

@external(erlang, "proptest_ffi", "counts")
fn counts() -> List(#(String, Int))

@external(erlang, "proptest_ffi", "reset")
fn reset() -> Nil

@external(erlang, "proptest_ffi", "putenv")
pub fn putenv(name: String, value: String) -> Nil

/// Writes a file with the given modification time in POSIX seconds.
@external(erlang, "proptest_ffi", "write_file")
pub fn write_file(path: String, bytes: BitArray, mtime: Int) -> Nil

@external(erlang, "proptest_ffi", "remove_tree")
pub fn remove_tree(path: String) -> Nil

/// The absolute path of a program on PATH.
@external(erlang, "proptest_ffi", "executable")
pub fn executable(name: String) -> Result(String, Nil)

@external(erlang, "proptest_ffi", "unique")
pub fn unique() -> Int

/// The Erlang atom `undefined`, which sqlight returns for SQL NULL.
@external(erlang, "proptest_ffi", "undefined")
pub fn undefined() -> Dynamic

fn env_int(name: String, default: Int) -> Int {
  getenv(name) |> result.try(int.parse) |> result.unwrap(default)
}

/// Runs `property` over `generator`, scaling the default count by `weight`
/// percent so slow properties can run fewer cases.
pub fn check(
  name: String,
  weight: Int,
  generator: qcheck.Generator(a),
  property: fn(a) -> Nil,
) -> Nil {
  let count = int.max(1, env_int("PROPTEST_COUNT", 1000) * weight / 100)
  let seed = env_int("PROPTEST_SEED", int.random(1_000_000_000))
  reset()
  io.println(
    name
    <> ": "
    <> int.to_string(count)
    <> " cases, PROPTEST_SEED="
    <> int.to_string(seed),
  )
  qcheck.run(
    qcheck.default_config()
      |> qcheck.with_test_count(count)
      |> qcheck.with_seed(qcheck.seed(seed)),
    generator,
    property,
  )
  let coverage =
    counts()
    |> list.map(fn(entry) { entry.0 <> "=" <> int.to_string(entry.1) })
    |> string.join(" ")
  io.println("  ok" <> case coverage {
    "" -> ""
    _ -> "  coverage: " <> coverage
  })
}
