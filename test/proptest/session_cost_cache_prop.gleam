//// The session cost cache (session_cost.gleam) against full recomputation:
//// histories of request inserts, lost rows, catalog changes and reads,
//// where every read must equal pricing the session's current rows with the
//// current catalog.

import albedo/storage/core_store
import albedo/usage/session_cost
import albedo_sdk/store
import albedo_sqlite
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import proptest
import qcheck
import session_cost_prop.{type Cost, type Rate, type Row, Bad, Num, Whole}
import sqlight

pub type Op {
  Insert(row: Row)
  /// Deletes the session's `nth` remaining row, as a session that lost rows.
  Lose(session: String, nth: Int)
  Reprice(catalog: List(#(#(String, String), Cost)))
  Total(session: String)
  Totals(sessions: List(String))
  Overall
  /// Waits for queued writes, including the cache's own save.
  Flush
}

pub type Case {
  Case(catalog: List(#(#(String, String), Cost)), ops: List(Op))
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn session() -> qcheck.Generator(String) {
  pick(["a", "b", "c", "d"])
}

fn op() -> qcheck.Generator(Op) {
  qcheck.from_weighted_generators(#(8, session_cost_prop.row() |> qcheck.map(Insert)), [
    #(2, qcheck.map2(session(), qcheck.bounded_int(0, 2), Lose)),
    #(1, session_cost_prop.catalog() |> qcheck.map(Reprice)),
    #(5, session() |> qcheck.map(Total)),
    #(2, qcheck.generic_list(session(), qcheck.bounded_int(0, 3)) |> qcheck.map(Totals)),
    #(2, qcheck.return(Overall)),
    #(3, qcheck.return(Flush)),
  ])
}

fn case_generator() -> qcheck.Generator(Case) {
  qcheck.map2(
    session_cost_prop.catalog(),
    qcheck.generic_list(op(), qcheck.bounded_int(0, 30)),
    Case,
  )
}

fn rate_json(rate: Rate) -> json.Json {
  case rate {
    Num(value) -> json.float(value)
    Whole(value) -> json.int(value)
    Bad -> json.string("free")
  }
}

fn rates_json(rates: List(#(String, Rate)), extra: List(#(String, json.Json))) -> json.Json {
  list.map(rates, fn(entry) { #(entry.0, rate_json(entry.1)) })
  |> list.append(extra)
  |> json.object
}

fn cost_json(cost: Cost) -> json.Json {
  let tiers =
    list.map(cost.tiers, fn(tier) {
      rates_json(tier.1, [
        #("tier", json.object([#("type", json.string("context")), #("size", json.int(tier.0))])),
      ])
    })
  let extra = case tiers {
    [] -> []
    _ -> [#("tiers", json.preprocessed_array(tiers))]
  }
  let extra = case cost.over_200k {
    None -> extra
    Some(rates) -> [#("context_over_200k", rates_json(rates, [])), ..extra]
  }
  rates_json(cost.rates, extra)
}

fn catalog_json(catalog: List(#(#(String, String), Cost))) -> String {
  ["p1", "p2"]
  |> list.map(fn(provider) {
    let models =
      list.filter_map(catalog, fn(entry) {
        let #(#(owner, model), cost) = entry
        case owner == provider {
          True -> Ok(#(model, json.object([#("id", json.string(model)), #("cost", cost_json(cost))])))
          False -> Error(Nil)
        }
      })
    #(
      provider,
      json.object([
        #("api", json.string("https://p.example/v1")),
        #("npm", json.string("@ai-sdk/openai-compatible")),
        #("models", json.object(models)),
      ]),
    )
  })
  |> json.object
  |> json.to_string
}

const schema =
  "CREATE TABLE provider_requests(id INTEGER PRIMARY KEY AUTOINCREMENT,session TEXT NOT NULL,profile TEXT NOT NULL,provider TEXT NOT NULL,model TEXT NOT NULL,outcome TEXT NOT NULL,input_tokens INTEGER,cached_input_tokens INTEGER,cache_creation_tokens INTEGER,cache_write_5m_tokens INTEGER,cache_write_1h_tokens INTEGER,output_tokens INTEGER);"

fn insert(ledger: store.Store, row: Row) -> Nil {
  let count = fn(value) { sqlight.nullable(sqlight.int, value) }
  list.repeat(Nil, row.count)
  |> list.each(fn(_) {
    let assert Ok(_) =
      store.writing(ledger, fn(db) { albedo_sqlite.run("INSERT INTO provider_requests(session,profile,provider,model,outcome,input_tokens,cached_input_tokens,cache_creation_tokens,cache_write_5m_tokens,cache_write_1h_tokens,output_tokens) VALUES(?,?,?,?,?,?,?,?,?,?,?)", on: db, with: [
          sqlight.text(row.session),
          sqlight.text(row.profile),
          sqlight.text("chat_completions:https://p.example/v1"),
          sqlight.text(row.model),
          sqlight.text(case row.ok {
            True -> "ok"
            False -> "error"
          }),
          count(row.input),
          count(row.cached),
          count(row.created),
          count(row.w5),
          count(row.w1),
          count(row.output),
        ]) })
    Nil
  })
}

type Model {
  Model(catalog: List(#(#(String, String), Cost)), rows: List(Row))
}

fn session_rows(model: Model, session: String) -> List(Row) {
  list.filter(model.rows, fn(row) { row.session == session })
}

fn expected_total(model: Model, session: String) -> Option(Float) {
  session_cost_prop.model_total(model.catalog, session_rows(model, session))
}

fn show(value: Option(Float)) -> String {
  case value {
    None -> "unknown"
    Some(x) -> float.to_string(x)
  }
}

fn expect(what: String, found: Option(Float), expected: Option(Float)) -> Nil {
  case session_cost_prop.close(found, expected) {
    True -> Nil
    False -> panic as { what <> ": cache " <> show(found) <> ", recomputed " <> show(expected) }
  }
}

pub fn main() -> Nil {
  proptest.check("cached session costs equal full recomputation", 10, case_generator(), fn(c) {
    let home = "/tmp/albedo-proptest-cost-" <> int.to_string(proptest.unique())
    // Unique integers restart with the VM, so an earlier run's home may remain.
    proptest.remove_tree(home)
    proptest.putenv("ALBEDO_HOME", home)
    let catalog_path = home <> "/models.json"
    // Each rewrite gets a later modification time, a distinct revision.
    let write_catalog = fn(catalog, version) {
      proptest.write_file(catalog_path, <<catalog_json(catalog):utf8>>, 1_700_000_000 + version)
    }
    write_catalog(c.catalog, 0)
    let assert Ok(ledger) = store.start(home <> "/ledger.db", albedo_sqlite.exec(schema, on: _), core_store.tables())
    let _ =
      list.fold(c.ops, #(Model(c.catalog, []), 1), fn(state, op) {
        let #(model, version) = state
        case op {
          Insert(row) -> {
            // The ledger stores one row per request.
            insert(ledger, row)
            #(Model(..model, rows: list.append(model.rows, list.repeat(session_cost_prop.Row(..row, count: 1), row.count))), version)
          }
          Lose(session, nth) -> {
            let own = session_rows(model, session)
            case nth < list.length(own) {
              False -> state
              True -> {
                proptest.bump("lose")
                let assert Ok(_) =
                  store.writing(ledger, fn(db) { albedo_sqlite.run("DELETE FROM provider_requests WHERE id=(SELECT id FROM provider_requests WHERE session=? ORDER BY id LIMIT 1 OFFSET ?)", on: db, with: [sqlight.text(session), sqlight.int(nth)]) })
                let #(_, kept) =
                  list.fold(model.rows, #(0, []), fn(acc, row) {
                    let #(seen, kept) = acc
                    case row.session == session {
                      True if seen == nth -> #(seen + 1, kept)
                      True -> #(seen + 1, [row, ..kept])
                      False -> #(seen, [row, ..kept])
                    }
                  })
                #(Model(..model, rows: list.reverse(kept)), version)
              }
            }
          }
          Reprice(catalog) -> {
            write_catalog(catalog, version)
            #(Model(..model, catalog: catalog), version + 1)
          }
          Total(session) -> {
            let expected = expected_total(model, session)
            proptest.bump(case expected {
              None -> "read_unknown"
              Some(_) -> "read_priced"
            })
            expect("total " <> session, session_cost.total(ledger, session), expected)
            state
          }
          Totals(sessions) -> {
            let found = session_cost.totals(ledger, sessions)
            list.each(sessions, fn(session) {
              expect("totals " <> session, found(session), expected_total(model, session))
            })
            state
          }
          Overall -> {
            let sessions = list.map(model.rows, fn(row) { row.session }) |> list.unique
            let expected =
              list.fold(sessions, #(0.0, False), fn(acc, session) {
                case expected_total(model, session) {
                  Some(cost) -> #(acc.0 +. cost, acc.1)
                  None -> #(acc.0, True)
                }
              })
            let assert Some(found) = session_cost.overall(ledger)
            expect("overall", Some(found.0), Some(expected.0))
            assert found.1 == expected.1
            state
          }
          Flush -> {
            store.query(ledger, fn(_) { Nil })
            state
          }
        }
      })
    store.close(ledger)
    proptest.remove_tree(home)
  })
}
