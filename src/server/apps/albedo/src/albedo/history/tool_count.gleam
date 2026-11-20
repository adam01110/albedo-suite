//// The session's committed tool results, for the client's activity counter
//// (albedo-suite). A client attaches with only the newest history page, so it
//// cannot count calls in history it never loaded.

import albedo_sdk/store
import gleam/dynamic/decode
import gleam/option.{type Option}
import sqlight

/// Tool result rows in the session; None when the ledger cannot be read.
/// Matching the packed `ToolOutput` tag at its fixed offset reads a few bytes
/// per row, and unlike a payload search ignores text that mentions the tag.
/// `test/suite_tool_count_test.gleam` pins the offset to the codec.
pub fn total(ledger: store.Store, session: String) -> Option(Int) {
  store.snapshot(ledger, fn(db) {
    store.one(
      db,
      "SELECT COUNT(*) FROM transcript WHERE session=? AND substr(payload,10,11)=CAST('tool_output' AS BLOB)",
      [sqlight.text(session)],
      decode.field(0, decode.int, decode.success),
      "no count",
    )
  })
  |> option.from_result
}
