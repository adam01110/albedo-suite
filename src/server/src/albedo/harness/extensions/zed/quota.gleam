//// Zed account quota for the daemon poller.
////
//// A Zed inference account has exactly one reading about itself: account-level
//// edit-prediction usage from `GET /client/users/me`, the identity endpoint the
//// request path already validates against. Hosted-model spend is not here; it
//// needs a separate browser billing session and stays in `/zed-budget`.
////
//// The reading is `plan.usage.edit_predictions`: how many edits were predicted
//// and the plan's limit, which is a count or "unlimited". A count becomes the
//// used percentage the poller records; "unlimited" carries no percentage. No
//// reading carries a window or a reset time, because Zed reports neither, and
//// nothing else is derived from what it does report.

import albedo/harness/usage_feed.{type Report}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/string

/// What the row is called. It names edit predictions, so a reader cannot take
/// it for hosted-model spend.
const label = "Edit predictions"

const limit_id = "edit-predictions"

const scope =
  "Account edit-prediction usage, not hosted-model spend (/zed-budget); Zed reports no window or reset"

/// The suite's feed for provider `zed`. The Zig usage core has no Zed provider,
/// so this reading is Albedo's own; a failure is still a report error, as it is
/// for every provider.
pub fn fetch(credential: json.Json) -> Result(Report, String) {
  fetch_with(credential, read_credential)
}

/// The account reading: the response status and body, or the transport failure.
/// The origin is fixed, because a native credential never goes anywhere else.
@external(erlang, "albedo_zed_quota", "read")
fn read(id: String, access: String) -> Result(#(Int, String), String)

fn read_credential(credential: json.Json) -> Result(#(Int, String), String) {
  let decoder = {
    use id <- decode.field("accountId", decode.string)
    use access <- decode.field("access", decode.string)
    decode.success(#(id, access))
  }
  case json.parse(json.to_string(credential), decoder) {
    Ok(#(id, access)) -> read(id, access)
    Error(_) -> Error("Zed account credential is unavailable")
  }
}

/// The feed over an injectable transport, so the report shape is testable
/// without a live account.
pub fn fetch_with(
  credential: json.Json,
  read: fn(json.Json) -> Result(#(Int, String), String),
) -> Result(Report, String) {
  case read(credential) {
    Error(message) -> Ok(failure(message))
    Ok(#(status, body)) -> Ok(of(status, body))
  }
}

fn of(status: Int, body: String) -> Report {
  case status {
    200 -> report(body)
    401 | 403 ->
      failure(
        "Zed rejected the stored account credential (HTTP "
        <> int.to_string(status)
        <> "); sign in again with /login zed",
      )
    _ if status >= 300 && status < 400 ->
      failure(
        "Zed account service redirected (HTTP "
        <> int.to_string(status)
        <> "); redirects are not followed",
      )
    _ -> failure("Zed account service returned HTTP " <> int.to_string(status))
  }
}

fn report(body: String) -> Report {
  case json.parse(body, usage_at()) {
    Ok(Usage(used, Counted(limit))) if limit > 0 && used >= 0 ->
      counted(used, limit)
    Ok(Usage(_, Counted(_))) ->
      failure(
        "Zed reported edit-prediction usage that is not a count within a positive limit; no percentage is implied",
      )
    Ok(Usage(_, Unlimited)) -> unlimited()
    Error(_) ->
      failure(
        "Zed reported no edit-prediction usage, so no reading is inferred",
      )
  }
}

fn counted(used: Int, limit: Int) -> Report {
  usage_feed.Report(
    None,
    None,
    None,
    [
      usage_feed.Limit(
        limit_id,
        label,
        Some(int.to_float(used) *. 100.0 /. int.to_float(limit)),
        None,
        None,
        None,
        Some(scope),
        "ok",
      ),
    ],
    None,
  )
}

/// An unlimited plan is a reading without a percentage, not a full one.
fn unlimited() -> Report {
  usage_feed.Report(
    None,
    None,
    None,
    [
      usage_feed.Limit(
        limit_id,
        label,
        None,
        None,
        None,
        None,
        Some(scope),
        "unlimited",
      ),
    ],
    None,
  )
}

fn failure(message: String) -> Report {
  usage_feed.Report(None, None, None, [], Some(message))
}

type Usage {
  Usage(used: Int, limit: Cap)
}

type Cap {
  Counted(Int)
  Unlimited
}

/// The reading is nested under plan.usage; a payload without it carries no
/// reading rather than a zero.
fn usage_at() -> decode.Decoder(Usage) {
  decode.at(["plan", "usage", "edit_predictions"], usage())
}

fn usage() -> decode.Decoder(Usage) {
  use used <- decode.field("used", decode.int)
  use limit <- decode.field("limit", cap())
  decode.success(Usage(used, limit))
}

fn cap() -> decode.Decoder(Cap) {
  decode.one_of(cap_text(), or: [decode.map(decode.int, Counted)])
}

fn cap_text() -> decode.Decoder(Cap) {
  decode.then(decode.string, fn(text) {
    case string.trim(text) {
      "unlimited" -> decode.success(Unlimited)
      count ->
        case int.parse(count) {
          Ok(value) -> decode.success(Counted(value))
          Error(_) ->
            decode.failure(
              Unlimited,
              "an edit-prediction limit that is a count or unlimited",
            )
        }
    }
  })
}
