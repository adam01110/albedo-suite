//// Session cost estimates read through the ledger cache: a page that names a
//// session twice prices it once, and the cache it leaves behind still
//// answers the single-session total.

import albedo/storage/core_store
import albedo/usage/session_cost
import albedo_sdk/store
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/io
import gleam/option.{Some}

const catalog =
  "{\"p\":{\"api\":\"https://p.example/v1\",\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"m\":{\"id\":\"m\",\"cost\":{\"input\":1,\"output\":2}}}}}"

const schema =
  "CREATE TABLE provider_requests(id INTEGER PRIMARY KEY AUTOINCREMENT,session TEXT NOT NULL,profile TEXT NOT NULL,provider TEXT NOT NULL,model TEXT NOT NULL,outcome TEXT NOT NULL,input_tokens INTEGER,cached_input_tokens INTEGER,cache_creation_tokens INTEGER,cache_write_5m_tokens INTEGER,cache_write_1h_tokens INTEGER,output_tokens INTEGER);"

pub fn main() -> Nil {
  let home =
    "/tmp/albedo-suite-session-cost-"
    <> int.to_string(list_to_integer(getpid()))
    <> "-"
    <> int.to_string(unique())
  // The OS reuses process ids, so a crashed run's home can carry this name.
  let _ = del_dir_r(home)
  let _ = make_dir(home)
  let _ = putenv(charlist("ALBEDO_HOME"), charlist(home))
  let _ = write_file(home <> "/models.json", catalog)
  let assert Ok(ledger) =
    store.start(home <> "/ledger.db", schema, core_store.tables())
  // One million input tokens at 1 USD per million.
  let assert Ok(_) =
    store.write(
      ledger,
      "INSERT INTO provider_requests(session,profile,provider,model,outcome,input_tokens,output_tokens) VALUES('a','p','chat_completions:https://p.example/v1','m','ok',1000000,0)",
      [],
    )
  let page = session_cost.totals(ledger, ["a", "a", "b"])
  assert page("a") == Some(1.0)
  assert page("b") == Some(0.0)
  // Wait for the cache the page saved, then read it back.
  store.query(ledger, fn(_) { Nil })
  assert session_cost.total(ledger, "a") == Some(1.0)
  assert session_cost.totals(ledger, ["a", "a"])("a") == Some(1.0)
  store.close(ledger)
  let _ = del_dir_r(home)
  io.println("Session cost: repeated sessions in a page are priced once passed")
}

@external(erlang, "file", "make_dir")
fn make_dir(path: String) -> Dynamic

@external(erlang, "file", "write_file")
fn write_file(path: String, contents: String) -> Dynamic

@external(erlang, "file", "del_dir_r")
fn del_dir_r(path: String) -> Dynamic

@external(erlang, "os", "putenv")
fn putenv(name: List(Int), value: List(Int)) -> Bool

@external(erlang, "unicode", "characters_to_list")
fn charlist(text: String) -> List(Int)

@external(erlang, "os", "getpid")
fn getpid() -> List(Int)

@external(erlang, "erlang", "list_to_integer")
fn list_to_integer(chars: List(Int)) -> Int

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int
