import albedo/daemon/store
import albedo/harness/settings
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

const columns =
  "p.profile,p.provider,p.model,p.input_tokens,p.cached_input_tokens,p.cache_creation_tokens,p.cache_write_5m_tokens,p.cache_write_1h_tokens,p.output_tokens,p.outcome"

/// Each session's estimate as of its request `through`, priced with the
/// catalog revision `catalog`; `usd` is NULL when a request could not be
/// priced. `requests` counts the rows up to `through`, so a cache row whose
/// session lost rows is recomputed instead of trusted.
const schema =
  "CREATE TABLE IF NOT EXISTS suite_session_costs(session TEXT PRIMARY KEY,catalog TEXT NOT NULL,usd REAL,requests INTEGER NOT NULL,through INTEGER NOT NULL)"

/// Bumped whenever pricing rules change, so cached estimates are recomputed.
const pricing = "1"

type Cached {
  Cached(session: String, valid: Bool, usd: Option(Float), requests: Int, through: Int)
}

type Estimate {
  Estimate(session: String, usd: Option(Float), requests: Int, through: Int)
}

/// Estimated USD for every metered request, including summaries and warmups.
/// An unpriced or unmetered successful request makes the total unknown, not
/// free; a failure without reported usage was not metered and costs nothing.
pub fn total(ledger: store.Store, session: String) -> Option(Float) {
  totals(ledger, [session])(session)
}

/// `total` for a page of sessions with one ledger read and one price lookup.
/// A session without requests costs zero; a failed read prices none of them.
pub fn totals(
  ledger: store.Store,
  sessions: List(String),
) -> fn(String) -> Option(Float) {
  let priced = case sessions {
    [] -> Ok(dict.new())
    _ ->
      estimates(
        ledger,
        "SELECT value FROM json_each(?)",
        [sqlight.text(json.to_string(json.array(sessions, json.string)))],
      )
      |> result.map(fn(found) {
        list.map(found, fn(estimate) { #(estimate.session, estimate.usd) })
        |> dict.from_list
      })
  }
  case priced {
    Ok(priced) -> fn(session) {
      dict.get(priced, session) |> result.unwrap(Some(0.0))
    }
    Error(_) -> fn(_) { None }
  }
}

/// Estimated USD across every stored session, archived and child sessions
/// included, with whether any session had an unpriced request and so was left
/// out. A failed read or an unreadable catalog prices nothing.
pub fn overall(ledger: store.Store) -> Option(#(Float, Bool)) {
  case estimates(ledger, "SELECT DISTINCT session FROM provider_requests", []) {
    Ok(found) ->
      Some(
        list.fold(found, #(0.0, False), fn(total, estimate) {
          case estimate.usd {
            Some(cost) -> #(total.0 +. cost, total.1)
            None -> #(total.0, True)
          }
        }),
      )
    Error(_) -> None
  }
}

/// Prices the sessions `target` selects from their cached estimates plus the
/// requests recorded since, then saves the advanced estimates without waiting
/// for the writer. Only requests newer than a valid cache row are priced.
fn estimates(
  ledger: store.Store,
  target: String,
  arguments: List(sqlight.Value),
) -> Result(List(Estimate), Nil) {
  let catalog = catalog()
  let revision = pricing <> ":" <> revision(catalog)
  let load = fn() {
    store.snapshot(ledger, fn(db) { read(db, catalog, revision, target, arguments) })
  }
  use #(found, changed) <- result.map(case load() {
    Ok(found) -> Ok(found)
    Error(_) -> {
      // The cache table is created on first use; a fresh ledger lacks it.
      use _ <- result.try(
        store.query(ledger, fn(db) { store.exec(db, schema) })
        |> result.replace_error(Nil),
      )
      load() |> result.replace_error(Nil)
    }
  })
  case changed {
    [] -> Nil
    _ -> store.query_then(ledger, fn(db) { save(db, revision, changed) }, fn(_) { Nil })
  }
  found
}

