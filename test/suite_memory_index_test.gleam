//// The memory startup block is a bounded topic index of own and linked
//// notes, while reads, search documents and writes keep every full note.

import albedo/harness/extensions/memory/files
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/io
import gleam/list
import gleam/string

pub fn main() -> Nil {
  let home = "/tmp/albedo-suite-memory-" <> int.to_string(unique())
  set_env("ALBEDO_HOME", home)
  let own = "/workspace/own"
  let linked = "host:/workspace/linked"
  let topics =
    numbers(19, [])
    |> list.map(fn(i) {
      "Topic " <> int.to_string(i) <> "\nBody " <> int.to_string(i)
    })
    |> string.join("\n\n")
  let original =
    "Old hidden constraint\n" <> string.repeat("秘密 ", 3000) <> "\n\n" <> topics
  assert files.load([]) == Ok("")
  assert files.load([own]) == Ok("")
  let assert Ok(_) = files.save(own, original)
  let assert Ok(_) = files.save(linked, "Linked constraint\nLINKED_FULL_BODY")
  let assert Ok(index) = files.load([own, linked])
  assert string.length(index) < 2200
  assert !string.contains(index, "Old hidden constraint")
  assert !string.contains(index, "LINKED_FULL_BODY")
  assert string.contains(index, "Topic 19")
  assert !string.contains(index, "Topic 7\n")
  assert string.contains(index, "\n## " <> linked <> "\n- Linked constraint")
  assert files.linked([linked])
    |> string.contains("- Linked constraint")
  assert files.read(own) == Ok(original)
  let assert Ok(_) = files.journal(linked, "2026-10-23", "JOURNAL_FULL_BODY")
  let #(documents, truncated) = files.documents([own, linked])
  assert !truncated
  assert list.contains(documents, #(own, "memory.md", original))
  assert list.contains(documents, #(
    linked,
    "journal/2026-10-23.md",
    "JOURNAL_FULL_BODY\n",
  ))
  let assert Ok(_) = files.append(own, "OWN_APPEND")
  assert files.read(linked) == Ok("Linked constraint\nLINKED_FULL_BODY")
  let assert Ok(current) = files.read(own)
  assert string.contains(current, "OWN_APPEND")
  let _ = del_dir_r(home)
  io.println(
    "Memory index: "
    <> int.to_string(string.byte_size(index))
    <> " index bytes for "
    <> int.to_string(string.byte_size(original))
    <> " note bytes; full reads, documents and writes passed",
  )
}

fn numbers(n: Int, acc: List(Int)) -> List(Int) {
  case n < 0 {
    True -> acc
    False -> numbers(n - 1, [n, ..acc])
  }
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
