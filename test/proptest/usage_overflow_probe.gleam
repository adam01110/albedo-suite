//// Probe: what SQLite and the usage reads do when provider-reported token
//// counts approach the int64 range. Not a property test; run explicitly with
//// `gleam run -m usage_overflow_probe` in an overlay tree.

import albedo/generated/sql/usage/usage_hours_sql
import albedo/refusal
import albedo/storage/core_store
import albedo/usage/usage_hours
import albedo/usage/usage_profile
import albedo_sdk/store
import albedo_sqlite
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import sqlight

const day = 86_400_000

const hour = 3_600_000

const max = 9_223_372_036_854_775_807

const base_day = 20_412

fn ledger() -> store.Store {
  let assert Ok(ledger) =
    store.start(":memory:", fn(db) {
      use _ <- result.try(usage_hours_sql.create_usage_hours(db:))
      albedo_sqlite.exec("CREATE TABLE input_turns(id TEXT PRIMARY KEY,session TEXT NOT NULL,state TEXT NOT NULL,started_at INTEGER NOT NULL,ended_at INTEGER);", on: db)
    }, core_store.tables())
  ledger
}

fn insert(ledger: store.Store, rows: List(#(Int, Int, Int, Int))) -> Nil {
  list.index_map(rows, fn(row, i) {
    let #(at, input, output, calls) = row
    let assert Ok(_) =
      store.writing(ledger, fn(db) { albedo_sqlite.run("INSERT INTO usage_hours(hour_ms,profile,provider,account,model,kind,calls,errors,input_tokens,cached_input_tokens,cache_creation_tokens,output_tokens,reasoning_tokens) VALUES(?,'p','prov','',?,'turn',?,0,?,0,0,?,0)", on: db, with: [
          sqlight.int(at),
          sqlight.text("m" <> int.to_string(i)),
          sqlight.int(calls),
          sqlight.int(input),
          sqlight.int(output),
        ]) })
    Nil
  })
  Nil
}

fn raw(label: String, sql: String, ledger: store.Store) -> Nil {
  let found =
    store.reading(ledger, fn(db) { albedo_sqlite.rows(sql, on: db, with: [], expecting: decode.field(0, decode.dynamic, decode.success)) })
  io.println("  raw " <> label <> ": " <> string.inspect(found))
}

fn scenario(label: String, rows: List(#(Int, Int, Int, Int))) -> Nil {
  let ledger = ledger()
  insert(ledger, rows)
  io.println("case: " <> label)
  raw("SUM(input)", "SELECT SUM(input_tokens) FROM usage_hours", ledger)
  raw(
    "SUM(input+output)",
    "SELECT SUM(input_tokens+output_tokens) FROM usage_hours",
    ledger,
  )
  raw("TOTAL(input)", "SELECT TOTAL(input_tokens) FROM usage_hours", ledger)
  io.println(
    "  profile: "
    <> string.inspect(usage_profile.read(ledger, base_day * day + 12 * hour, 0)),
  )
  let summary =
    usage_hours.summary(
      ledger,
      base_day * day + 12 * hour,
      371,
      0,
      usage_hours.AllScopes,
    )
  io.println(
    "  summary: "
    <> case summary {
      Ok(found) ->
        "Ok lines="
        <> string.inspect(found.lines)
        <> " last_day="
        <> string.inspect(list.last(found.days))
      Error(error) -> "Error " <> error
    },
  )
  store.close(ledger)
}


const trigger =
  "CREATE TRIGGER IF NOT EXISTS provider_requests_usage AFTER INSERT ON provider_requests WHEN (SELECT stage FROM sessions WHERE id=NEW.session)<>'importing' BEGIN INSERT INTO usage_hours(hour_ms,profile,provider,account,model,kind,calls,errors,input_tokens,cached_input_tokens,cache_creation_tokens,output_tokens,reasoning_tokens) VALUES(NEW.finished_ms/3600000*3600000,NEW.profile,NEW.provider,COALESCE(NEW.account,''),NEW.model,NEW.kind,1,NEW.outcome<>'ok',COALESCE(NEW.input_tokens,0),COALESCE(NEW.cached_input_tokens,0),COALESCE(NEW.cache_creation_tokens,0),COALESCE(NEW.output_tokens,0),COALESCE(NEW.reasoning_tokens,0)) ON CONFLICT(hour_ms,profile,provider,account,model,kind) DO UPDATE SET calls=calls+1,errors=errors+excluded.errors,input_tokens=input_tokens+excluded.input_tokens,cached_input_tokens=cached_input_tokens+excluded.cached_input_tokens,cache_creation_tokens=cache_creation_tokens+excluded.cache_creation_tokens,output_tokens=output_tokens+excluded.output_tokens,reasoning_tokens=reasoning_tokens+excluded.reasoning_tokens; END;"

const provider_requests_schema =
  "CREATE TABLE provider_requests(id INTEGER PRIMARY KEY,session TEXT NOT NULL,profile TEXT NOT NULL,provider TEXT NOT NULL,account TEXT,model TEXT NOT NULL,kind TEXT NOT NULL,finished_ms INTEGER NOT NULL,outcome TEXT NOT NULL,input_tokens INTEGER,cached_input_tokens INTEGER,cache_creation_tokens INTEGER,output_tokens INTEGER,reasoning_tokens INTEGER);"

const sessions_schema =
  "CREATE TABLE sessions(id TEXT PRIMARY KEY,stage TEXT NOT NULL);"

fn trigger_ledger() -> store.Store {
  let assert Ok(ledger) =
    store.start(":memory:", fn(db) {
      use _ <- result.try(usage_hours_sql.create_usage_hours(db:))
      albedo_sqlite.exec(provider_requests_schema
        <> sessions_schema
        <> trigger
        <> "CREATE TABLE input_turns(id TEXT PRIMARY KEY,session TEXT NOT NULL,state TEXT NOT NULL,started_at INTEGER NOT NULL,ended_at INTEGER);", on: db)
    }, core_store.tables())
  let assert Ok(_) =
    store.writing(ledger, fn(db) { albedo_sqlite.run("INSERT INTO sessions VALUES('s','active')", on: db, with: []) })
  ledger
}

fn request(ledger: store.Store, i: Int, input: Int) -> Nil {
  let assert Ok(_) =
    store.writing(ledger, fn(db) { albedo_sqlite.run("INSERT INTO provider_requests(id,session,profile,provider,account,model,kind,finished_ms,outcome,input_tokens,cached_input_tokens,cache_creation_tokens,output_tokens,reasoning_tokens) VALUES(?,'s','p','prov',NULL,'m','turn',?,'ok',?,NULL,NULL,0,NULL)", on: db, with: [sqlight.int(i), sqlight.int(base_day * day + hour), sqlight.int(input)]) })
  Nil
}

fn report(label: String, ledger: store.Store) -> Nil {
  io.println("case: " <> label)
  raw(
    "typeof(input_tokens)",
    "SELECT DISTINCT typeof(input_tokens) FROM usage_hours",
    ledger,
  )
  raw("SUM(input)", "SELECT SUM(input_tokens) FROM usage_hours", ledger)
  io.println(
    "  profile: "
    <> string.inspect(usage_profile.read(ledger, base_day * day + 12 * hour, 0)),
  )
  io.println(
    "  summary: "
    <> string.inspect(usage_hours.summary(
      ledger,
      base_day * day + 12 * hour,
      371,
      0,
      usage_hours.AllScopes,
    )),
  )
}

fn trigger_probes() -> Nil {
  let ledger = trigger_ledger()
  request(ledger, 1, max)
  report("one call at int64 max input", ledger)
  request(ledger, 2, max)
  report("a second call at int64 max input, same hour", ledger)
  store.close(ledger)

  let ledger = trigger_ledger()
  request(ledger, 1, max / 2)
  request(ledger, 2, max / 2)
  report("two calls of half the int64 max each", ledger)
  request(ledger, 3, 10)
  report("a third, ordinary call after them", ledger)
  store.close(ledger)

  let ledger = trigger_ledger()
  request(ledger, 1, -5)
  request(ledger, 2, 7)
  report("a call reporting a negative input count", ledger)
  store.close(ledger)
  Nil
}

pub fn main() -> Nil {
  scenario("one row, input at int64 max", [#(base_day * day + hour, max, 0, 1)])
  scenario("two rows, inputs half of int64 max", [
    #(base_day * day + hour, max / 2 + 10, 0, 1),
    #(base_day * day + 2 * hour, max / 2, 7, 1),
  ])
  scenario("one row, input max and output 1", [
    #(base_day * day + hour, max, 1, 1),
  ])
  scenario("two rows, input max each", [
    #(base_day * day + hour, max, 0, 1),
    #(base_day * day + 2 * hour, max, 0, 1),
  ])
  scenario("one row, input max and output max", [
    #(base_day * day + hour, max, max, 1),
  ])
  scenario("ordinary counts", [
    #(base_day * day + hour, 120, 30, 3),
    #(base_day * day + 2 * hour, 7, 2, 1),
  ])
  trigger_probes()
  // How the endpoint reports a read that the aggregates refused.
  io.println(
    "usage_summary maps a storage failure to: "
    <> string.inspect(refusal.unavailable("integer overflow")),
  )
  Nil
}
