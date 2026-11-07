import albedo/daemon/store
import albedo/harness/settings
import gleam/dynamic
import gleam/dynamic/decode
import gleam/option.{type Option, None}
import sqlight

/// Estimated USD for every metered request, including summaries and warmups.
/// An unpriced or unmetered request makes the total unknown, not free.
pub fn total(ledger: store.Store, session: String) -> Option(Float) {
  let rows =
    store.snapshot(ledger, fn(db) {
      store.rows(
        db,
        "SELECT provider,model,input_tokens,cached_input_tokens,cache_creation_tokens,cache_write_5m_tokens,cache_write_1h_tokens,output_tokens,COUNT(*) FROM provider_requests WHERE session=? GROUP BY provider,model,input_tokens,cached_input_tokens,cache_creation_tokens,cache_write_5m_tokens,cache_write_1h_tokens,output_tokens",
        [sqlight.text(session)],
        decode.dynamic,
      )
    })
  case rows {
    Ok(rows) -> estimate(settings.home() <> "/models.json", rows)
    Error(_) -> None
  }
}

@external(erlang, "albedo_session_cost", "estimate")
fn estimate(catalog: String, rows: List(dynamic.Dynamic)) -> Option(Float)
