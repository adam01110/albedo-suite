//// Account pools: their order, session affinity, and recorded rate limits.
//// `order` is pure. `arrange` captures time and session affinity around it.

import albedo_clock
import albedo_process/registry.{type Registry}
import albedo_sdk/credential_store
import albedo_sdk/settings_store
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

pub type Entry(account) {
  Entry(value: account, identity: String, selected: Bool, limited_until: Int)
}

/// Order available accounts with selected entries first, then other available
/// entries, then limited entries by earliest expiry. Within the available group,
/// prefer `sticky` identity or rotate deterministically by `session`.
/// `now` and `limited_until` must use the same clock and unit. No I/O occurs.
pub fn order(
  entries: List(Entry(account)),
  session: String,
  sticky: Option(String),
  now: Int,
) -> List(account) {
  let #(limited, open) =
    list.partition(entries, fn(entry) { entry.limited_until > now })
  let #(selected, rest) =
    list.partition(spread(open, session, sticky), fn(entry) { entry.selected })
  let limited =
    list.sort(limited, fn(first, second) {
      int.compare(first.limited_until, second.limited_until)
    })
  list.append(selected, list.append(rest, limited))
  |> list.map(fn(entry) { entry.value })
}

fn spread(
  entries: List(Entry(account)),
  session: String,
  sticky: Option(String),
) -> List(Entry(account)) {
  case entries, sticky {
    [], _ -> []
    _, Some(identity) -> {
      let #(hit, others) =
        list.partition(entries, fn(entry) { entry.identity == identity })
      list.append(hit, others)
    }
    _, None -> {
      let start =
        fingerprint(<<session:utf8>>, 0x811C9DC5) % list.length(entries)
      let #(head, tail) = list.split(entries, start)
      list.append(tail, head)
    }
  }
}

fn fingerprint(bytes: BitArray, hash: Int) -> Int {
  case bytes {
    <<byte, rest:bytes>> ->
      fingerprint(
        rest,
        int.bitwise_and(
          int.bitwise_exclusive_or(hash, byte) * 16_777_619,
          0xFFFFFFFF,
        ),
      )
    _ -> hash
  }
}

// ---- account pools ----------------------------------------------------------
//
// Account pools shared by providers that hold several accounts or keys: the
// order a session tries them in, which one it sticks to, and the limits that
// push it onto a sibling. Accounts are JSON objects. `selected`,
// `limitedUntil`, and `limitedMeters` are the only keys read here. A scope
// names the pool, such as `"codex"`.

/// Order raw accounts for a session. A user-selected account comes first,
/// then the session's sticky or hashed choice. Accounts still inside a
/// reported limit for `meter` go last, soonest reset first. `raw` exposes each
/// account's JSON object. `identity` is called only for an account that can
/// match the session's sticky choice. Accounts that need sign-in or that the
/// user disabled are left out.
pub fn arrange(
  scope: String,
  values: List(account),
  session: String,
  identity: fn(account) -> String,
  raw: fn(account) -> Dynamic,
  meter: Option(String),
) -> List(account) {
  arrange_by(
    credential_store.Automatic,
    scope,
    values,
    session,
    identity,
    raw,
    meter,
  )
}

/// `arrange` for a profile's rotation. `Automatic` keeps the selected and
/// hashed order above. A list rotation keeps the list's order: the session's
/// sticky account first while it is ready, then, for `Failover` and `First`,
/// the other ready accounts in list order, and for `Spread` the ready
/// accounts assigned to a session longest ago first, so each new session
/// starts on the next account. Limited accounts follow, soonest reset first.
pub fn arrange_by(
  rotation: credential_store.Rotation,
  scope: String,
  values: List(account),
  session: String,
  identity: fn(account) -> String,
  raw: fn(account) -> Dynamic,
  meter: Option(String),
) -> List(account) {
  let values =
    list.filter(values, fn(value) {
      let fields = raw(value)
      !signed_out(fields) && !disabled(fields)
    })
  case values {
    [] -> []
    _ -> {
      let now = albedo_clock.system_ms()
      let sticky = sticky(scope, session)
      case rotation {
        credential_store.Automatic -> {
          let entries =
            list.map(values, fn(value) {
              let fields = raw(value)
              let until = until_of(fields, meter)
              let id = case sticky {
                Some(_) if until <= now -> identity(value)
                _ -> ""
              }
              Entry(value, id, flag(fields, "selected"), until)
            })
          order(entries, session, sticky, now)
        }
        _ -> listed(rotation, scope, values, sticky, identity, raw, meter, now)
      }
    }
  }
}

