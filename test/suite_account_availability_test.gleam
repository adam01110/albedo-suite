//// Per-account availability: `enabled: false` on one saved account takes it
//// out of rotation without touching its siblings, its setups or its
//// credential, survives signing in again, and comes back when enabled.

import albedo_sdk/accounts
import albedo_sdk/auth_accounts
import albedo_sdk/key_environment
import albedo_sdk/oauth
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

const first = "0190a000-0000-7000-8000-000000000001"

const second = "0190a000-0000-7000-8000-000000000002"

const creds =
  "{\"accounts\":{\"openai\":[
  {\"type\":\"key\",\"apiKey\":\"key-1\",\"endpoint\":\"https://a.example/v1\",\"label\":\"one\",\"_albedo_account_id\":\"0190a000-0000-7000-8000-000000000001\"},
  {\"type\":\"key\",\"apiKey\":\"key-2\",\"endpoint\":\"https://a.example/v1\",\"label\":\"two\",\"_albedo_account_id\":\"0190a000-0000-7000-8000-000000000002\"}
]}}"

const config =
  "{\"active\":\"rotating\",\"providers\":{\"rotating\":{\"extension\":\"openai\",\"baseUrl\":\"https://a.example/v1\",\"model\":\"m\",\"accountIds\":[\"0190a000-0000-7000-8000-000000000001\",\"0190a000-0000-7000-8000-000000000002\"],\"rotation\":\"failover\"}}}"

pub fn main() -> Nil {
  use home <- scratch
  write(home, "creds.json", creds)
  write(home, "config.json", config)
  let before = read(home, "config.json")

  // Disabling one account answers with it disabled and changes only its row.
  let assert Ok(answer) = patch(home, first, None, Some(False))
  assert enabled_in(answer) == Ok(False)
  assert row(home, first, "enabled") == Ok(dynamic.bool(False))
  assert row(home, second, "enabled") == Error(Nil)
  assert row(home, first, "apiKey") == Ok(dynamic.string("key-1"))
  assert read(home, "config.json") == before

  // Rotation skips it and keeps its sibling, whatever the rotation.
  assert labels(rows(home)) == ["two"]

  // Renaming leaves the switch alone; enabling clears the mark.
  let assert Ok(_) = patch(home, first, Some("renamed"), None)
  assert row(home, first, "enabled") == Ok(dynamic.bool(False))
  let assert Ok(answer) = patch(home, first, None, Some(True))
  assert enabled_in(answer) == Ok(True)
  assert row(home, first, "enabled") == Error(Nil)
  assert labels(rows(home)) == ["renamed", "two"]

  // A patch naming nothing, or an unknown account, is refused.
  let assert Error(#(400, _, _)) = patch(home, first, None, None)
  let assert Error(#(404, _, _)) =
    patch(home, "0190a000-0000-7000-8000-000000000009", None, Some(False))

  signing_in_again_keeps_an_account_disabled()
  io.println("suite_account_availability_test: ok")
}

fn signing_in_again_keeps_an_account_disabled() -> Nil {
  let describe = fn(value: Dynamic) {
    let id =
      decode.run(value, decode.at(["sub"], decode.string)) |> result.unwrap("")
    oauth.account(id:, label: id, detail: "", selected: False)
  }
  let saved =
    json_value(
      "{\"accounts\":{\"store\":[{\"sub\":\"a\",\"token\":\"old\",\"enabled\":false,\"_albedo_account_id\":\"pub\"}]}}",
    )
  let fresh = json_value("{\"sub\":\"a\",\"token\":\"new\"}")
  let #(id, next) =
    auth_accounts.signed_in(saved, "store", fresh, describe, "a", "store")
  assert id == "pub"
  // One saved account stays a single object, as it was stored.
  assert decode.run(
      next,
      decode.at(["accounts", "store", "token"], decode.string),
    )
    == Ok("new")
  assert decode.run(
      next,
      decode.at(["accounts", "store", "enabled"], decode.bool),
    )
    == Ok(False)
}

fn patch(home, id, label, enabled) {
  auth_accounts.patch_account(
    home,
    [],
    id,
    label,
    enabled,
    key_environment.empty(),
  )
}

fn enabled_in(answer: String) -> Result(Bool, Nil) {
  json.parse(answer, decode.at(["enabled"], decode.bool))
  |> result.replace_error(Nil)
}

/// The saved key rows a rotation over them can use.
fn rows(home: String) -> List(Dynamic) {
  let assert Ok(values) =
    decode.run(
      read(home, "creds.json"),
      decode.at(["accounts", "openai"], decode.list(decode.dynamic)),
    )
  accounts.arrange("openai", values, "session", fn(_) { "" }, fn(v) { v }, None)
}

fn labels(values: List(Dynamic)) -> List(String) {
  list.map(values, fn(value) {
    decode.run(value, decode.at(["label"], decode.string)) |> result.unwrap("")
  })
  |> list.sort(string.compare)
}

fn row(home: String, id: String, field: String) -> Result(Dynamic, Nil) {
  let assert Ok(values) =
    decode.run(
      read(home, "creds.json"),
      decode.at(["accounts", "openai"], decode.list(decode.dynamic)),
    )
  list.find(values, fn(value) {
    decode.run(value, decode.at(["_albedo_account_id"], decode.string))
    == Ok(id)
  })
  |> result.try(fn(value) {
    decode.run(value, decode.at([field], decode.dynamic))
    |> result.replace_error(Nil)
  })
}

// ---- homes ------------------------------------------------------------------

fn scratch(run: fn(String) -> Nil) -> Nil {
  let home =
    "/tmp/albedo-account-availability-test-"
    <> int.to_string(int.absolute_value(unique_integer()))
  let _ = make_dir(home)
  run(home)
  let _ = del_dir_r(home)
  Nil
}

fn write(home: String, file: String, text: String) -> Nil {
  let _ = write_file(home <> "/" <> file, text)
  Nil
}

fn read(home: String, file: String) -> Dynamic {
  let assert Ok(text) = read_file(home <> "/" <> file)
  json_value(text)
}

fn json_value(text: String) -> Dynamic {
  let assert Ok(value) = json.parse(text, decode.dynamic)
  value
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "file", "make_dir")
fn make_dir(path: String) -> Dynamic

@external(erlang, "file", "write_file")
fn write_file(path: String, text: String) -> Dynamic

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(String, Dynamic)

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> Dynamic
