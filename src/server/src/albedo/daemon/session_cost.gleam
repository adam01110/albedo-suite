import albedo/daemon/store
import albedo/harness/settings
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

const columns =
  "profile,provider,model,input_tokens,cached_input_tokens,cache_creation_tokens,cache_write_5m_tokens,cache_write_1h_tokens,output_tokens,outcome"

/// Estimated USD for every metered request, including summaries and warmups.
/// An unpriced or unmetered successful request makes the total unknown, not
/// free; a failure without reported usage was not metered and costs nothing.
pub fn total(ledger: store.Store, session: String) -> Option(Float) {
  let rows =
    store.snapshot(ledger, fn(db) {
      store.rows(
        db,
        "SELECT "
          <> columns
          <> ",COUNT(*) FROM provider_requests WHERE session=? GROUP BY "
          <> columns,
        [sqlight.text(session)],
        decode.dynamic,
      )
    })
  case rows {
    Ok(rows) -> estimate(catalog(), rows)
    Error(_) -> None
  }
}

/// `total` for a page of sessions with one ledger read and one price lookup.
/// A session without requests costs zero; a failed read prices none of them.
pub fn totals(
  ledger: store.Store,
  sessions: List(String),
) -> fn(String) -> Option(Float) {
  let priced = case sessions {
    [] -> Ok(dict.new())
    _ -> {
      use rows <- result.try(
        store.snapshot(ledger, fn(db) {
          store.rows(
            db,
            "SELECT session,"
              <> columns
              <> ",COUNT(*) FROM provider_requests WHERE session IN ("
              <> string.join(list.map(sessions, fn(_) { "?" }), ",")
              <> ") GROUP BY session,"
              <> columns,
            list.map(sessions, sqlight.text),
            decode.dynamic,
          )
        })
        |> result.replace_error(Nil),
      )
      estimate_sessions(catalog(), rows) |> result.map(dict.from_list)
    }
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
  let rows =
    store.snapshot(ledger, fn(db) {
      store.rows(
        db,
        "SELECT session,"
          <> columns
          <> ",COUNT(*) FROM provider_requests GROUP BY session,"
          <> columns,
        [],
        decode.dynamic,
      )
    })
    |> result.replace_error(Nil)
  case result.try(rows, estimate_sessions(catalog(), _)) {
    Ok(priced) ->
      Some(
        list.fold(priced, #(0.0, False), fn(total, session) {
          case session.1 {
            Some(cost) -> #(total.0 +. cost, total.1)
            None -> #(total.0, True)
          }
        }),
      )
    Error(_) -> None
  }
}

fn catalog() -> String {
  settings.home() <> "/models.json"
}

@external(erlang, "albedo_session_cost", "estimate")
fn estimate(catalog: String, rows: List(dynamic.Dynamic)) -> Option(Float)

@external(erlang, "albedo_session_cost", "estimate_sessions")
fn estimate_sessions(
  catalog: String,
  rows: List(dynamic.Dynamic),
) -> Result(List(#(String, Option(Float))), Nil)
