//// Every workspace with notes stays named in the startup topic index, even
//// when an earlier section spends the whole shared topic budget: an agent has
//// to know which workspaces its search covers.

import albedo_ext_memory/files
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/io
import gleam/list
import gleam/string

pub fn main() -> Nil {
  let home =
    "/tmp/albedo-suite-memory-headings-"
    <> pid()
    <> "-"
    <> int.to_string(unique())
  // The OS reuses process ids, so a crashed run's home can carry this name.
  let _ = del_dir_r(home)
  set_env("ALBEDO_HOME", home)
  let own = "/workspace/own"
  let linked_a = "host:/workspace/linked-a"
  let linked_b = "host:/workspace/linked-b"
  // Twelve topics at the 120-character limit leave 124 characters of the
  // budget, which the first linked workspace spends before its topics end.
  let saturated =
    sequence(12, [])
    |> list.map(fn(index) {
      "Saturated topic "
      <> int.to_string(index)
      <> " "
      <> string.repeat("x", 110)
    })
    |> string.join("\n\n")
  let filled =
    sequence(12, [])
    |> list.map(fn(index) { "Linked topic " <> int.to_string(index) })
    |> string.join("\n\n")
  let assert Ok(_) = files.save(own, saturated)
  let assert Ok(_) = files.save(linked_a, filled)
  let assert Ok(_) = files.save(linked_b, "Second linked constraint")
  let assert Ok(index) = files.load([own, linked_a, linked_b])
  assert string.contains(index, "[more topics omitted")
  assert string.contains(index, "\n## " <> own)
  assert string.contains(index, "\n## " <> linked_a)
  assert string.contains(index, "\n## " <> linked_b)
  let _ = del_dir_r(home)
  io.println(
    "Memory headings: "
    <> int.to_string(string.byte_size(index))
    <> " index bytes naming own and "
    <> int.to_string(list.length([linked_a, linked_b]))
    <> " linked workspaces under a spent topic budget",
  )
}

/// 1, 2, ..., count.
fn sequence(count: Int, acc: List(Int)) -> List(Int) {
  case count <= 0 {
    True -> acc
    False -> sequence(count - 1, [count, ..acc])
  }
}

@external(erlang, "os", "getpid")
fn getpid() -> List(Int)

@external(erlang, "unicode", "characters_to_binary")
fn to_binary(chars: List(Int)) -> String

fn pid() -> String {
  to_binary(getpid())
}

@external(erlang, "os", "putenv")
fn putenv(name: List(Int), value: List(Int)) -> Bool

fn set_env(name: String, value: String) -> Nil {
  let _ = putenv(charlist(name), charlist(value))
  Nil
}

@external(erlang, "unicode", "characters_to_list")
fn charlist(text: String) -> List(Int)

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> Dynamic

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int