fn listed(
  rotation: credential_store.Rotation,
  scope: String,
  values: List(account),
  sticky: Option(String),
  identity: fn(account) -> String,
  raw: fn(account) -> Dynamic,
  meter: Option(String),
  now: Int,
) -> List(account) {
  let timed =
    list.map(values, fn(value) { #(value, until_of(raw(value), meter)) })
  let #(limited, open) = list.partition(timed, fn(entry) { entry.1 > now })
  let open = list.map(open, fn(entry) { entry.0 })
  let #(hit, others) = case sticky {
    None -> #([], open)
    Some(pinned) ->
      list.partition(open, fn(value) { identity(value) == pinned })
  }
  let others = case rotation {
    credential_store.Spread ->
      others
      |> list.index_map(fn(value, index) {
        #(value, assigned(scope, identity(value)), index)
      })
      |> list.sort(fn(first, second) {
        case int.compare(first.1, second.1) {
          order.Eq -> int.compare(first.2, second.2)
          other -> other
        }
      })
      |> list.map(fn(entry) { entry.0 })
    _ -> others
  }
  let limited =
    list.sort(limited, fn(first, second) { int.compare(first.1, second.1) })
    |> list.map(fn(entry) { entry.0 })
  list.flatten([hit, others, limited])
}

/// Whether a raw account is a sign-in that can no longer be used until it is
/// signed in again.
fn signed_out(value: Dynamic) -> Bool {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> credential_store.needs_sign_in(fields)
    Error(_) -> False
  }
}

/// Whether the user switched a raw account off with `enabled: false`. It
/// stays saved and signed in, but no rotation or pin uses it.
pub fn disabled(value: Dynamic) -> Bool {
  decode.run(value, decode.at(["enabled"], decode.bool)) == Ok(False)
}

/// Stick the session to the account it was just given. The choice is kept
/// for the daemon's lifetime, scoped by provider store and session, so every
/// turn of the session reaches the same account and its prompt cache. A
/// change of account also records when the account was last assigned, which
/// `Spread` reads to start the next session on another account.
pub fn remember(scope: String, session: String, identity: String) -> Nil {
  case sticky(scope, session) == Some(identity) {
    True -> Nil
    False -> {
      registry.register(affinity(), #(scope, session), identity)
      registry.register(assignments(), #(scope, identity), unique_integer())
    }
  }
}

/// Drop every account a session was given, when the session is deleted or
/// closed for good. Without it the affinity table keeps one entry per
/// session and store for the daemon's lifetime.
pub fn forget_session(session: String) -> Nil {
  case table_exists(affinity_table()) {
    True -> {
      let _ =
        match_delete(affinity_table(), #(
          #(atom.create("_"), session),
          atom.create("_"),
        ))
      Nil
    }
    False -> Nil
  }
}

/// Drop the assignment stamps of an account that was signed out, by its
/// provider identity in any store.
pub fn forget_account(identity: String) -> Nil {
  case table_exists(assigned_table()) {
    True -> {
      let _ =
        match_delete(assigned_table(), #(
          #(atom.create("_"), identity),
          atom.create("_"),
        ))
      Nil
    }
    False -> Nil
  }
}

fn table_exists(table: Atom) -> Bool {
  ets_whereis(table) != atom.to_dynamic(atom.create("undefined"))
}

@external(erlang, "ets", "whereis")
fn ets_whereis(table: Atom) -> Dynamic