fn read(
  db: sqlight.Connection,
  catalog: String,
  revision: String,
  target: String,
  arguments: List(sqlight.Value),
) -> Result(#(List(Estimate), List(Estimate)), String) {
  use cached <- result.try(store.rows(
    db,
    "WITH target(session) AS ("
      <> target
      <> ") SELECT t.session,c.session IS NOT NULL AND c.requests=(SELECT COUNT(*) FROM provider_requests p WHERE p.session=t.session AND p.id<=c.through),c.usd,COALESCE(c.requests,0),COALESCE(c.through,0) FROM target t LEFT JOIN suite_session_costs c ON c.session=t.session AND c.catalog=?",
    list.append(arguments, [sqlight.text(revision)]),
    {
      use session <- decode.field(0, decode.string)
      use valid <- decode.field(1, decode.int)
      use usd <- decode.field(2, decode.optional(decode.float))
      use requests <- decode.field(3, decode.int)
      use through <- decode.field(4, decode.int)
      decode.success(Cached(session, valid != 0, usd, requests, through))
    },
  ))
  // Requests after each valid cache row, or every request of the rest.
  let after =
    json.to_string(
      json.array(cached, fn(row) {
        json.preprocessed_array([
          json.string(row.session),
          json.int(case row.valid {
            True -> row.through
            False -> 0
          }),
        ])
      }),
    )
  let pending =
    "WITH after(session,id) AS (SELECT json_extract(value,'$[0]'),json_extract(value,'$[1]') FROM json_each(?)) "
  use stats <- result.try(store.rows(
    db,
    pending
      <> "SELECT p.session,COUNT(*),MAX(p.id) FROM after a JOIN provider_requests p ON p.session=a.session AND p.id>a.id GROUP BY p.session",
    [sqlight.text(after)],
    {
      use session <- decode.field(0, decode.string)
      use count <- decode.field(1, decode.int)
      use through <- decode.field(2, decode.int)
      decode.success(#(session, #(count, through)))
    },
  ))
  use priced <- result.try(case stats {
    [] -> Ok(dict.new())
    _ -> {
      use rows <- result.try(store.rows(
        db,
        pending
          <> "SELECT p.session,"
          <> columns
          <> ",COUNT(*) FROM after a JOIN provider_requests p ON p.session=a.session AND p.id>a.id GROUP BY p.session,"
          <> columns,
        [sqlight.text(after)],
        decode.dynamic,
      ))
      estimate_sessions(catalog, rows)
      |> result.map(dict.from_list)
      |> result.replace_error("models catalog is unreadable")
    }
  })
  let stats = dict.from_list(stats)
  Ok(
    list.fold(list.reverse(cached), #([], []), fn(acc, row) {
      let base = case row.valid {
        True -> Estimate(row.session, row.usd, row.requests, row.through)
        False -> Estimate(row.session, Some(0.0), 0, 0)
      }
      case dict.get(stats, row.session) {
        Ok(#(count, through)) -> {
          let added = dict.get(priced, row.session) |> result.unwrap(Some(0.0))
          let next =
            Estimate(
              row.session,
              option.then(base.usd, fn(a) { option.map(added, float.add(a, _)) }),
              base.requests + count,
              int.max(base.through, through),
            )
          #([next, ..acc.0], [next, ..acc.1])
        }
        Error(_) -> #([base, ..acc.0], acc.1)
      }
    }),
  )
}

fn save(
  db: sqlight.Connection,
  revision: String,
  changed: List(Estimate),
) -> Result(Nil, String) {
  use <- store.transaction(db)
  use _ <- result.try(store.exec(db, schema))
  list.try_each(changed, fn(estimate) {
    store.run(
      db,
      "INSERT INTO suite_session_costs(session,catalog,usd,requests,through) VALUES(?,?,?,?,?) ON CONFLICT(session) DO UPDATE SET catalog=excluded.catalog,usd=excluded.usd,requests=excluded.requests,through=excluded.through WHERE excluded.catalog<>suite_session_costs.catalog OR excluded.through>=suite_session_costs.through",
      [
        sqlight.text(estimate.session),
        sqlight.text(revision),
        sqlight.nullable(sqlight.float, estimate.usd),
        sqlight.int(estimate.requests),
        sqlight.int(estimate.through),
      ],
    )
  })
}

fn catalog() -> String {
  settings.home() <> "/models.json"
}

@external(erlang, "albedo_session_cost", "revision")
fn revision(catalog: String) -> String

@external(erlang, "albedo_session_cost", "estimate_sessions")
fn estimate_sessions(
  catalog: String,
  rows: List(dynamic.Dynamic),
) -> Result(List(#(String, Option(Float))), Nil)