@external(erlang, "ets", "match_delete")
fn match_delete(table: Atom, pattern: #(#(Atom, String), Atom)) -> Bool

fn sticky(scope: String, session: String) -> Option(String) {
  case registry.lookup(affinity(), #(scope, session)) {
    Ok(identity) if identity != "" -> Some(identity)
    _ -> None
  }
}

/// When an account was last given to a session, as an ordering stamp; 0
/// when never.
fn assigned(scope: String, identity: String) -> Int {
  registry.lookup(assignments(), #(scope, identity))
  |> result.unwrap(0)
}

/// The table `albedo_account_affinity`, from store and session to the
/// account the session was given.
fn affinity() -> Registry(#(String, String), String) {
  registry.new(affinity_table())
}

/// The table `albedo_account_assigned`, from store and account to when the
/// account was last given to a session.
fn assignments() -> Registry(#(String, String), Int) {
  registry.new(assigned_table())
}

fn affinity_table() -> Atom {
  atom.create("albedo_account_affinity")
}

fn assigned_table() -> Atom {
  atom.create("albedo_account_assigned")
}

/// Whether a raw account is inside any recorded limit at `now`.
pub fn limited(value: Dynamic, now: Int) -> Bool {
  until_of(value, None) > now
}

/// When a raw account's limit for `meter` ends, in Unix milliseconds, or 0.
/// `limitedUntil` is a mark no meter was named for, so it limits every meter:
/// a meter's limit is the later of it and the meter's own mark. Without a
/// meter, the latest of all of them.
pub fn until_of(value: Dynamic, meter: Option(String)) -> Int {
  let legacy = integer(value, "limitedUntil") |> result.unwrap(0)
  case meters(value), meter {
    Ok(meters), Some(meter) ->
      dict.get(meters, meter)
      |> result.try(fn(until) {
        decode.run(until, decode.int) |> result.replace_error(Nil)
      })
      |> result.unwrap(0)
      |> int.max(legacy)
    Error(_), Some(_) -> legacy
    Ok(meters), None ->
      dict.values(meters)
      |> list.filter_map(fn(until) { decode.run(until, decode.int) })
      |> list.fold(legacy, int.max)
    Error(_), None -> legacy
  }
}

fn meters(value: Dynamic) -> Result(Dict(String, Dynamic), Nil) {
  decode.run(
    value,
    decode.at(["limitedMeters"], decode.dict(decode.string, decode.dynamic)),
  )
  |> result.replace_error(Nil)
}

fn integer(value: Dynamic, field: String) -> Result(Int, Nil) {
  decode.run(value, decode.at([field], decode.int))
  |> result.replace_error(Nil)
}

fn flag(value: Dynamic, field: String) -> Bool {
  decode.run(value, decode.at([field], decode.bool)) == Ok(True)
}

/// Record `until` on the creds.json accounts under `key` that `hit` matches,
/// under the settings lock, and return every account there, updated. A
/// single stored object stays single. A `meter` mark keeps only the account's
/// other per-meter marks that have not ended.
pub fn mark_exact(
  path: String,
  key: String,
  hit: fn(Dynamic) -> Bool,
  until: Int,
  meter: Option(String),
) -> Result(List(Dynamic), String) {
  settings_store.lock(
    dirname(path),
    fn() {
      case credential_store.accounts(path) {
        Error(_) -> Error("stored credentials are unreadable")
        Ok(data) -> {
          let stored = dict.get(data, key)
          let #(values, single) = case stored {
            Error(_) -> #([], False)
            Ok(stored) ->
              case decode.run(stored, decode.list(decode.dynamic)) {
                Ok(values) -> #(values, False)
                Error(_) -> #([stored], True)
              }
          }
          let now = albedo_clock.system_ms()
          let hits =
            list.map(values, fn(value) {
              case is_object(value) && hit(value) {
                True -> #(update_mark(value, until, meter, now), True)
                False -> #(value, False)
              }
            })
          let updated = list.map(hits, fn(entry) { entry.0 })
          case list.any(hits, fn(entry) { entry.1 }) {
            False -> Error("Account is unavailable or changed")
            True -> {
              let kept = case single, updated {
                True, [one, ..] -> one
                _, _ -> settings_store.to_dynamic(updated)
              }
              case
                updated == values
                || credential_store.put_accounts(
                  path,
                  dict.insert(data, key, kept),
                )
                == Ok(Nil)
              {
                True -> Ok(list.filter(updated, is_object))
                False -> Error("could not record the account limit")
              }
            }
          }
        }
      }
    },
    fn(failure) {
      Error(settings_store.reason(failure, busy: "credential store is busy"))
    },
  )
}

fn is_object(value: Dynamic) -> Bool {
  case decode.run(value, decode.dict(decode.dynamic, decode.dynamic)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn update_mark(
  value: Dynamic,
  until: Int,
  meter: Option(String),
  now: Int,
) -> Dynamic {
  let assert Ok(fields) =
    decode.run(value, decode.dict(decode.string, decode.dynamic))
  case meter {
    None ->
      dict.insert(fields, "limitedUntil", settings_store.to_dynamic(until))
      |> settings_store.to_dynamic
    Some(meter) -> {
      let assert Ok(marks) = case dict.get(fields, "limitedMeters") {
        Error(_) -> Ok(dict.new())
        Ok(marks) ->
          decode.run(marks, decode.dict(decode.string, decode.dynamic))
      }
      let live =
        dict.filter(marks, fn(_, mark) {
          case decode.run(mark, decode.int) {
            Ok(mark) -> mark > now
            Error(_) -> False
          }
        })
        |> dict.insert(meter, settings_store.to_dynamic(until))
      dict.insert(fields, "limitedMeters", settings_store.to_dynamic(live))
      |> settings_store.to_dynamic
    }
  }
}

/// Limits for accounts that do not live in creds.json's accounts, such as
/// profile API keys or the environment. They last as long as the daemon,
/// which outlives any limit short enough to wait on. Recording one drops the
/// limits that have ended.
pub fn note(scope: String, id: String, until: Int) -> Nil {
  let now = albedo_clock.system_ms()
  registry.register(limits(), #(scope, id), until)
  let ended = #(
    #(atom.create("_"), atom.create("$1")),
    [
      #(atom.create("=<"), atom.create("$1"), now),
    ],
    [True],
  )
  let _ = select_delete(limits_table(), [ended])
  Nil
}

/// The limit `note` recorded for this account, or 0.
pub fn noted(scope: String, id: String) -> Int {
  registry.lookup(limits(), #(scope, id))
  |> result.unwrap(0)
}

/// The table `albedo_account_limits`, from scope and account id to when the
/// limit ends.
fn limits() -> Registry(#(String, String), Int) {
  registry.new(limits_table())
}

fn limits_table() -> Atom {
  atom.create("albedo_account_limits")
}

/// Record the account a rotating request last sent to, in the calling
/// process, so the failure it ends with is explained against that account
/// rather than the one it started on.
pub fn served(slot: slot, account: account) -> Nil {
  put(#(atom.create("albedo_accounts"), atom.create("served"), slot), account)
  Nil
}

/// The account `served` last recorded for `slot`, else `first`.
pub fn last_served(slot: slot, first: account) -> account {
  let saved =
    get(#(atom.create("albedo_accounts"), atom.create("served"), slot))
  case saved == atom.to_dynamic(atom.create("undefined")) {
    True -> first
    False -> unsafe_coerce(saved)
  }
}

/// A limit's end as /login shows it: `HH:MM` today, else with the date.
pub fn local_time(ms: Int) -> String {
  let parts = albedo_clock.local_parts(ms)
  let today = albedo_clock.local_parts(albedo_clock.system_ms()).date
  let #(year, month, day) = parts.date
  let #(hour, minute, _) = parts.time
  let time = pad(hour, 2) <> ":" <> pad(minute, 2)
  case parts.date == today {
    True -> time
    False ->
      pad(year, 4) <> "-" <> pad(month, 2) <> "-" <> pad(day, 2) <> " " <> time
  }
}

fn pad(number: Int, width: Int) -> String {
  int.to_string(number) |> string.pad_start(width, "0")
}

@external(erlang, "erlang", "get")
fn get(key: key) -> Dynamic

@external(erlang, "erlang", "put")
fn put(key: key, value: value) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn unsafe_coerce(value: Dynamic) -> a

/// A daemon-wide increasing integer, so two assignments in the same
/// millisecond still order.
fn unique_integer() -> Int {
  unique_monotonic([atom.create("monotonic"), atom.create("positive")])
}

@external(erlang, "erlang", "unique_integer")
fn unique_monotonic(options: List(Atom)) -> Int

@external(erlang, "ets", "select_delete")
fn select_delete(
  table: Atom,
  spec: List(#(#(Atom, Atom), List(#(Atom, Atom, Int)), List(Bool))),
) -> Int

@external(erlang, "filename", "dirname")
fn dirname(path: String) -> String
